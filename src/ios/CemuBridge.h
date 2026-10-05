// CemuBridge: the only interface between the WiiPad SwiftUI app and the Cemu core.
// Plain Objective-C on purpose: no C++ or Cemu types are visible to Swift.

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface CemuBridge : NSObject

@property (class, nonatomic, readonly) CemuBridge *shared;

/// Documents/WiiPad.log (visible in the Files app under On My iPad > WiiPad).
@property (nonatomic, readonly) NSString *logPath;

@property (nonatomic, readonly) BOOL coreInitialized;
@property (nonatomic, readonly) BOOL rendererInitialized;

- (instancetype)init NS_UNAVAILABLE;

/// Sets up paths and default files, then runs CemuCommonInit() (config, audio, input,
/// graphic packs, CafeSystem incl. the Wii U memory space). Blocking; call off the main thread.
- (BOOL)initializeCoreWithError:(NSError **)error;

/// Creates the Metal renderer and attaches its CAMetalLayer to `view`. Main thread only.
/// Requires initializeCore first.
- (BOOL)initializeRendererInView:(UIView *)view error:(NSError **)error;

/// Tears down the renderer and CafeSystem and flushes the logs.
- (void)shutdown;

/// Writes an app-side event into WiiPad.log.
- (void)log:(NSString *)message;

@end

NS_ASSUME_NONNULL_END
