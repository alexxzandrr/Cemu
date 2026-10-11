# Phase 3 Gate 0 — can WiiPad run generated code?

Branch `phase2`. Real speed needs Cemu's AArch64 recompiler (Phase 3), which generates machine code at run time.
This gate answers, before any recompiler work, whether a sideloaded WiiPad on the test device (M3 iPad Air,
iPadOS 27 beta) can get executable memory, write code into it, run it and patch it.

## Background: JIT on iOS 26+ (TXM/SPTM devices)

On iOS 17.4–18 an attached debugger (StikDebug) was enough: the process becomes `CS_DEBUGGED` and may make its own
pages executable. On iOS 26+ devices with TXM (A15 and later, all M-series iPads) that no longer works. StikDebug's
`universal.js` script instead services a breakpoint protocol (StikJIT `INTEGRATION.md`):

- the app executes `brk #0xf00d` with a selector in `x16` (`1` = prepare region, `0` = detach), arguments in `x0`/`x1`,
  result in `x0`;
- `JIT26PrepareRegion(NULL, size)` makes the debug server allocate an executable region (debugserver writes one byte
  per 16 KB page, which marks it executable). Passing the app's own mapping returns the same pointer without making
  it executable (Play! CodeGen PR #34);
- the region is execute-only; the app creates its own writable alias (`vm_remap` + `vm_protect rw-`), W^X;
- a `brk` with no debugger attached kills the process with SIGTRAP, so everything is gated on `CS_DEBUGGED`.

Status reports are mixed (an iOS 26.4 regression of StikDebug's offline mode was reported); nothing public covers
iPadOS 27, which is why this is tested on the device.

## The test (`src/ios/WiiPadJIT.mm`)

1. `csops`: `get-task-allow` (required for any debugger; comes from the sideloading tool's development profile) and
   `CS_DEBUGGED`.
2. `JIT26PrepareRegion(NULL, 64 MB)` (up to 3 tries); result must be page-aligned, mapped and executable.
3. Writable alias via `vm_remap` + `vm_protect`.
4. Generated code: (1) `return 42` on the first page, (2) `a + b` 16 MB into the region, (3) patching test 1 in place
   to `return 1234` after it ran, (4) 1M calls timed.
5. Optional second button: `JIT26Detach`, then the same tests again (does execution survive a detach?).

Each execution is logged (fsync) before it runs, so if iOS kills WiiPad the last line in `WiiPad.previous.log`
shows which step.

## How to run it

1. StikDebug installed with its pairing file, LocalDevVPN on, Wi-Fi on.
2. Open WiiPad, don't load a title. In "JIT test (Phase 3, Gate 0)", the status line should say
   `get-task-allow: yes`. If it says `NO`, the sideloading tool signed WiiPad without it and no debugger can attach.
3. Tap "Enable JIT with StikDebug and test". StikDebug opens and attaches with `universal.js`; switch back to WiiPad.
   The test starts by itself once the debugger is attached (it waits up to 2 minutes).
4. If it passes, tap "Test after detach (may close WiiPad)".
5. Send `WiiPad.log` (or `WiiPad.previous.log` if WiiPad closed), lines starting with `jit:`.

## Outcomes

| Result | Meaning for Phase 3 |
| --- | --- |
| Passed, also after detach | Recompiler feasible; prepare its arena once, then detach |
| Passed attached, killed after detach | Feasible, but StikDebug must stay attached while playing (as Play! does) |
| No executable region / killed at test 1 | Not possible on this iPadOS build with this method; speed stays interpreter-bound |
| `get-task-allow: NO` | Fix signing first (sideloading tool / profile), then rerun |

## Result: PASSED, also after detach (build 0d419d1, 2026-10-11)

Device `iPad15,6` (iPad Air 13" M3), iPadOS 27.2, StikDebug with `universal.js`.

```
jit: iPadOS 27.2.0, csops ok true, flags 0x32003005, get-task-allow true, CS_DEBUGGED true
jit: JIT26PrepareRegion(NULL, 64 MB), attempt 1
jit: JIT26PrepareRegion returned 0x115078000 after 274 ms
jit: RX region 0x115078000: entry 0x115078000+16 KB, prot r-x max rwx
jit: vm_remap -> kr 0 at 0x119078000 (cur r-x max rwx)
jit: vm_protect(alias, rw-) -> kr 0
jit: [attached] tests PASSED          (42, 40+2, patched 1234; 1M calls in ~1.1 ms)
jit: calling JIT26Detach
jit: detached; CS_DEBUGGED now true
jit: [detached] tests PASSED          (1M calls in 1.4 ms)
jit: GATE 0 PASSED (also after detach)
```

- The first request succeeded (no retries); preparing 64 MB took 274 ms (debugserver touches each 16 KB page; each
  page shows up as its own VM entry, hence "+16 KB").
- Writable alias via `vm_remap` + `vm_protect rw-` works; code written through it runs at the RX address.
- Patching code that already ran works (needed for block linking / invalidation).
- Generated calls run at native speed (~1.1 ns per call).
- After `JIT26Detach` execution and patching keep working; `CS_DEBUGGED` stays set. StikDebug does not have to stay
  attached while playing: the recompiler can prepare its whole arena up front, then detach.
- Not covered: writing into a page for the first time after detach (all pages used were written before). The
  recompiler integration will exercise this first.
- Moving to StikDebug and back made iOS lay the view out briefly in portrait (`game view resized: 1024x1366`, app
  switcher snapshot); harmless.

Next: Phase 3 proper — run Cemu's AArch64 recompiler backend (`BackendAArch64`, xbyak_aarch64) with its code
allocated from this arena (generate into a buffer, copy through the RW alias, execute at the RX address).
