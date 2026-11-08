// WiiPad frame timing and hitch logging. See WiiPadPerf.h.

#include "WiiPadPerf.h"
#include "WiiPadLog.h"

#include <algorithm>
#include <atomic>
#include <chrono>
#include <mutex>
#include <string>
#include <vector>

#include <dispatch/dispatch.h>
#include <os/proc.h>

// Shaders and Metal pipelines compiled so far. Incremented next to Cemu's own counters (RendererShaderMtl.cpp,
// MetalPipelineCompiler.cpp, BOOST_OS_IOS); those are reset by the "compiled N shaders" notification, this one isn't.
std::atomic_int g_wiipadCompiledShaders{ 0 };

// Memory pressure from the memory iOS still allows WiiPad (os_proc_available_memory), refreshed every 15 frames:
// 0 normal, 1 low (< 900 MB), 2 critical (< 450 MB). The texture cache evicts sooner as it rises (LatteTextureCache.cpp).
std::atomic<int> g_iosMemoryPressure{ 0 };
std::atomic<int> g_iosTextureCount{ 0 };   // textures in Cemu's cache (written by the texture cleanup)
std::atomic<int> g_iosTexturesEvicted{ 0 }; // RAM-backed textures freed early (iOS policy)

namespace coreinit
{
	extern std::atomic<bool> g_iosTitlePaused; // coreinit_Thread.cpp
}

namespace
{
	using Clock = std::chrono::steady_clock;

	constexpr double kHitchMs = 50.0;        // a frame this long is a visible stutter at 30 or 60 fps
	constexpr double kGapMs = 1000.0;        // longer: a pause, loading or the app in the background, not a hitch
	constexpr double kSummarySeconds = 30.0;

	// GPU thread only
	Clock::time_point s_lastFrame{};
	int s_lastShaderCount = 0;
	Clock::time_point s_windowStart{};
	int s_windowFrames = 0;
	double s_windowSumMs = 0.0;
	double s_windowWorstMs = 0.0;
	Clock::time_point s_summaryStart{};
	std::vector<float> s_summaryFrameMs;
	int s_summaryHitches = 0;
	int s_summaryHitchesWithShaders = 0;
	Clock::time_point s_lastHitchLog{};
	int s_suppressedHitches = 0;

	int s_lastEvicted = 0; // evictions counted at the last summary

	std::mutex s_statsMutex;
	WiiPadPerf::Stats s_stats;
	Clock::time_point s_statsTime{};

	// WiiPadLog::Write syncs the file to disk: never on the GPU thread, whose frames are being measured
	void LogAsync(std::string line)
	{
		static dispatch_queue_t queue = dispatch_queue_create("wiipad.perf.log", DISPATCH_QUEUE_SERIAL);
		auto* heapLine = new std::string(std::move(line));
		dispatch_async_f(queue, heapLine, [](void* context) {
			auto* text = static_cast<std::string*>(context);
			WiiPadLog::Write(*text);
			delete text;
		});
	}

	double Ms(Clock::duration d)
	{
		return std::chrono::duration<double, std::milli>(d).count();
	}

	void WriteSummary(double seconds)
	{
		if (s_summaryFrameMs.empty())
			return;
		std::vector<float> sorted = s_summaryFrameMs;
		std::sort(sorted.begin(), sorted.end());
		const float p99 = sorted[std::min(sorted.size() - 1, (size_t)(sorted.size() * 0.99))];
		double sum = 0.0;
		for (float ms : s_summaryFrameMs)
			sum += ms;
		const double avgMs = sum / s_summaryFrameMs.size();
		LogAsync(fmt::format("perf: last {:.0f} s: {:.1f} fps average, 1% low {:.1f} fps (frame {:.1f} ms), worst frame {:.0f} ms, "
			"{} hitches > {:.0f} ms ({} while shaders compiled), {} MB memory still available to WiiPad, {} textures cached, {} freed early",
			seconds, 1000.0 / avgMs, 1000.0 / p99, p99, sorted.back(), s_summaryHitches, kHitchMs, s_summaryHitchesWithShaders,
			os_proc_available_memory() >> 20, g_iosTextureCount.load(std::memory_order_relaxed),
			g_iosTexturesEvicted.load(std::memory_order_relaxed) - s_lastEvicted));
		s_lastEvicted = g_iosTexturesEvicted.load(std::memory_order_relaxed);
	}
}

namespace
{
	int s_framesSincePressureCheck = 0;
	int s_lastLoggedPressure = 0;

	void UpdateMemoryPressure()
	{
		const size_t availableMB = os_proc_available_memory() >> 20;
		const int level = availableMB < 450 ? 2 : (availableMB < 900 ? 1 : 0);
		g_iosMemoryPressure.store(level, std::memory_order_relaxed);
		if (level != s_lastLoggedPressure)
		{
			static const char* names[] = { "normal", "low", "critical" };
			LogAsync(fmt::format("memory: pressure {} ({} MB still available to WiiPad, {} textures cached): {}",
				names[level], availableMB, g_iosTextureCount.load(std::memory_order_relaxed),
				level > s_lastLoggedPressure ? "freeing unused textures sooner" : "back to the normal texture cache policy"));
			s_lastLoggedPressure = level;
		}
	}
}

void WiiPadPerf_FramePresented()
{
	if (++s_framesSincePressureCheck >= 15)
	{
		s_framesSincePressureCheck = 0;
		UpdateMemoryPressure();
	}
	const auto now = Clock::now();
	const int shaders = g_wiipadCompiledShaders.load(std::memory_order_relaxed);
	if (s_lastFrame == Clock::time_point{})
	{
		s_lastFrame = s_windowStart = s_summaryStart = now;
		s_lastShaderCount = shaders;
		return;
	}
	const double frameMs = Ms(now - s_lastFrame);
	const int newShaders = shaders - s_lastShaderCount;
	s_lastFrame = now;
	s_lastShaderCount = shaders;

	if (frameMs >= kGapMs || coreinit::g_iosTitlePaused.load(std::memory_order_relaxed))
	{
		// paused, loading or in the background: start fresh windows
		s_windowStart = s_summaryStart = now;
		s_windowFrames = 0;
		s_windowSumMs = s_windowWorstMs = 0.0;
		s_summaryFrameMs.clear();
		s_summaryHitches = s_summaryHitchesWithShaders = 0;
		return;
	}

	s_windowFrames++;
	s_windowSumMs += frameMs;
	s_windowWorstMs = std::max(s_windowWorstMs, frameMs);
	s_summaryFrameMs.push_back((float)frameMs);

	if (frameMs > kHitchMs)
	{
		s_summaryHitches++;
		if (newShaders > 0)
			s_summaryHitchesWithShaders++;
		// at most two lines per second; the rest are counted in the next line
		if (Ms(now - s_lastHitchLog) >= 500.0)
		{
			LogAsync(fmt::format("perf: hitch {:.0f} ms{}{}", frameMs,
				newShaders > 0 ? fmt::format(", {} shader(s)/pipeline(s) compiled during it", newShaders) : std::string(", no new shaders"),
				s_suppressedHitches > 0 ? fmt::format(" (+{} more since the last line)", s_suppressedHitches) : std::string()));
			s_lastHitchLog = now;
			s_suppressedHitches = 0;
		}
		else
			s_suppressedHitches++;
	}

	const double windowMs = Ms(now - s_windowStart);
	if (windowMs >= 1000.0 && s_windowFrames > 0)
	{
		{
			std::lock_guard lock(s_statsMutex);
			s_stats.fps = (float)(s_windowFrames * 1000.0 / windowMs);
			s_stats.averageMs = (float)(s_windowSumMs / s_windowFrames);
			s_stats.worstMs = (float)s_windowWorstMs;
			s_statsTime = now;
		}
		s_windowStart = now;
		s_windowFrames = 0;
		s_windowSumMs = s_windowWorstMs = 0.0;
	}

	const double summarySeconds = Ms(now - s_summaryStart) / 1000.0;
	if (summarySeconds >= kSummarySeconds)
	{
		WriteSummary(summarySeconds);
		s_summaryStart = now;
		s_summaryFrameMs.clear();
		s_summaryHitches = s_summaryHitchesWithShaders = 0;
	}
}

namespace WiiPadPerf
{
	Stats GetStats()
	{
		std::lock_guard lock(s_statsMutex);
		// no frames for a while (paused, loading, stopped): report zeros rather than the last second that had frames
		if (s_statsTime == Clock::time_point{} || Ms(Clock::now() - s_statsTime) > 1500.0)
			return Stats{};
		return s_stats;
	}
}
