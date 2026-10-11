# Phase 2D — Tilt controls (GamePad motion)

Branch `phase2`. The iPad's gyroscope and accelerometer drive the emulated Wii U GamePad's motion sensors.

## Cemu path (reused)

`VPADController::update_motion` → `EmulatedController::has_motion/get_motion_data` → `ControllerBase::use_motion()` /
`get_motion_sample()` → `MotionSample` (accelerometer, gyro change, orientation, attitude matrix) → `VPADStatus`.
Desktop gyro sources (SDL gamepad sensors, DSU) convert their sensor axes to one convention and fuse them with
`WiiUMotionHandler` (Mahony filter, `input/motion/MotionHandler.h`).

## WiiPad

| Piece | What |
| --- | --- |
| `src/ios/WiiPadMotion.h/.mm` | Core Motion device motion at 100 Hz (main queue). Device axes → SDL's gamepad sensor frame for the current interface orientation (x right, y out of the screen, z toward the player), then exactly the sign/scale steps of `SDLControllerProvider` (`SDL_EVENT_GAMEPAD_SENSOR_UPDATE`) into `WiiUMotionHandler`. `Recenter()` resets the fusion. |
| `src/ios/WiiPadTouchController.cpp` | `has_motion()` / `get_motion_sample()`; `set_use_motion(true)` when the GamePad is connected |
| `src/ios/CemuBridge.h/.mm` | `recenterMotion` |
| `app/WiiPad/Sources/GamePadControls.swift` | "Recenter" button next to − |
| `app/WiiPad/project.yml` | links `CoreMotion` (gyroscope/accelerometer need no permission prompt) |

Hold the iPad like a GamePad (landscape, screen facing you). Log lines: `motion: Core Motion device motion started`,
`motion: first sample (...)`, `motion: recentered`; heartbeat `| motion +N` (samples per interval).
No upstream Cemu file changed.

## Fix: Recenter drifted back (2026-10-11)

Device report: Recenter snapped the view, which then slid back to where it was. Cause: Recenter only reset the sensor
fusion (`WiiUMotionHandler`); the Mahony filter's accelerometer feedback then pulled the fused orientation back to
the real tilt within about a second, so the game saw a jump followed by a slow rotation back.

Now Recenter is a calibration: the current gravity direction (Core Motion `gravity`, gamepad frame) is rotated onto
the "GamePad held upright, screen facing you" reference (shortest-arc rotation), and every later accelerometer and
gyro sample is rotated the same way. The fusion is reset and settled on the rotated gravity at once (500 steps of
20 ms), so the game sees one step to the new centre, yaw included, and nothing to drift back to. Log:
`motion: recentered: current pose is the new upright (it was N deg from upright; ...)`.
