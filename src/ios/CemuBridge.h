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

/// Hands a user-selected Wii U title to Cemu's existing title-loading/boot path
/// (TitleInfo -> CafeTitleList -> CafeSystem::PrepareForegroundTitle -> CafeSystem::LaunchForegroundTitle).
/// `url` comes from the Files picker and may be security-scoped; access is held for the rest of the session
/// and a bookmark is saved so the title can be reopened next launch.
/// Accepts a title root folder (code/content/meta), a .wua / .wud / .wux / .wuhb file, or a standalone .rpx / .elf.
/// Blocking (identification + mounting); call off the main thread. Requires core and renderer.
/// Returns the title name. One title per app session.
- (nullable NSString *)launchTitleAtURL:(NSURL *)url error:(NSError **)error;

/// The title selected in a previous session (resolved from its saved bookmark), or nil.
@property (nonatomic, readonly, nullable) NSURL *savedTitleURL;

/// YES once a title was handed to CafeSystem::LaunchForegroundTitle in this session.
@property (nonatomic, readonly) BOOL titleLaunched;

/// Tears down the renderer and CafeSystem and flushes the logs.
/// Not supported while a title is running (Phase 2A); in that case it only logs.
- (void)shutdown;

/// Writes an app-side event into WiiPad.log.
- (void)log:(NSString *)message;

@end

NS_ASSUME_NONNULL_END
