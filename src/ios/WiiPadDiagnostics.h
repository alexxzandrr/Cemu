#pragma once

// Diagnostic-only instrumentation (Phase 2B/2C investigation): counters with last-hit timestamps and a
// monitor thread that periodically logs them, samples host thread state/backtraces (Mach APIs) and takes
// snapshots of the emulated PPC threads (like Cemu's PPC thread viewer). Does not change emulation behaviour:
// counters are relaxed atomics; the guest snapshot only uses __OSTryLockScheduler and holds it for a copy.

#include <atomic>
#include <cstdint>

namespace WiiPadDiag
{
	struct Counter
	{
		std::atomic<uint64_t> count{ 0 };
		std::atomic<int64_t> lastNs{ 0 }; // steady clock

		void Hit();
	};

	extern Counter vpadRead;        // WiiPadTouchController::raw_state from VPADController::VPADRead (game's VPADRead)
	extern Counter schedulerEvents; // IOSAudioAPI::NeedAdditionalBlocks <- AXOut_update <- __OSCheckSystemEvents (PPC scheduler idle loop)
	extern Counter audioPlay;       // IOSAudioAPI::Play() attempts that start the device
	extern Counter audioFeed;       // IOSAudioAPI::FeedBlock (game audio blocks)
	extern Counter audioRender;     // RemoteIO render callback invocations
	extern Counter audioRenderData; // render callbacks that had game samples

	// Starts the monitor thread (once). Call right after CafeSystem::LaunchForegroundTitle().
	void StartMonitor();
}
