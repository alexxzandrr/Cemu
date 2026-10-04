#pragma once

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Phase 1A toolchain probe. Implemented in Objective-C++ so the build proves
/// Swift can call into code compiled as C++20. Replaced by CemuBridge later.
@interface BuildInfo : NSObject
+ (NSString*)summary;
@end

NS_ASSUME_NONNULL_END
