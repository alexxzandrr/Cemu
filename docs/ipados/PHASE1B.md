# Phase 1B — CemuCore on iPadOS

Status: **verified on a physical M3 iPad Air (iPadOS 27.2 beta)** with commit `37f480e`
(CI run 37257703693, Xcode 26.6 / iOS SDK 26.5, binary arm64, minos 16.0). The clean baseline is the cleanup
commit that follows it, which only removes temporary diagnostics.

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

## Verified on device (`37f480e`, M3 iPad Air, iPadOS 27.2 beta)

| Check | Result |
| --- | --- |
| App reaches `main()` | yes, 0 C++ exceptions during static initialization |
| `CemuCommonInit()` | succeeds |
| 4 GB Wii U address-space reservation | succeeds, base `0x7000000000` (no extended-virtual-addressing entitlement needed) |
| `CafeSystem` | initializes and shuts down cleanly |
| Metal renderer (Apple M3 GPU) | constructs and shuts down cleanly |
| `CAMetalLayer` | created and attached to the SwiftUI host view |
| AArch64 JIT / xbyak objects linked into the app | none |
| Crashes | none |

## Startup crash found during bring-up (fixed in `37f480e`)

The first device build (`7c2b328`) aborted ~0.18 s after launch, inside dyld's initializer loop
(`dyld4::LibSystemHelpers::callInitializer` → `abort_report_np`), before `main()`, so no log existed yet.

Root cause: `src/Cafe/HW/Espresso/Recompiler/BackendAArch64/BackendAArch64.cpp` defines three namespace-scope code
generators (`enterRecompilerCode_ctx`, `leaveRecompilerCode_unvisited_ctx`, `leaveRecompilerCode_visited_ctx`). Their
constructors build xbyak `CodeGenerator`s whose default `MmapAllocator` allocates `MAP_JIT` executable memory during
static initialization. iPadOS refuses that, so xbyak threw `Xbyak_aarch64::Error` out of
`_GLOBAL__sub_I_BackendAArch64.cpp` and dyld aborted. The backend was linked even though the interpreter is forced,
because `PPCRecompiler.cpp` references two of its functions (`PPCRecompiler_generateAArch64Code`,
`PPCRecompilerAArch64Gen_generateRecompilerInterfaceFunctions`); at runtime `PPCRecompiler_init()` already returned
early in interpreter mode.

How it was found: the binary has ~2300 static initializers (`__TEXT,__init_offsets`); a temporary app-side constructor
that ran before them recorded the C++ throw (type + frames) to a file, and a CI step mapped every initializer to its
object file via the linker map. Both diagnostics were removed after verification.

Fix (no change to xbyak, memory, the 4 GB reservation or Metal; nothing catches the exception):

| File | Change |
| --- | --- |
| `CMakeLists.txt` | option `ENABLE_AARCH64_RECOMPILER`, default ON, **OFF for iOS**; xbyak only added when ON |
| `src/Cafe/CMakeLists.txt` | OFF: `BackendAArch64.cpp` and xbyak are not built or linked; `CemuCafe` gets `CEMU_AARCH64_RECOMPILER_DISABLED` |
| `PPCRecompiler.cpp` | when disabled: `PPCRecompiler_init()` returns early with a log line, and the two backend calls are compiled out |

Desktop builds are unchanged (option ON, macro never defined). The backend source stays in the tree for a future
iPadOS JIT phase, which must also avoid allocating executable memory at load time.

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
| `CMakeLists.txt` | `CEMU_IOS`; no macOS deployment target, LTO or app-bundle default on iOS; glslang only with Vulkan on iOS; `ENABLE_AARCH64_RECOMPILER` |
| `src/CMakeLists.txt` | iOS: build `src/ios` instead of `CemuBin` |
| `src/Cafe/CMakeLists.txt` | AppKit `MetalView.mm` / `MetalLayer.mm` macOS-only; glslang link guarded like above |
| 13 source files | `BOOST_OS_MACOS` → `BOOST_OS_MACOS \|\| BOOST_OS_IOS` where the code is Darwin-generic |
| `src/main.cpp` | optional init-stage callback (null on desktop); no desktop `main()` on iOS |
| `src/config/ActiveSettings.cpp` | iOS: `GetCPUMode()` returns `SinglecoreInterpreter` |
| `Metal/MetalCommon.h` | iOS: no `depth24Stencil8PixelFormatSupported` (macOS-only selector), no `system()` |
| `Metal/MetalRenderer.cpp` | null checks for `CopyAllDevices()` (nullptr on iOS) |
| `gui/interface/WindowSystem.h` | `UIKit` backend value |
| `src/Cafe/HW/Espresso/Recompiler/PPCRecompiler.cpp` | no backend references when `ENABLE_AARCH64_RECOMPILER=OFF` (see above) |
| `Latte/Core/LatteShader.cpp`, `LatteBufferData.cpp` | missing includes/constants when Vulkan is disabled (pre-existing upstream issue) |

Disabled on iOS: wxWidgets, OpenGL, Vulkan, Discord RPC, HIDAPI (Wiimote), SDL, libusb, **Cubeb (no audio yet)**.
The AArch64 JIT backend (and xbyak) is not built for iOS (`ENABLE_AARCH64_RECOMPILER=OFF`, see above); its source is unchanged.

## Open risks for Phase 2 (not exercised yet)

| Risk | Why it is open |
| --- | --- |
| `ucontext` fibers (deprecated on iOS) | only used once a title runs |
| Full renderer setup (`Renderer::Initialize`, shader compile, imgui overlay) | only runs at game launch |
| Memory pressure / jetsam while a title runs | init footprint was fine; game working sets are much larger |
| No audio | Cubeb is disabled |

## CI

`.github/workflows/ios-build.yml` (push to `ipados`): vcpkg dependencies for `arm64-ios-wiipad` (binary-cached),
`cmake --build build-ios --target CemuCore`, XcodeGen + `xcodebuild`, unsigned `.ipa`. Failing steps publish
deduplicated error annotations (`.github/scripts/annotate_errors.py`).
