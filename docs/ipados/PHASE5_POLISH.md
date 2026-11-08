# Phase 5 — smooth, cool and polished (iPhone Duo first)

Branch `phase2`. Goal: run cooler and smoother on iPhone Duo and iPad, and replace the developer setup screen with a
finished app UI. Researched against EspressU (Cemu-based iOS emulator, MPL-2.0, github.com/EspressU/EspressU-Emu):
its approaches to idle spinning, thread priority, pausing and heat informed this phase; WiiPad's code is its own.
"77u" was also requested as a reference, but no public source or documentation could be found.

## Heat: why the device got hot, and what changed

Desktop Cemu polls in tight loops while the game waits, which on a phone keeps host cores at 100 % even when the game
is idle (waiting for vsync or the next GX2 command):

| Loop | Before | Now (iOS only, `#if BOOST_OS_IOS`) |
| --- | --- | --- |
| CPU scheduler idle (`__OSThreadCoreIdle`, coreinit_Thread.cpp) | spins over the run queues and `__OSCheckSystemEvents` | after 24 (multi-core) / 72 (single-core) empty rounds, and only when no run queue holds a thread, waits ≤ 250 µs (4 ms while paused) on a condition variable; `__OSAddReadyThreadToRunQueue` wakes it at once |
| GPU command wait (`LatteCP_readU32Deprc`) | `_mm_pause` + `yield` | after 64 rounds sleeps 50 µs, after 1024 rounds 250 µs (2 ms while paused) |
| GPU wait for flip (`LatteCP_itHLEWaitForFlip`) | spins up to a whole frame | after 32 rounds sleeps in 100 µs steps |
| GPU semaphore wait | yields after 2000 rounds | also sleeps 50 µs after 20000 rounds |

Emulated CPU threads and the GPU thread run at `QOS_CLASS_USER_INTERACTIVE` (performance cores).

## Output resolution and automatic cooling

`CemuBridge.outputScale` scales the TV and GamePad drawables (and Cemu's window pixel size) while the views keep their
size; Core Animation stretches the smaller drawable. Choices: Native 1.0, High 0.75 (default), Balanced 0.6,
Battery 0.45. With "Cool down automatically" (default on), `GameSession` lowers it to Balanced at thermal state
serious and Battery at critical, and restores it when the device cools (`heat:` lines in WiiPad.log).

## Pause

`WiiPadPause` suspends every guest thread (Cemu's own suspend, as `OSSuspendThread` does) and stops audio; resume undoes
exactly those suspends. `coreinit::g_iosTitlePaused` keeps `AXOut_update` from restarting the audio output and
lengthens the idle waits while paused. With the idle waits above, a paused game uses almost no CPU. Pause holders (`GameSession`):
the menu, the app not being active (Control Center, app switcher, Home), and iPhone Duo folded shut
(`onHingeChange`, iOS 27.1; setting "Pause when iPhone Duo is closed"). The game runs while no holder remains.

## UI

| Screen | What |
| --- | --- |
| Home (`Library.swift`) | library grid with each game's own name and icon, read from the user's dump at runtime (`inspectTitleAtURL:` mounts the title and decodes `meta/iconTex.tga`, as the desktop game list does); engine and JIT status pills (tap to enable JIT); add game folder or file; recently played first |
| Launch | game icon and name while Cemu prepares the title |
| In game | bar with menu and (single screen) TV/GamePad swap, optional FPS + heat; GamePad controls restyled (flat translucent, no blur over the game, accent press state, haptics, joined D-pad) |
| Pause menu (`GameSession.swift`) | resume, screens, resolution, hide controls, recenter tilt, FPS, settings, quit (WiiPad exits: Cemu cannot unload a game) |
| Settings (`SettingsView.swift`) | performance, emulation, screens, controls, JIT, diagnostics |

`Theme.swift` holds colours, fonts and button styles. Blur materials appear only on screens shown while the game is
paused or not running.

Also: `GCSupportsGameMode` (Game Mode) and the games app category in Info.plist.

## Review

An independent review of the diff (before device testing) found and this phase fixed: idle-wait latency in single-core
mode (a thread queued for another core waited for a timeout), audio restarting during a pause, the pause UI state
drifting from the core's, and too-frequent wakeups while paused.

## Phase 5b — controllers and stutter tracing

**Bluetooth controllers** (`Controllers.swift`): DualSense, DualShock 4, Xbox, Switch Pro and MFi controllers through
GameController, mapped onto the emulated GamePad as a second input source (`WiiPadInput::Source::GameController`),
merged with the on-screen controls when Cemu reads the GamePad (buttons: either; sticks: the one deflected most).
Face buttons by Wii U position (○ A, ✕ B, △ X, □ Y) or by Xbox letters. Controller gyro → GamePad motion (the first
sample becomes "upright", like Recenter; the device's own motion updates stop meanwhile). Game rumble → controller
haptics (latched in C++ so pulses shorter than the 30 Hz poll aren't lost; looping haptic player). PS/Home button →
WiiPad's menu (only while a game runs and Settings is closed); touchpad click → GamePad screen. On-screen controls
hide while a controller is connected. Events arrive on a background queue.

**Stutter tracing** (`WiiPadPerf.cpp`): every frame is timed on the GPU thread. Frames over 50 ms are logged
(`perf: hitch …`) with the number of shaders/pipelines compiled meanwhile (`g_wiipadCompiledShaders`, a counter that
the "compiled N shaders" notification doesn't reset), and a 30 s summary (`perf: last 30 s …`: average, 1 % low,
worst frame, hitches, available memory). Log lines are written from a background queue. The in-game readout shows
FPS and the worst frame time of the last second.

**Compile threads** (Metal shader and pipeline compilers) run at user-initiated QoS, below the game's
user-interactive CPU and GPU threads, so background compiling doesn't take the performance cores (the A-series chip in
iPhone Duo has two). When the GPU thread has to wait for a shader a compile thread is working on, that thread's QoS is
raised to user-interactive for the wait (`pthread_override_qos_class_start_np`).
