# Phase 3 — Cemu's AArch64 recompiler (JIT) on iPadOS

Branch `phase2`. Gate 0 (`PHASE3_GATE0.md`) showed that on iPadOS 27.2 a sideloaded WiiPad can get executable memory
from StikDebug's `universal.js` (breakpoint protocol), write code through a writable alias, patch it, and keep running
it after StikDebug detaches. This phase runs Cemu's existing AArch64 PPC recompiler (`BackendAArch64`, xbyak_aarch64)
on that memory. The interpreter stays the fallback.

## Why the backend can use a debugger-prepared arena unchanged

Generated blocks are position-independent:

- branches inside a block are PC-relative (`processAllJumps`, labels; xbyak_aarch64 resolves them as offsets);
- every exit (other blocks, HLE calls, interpreter fallback, leave) goes through an absolute address in a register
  (`mov` + `br`/`blr`) or Cemu's `ppcRecompilerDirectJumpTable` (RW data).

So a block can be generated in an ordinary heap buffer and copied into the arena afterwards.

## Changes

| Piece | What |
| --- | --- |
| `CMakeLists.txt` | `ENABLE_AARCH64_RECOMPILER` on for iOS too (xbyak_aarch64 is merged into `libCemuCore.a`; CI already checked it out) |
| `BackendAArch64.cpp/.h` (`#if BOOST_OS_IOS`) | heap `Allocator` instead of xbyak's `MmapAllocator` (`MAP_JIT` is refused on iOS), never `mprotect`; finished code (`codeSize`, not the buffer capacity) is handed to `g_aarch64CommitCode`, which returns the address to execute; `nullptr` → the function stays interpreted. The three interface functions (enter/leave) are generated on demand instead of in global generators, whose default allocator would `mmap(MAP_JIT)` at load time. xbyak's CPU probe (`util::Cpu`, throws if a sysctl is missing) is constructed lazily instead of at load time; iPads always have LSE atomics. `PPCRecompiler_cleanupAArch64Code` is a no-op (never called; arena code is not freed). |
| `config/ActiveSettings` | iOS: `GetCPUMode()` returns the mode WiiPad sets per launch (`SetIOSCPUMode`) instead of always the interpreter |
| `src/ios/WiiPadJIT.mm` | the arena: `EnableArena()` requests 256 MB (then 128, 64) with `JIT26PrepareRegion(NULL, size)`, checks first and last page are executable, `vm_remap` + `vm_protect rw-` alias, writes one `brk #0` into every page while still attached (Gate 0 only proved "written before detach" pages), self-test, `JIT26Detach`, self-test again, installs `g_aarch64CommitCode`. `Commit` is a mutex-protected bump allocator (64-byte aligned): `memcpy` into the alias, `sys_icache_invalidate` on the RX address. Logs every 16 MB used and once when full. |
| `src/ios/CemuBridge` | `enableJIT`, `jitReady`, `useJIT` (default on); before `PrepareForegroundTitle` (which calls `PPCRecompiler_init`): JIT ready and `useJIT` → single- or multi-core recompiler (the existing multi-core switch, now `multicoreCPU`), otherwise single-core or multi-core interpreter as before |
| `app/WiiPad/Sources/JITSection.swift` | replaces the Gate 0 test section: "Enable JIT with StikDebug" (opens `stikdebug://enable-jit` with `universal.js`, waits for the attach, prepares the arena), status line, "Use the recompiler" switch |
| `WiiPadDiagnostics` | heartbeat also shows the `PPCRecompiler` thread and `jit code N MB` |

No change to Cemu's recompiler logic itself, and none for desktop builds (all iOS parts are `#if BOOST_OS_IOS`).

## Log lines (`WiiPad.log`)

- `jit: JIT26PrepareRegion(NULL, 256 MB)` … `jit: arena ready: 256 MB at 0x… (alias 0x…)`
- `CPU mode for this title: single-core recompiler (JIT) (JIT enabled, 256 MB arena, recompiler setting on)`
- `PPC scheduler started: game code now runs on the single-core recompiler (JIT)`
- `jit: arena: 16 MB of 256 MB used`, heartbeat `| PPCRecompiler cpu +…s | jit code N MB`
- Cemu's own `log.txt`: `Recompiler initialized`

## Test plan (device)

1. Open WiiPad, don't load a title. "JIT (recompiler)" → "Enable JIT with StikDebug"; switch back when StikDebug says
   JIT is enabled. Expect "JIT enabled: 256 MB code arena ready".
2. Load Splatoon (single-core first; multi-core off).
3. Compare with the interpreter baseline (`PHASE2_CHECKPOINT.md`): `VPADRead` per 10 s in gameplay (600 = full speed;
   interpreter ~364).
4. Then the same with multi-core on (restart WiiPad, enable JIT again).
5. "Use the recompiler" off → interpreter in the same build, for an A/B comparison.

If WiiPad closes, send `WiiPad.previous.log`, `log.previous.txt` and any `*.crash.*` file.

## Result: full speed in gameplay (build 03ba3c6, 2026-10-11, single-core recompiler)

iPad Air 13" M3, iPadOS 27.2, Splatoon. JIT arena: 256 MB prepared in 1065 ms, 16384 pages touched in 43 ms, both
self-tests passed, detach fine. No crash in ~4.5 minutes.

| | Interpreter (Phase 2 baseline) | Single-core recompiler |
| --- | --- | --- |
| `VPADRead` per 10 s in gameplay (600 = 60 fps) | ~364 | **~600** (502–602) |
| `OSSched[core=0]` | 100 % | 100 % (now mostly waiting on the game's own frame pacing) |
| `LatteThread` (GPU) | ~99 % | 55–65 %, rising to ~95 % in heavier scenes (t ≥ 220 s) |
| JIT code | — | 18 MB after boot, 33.5 MB after 4 min (of 256 MB) |

Open issues from this run:

- **Character rendering looks wrong** (the Inkling). Not yet known whether the recompiler or the renderer causes it:
  needs the same scene with "Use the recompiler" off.
- **~1 s hitches.** The heartbeat shows dips when new code is compiled (e.g. +210 s: `PPCRecompiler` +0.46 s CPU,
  JIT code 29.2 → 33.1 MB, `VPADRead` 382). While a function is being recompiled it runs in the interpreter.
  New shaders (async compilation) are the other candidate. The 10 s heartbeat is too coarse to separate the two;
  `+22..28 s` (`VPADRead` 55, 0, 1, 20) is most likely a loading screen.
- The GPU thread approaches 100 % in heavier scenes: the next bottleneck after the CPU.

### Follow-up: the character glitch was the empty shader cache, not the recompiler

The run above started with `config: ... (first start, writing defaults)`: installing the build had wiped WiiPad's data
container (settings, `mlc01` saves, `shaderCache`). With an empty cache every pipeline compiles while playing, and with
async compilation Cemu skips draws until theirs is ready. Its filter (`IsAsyncPipelineAllowed`) allows that for any draw
with a depth attachment, which includes character models. After a relaunch the cache existed and the Inkling looked
right. WiiPad now logs the cache state at title launch (`shader cache: EMPTY (first run since install) ...` or
`shader cache: N files, X MB`) and says explicitly when Documents was empty at startup.

Device follow-up: the tutorial scene also came up as a yellow/green wash without level geometry on that first run; a
relaunch (warm cache) fixed it as well. Both first-run glitches are async pipeline compilation on an empty cache, not
the recompiler. Data loss on install: Sideloadly keeps the data container when a build is installed over the existing
app (same Apple ID, unchanged bundle ID); deleting WiiPad first wipes `mlc01` saves and `shaderCache`.

## Light shaft / "yellow screen" glitch: occlusion query leak in Cemu's Metal renderer

Device recording (build 7b9ee29, async shader compilation off, recompiler): in the tutorial the light shafts flicker
between correct translucent beams and solid over-bright wedges from frame to frame; the earlier full-screen yellow/green
wash in the same room is the same effect. With async compilation off nothing is skipped, so this is not the shader cache.

Cause (also in upstream Cemu `main`): `MetalRenderer::draw_execute` sets `setVisibilityResultMode(Counting, slot)` for
draws inside an occlusion query, but never turns counting off when the query ends. The encoder keeps counting every
later draw in the same render pass into the current slot, which is the first slot of the next query, so the next
query reports far too many visible samples. Splatoon scales its light shafts by such a query (light source visibility),
so they render at full intensity. Whether the next query lands in the same render pass depends on where command
buffers are committed, so it flickers. Faster emulation (recompiler) changes that timing, which is likely why it showed
up now.

Fix: `MetalEncoderState::m_visibilityCounting` tracks the encoder's mode (reset with every new encoder, as Metal
starts each encoder disabled); the first draw after a query ends sets `VisibilityResultModeDisabled`.

### Open: characters invisible on the first launch after an install, even with async compilation off

Device report (2b77592): the light shafts are fixed, but on the first launch after installing, the Inklings on
"Choose an Inkling!" are still missing their skin; after restarting WiiPad they are fine. With async compilation off,
`MetalPipelineCache` compiles every pipeline synchronously, so the async explanation does not cover this. Diagnostic:
the Metal renderer now counts draws it drops (`no pipeline`: pipeline missing or failed to compile; `no mesh shader`:
geometry-shader draw without mesh shader support) and the heartbeat prints `DRAWS DROPPED: ...` when that happens.
Pipeline and shader compile errors are in Cemu's `log.txt` (`error creating render pipeline state`, `failed to create
library from source`).
