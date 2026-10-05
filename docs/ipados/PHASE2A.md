# Phase 2A — First Wii U title

Goal: select a legally dumped Wii U title in the Files app and hand it to Cemu's **existing** title-loading/boot
path, with `WiiPad.log` showing exactly how far it gets. Branch `phase2`, based on the Phase 1B baseline `20f14a4`.

## Desktop launch path (traced) and what WiiPad reuses

`wxgui/MainWindow::FileLoad(path)` does, in order:

| Step | Cemu function | wx/desktop dependency | WiiPad |
| --- | --- | --- | --- |
| Identify title | `TitleInfo(path)` (format detection + `app.xml`/`meta.xml`) | none | reused |
| Register title | `CafeTitleList::AddTitleFromPath`, `CafeTitleList::FindBaseTitleId` | none | reused |
| Mount + prepare | `CafeSystem::PrepareForegroundTitle(titleId)` → mount MLC/base/update/DLC, game profile, `SetupMemorySpace`, `PPCRecompiler_init` (returns early: interpreter), `PrepareExecutable` | none | reused |
| Standalone RPX/ELF | `CafeSystem::PrepareForegroundTitleFromStandaloneRPX(path)` | none | reused |
| Error dialogs | `wxMessageBox` | **wx** | errors returned through `CemuBridge` to SwiftUI |
| Recent files, menus, Discord, fullscreen | wx config / menus | **wx** | not used |
| Render target | `MainWindow::CreateCanvas` → `MetalCanvas` creates `MetalRenderer` | **wx** | already created by `CemuBridge` (Phase 1B) |
| Boot | `CafeSystem::LaunchForegroundTitle()` → thread → `cemu_initForGame()` | none | reused |
| Frontend callbacks | `CafeSystem::SystemImplementation` (`CafeRecreateCanvas`, `CafePPCProcessExit`) | implemented by wx `MainWindow` | implemented in `CemuBridge.mm` (log only) |

Inside `cemu_initForGame()` (launch thread): `RPLLoader_LoadCoreinit` → `LoadMainExecutable` (RPX/ELF) → RPL link →
`GamePatch_scan` → `Latte_Start` (GPU thread: `g_renderer->Initialize`, shader cache, registers) → wait for GPU init →
`RPLLoader_CallCoreinitEntrypoint` → `AXOut_init`; then `coreinit::OSSchedulerBegin(1)` runs the game threads.

Other dependencies checked:

- **Paths**: Cemu uses `std::filesystem`/POSIX I/O on the title path. A Files-picker URL resolves to a normal POSIX
  path (`fileSystemRepresentation`) that works while security-scoped access is held. No custom filesystem needed.
- **Command line** (`LaunchSettings`): only optional overrides; unset on iPadOS.
- **WindowSystem**: `NotifyGameLoaded`, `UpdateWindowTitles`, sizes: already implemented by `IOSWindowSystem`.
- **Shared fonts** (`LoadSharedData`): missing fonts are only logged; not bundled in 2A.
- **Audio** (`AXOut_init`): device creation is in `try/catch`; no backend on iPadOS yet.
- **Fibers**: `OSSchedulerBegin` uses `util/Fiber/FiberUnix.cpp` (`ucontext`, deprecated on iOS). First exercised in 2A.
- **Crash-on-failure**: after launch, Cemu reports some failures with `cemu_assert(false)` (`raise(SIGTRAP)`), e.g. a
  missing RPX in `LoadMainExecutable`. WiiPad checks the mounted code folder for an `.rpx` **before** launching
  (read-only), so that case is a normal error. Other post-launch failures are recorded by WiiPadLog's fatal handler with
  the last boot stage.

## Changes

| File | Change |
| --- | --- |
| `src/Cafe/CafeSystem.cpp` | optional launch-stage callback (null on desktop, additions only); loader logic unchanged |
| `src/Cafe/HW/Latte/Renderer/Metal/MetalRenderer.h` | `SetShouldMaximizeConcurrentCompilation` is a no-op on iOS (the selector is macOS-only); desktop unchanged |
| `src/ios/CemuBridge.h/.mm` | `launchTitleAtURL:error:` (mirrors `FileLoad`), `savedTitleURL`, `titleLaunched`, `SystemImplementation`, progress monitor, no in-app shutdown while a title runs |
| `src/ios/WiiPadLog.h/.mm` | fatal handler prints the last boot stage and a backtrace; `std::terminate` handler logs the exception (C++ or Objective-C) and chains to the runtime's handler; crashed sessions' logs kept as `*.crash.*` |
| `app/WiiPad/Sources/ContentView.swift` | Files pickers (folder / file), reopen last title, status and errors |

## Result (verified on device, commit `3a01f15`)

M3 iPad Air, iPadOS 27 beta, unsigned IPA from CI run 37265857978, sideloaded. Title: Splatoon
(`0005000010176900`, v16, extracted folder, user's own dump).

Verified boot path, in order, from `WiiPad.log`:

1. Files picker → security-scoped access → POSIX path → `TitleInfo` → `CafeTitleList` → `PrepareForegroundTitle` (mounted)
2. `RPX/RPL loading` (coreinit + `Gambit.rpx`) → `RPL linking`
3. `GPU thread start` → `GPU initialization completed` (Metal renderer, shader cache, registers)
4. `game initialization completed (coreinit entrypoint returned)`
5. `PPC scheduler started: game code now runs on the single-core interpreter` (fibers via `FiberUnix.cpp` work)
6. ~~The game renders to the Metal surface on the iPad.~~ **Correction (Phase 2B/2C investigation):** the image was
   Cemu's shader-cache loading screen (the title's `bootTvTex.tga`), not game output. No guest code ran after
   `PPC scheduler started`: iOS does not implement `getcontext`/`swapcontext` (ENOTSUP), so Cemu's ucontext fibers
   never switched and the scheduler thread exited. Fixed with `src/ios/FiberIOS.cpp`, see `PHASE2B_2C.md`.

### Blocker fixed on the way

The first attempt aborted on the GPU thread at "GPU initialization (shader cache, registers)":
`RendererShaderMtl::ShaderCacheLoading_begin` → `MetalRenderer::SetShouldMaximizeConcurrentCompilation` →
`-[MTLDevice setShouldMaximizeConcurrentCompilation:]`, which exists only on macOS 13.3+. On iPadOS it raises
`NSInvalidArgumentException` (unrecognized selector); uncaught on the GPU thread → `std::terminate` → SIGABRT.
Fix: the call is compiled out under `BOOST_OS_IOS`. Effect on iPadOS: Metal does not receive the "maximize
concurrent shader compilation" hint. Nothing else changes.

### Runtime-behaviour audit of the Phase 2A diagnostics

Checked before the checkpoint: none of the diagnostics changes what Cemu or the game does.

| Diagnostic | Effect on normal runtime |
| --- | --- |
| `g_cemuTitleLaunchStageCallback` (CafeSystem) | observer only; null on desktop; on iPadOS writes one log line per stage (6 calls per boot) |
| Progress monitor thread (`WiiPadMonitor`) | read-only polling of `g_isGPUInitFinished`, `LatteGPUState.gx2InitCalled`, `flipCounter` every 250 ms; at most one line per 60 frames; exits after 5 minutes |
| Fatal signal handlers | run only on a fatal signal; write, then chain to the previous handler (Cemu's `ExceptionHandler`, or the default action) |
| `std::terminate` handler | runs only when the process is already terminating; logs, then chains to the previous (Objective-C runtime) handler, then `abort()` |
| `NSSetUncaughtExceptionHandler` | logging only; nothing else in the app installs one |
| Crash-log preservation | file renames at app start, before Cemu initializes |
| stdout/stderr → `stdout.txt` | redirects console output only |
| Pre-launch `.rpx` check | read-only `fsc` directory listing; turns Cemu's post-launch `cemu_assert` trap into a reportable error |
| 4 GB address-space probe (Phase 1B) | `mmap(PROT_NONE)` + immediate `munmap`; Cemu's own reservation is unchanged |

No temporary investigation code remains (the Phase 1B initializer diagnostics were removed in `20f14a4`).

## Known limitations

- **No audio.** `snd_core::AXOut_init` → `IAudioAPI::CreateDeviceFromConfig` fails because Cubeb (and every other
  audio backend) is intentionally disabled in the iPadOS build (`ENABLE_CUBEB=OFF`). Cemu catches the error and logs
  `can't initialize tv audio: …` to `log.txt` (GamePad audio likewise); the title keeps running silently. An iOS audio
  backend is a later phase.
- **No input.** No controller, touch or GamePad input is wired up yet.
- **Interpreter only.** Single-core interpreter (`ENABLE_AARCH64_RECOMPILER=OFF`); no performance work done.
- **One title per session.** Stopping a running title (`CafeSystem::ShutdownTitle`) is not wired up. Close WiiPad from
  the app switcher.
- **Fixed preview surface.** The game renders into the 480×270 diagnostic view; `CafeRecreateCanvas` is ignored.
- **No shared fonts.** System fonts are not bundled; titles that need them may show missing text.

## Selecting a title (iPad)

- **Extracted title**: choose the title's **root folder** (contains `code`, `content`, `meta`). Picking the `.rpx`
  inside `code` grants access to that file only, so `meta` would be unreadable.
- **Single file**: `.wua`, `.wud`/`.wux` (needs `keys.txt` with the disc key in WiiPad's Documents folder), `.wuhb`,
  or a homebrew `.rpx`/`.elf`.
- Store titles **On My iPad** (or download them first); iCloud placeholders are not readable.
- Access is held for the session; a bookmark lets "Reopen …" load the same title next launch.
- One title per session. While a title runs, close WiiPad from the app switcher to stop it.

## Log stages (`WiiPad.log`)

`title picker opened` → `title URL selected` → `security-scoped access started` → `resolved title path` →
`title metadata loaded` → `Cafe boot requested` → `title prepared` → `game initialization started` →
`RPX/RPL loading started/completed` → `boot stage …` (linking, GPU thread, GPU init) →
`game initialization completed` → `PPC scheduler started` → `progress +Ns: …` (GPU init, GX2Init, frames).
Failures: `title load failed: <Cemu reason>` or `!!! FATAL <signal>` with `!!! last stage: …`.
