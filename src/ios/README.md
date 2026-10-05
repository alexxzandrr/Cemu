# src/ios — WiiPad (Cemu for iPadOS) platform layer

Built only when CMake is configured with `-DCMAKE_SYSTEM_NAME=iOS` (see `src/CMakeLists.txt`).

| File | Role |
| --- | --- |
| `CemuBridge.h/.mm` | The only API the SwiftUI app uses. `CemuBridge.h` is plain Objective-C (no C++/Cemu types). |
| `IOSWindowSystem.mm` | iPadOS implementation of `gui/interface/WindowSystem.h` (desktop: `wxgui/wxWindowSystem.cpp`). |
| `MetalLayerUIKit.mm` | UIKit `CreateMetalLayer()` (desktop: `Cafe/HW/Latte/Renderer/Metal/MetalLayer.mm`). |
| `WiiPadLog.h/.mm` | Crash-safe log at `Documents/WiiPad.log`, stdout/stderr capture, fatal handlers. |
| `CMakeLists.txt` | `WiiPadPlatform` target (+ `../main.cpp` for `CemuCommonInit()`), and `CemuCore`: all Cemu + vcpkg static libraries merged into `build-ios/CemuCore/libCemuCore.a`. |

See `docs/ipados/` for the architecture decisions.
