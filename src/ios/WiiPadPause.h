#pragma once

// Pausing a running title (iPhone/iPad). Cemu has no pause: WiiPad suspends every guest thread (the same internal
// suspend OSSuspendThread uses) and stops the audio output; resume undoes exactly those suspends. While paused the
// emulated cores have nothing to run and sleep in the idle loop (coreinit_Thread.cpp, BOOST_OS_IOS), so the device
// cools down. Used when the app leaves the foreground, when iPhone Duo is closed and from the in-game menu.

namespace WiiPadPause
{
	// Main thread or any non-emulation thread. Returns false if no title runs or it is already paused / not paused.
	bool Pause(const char* reason);
	bool Resume(const char* reason);
	bool IsPaused();
}
