// CemuBridge: the only interface between the WiiPad SwiftUI app and the Cemu core.
// Plain Objective-C on purpose: no C++ or Cemu types are visible to Swift.

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/// Wii U GamePad buttons for the on-screen controls (order matches WiiPadInput::Button).
typedef NS_ENUM(NSInteger, WiiPadButton) {
    // explicit Swift names: the importer's prefix stripping is ambiguous for single-letter cases
    WiiPadButtonA NS_SWIFT_NAME(a),
    WiiPadButtonB NS_SWIFT_NAME(b),
    WiiPadButtonX NS_SWIFT_NAME(x),
    WiiPadButtonY NS_SWIFT_NAME(y),
    WiiPadButtonL NS_SWIFT_NAME(l),
    WiiPadButtonR NS_SWIFT_NAME(r),
    WiiPadButtonZL NS_SWIFT_NAME(zl),
    WiiPadButtonZR NS_SWIFT_NAME(zr),
    WiiPadButtonPlus NS_SWIFT_NAME(plus),
    WiiPadButtonMinus NS_SWIFT_NAME(minus),
    WiiPadButtonUp NS_SWIFT_NAME(up),
    WiiPadButtonDown NS_SWIFT_NAME(down),
    WiiPadButtonLeft NS_SWIFT_NAME(left),
    WiiPadButtonRight NS_SWIFT_NAME(right),
    WiiPadButtonStickL NS_SWIFT_NAME(stickL),
    WiiPadButtonStickR NS_SWIFT_NAME(stickR),
    /// Shows the GamePad screen in the game view while held (Cemu's VPAD "screen" mapping).
    WiiPadButtonScreen NS_SWIFT_NAME(screen),
};

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

/// Call when the view passed to initializeRendererInView: changes size (layout, rotation, Split View). Updates
/// Cemu's window size (output scaling, touch mapping) and the CAMetalLayer drawable, like the desktop window's
/// resize handlers. Main thread only; no-op before the renderer exists or when the size is unchanged.
- (void)gameViewDidResize:(UIView *)view;

// --- Performance, pause, library (Phase 5) ---

/// Output resolution as a fraction of the screen's pixels (0.4 ... 1.0, default 1.0). Applies to the TV and GamePad
/// views right away. The game itself still renders at its own resolution; this sets the size of the final image (less
/// GPU work and memory traffic per frame: cooler, longer battery). Not stored: the app passes its setting in. Main thread.
@property (nonatomic) float outputScale;

/// Frames the game has presented so far (Cemu's swap counter). Sample twice to get frames per second.
@property (nonatomic, readonly) NSUInteger presentedFrameCount;

/// Pauses the running title (suspends its threads, stops the audio). `reason` goes to WiiPad.log. NO if nothing runs
/// or it is already paused.
- (BOOL)pauseTitle:(NSString *)reason;
/// Undoes pauseTitle:.
- (BOOL)resumeTitle:(NSString *)reason;
@property (nonatomic, readonly) BOOL titlePaused;

/// Reads a title's name, title ID and icon (meta/iconTex.tga, as PNG) without launching it, for the game library.
/// Keys: "name" (NSString), "titleId" (NSString, 16 hex digits), "icon" (NSData PNG, may be missing). nil if `url` is
/// not a Wii U title. Requires initializeCore. Blocking (mounts the title); call off the main thread.
- (nullable NSDictionary<NSString *, id> *)inspectTitleAtURL:(NSURL *)url;

// --- Separate GamePad screen (dual-screen layouts, iPhone Duo). Main thread only. ---

/// Shows the GamePad (DRC) screen in its own view, like Cemu's desktop "separate GamePad view" window: Cemu then draws
/// the TV image in the game view and the GamePad image here, every frame. No-op before the renderer exists or when
/// already attached to `view`.
- (void)attachGamePadView:(UIView *)view;
/// Closes the separate GamePad screen; the GamePad image is only reachable through the "screen" button again.
- (void)detachGamePadView;
/// YES while a GamePad view is attached.
@property (nonatomic, readonly) BOOL gamePadViewAttached;
/// Call when the attached GamePad view changes size.
- (void)gamePadViewDidResize:(UIView *)view;
/// Touch on the GamePad view, normalized to [0, 1] with a top-left origin. Becomes GamePad touchscreen input.
- (void)setGamePadViewTouchDown:(BOOL)down x:(float)x y:(float)y;

/// Hands a user-selected Wii U title to Cemu's existing title-loading/boot path
/// (TitleInfo -> CafeTitleList -> CafeSystem::PrepareForegroundTitle -> CafeSystem::LaunchForegroundTitle).
/// `url` comes from the Files picker and may be security-scoped; access is held for the rest of the session
/// and a bookmark is saved so the title can be reopened next launch.
/// Accepts a title root folder (code/content/meta), a .wua / .wud / .wux / .wuhb file, or a standalone .rpx / .elf.
/// Blocking (identification + mounting); call off the main thread. Requires core and renderer.
/// Returns the title name. One title per app session.
- (nullable NSString *)launchTitleAtURL:(NSURL *)url error:(NSError **)error;

/// Run the three Wii U cores on three host threads (multi-core recompiler with JIT, otherwise Cemu's multi-core
/// interpreter, desktop --force-multicore-interpreter) instead of time-slicing them on one. Read when a title is
/// launched; stored across launches.
@property (nonatomic) BOOL multicoreCPU;

/// Cemu's "async shader compile" option (default YES). NO: emulation waits for each new shader instead of skipping the
/// draw until it is compiled, so nothing pops in but new scenes hitch. Read when a title is launched; stored across launches.
@property (nonatomic) BOOL asyncShaderCompile;

/// The title selected in a previous session (resolved from its saved bookmark), or nil.
@property (nonatomic, readonly, nullable) NSURL *savedTitleURL;

/// YES once a title was handed to CafeSystem::LaunchForegroundTitle in this session.
@property (nonatomic, readonly) BOOL titleLaunched;

/// Tears down the renderer and CafeSystem and flushes the logs.
/// Not supported while a title is running (Phase 2A); in that case it only logs.
- (void)shutdown;

// --- GamePad input (Phase 2B). Cheap and thread-safe; call from the main thread on every touch change. ---

/// Press or release a GamePad button.
- (void)setGamePadButton:(WiiPadButton)button pressed:(BOOL)pressed;
/// Stick position, x and y in [-1, 1] with y up positive. stick 0 = left, 1 = right.
- (void)setGamePadStick:(NSInteger)stick x:(float)x y:(float)y;
/// Touch on the game view, position normalized to [0, 1] with a top-left origin. Becomes GamePad touchscreen input.
- (void)setGameViewTouchDown:(BOOL)down x:(float)x y:(float)y;

/// Resets GamePad motion (iPad gyroscope/accelerometer): the current pose becomes the starting pose.
- (void)recenterMotion;

// --- JIT (Phase 3, WiiPadJIT). Independent of the core; enable before launching a title. ---

/// One line: JIT state (arena size and use), or signing and debugger state while JIT is off.
@property (nonatomic, readonly) NSString *jitStatus;
/// YES once a debugger is attached (CS_DEBUGGED; stays set after the detach).
@property (nonatomic, readonly) BOOL jitDebuggerAttached;
/// YES once the JIT code arena is ready (this app session).
@property (nonatomic, readonly) BOOL jitReady;
/// With StikDebug attached: prepares the executable code arena, self-tests it and detaches the debugger.
/// Blocking; call off the main thread. Returns a short result line; details in WiiPad.log ("jit:" lines).
- (NSString *)enableJIT;
/// Use Cemu's recompiler when JIT is enabled (default YES). Read when a title is launched; stored across launches.
@property (nonatomic) BOOL useJIT;

/// Writes an app-side event into WiiPad.log.
- (void)log:(NSString *)message;

@end

NS_ASSUME_NONNULL_END
