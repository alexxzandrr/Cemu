#pragma once

// Frame timing on iPhone/iPad: frames per second, average and worst frame time for the in-game readout, and hitch
// logging to WiiPad.log so stutter can be traced to its cause. Every frame longer than 50 ms ("hitch") is logged
// (rate-limited) with the number of shaders/pipelines compiled while it was rendered; every 30 s a summary line
// (average fps, 1 % low, hitches) is written.
//
// WiiPadPerf_FramePresented() is called by Cemu's GPU thread on every swap (LatteRenderTarget.cpp, BOOST_OS_IOS).

#include <cstdint>

void WiiPadPerf_FramePresented();

namespace WiiPadPerf
{
	struct Stats
	{
		float fps = 0;       // last full second
		float averageMs = 0; // last full second
		float worstMs = 0;   // last full second
	};
	Stats GetStats();
}
