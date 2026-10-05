# Phase 1B — CemuCore on iPadOS

Status: **CemuCore compiles for arm64 iPadOS and the WiiPad app links against it** (CI run 37250652620,
commit `d1d502f`, Xcode 26.6 / iOS SDK 26.5, binary arm64, minos 16.0). **Not yet verified on the device.**

```
SwiftUI (app/WiiPad)  →  CemuBridge (src/ios, plain Obj-C header)  →  libCemuCore.a  →  CemuCommonInit() / MetalRenderer
```

## What the app does on launch

1. `CemuBridge.shared` opens `Documents/WiiPad.log` and logs device, OS and memory.
2. Background thread: `initializeCore`
   - paths: user data + config = `Documents`, cache = `Library/Caches/Cemu`, data = app bundle
   - default folders + MLC (`Documents/mlc01`), `settings.xml` defaults on first start
   - 4 GB address-space probe (logged), then `CemuCommonInit()` with every stage logged:
     PPC timer, exception handler, config, audio + graphic packs, input, **CafeSystem** (Wii U memory), title list, save list
3. Main thread: `initializeRendererInView:` logs the Metal device, constructs `MetalRenderer`, attaches its `CAMetalLayer`.
4. "Shut down core" button: renderer teardown, `CafeSystem::Shutdown()`, log flush.

No game is launched. CPU mode is forced to the single-core interpreter.

## Logs (Files › On My iPad › WiiPad)

| File | Content |
| --- | --- |
| `WiiPad.log` | Bridge log, written with `fsync` per line: complete up to a crash. Start here. |
| `WiiPad.previous.log` | The previous launch's log. |
| `log.txt` | Cemu's own log (CPU, RAM, memory base, errors). Flushed by a background thread. |
| `stdout.txt` | stdout/stderr, including Cemu's crash backtrace. |

A `!!! FATAL` line means a crash (signal, uncaught exception or `std::terminate`). "previous session did not
shut down cleanly" means the last run crashed or was killed.

## Changes to upstream Cemu files (all no-ops on Windows/Linux/macOS)

| File | Change |
| --- | --- |
| `CMakeLists.txt` | `CEMU_IOS`; no macOS deployment target, LTO or app-bundle default on iOS; glslang only with Vulkan on iOS |
| `src/CMakeLists.txt` | iOS: build `src/ios` instead of `CemuBin` |
| `src/Cafe/CMakeLists.txt` | AppKit `MetalView.mm` / `MetalLayer.mm` macOS-only; glslang link guarded like above |
| 13 source files | `BOOST_OS_MACOS` → `BOOST_OS_MACOS \|\| BOOST_OS_IOS` where the code is Darwin-generic |
| `src/main.cpp` | optional init-stage callback (null on desktop); no desktop `main()` on iOS |
| `src/config/ActiveSettings.cpp` | iOS: `GetCPUMode()` returns `SinglecoreInterpreter` |
| `Metal/MetalCommon.h` | iOS: no `depth24Stencil8PixelFormatSupported` (macOS-only selector), no `system()` |
| `Metal/MetalRenderer.cpp` | null checks for `CopyAllDevices()` (nullptr on iOS) |
| `gui/interface/WindowSystem.h` | `UIKit` backend value |
| `Latte/Core/LatteShader.cpp`, `LatteBufferData.cpp` | missing includes/constants when Vulkan is disabled (pre-existing upstream issue) |

Disabled on iOS: wxWidgets, OpenGL, Vulkan, Discord RPC, HIDAPI (Wiimote), SDL, libusb, **Cubeb (no audio yet)**.
The AArch64 JIT is compiled but unused and unchanged.

## Known risks for the first device run

| Risk | Where it shows | Next step if it fails |
| --- | --- | --- |
| 4 GB guest address space refused without `extended-virtual-addressing` | "memory probe ... FAILED", then a fatal in `CafeSystem` | entitlement via signing, or a smaller reservation strategy |
| `ucontext` fibers (deprecated on iOS) | not used until a game runs | — |
| Metal API availability on the device | "MetalRenderer: constructing" without "constructed" | guard the failing call |
| Sandbox paths not writable | "no write access" / MLC errors | adjust paths |

## CI

`.github/workflows/ios-build.yml` (push to `ipados`): vcpkg dependencies for `arm64-ios-wiipad` (binary-cached),
`cmake --build build-ios --target CemuCore`, XcodeGen + `xcodebuild`, unsigned `.ipa`. Failing steps publish
deduplicated error annotations (`.github/scripts/annotate_errors.py`).
