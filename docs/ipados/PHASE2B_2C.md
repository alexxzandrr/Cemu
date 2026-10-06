# Phase 2B + 2C — GamePad input and TV audio

Branch `phase2`, from the Phase 2A checkpoint `2e4623c`. Boot path, interpreter and renderer unchanged.

## 2B — Input

### Cemu's existing path (reused)

```
game VPADRead(0)                                   Cafe/OS/libs/vpad/vpad.cpp
 └ InputManager::get_vpad_controller(0)            input/InputManager.cpp   ("connected" = a VPAD exists in slot 0;
 └ VPADController::VPADRead                        input/emulated/            channel 0 is always reported connected)
    ├ controllers_update_states → ControllerBase::update_state → raw_state()   (each attached input device)
    ├ mappings: Wii U button id → device button (kButtonId_A → kButton0, kButtonId_StickL_Up → kAxisYP, ...)
    │   → status.hold/trig/release, leftStick, rightStick (ZL/ZR are digital on the GamePad)
    ├ kButtonId_Screen (no Wii U flag) → is_screen_active() → GamePad image shown in the main view
    └ update_touch → InputManager::get_left_down_mouse_info (m_main_touch / m_main_mouse, window pixels)
        → LatteRenderTarget_getScreenImageArea → Wii U touch coordinates (x*3883+92, 4095-y*3694-254)
```

### WiiPad integration

| Piece | What |
| --- | --- |
| `src/ios/WiiPadTouchController.cpp` | `ControllerBase` subclass (API `WiiPadTouch`). `raw_state()` reads lock-free atomics written by the UI. Set as the VPAD (player 1, slot 0) with fixed mappings before launch. |
| touchscreen | game-view touches → `InputManager::m_main_touch` (same as desktop `MainWindow::OnGesturePan`), in the view's physical pixels |
| `src/input/api/InputAPI.h` | `WiiPadTouch` enum value + name, `#if BOOST_OS_IOS` only |
| `src/ios/CemuBridge.h/.mm` | `setGamePadButton:pressed:`, `setGamePadStick:x:y:`, `setGameViewTouchDown:x:y:`; GamePad connected in `launchTitleAtURL` |
| `app/WiiPad/Sources/GamePadControls.swift` | on-screen ZL/L, left stick, D-pad, −; R/ZR, X/A/B/Y, right stick, +; "Pad view" (holds the VPAD screen mapping) |
| `app/WiiPad/Sources/ContentView.swift` | controls beside the game view while a title runs; `GameSurfaceView` forwards touches |

Not included: motion (needs a motion source; Cemu's fallback is right-mouse-drag), Home (Cemu has no GamePad HOME
Menu: the VPAD Home mapping has no effect), microphone, hardware controllers/keyboards, multi-touch on the game view.

## 2C — Audio

### Cemu's existing path

`snd_core::AXOut_init` → `IAudioAPI::CreateDeviceFromConfig(TV, 48000, 576 frames/block, 16-bit)` using
`config.audio_api` + `tv_device` ("default"). Game audio: `AIInitDMA` → `g_tvAudio->FeedBlock()` (interleaved
s16, channels from `tv_channels`, stereo by default); `AXOut_update` → `Play()` / `NeedAdditionalBlocks()`.
GamePad audio uses `pad_device`, empty by default (also off on desktop until configured).

### Why not Cubeb

Cubeb was turned off in Phase 1B to keep dependencies small. Re-enabling it is not viable without patching the
submodule: Cemu's pinned Cubeb (`2071354`) AudioUnit backend calls macOS-only Core Audio APIs outside its
`TARGET_OS_IPHONE` guards (`AudioObjectGetPropertyData` on the system object, aggregate-device creation via
`kAudioPlugInCreateAggregateDevice`), `cubeb_osx_run_loop.cpp` uses the macOS HAL run-loop property, and its CMake
links `CoreServices` (not on iOS).

### WiiPad backend

| Piece | What |
| --- | --- |
| `src/ios/IOSAudioAPI.h/.mm` | `IAudioAPI` backend: RemoteIO AudioUnit, `AVAudioSession` category Playback, s16 interleaved input; queue + render callback as in `CubebAPI`; config volume applied in the callback |
| `src/audio/IAudioAPI.h/.cpp` | `AudioUnitIOS` enum value, registration, create, device list, log line, `#if BOOST_OS_IOS` only |
| `src/ios/CemuBridge.mm` | after `CemuCommonInit` (which loads the config): `audio_api = AudioUnitIOS`, `tv_device = "default"` (in memory) |
| `app/WiiPad/project.yml` | links `AudioToolbox`, `AVFAudio` |

## Log lines (`WiiPad.log`)

- `audio: backend initialized (...)`, `audio: TV output -> AudioUnit (iOS) ...`, `audio: stream created (...)`,
  `audio: output started`, `audio: first samples submitted by the game (TV)`,
  `audio: first game samples played by the audio device`, `audio: device error: ...`
- `input: Wii U GamePad connected (...)`, `input: game is reading the GamePad (...)`,
  `input: buttons reaching Cemu: A+ZR`, `input: left stick moved (x, y)` / `released`,
  `input: touch down at (x, y) px ...` / `touch released`

Logged on change only (no per-frame lines); the audio thread itself never logs.

## Known limitations

- No motion controls, no Home, no microphone, no hardware controllers.
- GamePad (DRC) audio is not output (no `pad_device`, Cemu's default); TV audio only.
- Audio does not resume after an interruption (phone call, Siri); restart WiiPad.
- Landscape only for the controls (they sit beside the 480×270 game view).
- Touch maps to whichever screen the game view shows; use "Pad view" so touches line up with the GamePad screen.

## Investigation: title stays on the loading screen (471c9db)

Device run: `PPC scheduler started`, then nothing: no `GX2Init`, no frames, no `VPADRead`, no audio samples
(5-minute monitor: `GPU init yes, GX2Init calls 0, frames 0`). The image that stays on screen is Cemu's own
shader-cache loading screen (`bootTvTex.tga` / `bootDRCTex.tga` from the title's `meta`, drawn by the GPU thread),
not game output: the game's code has not reached `GX2Init()`.

Diagnostic-only instrumentation (`src/ios/WiiPadDiagnostics.h/.mm`, lines prefixed `diag:`):

- heartbeat every 2 s (first 30 s), then every 10 s: CPU time used by the `OSSched[core=0]` (PPC interpreter) and
  `LatteThread` host threads with their run state; `sched events` = `AXOut_update` calls from the PPC scheduler's idle
  loop (`__OSCheckSystemEvents`); `VPADRead` count; `GX2Init` / flip counters; audio `Play`, `FeedBlock` and render
  callback counts with last-hit times
- snapshots at +3/15/60/180/600 s: every host thread (name, run state, CPU time, BUSY if > 50 % of a core) with a
  frame-pointer backtrace of the emulation, GPU, input and audio threads (and any busy thread); every emulated PPC
  thread (state, priority, suspend count, waited-on mutex/queue, saved PC/LR with RPL symbol), copied under
  `__OSTryLockScheduler` (never a blocking lock)
- once, at the first snapshot: the measured PPC timer frequency, and a `ucontext` self-test (`getcontext` /
  `makecontext` / `swapcontext` on the monitor thread with its own stack). Cemu's `FiberUnix.cpp` runs the scheduler
  idle loop and every PPC thread on these calls without checking their results: if they are unsupported,
  `Fiber::Switch` returns immediately and `OSSchedulerCoreEmulationThread` exits without running any guest code.

### Result (diagnostic build 5886164, device run)

- `diag: fiber self-test: getcontext -> -1 (errno 45 Operation not supported)`
- no `OSSched[core=0]` host thread in any snapshot; the PPC scheduler lock is never free; `sched events`, `VPADRead`,
  `GX2Init`, flips and audio counters stay 0; PPC timer frequency correct (~1 GHz)

Cause: `OSSchedulerCoreEmulationThread` takes the scheduler lock and calls `Fiber::Switch` to the idle-loop fiber;
with ucontext unsupported the switch returns at once, the thread falls through to "returned from scheduler loop" and
exits while holding the lock. No guest code ever runs (also true for the Phase 2A builds). Input and audio were not
involved.

### Fix: `src/ios/FiberIOS.cpp`

`util/Fiber/Fiber.h` implemented with Boost.Context `make_fcontext` / `jump_fcontext` (vcpkg `boost-context`, arm64
Mach-O assembly). Same interface and semantics as `FiberUnix.cpp` (2 MB stack per fiber, `Switch`, thread-local current
fiber, `GetFiberPrivateData`). `src/util/CMakeLists.txt` skips `FiberUnix.cpp` when `CEMU_IOS`; desktop unchanged.
The diagnostics add a self-test of Cemu's `Fiber` on the monitor thread
(`diag: fiber self-test (Cemu Fiber, Boost.Context): ... OK`).

### Follow-up: SIGSEGV in `FiberTrampoline` (60f82ea)

The game started running, then crashed at the first PPC thread fiber: fault address `0x0e76c000_16c9c688`. Under
`__arm64__`, coreinit declares `__OSFiberThreadEntry(uint32 high, uint32 low)` and rebuilds its `OSHostThread*` from the
two halves, matching `FiberUnix.cpp`, which passes the parameter to `makecontext()` split in two. The first
`FiberIOS.cpp` passed the pointer whole, so the entry rebuilt `(low32 << 32) | garbage`. The trampoline now uses the
same split convention on arm64 (no coreinit change). The scheduler idle-loop fiber ignores its parameter, which is why
it ran. The self-test now passes a real pointer and checks it arrives intact.

### Multi-core interpreter crash (77111cd .. 5c21e08) and fix

iOS crash report: `EXC_BAD_ACCESS` executing `0x70104054c8`, termination CODESIGNING "Invalid Page", on
`OSSched[core=2]`; `jump_fcontext` restored a stale context. The FiberIOS ownership check (5c21e08) then reported the
cause directly: core 2's guest-thread fiber switched **to itself**. In multi-core mode `__OSThreadSwitchToNext` on a
non-main core re-queues the current thread and can pick it again. With ucontext (`swapcontext(ctx, ctx)`) that is
effectively a no-op; with `jump_fcontext` it jumps to the fiber's stale context from its previous suspension. Fix:
`Fiber::Switch` returns immediately when the target is the current fiber. Not an upstream or iOS API issue.
