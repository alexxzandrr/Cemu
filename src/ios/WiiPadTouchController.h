#pragma once

// iPadOS on-screen GamePad controls as a regular Cemu input device (ControllerBase), attached to the
// emulated Wii U GamePad (VPADController, player 0) through Cemu's existing InputManager and mappings.
// The SwiftUI overlay writes button/stick state through WiiPadInput (lock-free atomics, any thread);
// Cemu reads it in raw_state() when the game calls VPADRead.
//
// Touches on the game view are forwarded to InputManager::m_main_touch, which Cemu's VPADController
// already converts into GamePad touchscreen coordinates (same path as the desktop's touch handler).

#include <cstdint>

namespace WiiPadInput
{
	// Order matches WiiPadButton in CemuBridge.h. Each virtual button i is reported as Cemu button kButton<i>.
	enum Button : uint32_t
	{
		A, B, X, Y,
		L, R, ZL, ZR,
		Plus, Minus,
		Up, Down, Left, Right,
		StickL, StickR,
		Screen, // VPAD "show GamePad screen" mapping (kButtonId_Screen): GamePad image in the game view while held
		Count
	};

	// Creates the touch controller and sets it as the emulated Wii U GamePad (player 0) with fixed mappings.
	// Call once before CafeSystem::LaunchForegroundTitle(). Returns false on failure (logged).
	bool ConnectGamePad();

	// Input sources, kept apart and merged when Cemu reads the GamePad (buttons: either source; sticks: the one deflected
	// most), so releasing an on-screen button never cancels the same button held on a controller.
	enum Source : int { OnScreen = 0, GameController = 1 };

	void SetButton(Button button, bool pressed, Source source = OnScreen);
	// x, y in [-1, 1], y up positive. stick 0 = left, 1 = right
	void SetStick(int stick, float x, float y, Source source = OnScreen);
	// releases every button and centres both sticks of `source` (controller disconnected)
	void ReleaseAll(Source source);
	// the game asked the GamePad to rumble (Cemu's VPAD rumble)
	bool RumbleActive();
	// normalized [0, 1] position in the game view (top-left origin)
	// Touch at a position normalized to [0, 1] (top-left origin). padWindow = false: on the main game view (Cemu's
	// main-window touch); true: on the separate GamePad screen view (Cemu's pad-window touch, desktop PadViewFrame).
	void SetTouch(bool down, float nx, float ny, bool padWindow = false);
}
