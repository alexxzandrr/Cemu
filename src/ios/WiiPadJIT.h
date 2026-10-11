#pragma once

// Phase 3 "Gate 0": can WiiPad generate and run machine code on this device?
//
// iOS 26+ on TXM/SPTM devices (A15+, M-series) no longer makes a debugger-attached process's own pages executable.
// Instead an attached debugger (StikDebug, iOS 17.4+, with its universal.js script) services a breakpoint protocol:
// the app executes `brk #0xf00d` with a selector in x16 and the debug server prepares an executable (RX) region.
// The app writes code through its own writable alias of that region (W^X). Protocol: StikJIT INTEGRATION.md.
//
// This module only tests that path end to end and logs every step to WiiPad.log (fsync per line, so a kill by iOS
// still leaves the last step on disk). It does not touch Cemu's recompiler.

#include <string>

namespace WiiPadJIT
{
	struct CodeSignStatus
	{
		bool ok = false;        // csops() succeeded
		unsigned flags = 0;
		bool getTaskAllow = false;  // CS_GET_TASK_ALLOW: a debugger may attach (sideload signing with a dev profile)
		bool debugged = false;      // CS_DEBUGGED: a debugger is (or was) attached
	};

	CodeSignStatus GetCodeSignStatus();

	// One-line human summary of the state above (for the UI).
	std::string DescribeStatus();

	// Runs the Gate 0 test: requires CS_DEBUGGED (never executes brk otherwise, that would kill the process with
	// SIGTRAP). Blocking (the breakpoint waits for the debug server); call off the main thread.
	// detachAfter: also call JIT26Detach and run the code again (tells whether execution survives a detach).
	// Returns a short result line; details are in WiiPad.log (lines prefixed "jit:").
	std::string RunGate0(bool detachAfter);
}
