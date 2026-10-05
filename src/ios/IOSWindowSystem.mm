// iPadOS implementation of gui/interface/WindowSystem.h (the desktop builds use wxgui/wxWindowSystem.cpp).
// Phase 1B: no game window or input yet. Sizes come from the UIView handed to CemuBridge.

#include "gui/interface/WindowSystem.h"
#include "WiiPadLog.h"

namespace
{
	WindowSystem::WindowInfo s_windowInfo{};
}

void WindowSystem::Create()
{
	// On iPadOS the SwiftUI app owns the UI; CemuBridge drives initialization instead.
	WiiPadLog::Write("WindowSystem::Create() called (no-op on iPadOS)");
}

void WindowSystem::ShowErrorDialog(std::string_view message, std::string_view title, std::optional<WindowSystem::ErrorCategory> /*errorCategory*/)
{
	// No modal UI from the core yet: record it so it is visible in WiiPad.log and Cemu's log.txt.
	WiiPadLog::Write(fmt::format("Cemu error dialog: [{}] {}", title, message));
	cemuLog_log(LogType::Force, "Error dialog: [{}] {}", title, message);
}

WindowSystem::WindowInfo& WindowSystem::GetWindowInfo()
{
	return s_windowInfo;
}

void WindowSystem::UpdateWindowTitles(bool /*isIdle*/, bool /*isLoading*/, double /*fps*/)
{
}

void WindowSystem::GetWindowSize(int& w, int& h)
{
	w = s_windowInfo.width;
	h = s_windowInfo.height;
}

void WindowSystem::GetPadWindowSize(int& w, int& h)
{
	if (s_windowInfo.pad_open)
	{
		w = s_windowInfo.pad_width;
		h = s_windowInfo.pad_height;
	}
	else
	{
		w = 0;
		h = 0;
	}
}

void WindowSystem::GetWindowPhysSize(int& w, int& h)
{
	w = s_windowInfo.phys_width;
	h = s_windowInfo.phys_height;
}

void WindowSystem::GetPadWindowPhysSize(int& w, int& h)
{
	if (s_windowInfo.pad_open)
	{
		w = s_windowInfo.phys_pad_width;
		h = s_windowInfo.phys_pad_height;
	}
	else
	{
		w = 0;
		h = 0;
	}
}

double WindowSystem::GetWindowDPIScale()
{
	return s_windowInfo.dpi_scale;
}

double WindowSystem::GetPadDPIScale()
{
	return s_windowInfo.pad_open ? s_windowInfo.pad_dpi_scale.load() : 1.0;
}

bool WindowSystem::IsPadWindowOpen()
{
	return s_windowInfo.pad_open;
}

bool WindowSystem::IsKeyDown(uint32 key)
{
	return s_windowInfo.get_keystate(key);
}

bool WindowSystem::IsKeyDown(PlatformKeyCodes /*key*/)
{
	return false; // no hardware keyboard mapping yet
}

std::string WindowSystem::GetKeyCodeName(uint32 key)
{
	return fmt::format("key {}", key);
}

bool WindowSystem::InputConfigWindowHasFocus()
{
	return false;
}

void WindowSystem::NotifyGameLoaded()
{
	WiiPadLog::Write("WindowSystem::NotifyGameLoaded()");
}

void WindowSystem::NotifyGameExited()
{
	WiiPadLog::Write("WindowSystem::NotifyGameExited()");
}

void WindowSystem::RefreshGameList()
{
}

bool WindowSystem::IsFullScreen()
{
	return s_windowInfo.is_fullscreen;
}

void WindowSystem::CaptureInput(const ControllerState& /*currentState*/, const ControllerState& /*lastState*/)
{
}
