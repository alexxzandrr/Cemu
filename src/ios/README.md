# src/ios — WiiPad (Cemu for iPadOS) platform layer

Built only when CMake is configured with `-DCMAKE_SYSTEM_NAME=iOS` (see `src/CMakeLists.txt`).

| File | Role |
| --- | --- |
| `CemuBridge.h/.mm` | The only API the SwiftUI app uses. `CemuBridge.h` is plain Objective-C (no C++/Cemu types). |
| `IOSWindowSystem.mm` | iPadOS implementation of `gui/interface/WindowSystem.h` (desktop: `wxgui/wxWindowSystem.cpp`). |
| `MetalLayerUIKit.mm` | UIKit `CreateMetalLayer()` (desktop: `Cafe/HW/Latte/Renderer/Metal/MetalLayer.mm`). |
| `WiiPadLog.h/.mm` | Crash-safe log at `Documents/WiiPad.log`, stdout/stderr capture, fatal signal + `std::terminate` handlers (both chain to the previous handler), crash logs kept as `*.crash.*`. |
| `WiiPadTouchController.h/.cpp` | On-screen controls as a Cemu input device (`ControllerBase`), attached to the emulated Wii U GamePad; game-view touches → GamePad touchscreen. |
| `IOSAudioAPI.h/.mm` | `IAudioAPI` audio backend (RemoteIO AudioUnit), registered in `audio/IAudioAPI.cpp`. |
| `WiiPadMotion.h/.mm` | iPad gyroscope/accelerometer (Core Motion) as GamePad motion, via Cemu's `WiiUMotionHandler`. |
| `FiberIOS.cpp` | `util/Fiber/Fiber.h` on Boost.Context fcontext (iOS has no working ucontext; replaces `FiberUnix.cpp` on iOS). |
| `WiiPadDiagnostics.h/.mm` | Lightweight runtime diagnostics: heartbeat (CPU per emulation thread, VPADRead, audio, motion counters) and host/guest thread snapshots in `WiiPad.log`. |
| `CMakeLists.txt` | `WiiPadPlatform` target (+ `../main.cpp` for `CemuCommonInit()`), and `CemuCore`: all Cemu + vcpkg static libraries merged into `build-ios/CemuCore/libCemuCore.a`. |

See `docs/ipados/` for the architecture decisions.
