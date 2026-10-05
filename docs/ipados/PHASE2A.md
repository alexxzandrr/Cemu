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
| `src/ios/CemuBridge.h/.mm` | `launchTitleAtURL:error:` (mirrors `FileLoad`), `savedTitleURL`, `titleLaunched`, `SystemImplementation`, progress monitor, no in-app shutdown while a title runs |
| `src/ios/WiiPadLog.h/.mm` | fatal handler prints the last boot stage |
| `app/WiiPad/Sources/ContentView.swift` | Files pickers (folder / file), reopen last title, status and errors |

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
