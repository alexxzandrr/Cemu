#include "WiiPadMotion.h"
#include "WiiPadDiagnostics.h"
#include "WiiPadLog.h"

#include "input/motion/MotionHandler.h"

#import <CoreMotion/CoreMotion.h>
#import <UIKit/UIKit.h>

#include <algorithm>
#include <cmath>
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

	struct Mat3
	{
		double m[3][3] = { { 1, 0, 0 }, { 0, 1, 0 }, { 0, 0, 1 } };
		Vec3 operator*(const Vec3& v) const
		{
			return { m[0][0] * v.x + m[0][1] * v.y + m[0][2] * v.z,
				m[1][0] * v.x + m[1][1] * v.y + m[1][2] * v.z,
				m[2][0] * v.x + m[2][1] * v.y + m[2][2] * v.z };
		}
	};

	// Recenter calibration (gamepad frame): rotates the iPad's current pose onto the reference pose below, applied to
	// every accelerometer and gyro sample. Identity until the first Recenter.
	Mat3 s_calibration;
	Vec3 s_lastGravity{ 0, 0, 1 }; // latest Core Motion gravity in the gamepad frame (toward the earth, unit)

	// Reference pose: the GamePad held upright in front of you, screen facing you. Gamepad frame (below): gravity
	// toward the earth points along +z (the bottom edge of the screen).
	constexpr Vec3 kUprightGravity{ 0, 0, 1 };

	// Shortest rotation taking unit vector a onto unit vector b.
	Mat3 RotationBetween(const Vec3& a, const Vec3& b)
	{
		const Vec3 v{ a.y * b.z - a.z * b.y, a.z * b.x - a.x * b.z, a.x * b.y - a.y * b.x };
		const double c = a.x * b.x + a.y * b.y + a.z * b.z;
		Mat3 r;
		if (c < -0.9999)
		{
			// opposite: 180 degrees around x (any axis perpendicular to a works; a is close to +-z or +-y here)
			const bool useX = std::fabs(a.x) < 0.9;
			const Vec3 axis = useX ? Vec3{ 1, 0, 0 } : Vec3{ 0, 1, 0 };
			for (int i = 0; i < 3; i++)
				for (int j = 0; j < 3; j++)
				{
					const double ai = i == 0 ? axis.x : i == 1 ? axis.y : axis.z;
					const double aj = j == 0 ? axis.x : j == 1 ? axis.y : axis.z;
					r.m[i][j] = 2.0 * ai * aj - (i == j ? 1.0 : 0.0);
				}
			return r;
		}
		// R = I + [v]x + [v]x^2 / (1 + c)
		const double k = 1.0 / (1.0 + c);
		const double vx[3][3] = { { 0, -v.z, v.y }, { v.z, 0, -v.x }, { -v.y, v.x, 0 } };
		for (int i = 0; i < 3; i++)
			for (int j = 0; j < 3; j++)
			{
				double sq = 0.0;
				for (int n = 0; n < 3; n++)
					sq += vx[i][n] * vx[n][j];
				r.m[i][j] = (i == j ? 1.0 : 0.0) + vx[i][j] + sq * k;
			}
		return r;
	}

	Vec3 Normalized(const Vec3& v)
	{
		const double len = std::sqrt(v.x * v.x + v.y * v.y + v.z * v.z);
		return len > 1e-6 ? Vec3{ v.x / len, v.y / len, v.z / len } : kUprightGravity;
	}

	// same final sign convention as SDLControllerProvider::event_thread (SDL_EVENT_GAMEPAD_SENSOR_UPDATE)
	void Feed(WiiUMotionHandler& handler, double dt, const Vec3& gyro, const Vec3& acc)
	{
		handler.processMotionSample((float)dt, (float)gyro.x, (float)-gyro.y, (float)-gyro.z, (float)acc.x, (float)-acc.y, (float)-acc.z);
	}

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
		const Vec3 rawAcc = ToGamepadFrame({ motion.gravity.x + motion.userAcceleration.x, motion.gravity.y + motion.userAcceleration.y,
			motion.gravity.z + motion.userAcceleration.z }, r, u);
		const Vec3 rawGyro = ToGamepadFrame({ motion.rotationRate.x, motion.rotationRate.y, motion.rotationRate.z }, r, u); // rad/s
		const Vec3 gravity = Normalized(ToGamepadFrame({ motion.gravity.x, motion.gravity.y, motion.gravity.z }, r, u));

		{
			std::scoped_lock lock(s_mutex);
			s_lastGravity = gravity;
			// Recenter calibration: the same rotation for both, so the iPad's frame becomes a rotated GamePad frame
			const Vec3 acc = s_calibration * rawAcc;
			const Vec3 gyro = s_calibration * rawGyro;
			double dt = s_lastTimestamp > 0.0 ? motion.timestamp - s_lastTimestamp : 0.01;
			s_lastTimestamp = motion.timestamp;
			if (dt <= 0.0)
				return;
			if (dt > 1.0)
				dt = 1.0;
			Feed(s_handler, dt, gyro, acc);
			s_sample = s_handler.getMotionSample();
		}
		WiiPadDiag::motionSamples.Hit();
		if (!s_loggedFirst)
		{
			s_loggedFirst = true;
			WiiPadLog::Write(fmt::format("motion: first sample (gamepad frame: acc {:.2f} {:.2f} {:.2f} g, gyro {:.2f} {:.2f} {:.2f} rad/s)",
				rawAcc.x, rawAcc.y, rawAcc.z, rawGyro.x, rawGyro.y, rawGyro.z));
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

	// The iPad's current pose becomes "GamePad held upright, facing you". Resetting the sensor fusion alone (the
	// Phase 2D behaviour) only lasted about a second: the accelerometer pulls the fused orientation back to the real
	// tilt, so the game saw a jump and then a slow drift back. Instead the current gravity direction is rotated onto the
	// upright reference for all later samples, and the fusion is reset and settled in that rotated frame at once, so
	// the game sees a single step to the new centre (yaw included) that stays.
	void Recenter()
	{
		std::scoped_lock lock(s_mutex);
		const Vec3 g = s_lastGravity;
		s_calibration = RotationBetween(g, kUprightGravity);
		s_handler = WiiUMotionHandler{};
		// settle the fusion on the (now upright) gravity: equivalent to ~10 s of holding still, so no visible drift
		const Vec3 settledAcc = s_calibration * g;
		for (int i = 0; i < 500; i++)
			Feed(s_handler, 0.02, Vec3{ 0, 0, 0 }, settledAcc);
		s_sample = s_handler.getMotionSample();
		s_lastTimestamp = 0.0;
		const double tiltDeg = std::acos(std::clamp(g.z, -1.0, 1.0)) * 180.0 / M_PI;
		WiiPadLog::Write(fmt::format("motion: recentered: current pose is the new upright (it was {:.0f} deg from upright; gravity {:.2f} {:.2f} {:.2f})",
			tiltDeg, g.x, g.y, g.z));
	}

	MotionSample GetSample()
	{
		std::scoped_lock lock(s_mutex);
		return s_sample;
	}
}
