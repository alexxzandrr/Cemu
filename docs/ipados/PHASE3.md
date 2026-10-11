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
