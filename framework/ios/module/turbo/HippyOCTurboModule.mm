/*
 *
 * Tencent is pleased to support the open source community by making
 * Hippy available.
 *
 * Copyright (C) 2021 THL A29 Limited, a Tencent company.
 * All rights reserved.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 *
 */

#import "HippyAssert.h"
#import "HippyLog.h"
#import "HippyModuleMethod.h"
#import "NSObject+HippyTurbo.h"
#import "HippyJSExecutor.h"
#import "HippyOCTurboModule.h"
#import "HippyTurboModuleManager.h"
#import "NativeRenderUtils.h"
#import "NSObject+CtxValue.h"
#import "NSObject+HippyTurbo.h"

#include "objc/message.h"
#include "footstone/string_view_utils.h"
#include "driver/napi/js_native_turbo.h"


using namespace hippy;
using namespace napi;

using string_view = footstone::stringview::string_view;
using StringViewUtils = footstone::stringview::StringViewUtils;

@interface HippyOCTurboModule () {
    std::shared_ptr<HippyTurboModule> _turboModule;

}
@property(nonatomic, weak, readwrite) HippyBridge *bridge;
@end

@implementation HippyOCTurboModule

HIPPY_EXPORT_TURBO_MODULE(HippyOCTurboModule)

- (void)dealloc {
    _turboModule->callback_ = nullptr;
    _turboModule = nullptr;
}

- (instancetype)initWithName:(NSString *)moduleName bridge:(HippyBridge *)bridge {
    if (self = [self init]) {
        _bridge = bridge;
        _turboModule = std::make_shared<HippyTurboModule>(std::string([moduleName UTF8String]));

        __weak HippyOCTurboModule *weakSelf = self;
        _turboModule->callback_ = [weakSelf](const TurboEnv& env,
                                             const std::shared_ptr<napi::CtxValue> &thisVal,
                                             const std::shared_ptr<napi::CtxValue> *args,
                                             size_t count) -> std::shared_ptr<napi::CtxValue> {
            std::shared_ptr<napi::Ctx> context = env.context_;

            // get method name
            string_view name;
            if (!context->GetValueString(thisVal, &name)) {
                return context->CreateNull();
            }
            std::string methodName = StringViewUtils::ToStdString(StringViewUtils::ConvertEncoding(name, string_view::Encoding::Utf8).utf8_value());
            // get argument
            NSInteger argumentCount = static_cast<long>(count);
            NSMutableArray *argumentArray = @[].mutableCopy;
            for (NSInteger i = 0; i < argumentCount; i++) {
                std::shared_ptr<napi::CtxValue> ctxValue = *(args + i);
                [argumentArray addObject:convertCtxValueToObjcObject(context, ctxValue, weakSelf)?: [NSNull null]];
            }

            id objcRes = [weakSelf invokeObjCMethodWithName:[NSString stringWithUTF8String:methodName.c_str()]
                                              argumentCount:argumentCount
                                              argumentArray:argumentArray];
            std::shared_ptr<napi::CtxValue> result = convertObjcObjectToCtxValue(context, objcRes, weakSelf);
            return result;
        };
    }
    return self;
}

- (std::shared_ptr<HippyTurboModule>)getTurboModule {
    return _turboModule;
}

- (id)invokeObjCMethodWithName:(NSString *)methodName
                 argumentCount:(NSInteger)argumentCount
                 argumentArray:(NSArray *)argumentArray {
    return [self invokeObjCMethodWithName:methodName
                            argumentCount:argumentCount
                            argumentArray:argumentArray
                                   object:self];
}

- (id)invokeObjCMethodWithName:(NSString *)methodName
                 argumentCount:(NSInteger)argumentCount
                 argumentArray:(NSArray *)argumentArray
                        object:(NSObject *)obj {
    NSArray<id<HippyBridgeMethod>> *moduleMethods = [obj hippyTurboModuleMethods];
    id<HippyBridgeMethod> method;
    for (id<HippyBridgeMethod> m in moduleMethods) {
        if ([m.JSMethodName isEqualToString:methodName]) {
            method = m;
            break;
        }
    }

    if (HIPPY_DEBUG && !method) {
        HippyLogError(@"Unknown methodID: %@ for module:%@", methodName, obj);
        return nil;
    }

    @try {
        id value = [method invokeWithBridge:_bridge module:obj arguments:argumentArray];
        return value;
    } @catch (NSException *exception) {
        // Pass on JS exceptions
        if ([exception.name hasPrefix:HippyFatalExceptionName]) {
            @throw exception;
        }

        NSString *message = [NSString stringWithFormat:@"Exception '%@' was thrown while invoking %@ on target %@ with params %@", exception,
                                      method.JSMethodName, NSStringFromClass([self class]) ,argumentArray];
        NSError *error = NativeRenderErrorWithMessageAndModuleName(message, self.bridge.moduleName);
        HippyFatal(error, self.bridge);
        return nil;
    }
}

#pragma mark -

static std::shared_ptr<napi::CtxValue> convertObjcObjectToCtxValue(const std::shared_ptr<napi::Ctx> &context,
                                                                   id objcObject,
                                                                   HippyOCTurboModule *module) {

    std::shared_ptr<napi::CtxValue> result;

    if ([objcObject isKindOfClass:[NSString class]]) {
        result = context->CreateString([((NSString *)objcObject) UTF8String]);
    } else if ([objcObject isKindOfClass:[NSNumber class]]) {
      if ([objcObject isKindOfClass:[@YES class]]) {
          result = context->CreateBoolean(((NSNumber *)objcObject).boolValue);
      } else {
          result = context->CreateNumber(((NSNumber *)objcObject).doubleValue);
      }
    } else if ([objcObject isKindOfClass:[NSDictionary class]]) {
        result = convertNSDictionaryToCtxValue(context, objcObject, module);
    } else if ([objcObject isKindOfClass:[NSArray class]]) {
        result = convertNSArrayToCtxValue(context, objcObject, module);
    } else if ([objcObject isKindOfClass:[NSObject class]]) {
        result = convertNSObjectToCtxValue(context, objcObject, module);
    } else {
        result = context->CreateNull();
    }
    return result;
}

static std::shared_ptr<napi::CtxValue> convertNSDictionaryToCtxValue(const std::shared_ptr<napi::Ctx> &context,
                                                                     NSDictionary *dict,
                                                                     HippyOCTurboModule *module) {
    if (!dict) {
        return context->CreateNull();
    }
    return [dict convertToCtxValue:context];
}

static std::shared_ptr<napi::CtxValue> convertNSArrayToCtxValue(const std::shared_ptr<napi::Ctx> &context,
                                                                NSArray *array,
                                                                HippyOCTurboModule *module) {
    if (!array) {
        return context->CreateNull();
    }

    size_t size = static_cast<size_t>(array.count);
    std::shared_ptr<napi::CtxValue> buffer[size];
    for (size_t idx = 0; idx < array.count; idx++) {
        buffer[idx] = convertObjcObjectToCtxValue(context, array[idx], module);
    }
    return context->CreateArray(size, buffer);
}

static std::shared_ptr<napi::CtxValue> convertNSObjectToCtxValue(const std::shared_ptr<napi::Ctx> &context,
                                                                id objcObject,
                                                                HippyOCTurboModule *module) {
    HippyJSExecutor *jsExecutor = (HippyJSExecutor *)module.bridge.javaScriptExecutor;
    if ([objcObject isKindOfClass:[HippyOCTurboModule class]]) {
        NSString *name = [[objcObject class] turoboModuleName];
        std::shared_ptr<hippy::napi::CtxValue> value = [jsExecutor JSTurboObjectWithName:name];
        HippyTurboModuleManager *turboManager = module.bridge.turboModuleManager;
        [turboManager bindJSObject:value toModuleName:name];
        return value;
    }
    return context->CreateNull();
}

#pragma mark -

/// null & undefined : nil
/// bool * number    : NSNumber
/// string           : NSString
/// array            : NSArray
/// function         : HippyResponseSenderBlock
/// object           : NSDictionary
/// JSON             : NSArray & NSDictionary

static id convertCtxValueToObjcObject(const std::shared_ptr<napi::Ctx> &context,
                                      const std::shared_ptr<napi::CtxValue> &value,
                                      HippyOCTurboModule *module) {
    id objcObject;
    double numberResult;
    bool boolResult;
    string_view result;

    if (context->IsNullOrUndefined(value)) {
        objcObject = nil;
    } else if (context->GetValueNumber(value, &numberResult)) {
        objcObject = @(numberResult);
    } else if (context->GetValueBoolean(value, &boolResult)) {
        objcObject = @(boolResult);
    } else if (context->GetValueString(value, &result)) {
        std::string resultStr = StringViewUtils::ToStdString(StringViewUtils::ConvertEncoding(result, string_view::Encoding::Utf8).utf8_value());
        objcObject = [NSString stringWithUTF8String:resultStr.c_str()];
    } else if (context->IsObject(value)) {
        if (context->IsArray(value)) {
            objcObject = convertJSIArrayToNSArray(context, value, module);
        } else if (context->IsFunction(value)) {
            objcObject = @(0);
        } else {
            objcObject = convertJSIObjectToTurboObject(context, value, module);
            if (!objcObject) {
                //map
                objcObject = convertJSIObjectToNSDictionary(context, value, module);
            }
        }
    } else if (context->GetValueJson(value, &result)) {
        objcObject = convertJSIObjectToNSObject(context, value);
    }
    return objcObject;
}

static id convertJSIObjectToNSObject(const std::shared_ptr<napi::Ctx> &context,
                                     const std::shared_ptr<napi::CtxValue> &value) {
    string_view result;
    if (!context->GetValueJson(value, &result)) {
        return nil;
    }
    std::string resultStr = StringViewUtils::ToStdString(StringViewUtils::ConvertEncoding(result, string_view::Encoding::Utf8).utf8_value());
    NSString *jsonString = [NSString stringWithCString:resultStr.c_str() encoding:[NSString defaultCStringEncoding]];
    NSData *data = [jsonString dataUsingEncoding:NSUTF8StringEncoding];
    NSError *error;
    id objcObject = [NSJSONSerialization JSONObjectWithData:data options:0 error:&error];
    if (error) {
        HippyLogError(@"JSONObjectWithData error:%@", error);
    }
    return objcObject;
}

static NSArray *convertJSIArrayToNSArray(const std::shared_ptr<napi::Ctx> &context,
                                         const std::shared_ptr<napi::CtxValue> &value,
                                         HippyOCTurboModule *module) {
    size_t length = context->GetArrayLength(value);
    NSMutableArray *result = [NSMutableArray new];
    for (uint32_t i = 0; i < length; i++) {
        std::shared_ptr<napi::CtxValue> v = context->CopyArrayElement(value, i);
        [result addObject:convertCtxValueToObjcObject(context, v, module) ?: [NSNull null]];
    }
    return [result copy];
}

static NSObject *convertJSIObjectToTurboObject(const std::shared_ptr<napi::Ctx> &context,
                                               const std::shared_ptr<napi::CtxValue> &value,
                                               HippyOCTurboModule *module) {
    HippyTurboModuleManager *turboManager = module.bridge.turboModuleManager;
    NSString *moduleNameStr = [turboManager turboModuleNameForJSObject:value];
    if (moduleNameStr) {
        HippyOCTurboModule *turboModule = [module.bridge turboModuleWithName:moduleNameStr];
        return turboModule;
    }
    return nil;
}

static NSDictionary *convertJSIObjectToNSDictionary(const std::shared_ptr<napi::Ctx> &context,
                                                    const std::shared_ptr<napi::CtxValue> &value,
                                                    HippyOCTurboModule *module) {
    if (!context->IsObject(value)) {
        return nil;
    }
    std::unordered_map<string_view, std::shared_ptr<hippy::CtxValue>> map;
    if (!context->GetEntriesFromObject(value, map)) {
        return nil;
    }
    NSMutableDictionary *result = [[NSMutableDictionary alloc] initWithCapacity:map.size()];
    for (const auto &entry : map) {
        const auto &key = entry.first;
        const auto &value = entry.second;
        std::u16string u16Key = StringViewUtils::ConvertEncoding(key, string_view::Encoding::Utf16).utf16_value();
        NSString *stringKey = [NSString stringWithCharacters:(const unichar*)u16Key.c_str() length:(u16Key.length())];
        id objValue = convertCtxValueToObjcObject(context, value, module);
        [result setObject:objValue forKey:stringKey];
    }
    return [result copy];
}

@end