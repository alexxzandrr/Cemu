# Phase 2 checkpoint — Splatoon playable on iPadOS (interpreter)

Branch `phase2`. Verified on an M3 iPad Air (iPadOS 27.2 beta) with the user's own Splatoon dump (v16, extracted
folder), build `3617616`, before the cleanup in this checkpoint.

## Status

| Area | State | Details |
| --- | --- | --- |
| Boot (2A) | works | Files picker → TitleInfo → mount → RPX load/link → GPU init → coreinit → PPC scheduler (`PHASE2A.md`) |
| Fibers | works | `src/ios/FiberIOS.cpp` (Boost.Context); iOS has no ucontext (below) |
| Rendering | works | Metal; shader cache persists between runs; first sight of a scene compiles shaders asynchronously (pop-in once) |
| Input (2B) | works | on-screen GamePad controls + game-view touch → GamePad touchscreen (`PHASE2B_2C.md`) |
| Audio (2C) | works | TV audio via RemoteIO AudioUnit, real time (48 kHz) |
| Tilt (2D) | works | iPad gyroscope/accelerometer → GamePad motion, Recenter button (`PHASE2D.md`) |
| CPU | interpreter | single-core (default) or multi-core interpreter (switch before loading a title); no JIT yet |

## Fibers on iOS: two root causes, both fixed in `FiberIOS.cpp`

1. **No ucontext on iOS.** `getcontext` returns -1 / `ENOTSUP`. Cemu's `FiberUnix.cpp` ignores the result, so the
   scheduler thread's first `Fiber::Switch` returned at once, the thread exited holding the scheduler lock, and no
   guest code ran (the Phase 2A "rendered surface" was Cemu's loading screen). `FiberIOS.cpp` implements `Fiber.h` with
   Boost.Context `make_fcontext` / `jump_fcontext`. On arm64 the entry parameter is passed as two 32-bit halves, the
   convention `FiberUnix.cpp` established and coreinit's `__OSFiberThreadEntry(uint32, uint32)` depends on.
2. **Self-switch in multi-core mode.** On a non-main core, `__OSThreadSwitchToNext` re-queues the current guest thread
   and may pick it again, calling `Fiber::Switch` on the running fiber. `swapcontext(ctx, ctx)` effectively returns;
   `jump_fcontext` jumped to the fiber's stale context from its previous suspension. iOS killed that with
   EXC_BAD_ACCESS executing a guest pointer, termination CODESIGNING "Invalid Page" (SIGKILL, no in-app crash log).
   Found with temporary fiber ownership checks (now removed). Fix: `Fiber::Switch` returns when target == current
   fiber. Not an upstream Cemu bug and not an iOS API problem; Cemu and single-core mode are unchanged.
   Also verified from the iOS build's disassembly (temporary CI step, now removed): the scheduler does not reuse
   thread_local addresses across fiber switches, so fibers migrating between host threads are safe.

## Multi-core interpreter

Working: 150 s of gameplay on `3617616` with all three `OSSched` threads active, fiber migrations between host threads
(logged by the ownership checks, which never fired), no crash. Selected like the desktop `--force-multicore-interpreter`
option. Not faster for Splatoon (below), so single-core stays the default.

## Performance baseline (3617616, Splatoon gameplay, 10 s heartbeat intervals)

| | Single-core interpreter | Multi-core interpreter |
| --- | --- | --- |
| `VPADRead` per 10 s in gameplay (game reads the GamePad once per frame; 600 = full 60 fps) | ~364 (336–386), ≈ 61% | ~336 (292–368), ≈ 56% |
| Menus / title | 120 per 2 s = full rate | full rate |
| Emulation threads | `OSSched[core=0]` 100% | core 1 ~98%, core 0 ~70%, core 2 ~45% |
| `LatteThread` (GPU) | ~99% | ~85–95% |
| Audio | real time (~83 blocks/s × 576 samples) | real time |

The game's main core (one host thread running the interpreter) is the bottleneck in both modes; the screen recording
showed 25–30 distinct frames per second. Spreading the other cores over more threads does not help and costs about
twice the CPU. Real speed requires the AArch64 recompiler (JIT), Phase 3, gated on whether JIT can be enabled on the
device (StikDebug attach test, "Gate 0").

## Diagnostics kept

`WiiPad.log` heartbeat and thread snapshots (`WiiPadDiagnostics`), fatal signal / `std::terminate` / Objective-C
exception logging with backtraces, crash logs kept as `*.crash.*`, and after any other unclean exit (e.g. SIGKILL from
iOS) `WiiPad.previous.log`, `log.previous.txt`, `stdout.previous.txt`. The Cemu `Fiber` startup self-test (switch into
a fiber and back, entry parameter check) stays; the ucontext self-test was removed.

## Known limitations

- Speed: ~55–60% in gameplay (interpreter only).
- No GamePad (DRC) audio; audio does not resume after an interruption.
- One title per session; stop it by closing WiiPad from the app switcher. 480×270 game view, landscape controls.
- No microphone, no Home menu, no hardware controllers; shared system fonts not bundled (placeholder font).
