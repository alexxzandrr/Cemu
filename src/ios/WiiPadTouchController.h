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

	void SetButton(Button button, bool pressed);
	// x, y in [-1, 1], y up positive. stick 0 = left, 1 = right
	void SetStick(int stick, float x, float y);
	// normalized [0, 1] position in the game view (top-left origin)
	void SetTouch(bool down, float nx, float ny);
}
