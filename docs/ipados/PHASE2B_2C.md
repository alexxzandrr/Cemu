# Phase 2B + 2C — GamePad input and TV audio

Branch `phase2`, from the Phase 2A checkpoint `2e4623c`. Boot path, interpreter and renderer unchanged.

## 2B — Input

### Cemu's existing path (reused)

```
game VPADRead(0)                                   Cafe/OS/libs/vpad/vpad.cpp
 └ InputManager::get_vpad_controller(0)            input/InputManager.cpp   ("connected" = a VPAD exists in slot 0;
 └ VPADController::VPADRead                        input/emulated/            channel 0 is always reported connected)
    ├ controllers_update_states → ControllerBase::update_state → raw_state()   (each attached input device)
    ├ mappings: Wii U button id → device button (kButtonId_A → kButton0, kButtonId_StickL_Up → kAxisYP, ...)
    │   → status.hold/trig/release, leftStick, rightStick (ZL/ZR are digital on the GamePad)
    ├ kButtonId_Screen (no Wii U flag) → is_screen_active() → GamePad image shown in the main view
    └ update_touch → InputManager::get_left_down_mouse_info (m_main_touch / m_main_mouse, window pixels)
        → LatteRenderTarget_getScreenImageArea → Wii U touch coordinates (x*3883+92, 4095-y*3694-254)
```

### WiiPad integration

| Piece | What |
| --- | --- |
| `src/ios/WiiPadTouchController.cpp` | `ControllerBase` subclass (API `WiiPadTouch`). `raw_state()` reads lock-free atomics written by the UI. Set as the VPAD (player 1, slot 0) with fixed mappings before launch. |
| touchscreen | game-view touches → `InputManager::m_main_touch` (same as desktop `MainWindow::OnGesturePan`), in the view's physical pixels |
| `src/input/api/InputAPI.h` | `WiiPadTouch` enum value + name, `#if BOOST_OS_IOS` only |
| `src/ios/CemuBridge.h/.mm` | `setGamePadButton:pressed:`, `setGamePadStick:x:y:`, `setGameViewTouchDown:x:y:`; GamePad connected in `launchTitleAtURL` |
| `app/WiiPad/Sources/GamePadControls.swift` | on-screen ZL/L, left stick, D-pad, −; R/ZR, X/A/B/Y, right stick, +; "Pad view" (holds the VPAD screen mapping) |
| `app/WiiPad/Sources/ContentView.swift` | controls beside the game view while a title runs; `GameSurfaceView` forwards touches |

Not included: motion (needs a motion source; Cemu's fallback is right-mouse-drag), Home (Cemu has no GamePad HOME
Menu: the VPAD Home mapping has no effect), microphone, hardware controllers/keyboards, multi-touch on the game view.

## 2C — Audio

### Cemu's existing path

`snd_core::AXOut_init` → `IAudioAPI::CreateDeviceFromConfig(TV, 48000, 576 frames/block, 16-bit)` using
`config.audio_api` + `tv_device` ("default"). Game audio: `AIInitDMA` → `g_tvAudio->FeedBlock()` (interleaved
s16, channels from `tv_channels`, stereo by default); `AXOut_update` → `Play()` / `NeedAdditionalBlocks()`.
GamePad audio uses `pad_device`, empty by default (also off on desktop until configured).

### Why not Cubeb

Cubeb was turned off in Phase 1B to keep dependencies small. Re-enabling it is not viable without patching the
submodule: Cemu's pinned Cubeb (`2071354`) AudioUnit backend calls macOS-only Core Audio APIs outside its
`TARGET_OS_IPHONE` guards (`AudioObjectGetPropertyData` on the system object, aggregate-device creation via
`kAudioPlugInCreateAggregateDevice`), `cubeb_osx_run_loop.cpp` uses the macOS HAL run-loop property, and its CMake
links `CoreServices` (not on iOS).

### WiiPad backend

| Piece | What |
| --- | --- |
| `src/ios/IOSAudioAPI.h/.mm` | `IAudioAPI` backend: RemoteIO AudioUnit, `AVAudioSession` category Playback, s16 interleaved input; queue + render callback as in `CubebAPI`; config volume applied in the callback |
| `src/audio/IAudioAPI.h/.cpp` | `AudioUnitIOS` enum value, registration, create, device list, log line, `#if BOOST_OS_IOS` only |
| `src/ios/CemuBridge.mm` | after `CemuCommonInit` (which loads the config): `audio_api = AudioUnitIOS`, `tv_device = "default"` (in memory) |
| `app/WiiPad/project.yml` | links `AudioToolbox`, `AVFAudio` |

## Log lines (`WiiPad.log`)

- `audio: backend initialized (...)`, `audio: TV output -> AudioUnit (iOS) ...`, `audio: stream created (...)`,
  `audio: output started`, `audio: first samples submitted by the game (TV)`,
  `audio: first game samples played by the audio device`, `audio: device error: ...`
- `input: Wii U GamePad connected (...)`, `input: game is reading the GamePad (...)`,
  `input: buttons reaching Cemu: A+ZR`, `input: left stick moved (x, y)` / `released`,
  `input: touch down at (x, y) px ...` / `touch released`

Logged on change only (no per-frame lines); the audio thread itself never logs.

## Known limitations

- No motion controls, no Home, no microphone, no hardware controllers.
- GamePad (DRC) audio is not output (no `pad_device`, Cemu's default); TV audio only.
- Audio does not resume after an interruption (phone call, Siri); restart WiiPad.
- Landscape only for the controls (they sit beside the 480×270 game view).
- Touch maps to whichever screen the game view shows; use "Pad view" so touches line up with the GamePad screen.
