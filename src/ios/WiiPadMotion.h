#pragma once

// iPad gyroscope + accelerometer (Core Motion) as GamePad motion for Cemu (Phase 2D).
// Samples are converted to the same axis convention SDLControllerProvider uses for SDL gamepad sensors and fused with
// Cemu's WiiUMotionHandler (Mahony filter), so VPADController::update_motion receives a normal MotionSample.
// The iPad's screen plays the GamePad's screen: holding the iPad like a GamePad, tilting it tilts the GamePad.

#include "input/motion/MotionSample.h"

namespace WiiPadMotion
{
	bool Available();    // device has a gyroscope and accelerometer (Core Motion device motion)
	void Start();        // starts 100 Hz updates; safe to call more than once
	void Recenter();     // resets the sensor fusion (current pose becomes the starting pose)
	MotionSample GetSample();

	// Game controller motion (DualSense, DualShock 4, Switch Pro): while enabled the device's own sensors are ignored.
	void SetControllerSource(bool enabled);
	// One controller sample: timestamp in seconds, rotation rate in rad/s, total acceleration in g (toward the earth),
	// in the controller's frame (x right, y away from the player, z up out of the face).
	void FeedController(double timestamp, double gyroX, double gyroY, double gyroZ, double accX, double accY, double accZ);
}
