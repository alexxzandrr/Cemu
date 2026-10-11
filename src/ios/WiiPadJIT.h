#pragma once

// JIT on iPadOS 26+ (TXM/SPTM devices: A15+, every M-series iPad) for Cemu's AArch64 recompiler (Phase 3).
//
// A process cannot make its own pages executable. An attached debugger (StikDebug 17.4+, with its universal.js script)
// services a breakpoint protocol instead: the app executes `brk #0xf00d` with a selector in x16 and the debug server
// prepares an executable (RX) region (StikJIT INTEGRATION.md). The app writes code through its own writable alias of
// that region (W^X). Gate 0 (docs/ipados/PHASE3_GATE0.md) showed on iPadOS 27.2 that pages written while attached can
// be rewritten and executed after the debugger detaches.
//
// EnableArena() does the whole setup once per app session: executable region, writable alias, one write into every
// page while still attached, a self-test, detach. After that the arena serves the recompiler through
// g_aarch64CommitCode (bump allocation, never freed, like the x64 backend's code blocks). Every step is logged to
// WiiPad.log (fsync per line, so a kill by iOS still leaves the last step on disk).

#include <cstddef>
#include <string>

namespace WiiPadJIT
{
	struct CodeSignStatus
	{
		bool ok = false;           // csops() succeeded
		unsigned flags = 0;
		bool getTaskAllow = false; // CS_GET_TASK_ALLOW: a debugger may attach (sideload signing with a dev profile)
		bool debugged = false;     // CS_DEBUGGED: a debugger is (or was) attached; stays set after a detach
	};

	CodeSignStatus GetCodeSignStatus();

	// One-line human summary (signing, debugger, arena) for the UI.
	std::string DescribeStatus();

	// Requires CS_DEBUGGED (never executes brk otherwise, which would kill the process with SIGTRAP).
	// Blocking (the breakpoints wait for the debug server); call off the main thread. Returns a short result line.
	std::string EnableArena();

	bool ArenaReady();
	size_t ArenaSize();
	size_t ArenaUsed();
}
