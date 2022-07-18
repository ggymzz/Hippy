/*!
 * iOS SDK
 *
 * Tencent is pleased to support the open source community by making
 * NativeRender available.
 *
 * Copyright (C) 2019 THL A29 Limited, a Tencent company.
 * All rights reserved.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *   http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

#import <UIKit/UIKit.h>
#import "NativeRenderModalHostViewInteractor.h"

@class NativeRenderModalHostView;
@class NativeRenderModalHostViewController;

@protocol NativeRenderModalHostViewInteractor;
typedef void (^NativeRenderModalViewInteractionBlock)(
    UIViewController *hippyViewController, UIViewController *viewController, BOOL animated, dispatch_block_t completionBlock);

@interface NativeRenderModalTransitioningDelegate : NSObject <NativeRenderModalHostViewInteractor, UIViewControllerTransitioningDelegate>
/**
 * `presentationBlock` and `dismissalBlock` allow you to control how a Modal interacts with your case,
 * e.g. in case you have a native navigator that has its own way to display a modal.
 * If these are not specified, it falls back to the UIViewController standard way of presenting.
 */
@property (nonatomic, strong) NativeRenderModalViewInteractionBlock presentationBlock;
@property (nonatomic, strong) NativeRenderModalViewInteractionBlock dismissalBlock;

- (void)presentModalHostView:(NativeRenderModalHostView *)modalHostView
          withViewController:(NativeRenderModalHostViewController *)viewController
                    animated:(BOOL)animated;
- (void)dismissModalHostView:(NativeRenderModalHostView *)modalHostView
          withViewController:(NativeRenderModalHostViewController *)viewController
                    animated:(BOOL)animated;

@end