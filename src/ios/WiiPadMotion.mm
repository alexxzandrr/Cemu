#include "WiiPadMotion.h"
#include "WiiPadDiagnostics.h"
#include "WiiPadLog.h"

#include "input/motion/MotionHandler.h"

#import <CoreMotion/CoreMotion.h>
#import <UIKit/UIKit.h>

#include <mutex>

namespace
{
	CMMotionManager* s_manager = nil;
	std::mutex s_mutex;
	WiiUMotionHandler s_handler;
	MotionSample s_sample;
	double s_lastTimestamp = 0.0;
	bool s_loggedFirst = false;

	struct Vec3
	{
		double x, y, z;
	};

	// Current interface orientation (main thread): which device axes point to the right and up on screen.
	// Device frame (Core Motion): x = right edge, y = top edge (portrait), z = out of the screen.
	void ScreenAxes(double r[2], double u[2])
	{
		UIInterfaceOrientation orientation = UIInterfaceOrientationLandscapeRight;
		for (UIScene* scene in UIApplication.sharedApplication.connectedScenes)
		{
			if ([scene isKindOfClass:[UIWindowScene class]])
			{
				orientation = ((UIWindowScene*)scene).interfaceOrientation;
				break;
			}
		}
		switch (orientation)
		{
		case UIInterfaceOrientationPortraitUpsideDown: r[0] = -1; r[1] = 0;  u[0] = 0;  u[1] = -1; break;
		case UIInterfaceOrientationLandscapeLeft:      r[0] = 0;  r[1] = 1;  u[0] = -1; u[1] = 0;  break; // device top on the right
		case UIInterfaceOrientationLandscapeRight:     r[0] = 0;  r[1] = -1; u[0] = 1;  u[1] = 0;  break; // device top on the left
		default:                                       r[0] = 1;  r[1] = 0;  u[0] = 0;  u[1] = 1;  break; // portrait
		}
	}

	// Device frame -> gamepad frame as SDL defines it for gamepad sensors (held in front of you, face up):
	// x = right, y = up out of the face (the screen), z = toward the player (the bottom edge of the screen).
	// Right-handed, so rotation rates map the same way as vectors.
	Vec3 ToGamepadFrame(const Vec3& v, const double r[2], const double u[2])
	{
		return { v.x * r[0] + v.y * r[1], v.z, -(v.x * u[0] + v.y * u[1]) };
	}

	void HandleMotion(CMDeviceMotion* motion)
	{
		double r[2], u[2];
		ScreenAxes(r, u);
		// Core Motion acceleration is in g and points toward the earth (flat, face up: z = -1); SDL's is in m/s^2 and
		// points away from it. SDLControllerProvider negates and scales SDL values, so the Core Motion vector mapped
		// into the gamepad frame equals SDL's intermediate "tracking.acc" directly.
		const Vec3 acc = ToGamepadFrame({ motion.gravity.x + motion.userAcceleration.x, motion.gravity.y + motion.userAcceleration.y,
			motion.gravity.z + motion.userAcceleration.z }, r, u);
		const Vec3 gyro = ToGamepadFrame({ motion.rotationRate.x, motion.rotationRate.y, motion.rotationRate.z }, r, u); // rad/s

		{
			std::scoped_lock lock(s_mutex);
			double dt = s_lastTimestamp > 0.0 ? motion.timestamp - s_lastTimestamp : 0.01;
			s_lastTimestamp = motion.timestamp;
			if (dt <= 0.0)
				return;
			if (dt > 1.0)
				dt = 1.0;
			// same final sign convention as SDLControllerProvider::event_thread (SDL_EVENT_GAMEPAD_SENSOR_UPDATE)
			s_handler.processMotionSample((float)dt, (float)gyro.x, (float)-gyro.y, (float)-gyro.z, (float)acc.x, (float)-acc.y, (float)-acc.z);
			s_sample = s_handler.getMotionSample();
		}
		WiiPadDiag::motionSamples.Hit();
		if (!s_loggedFirst)
		{
			s_loggedFirst = true;
			WiiPadLog::Write(fmt::format("motion: first sample (gamepad frame: acc {:.2f} {:.2f} {:.2f} g, gyro {:.2f} {:.2f} {:.2f} rad/s)",
				acc.x, acc.y, acc.z, gyro.x, gyro.y, gyro.z));
		}
	}
}

namespace WiiPadMotion
{
	bool Available()
	{
		static const bool available = [] {
			CMMotionManager* manager = [[CMMotionManager alloc] init];
			return (bool)manager.deviceMotionAvailable;
		}();
		return available;
	}

	void Start()
	{
		dispatch_async(dispatch_get_main_queue(), ^{
			if (s_manager)
				return;
			s_manager = [[CMMotionManager alloc] init];
			if (!s_manager.deviceMotionAvailable)
			{
				WiiPadLog::Write("motion: device motion (gyroscope + accelerometer) not available; no tilt controls");
				return;
			}
			s_manager.deviceMotionUpdateInterval = 0.01; // 100 Hz
			// main queue: the handler reads the interface orientation from UIKit
			[s_manager startDeviceMotionUpdatesToQueue:NSOperationQueue.mainQueue withHandler:^(CMDeviceMotion* motion, NSError* error) {
				if (error)
				{
					WiiPadLog::Write(std::string("motion: device error: ") + (error.localizedDescription.UTF8String ?: "?"));
					return;
				}
				if (motion)
					HandleMotion(motion);
			}];
			WiiPadLog::Write("motion: Core Motion device motion started (100 Hz) -> GamePad gyro/accelerometer");
		});
	}

	void Recenter()
	{
		std::scoped_lock lock(s_mutex);
		s_handler = WiiUMotionHandler{};
		s_lastTimestamp = 0.0;
		WiiPadLog::Write("motion: recentered (sensor fusion reset)");
	}

	MotionSample GetSample()
	{
		std::scoped_lock lock(s_mutex);
		return s_sample;
	}
}
