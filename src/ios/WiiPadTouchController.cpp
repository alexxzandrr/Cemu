#include "WiiPadTouchController.h"
#include "WiiPadLog.h"
#include "WiiPadDiagnostics.h"
#include "WiiPadMotion.h"

#include "input/InputManager.h"
#include "input/api/Controller.h"
#include "input/emulated/VPADController.h"
#include "gui/interface/WindowSystem.h"

#include <atomic>

namespace
{
	// state written by the UI (main thread), read by Cemu (emulation thread); one set per source
	// (WiiPadInput::Source: on-screen controls, game controller), merged in raw_state()
	constexpr int kSources = 2;
	std::atomic<uint32_t> s_buttons[kSources]{};
	std::atomic<float> s_stick[kSources][2][2]{}; // [source][stick][x/y]
	std::atomic<bool> s_rumble{ false };          // set by Cemu (VPAD rumble), polled by the app
	std::atomic<bool> s_rumbleSeen{ false };      // latched start: a pulse shorter than the app's poll interval still counts
	bool s_touchDown = false;                     // main thread only (logging)

	// the stick from the source that is deflected most
	glm::vec2 MergedStick(int stick)
	{
		glm::vec2 best{ 0.0f, 0.0f };
		float bestLength = 0.0f;
		for (int source = 0; source < kSources; source++)
		{
			const glm::vec2 v{ s_stick[source][stick][0].load(std::memory_order_relaxed),
				s_stick[source][stick][1].load(std::memory_order_relaxed) };
			const float length = v.x * v.x + v.y * v.y;
			if (length > bestLength)
			{
				best = v;
				bestLength = length;
			}
		}
		return best;
	}

	const char* kButtonNames[WiiPadInput::Count] = {
		"A", "B", "X", "Y", "L", "R", "ZL", "ZR", "+", "-", "Up", "Down", "Left", "Right", "StickL", "StickR", "Screen"
	};

	std::string ButtonList(uint32_t mask)
	{
		std::string s;
		for (uint32_t i = 0; i < WiiPadInput::Count; i++)
		{
			if (mask & (1u << i))
			{
				if (!s.empty())
					s += "+";
				s += kButtonNames[i];
			}
		}
		return s.empty() ? std::string("none") : s;
	}

	class WiiPadTouchController : public ControllerBase
	{
	public:
		WiiPadTouchController() : ControllerBase("wiipad-touch", "WiiPad on-screen controls") {}

		std::string_view api_name() const override { return to_string(InputAPI::WiiPadTouch); }
		InputAPI::Type api() const override { return InputAPI::WiiPadTouch; }
		bool is_connected() override { return true; }

		// iPad gyroscope/accelerometer as GamePad motion (VPADController::update_motion uses it when use_motion())
		bool has_motion() override { return WiiPadMotion::Available(); }
		MotionSample get_motion_sample() override { return WiiPadMotion::GetSample(); }

		// GamePad rumble: forwarded to a connected game controller by the app (CemuBridge.gamePadRumble)
		bool has_rumble() override { return true; }
		void start_rumble() override
		{
			s_rumble.store(true, std::memory_order_relaxed);
			s_rumbleSeen.store(true, std::memory_order_relaxed);
		}
		void stop_rumble() override { s_rumble.store(false, std::memory_order_relaxed); }

		// Called by VPADController::VPADRead (emulation thread) through update_state()
		ControllerState raw_state() override
		{
			ControllerState result{};
			uint32_t mask = 0;
			for (int source = 0; source < kSources; source++)
				mask |= s_buttons[source].load(std::memory_order_relaxed);
			for (uint32_t i = 0; i < WiiPadInput::Count; i++)
			{
				if (mask & (1u << i))
					result.buttons.SetButtonState(kButton0 + i, true);
			}
			result.axis = MergedStick(0);
			result.rotation = MergedStick(1);

			if (m_logging) // false during calibrate(): only count reads made by the game's VPADRead
			{
				WiiPadDiag::vpadRead.Hit();
				LogChanges(mask, result);
			}
			return result;
		}

		void EnableLogging() { m_logging = true; }

	private:
		// lightweight: one line when the game first reads the GamePad, then only on changes
		void LogChanges(uint32_t mask, const ControllerState& state)
		{
			if (!m_loggedFirstRead)
			{
				m_loggedFirstRead = true;
				WiiPadLog::Write("input: game is reading the GamePad (VPADRead -> WiiPad on-screen controls)");
			}
			if (mask != m_lastMask)
			{
				WiiPadLog::Write(fmt::format("input: buttons reaching Cemu: {}", ButtonList(mask)));
				m_lastMask = mask;
			}
			const glm::vec2 sticks[2] = { state.axis, state.rotation };
			for (int i = 0; i < 2; i++)
			{
				const bool active = glm::length(sticks[i]) > 0.25f; // Cemu's default stick deadzone
				if (active != m_stickActive[i])
				{
					m_stickActive[i] = active;
					if (active)
						WiiPadLog::Write(fmt::format("input: {} stick moved ({:.2f}, {:.2f})", i == 0 ? "left" : "right", sticks[i].x, sticks[i].y));
					else
						WiiPadLog::Write(fmt::format("input: {} stick released", i == 0 ? "left" : "right"));
				}
			}
		}

		bool m_logging = false;
		bool m_loggedFirstRead = false;
		uint32_t m_lastMask = 0;
		bool m_stickActive[2]{};
	};
}

namespace WiiPadInput
{
	bool ConnectGamePad()
	{
		try
		{
			auto controller = std::make_shared<WiiPadTouchController>();
			controller->calibrate(); // nothing is pressed yet: neutral state
			if (WiiPadMotion::Available())
			{
				controller->set_use_motion(true);
				WiiPadMotion::Start();
			}

			auto& input = InputManager::instance();
			auto emulated = input.set_controller(0, EmulatedController::Type::VPAD, controller);
			if (!emulated)
			{
				WiiPadLog::Write("input: could not create the emulated Wii U GamePad");
				return false;
			}

			auto button = [](Button b) { return (uint64)(kButton0 + b); };
			const std::pair<uint64, uint64> mappings[] = {
				{ VPADController::kButtonId_A, button(A) },
				{ VPADController::kButtonId_B, button(B) },
				{ VPADController::kButtonId_X, button(X) },
				{ VPADController::kButtonId_Y, button(Y) },
				{ VPADController::kButtonId_L, button(L) },
				{ VPADController::kButtonId_R, button(R) },
				{ VPADController::kButtonId_ZL, button(ZL) },
				{ VPADController::kButtonId_ZR, button(ZR) },
				{ VPADController::kButtonId_Plus, button(Plus) },
				{ VPADController::kButtonId_Minus, button(Minus) },
				{ VPADController::kButtonId_Up, button(Up) },
				{ VPADController::kButtonId_Down, button(Down) },
				{ VPADController::kButtonId_Left, button(Left) },
				{ VPADController::kButtonId_Right, button(Right) },
				{ VPADController::kButtonId_StickL, button(StickL) },
				{ VPADController::kButtonId_StickR, button(StickR) },
				{ VPADController::kButtonId_Screen, button(Screen) },
				{ VPADController::kButtonId_StickL_Up, kAxisYP },
				{ VPADController::kButtonId_StickL_Down, kAxisYN },
				{ VPADController::kButtonId_StickL_Left, kAxisXN },
				{ VPADController::kButtonId_StickL_Right, kAxisXP },
				{ VPADController::kButtonId_StickR_Up, kRotationYP },
				{ VPADController::kButtonId_StickR_Down, kRotationYN },
				{ VPADController::kButtonId_StickR_Left, kRotationXN },
				{ VPADController::kButtonId_StickR_Right, kRotationXP },
			};
			for (const auto& [vpadButton, controllerButton] : mappings)
				emulated->set_mapping(vpadButton, controller, controllerButton);

			controller->EnableLogging();
			const bool attached = input.get_vpad_controller(0) == emulated;
			WiiPadLog::Write(fmt::format("input: Wii U GamePad connected (player 1, VPAD slot 0{}): WiiPad on-screen controls, {} mappings, touch -> GamePad touchscreen, motion: {}",
				attached ? "" : " - NOT in slot 0", std::size(mappings), WiiPadMotion::Available() ? "iPad gyroscope + accelerometer" : "not available"));
			return attached;
		}
		catch (const std::exception& ex)
		{
			WiiPadLog::Write(std::string("input: GamePad setup failed: ") + ex.what());
			return false;
		}
	}

	void SetButton(Button button, bool pressed, Source source)
	{
		if (button >= Count || source < 0 || source >= kSources)
			return;
		if (pressed)
			s_buttons[source].fetch_or(1u << button, std::memory_order_relaxed);
		else
			s_buttons[source].fetch_and(~(1u << button), std::memory_order_relaxed);
	}

	void SetStick(int stick, float x, float y, Source source)
	{
		if (stick < 0 || stick > 1 || source < 0 || source >= kSources)
			return;
		s_stick[source][stick][0].store(std::clamp(x, -1.0f, 1.0f), std::memory_order_relaxed);
		s_stick[source][stick][1].store(std::clamp(y, -1.0f, 1.0f), std::memory_order_relaxed);
	}

	void ReleaseAll(Source source)
	{
		if (source < 0 || source >= kSources)
			return;
		s_buttons[source].store(0, std::memory_order_relaxed);
		for (int stick = 0; stick < 2; stick++)
			for (int axis = 0; axis < 2; axis++)
				s_stick[source][stick][axis].store(0.0f, std::memory_order_relaxed);
	}

	bool RumbleActive()
	{
		const bool seen = s_rumbleSeen.exchange(false, std::memory_order_relaxed);
		return s_rumble.load(std::memory_order_relaxed) || seen;
	}

	void SetTouch(bool down, float nx, float ny, bool padWindow)
	{
		int w = 0, h = 0;
		if (padWindow)
			WindowSystem::GetPadWindowPhysSize(w, h);
		else
			WindowSystem::GetWindowPhysSize(w, h);
		const glm::ivec2 pos{ (int)(std::clamp(nx, 0.0f, 1.0f) * w), (int)(std::clamp(ny, 0.0f, 1.0f) * h) };

		auto& input = InputManager::instance();
		{
			// same as the desktop touch handlers (wxgui MainWindow / PadViewFrame::OnGesturePan)
			auto& touch = padWindow ? input.m_pad_touch : input.m_main_touch;
			std::scoped_lock lock(touch.m_mutex);
			touch.position = pos;
			touch.left_down = down;
			if (down)
				touch.left_down_toggle = true;
		}

		if (down != s_touchDown)
		{
			s_touchDown = down;
			if (down)
				WiiPadLog::Write(fmt::format("input: touch down at ({}, {}) px of {}x{} on the {} view -> GamePad touchscreen",
					pos.x, pos.y, w, h, padWindow ? "GamePad" : "game"));
			else
				WiiPadLog::Write("input: touch released");
		}
	}
}
