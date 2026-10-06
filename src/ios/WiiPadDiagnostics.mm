#include "WiiPadDiagnostics.h"
#include "WiiPadLog.h"

#include "Cafe/HW/Latte/Core/Latte.h"
#include "Cafe/OS/libs/coreinit/coreinit_Scheduler.h"
#include "Cafe/OS/libs/coreinit/coreinit_Thread.h"
#include "Cafe/OS/RPL/rpl_symbol_storage.h"
#include "util/helpers/helpers.h"
#include "util/Fiber/Fiber.h"

#include <chrono>
#include <cxxabi.h>
#include <dlfcn.h>
#include <mach/mach.h>
#include <mach/thread_info.h>
#include <pthread.h>
#include <thread>
#include <unordered_map>

// Cafe/HW/Espresso/PPCTimer.cpp: host counter (cntvct_el0) frequency measured at startup; guest time derives from it
extern uint64 _rdtscFrequency;

namespace WiiPadDiag
{
	Counter vpadRead, schedulerEvents, audioPlay, audioFeed, audioRender, audioRenderData, motionSamples;

	static int64_t NowNs()
	{
		return std::chrono::duration_cast<std::chrono::nanoseconds>(std::chrono::steady_clock::now().time_since_epoch()).count();
	}

	void Counter::Hit()
	{
		count.fetch_add(1, std::memory_order_relaxed);
		lastNs.store(NowNs(), std::memory_order_relaxed);
	}
}

namespace
{
	using namespace WiiPadDiag;

	int64_t s_startNs = 0;

	std::string Ago(const Counter& c)
	{
		const int64_t last = c.lastNs.load(std::memory_order_relaxed);
		if (last == 0)
			return "never";
		return fmt::format("{:.1f}s ago", (NowNs() - last) / 1e9);
	}

	// ---------------- host threads (Mach) ----------------

	struct HostThread
	{
		thread_act_t port;
		std::string name;
		int runState;
		double cpuSeconds;
	};

	const char* RunStateName(int s)
	{
		switch (s)
		{
		case TH_STATE_RUNNING: return "running";
		case TH_STATE_STOPPED: return "stopped";
		case TH_STATE_WAITING: return "waiting";
		case TH_STATE_UNINTERRUPTIBLE: return "uninterruptible";
		case TH_STATE_HALTED: return "halted";
		default: return "?";
		}
	}

	// Caller must deallocate the ports via ReleaseThreads().
	std::vector<HostThread> ListHostThreads()
	{
		std::vector<HostThread> result;
		thread_act_array_t threads = nullptr;
		mach_msg_type_number_t count = 0;
		if (task_threads(mach_task_self(), &threads, &count) != KERN_SUCCESS)
			return result;
		for (mach_msg_type_number_t i = 0; i < count; i++)
		{
			thread_extended_info_data_t info{};
			mach_msg_type_number_t infoCount = THREAD_EXTENDED_INFO_COUNT;
			HostThread t{ threads[i], "", 0, 0.0 };
			if (thread_info(threads[i], THREAD_EXTENDED_INFO, (thread_info_t)&info, &infoCount) == KERN_SUCCESS)
			{
				t.name = info.pth_name;
				t.runState = info.pth_run_state;
				t.cpuSeconds = (info.pth_user_time + info.pth_system_time) / 1e9;
			}
			result.push_back(std::move(t));
		}
		vm_deallocate(mach_task_self(), (vm_address_t)threads, count * sizeof(thread_act_t));
		return result;
	}

	void ReleaseThreads(std::vector<HostThread>& threads)
	{
		for (auto& t : threads)
			mach_port_deallocate(mach_task_self(), t.port);
		threads.clear();
	}

	bool ReadWord(uint64_t address, uint64_t& value)
	{
		vm_size_t size = 0;
		return vm_read_overwrite(mach_task_self(), (vm_address_t)address, sizeof(value), (vm_address_t)&value, &size) == KERN_SUCCESS && size == sizeof(value);
	}

	// Suspends the thread only while copying registers and frame-pointer return addresses into a fixed array
	// (no allocation, no locks while it is suspended), then symbolizes after resuming.
	int SampleBacktrace(thread_act_t thread, uint64_t* frames, int maxFrames)
	{
		if (thread == pthread_mach_thread_np(pthread_self())) // never suspend the monitor itself
			return 0;
		if (thread_suspend(thread) != KERN_SUCCESS)
			return 0;
		int n = 0;
		arm_thread_state64_t state{};
		mach_msg_type_number_t stateCount = ARM_THREAD_STATE64_COUNT;
		if (thread_get_state(thread, ARM_THREAD_STATE64, (thread_state_t)&state, &stateCount) == KERN_SUCCESS)
		{
			frames[n++] = (uint64_t)arm_thread_state64_get_pc(state);
			frames[n++] = (uint64_t)arm_thread_state64_get_lr(state);
			uint64_t fp = (uint64_t)arm_thread_state64_get_fp(state);
			while (n < maxFrames && fp != 0 && (fp & 0xF) == 0)
			{
				uint64_t nextFp = 0, ret = 0;
				if (!ReadWord(fp, nextFp) || !ReadWord(fp + 8, ret) || ret == 0)
					break;
				frames[n++] = ret;
				if (nextFp <= fp)
					break;
				fp = nextFp;
			}
		}
		thread_resume(thread);
		return n;
	}

	std::string Symbolize(uint64_t address)
	{
		Dl_info info{};
		uint64_t candidates[] = { address, address & 0x00007FFFFFFFFFFFull, address & 0x0000000FFFFFFFFFull }; // strip pointer-auth bits if any
		for (uint64_t a : candidates)
		{
			if (!dladdr((void*)a, &info) || !info.dli_fname)
				continue;
			const char* image = strrchr(info.dli_fname, '/');
			image = image ? image + 1 : info.dli_fname;
			std::string symbol = "?";
			uint64_t offset = a - (uint64_t)info.dli_fbase;
			if (info.dli_sname)
			{
				int status = 0;
				char* demangled = abi::__cxa_demangle(info.dli_sname, nullptr, nullptr, &status);
				symbol = (status == 0 && demangled) ? demangled : info.dli_sname;
				free(demangled);
				offset = a - (uint64_t)info.dli_saddr;
				if (symbol.size() > 140)
					symbol = symbol.substr(0, 140) + "...";
			}
			return fmt::format("{} {} +0x{:x}", image, symbol, offset);
		}
		return fmt::format("0x{:x}", address);
	}

	bool IsInterestingThread(const std::string& name)
	{
		return name.rfind("OSSched", 0) == 0 || name == "LatteThread" || name == "Input_update" ||
			name.find("AURemoteIO") != std::string::npos || name.find("audio") != std::string::npos;
	}

	// ---------------- guest (emulated PPC) threads ----------------

	struct GuestThread
	{
		uint32 address, srr0, lr, waitingForMutex, waitQueue;
		sint32 suspendCounter, priority;
		uint16 id;
		uint8 state;
		char name[48];
	};

	const char* GuestStateName(uint8 s)
	{
		switch (s)
		{
		case 0: return "none";
		case 1: return "ready";
		case 2: return "RUNNING";
		case 4: return "waiting";
		case 8: return "moribund";
		default: return "?";
		}
	}

	std::string GuestSymbol(uint32 address)
	{
		if (address == 0)
			return "-";
		RPLStoredSymbol* s = rplSymbolStorage_getByClosestAddress(address);
		if (!s || !s->symbolName)
			return fmt::format("{:08x}", address);
		return fmt::format("{:08x} {}.{}+0x{:x}", address, s->libName ? (const char*)s->libName : "?", (const char*)s->symbolName, address - s->address);
	}

	void LogGuestThreads()
	{
		// try-lock only: if the scheduler lock is never released, that is itself the finding and the monitor keeps running
		bool locked = false;
		const auto start = std::chrono::steady_clock::now();
		while (!(locked = __OSTryLockScheduler()) && std::chrono::steady_clock::now() - start < std::chrono::seconds(2))
			std::this_thread::sleep_for(std::chrono::milliseconds(5));
		if (!locked)
		{
			WiiPadLog::Write("diag: guest threads: PPC scheduler lock NOT available for 2 s (held by the emulation thread: blocked while holding it?)");
			return;
		}
		GuestThread copy[64];
		const int total = activeThreadCount;
		const int n = std::min(total, 64);
		for (int i = 0; i < n; i++)
		{
			auto* t = (OSThread_t*)memory_getPointerFromVirtualOffset(activeThread[i]);
			GuestThread& g = copy[i];
			g.address = activeThread[i];
			g.srr0 = t->context.srr0;
			g.lr = _swapEndianU32(t->context.lr);
			g.waitingForMutex = t->waitingForMutex.GetMPTR();
			g.waitQueue = t->currentWaitQueue.GetMPTR();
			g.suspendCounter = t->suspendCounter;
			g.priority = t->effectivePriority;
			g.id = t->id;
			g.state = (uint8)(OSThread_t::THREAD_STATE)t->state;
			g.name[0] = 0;
			if (!t->threadName.IsNull())
				strlcpy(g.name, t->threadName.GetPtr(), sizeof(g.name));
		}
		__OSUnlockScheduler();

		WiiPadLog::Write(fmt::format("diag: guest threads: {} active (PC/LR are the values saved at the last switch; a RUNNING thread's are stale)", total));
		for (int i = 0; i < n; i++)
		{
			const GuestThread& g = copy[i];
			WiiPadLog::Write(fmt::format("diag:   [{:08x}] id {} \"{}\" {} prio {}{}{}{} | PC {} | LR {}",
				g.address, g.id, g.name, GuestStateName(g.state), g.priority,
				g.suspendCounter ? fmt::format(" suspended {}", g.suspendCounter) : std::string(),
				g.waitingForMutex ? fmt::format(" waitMutex {:08x}", g.waitingForMutex) : std::string(),
				g.waitQueue ? fmt::format(" waitQueue {:08x}", g.waitQueue) : std::string(),
				GuestSymbol(g.srr0), GuestSymbol(g.lr)));
		}
	}

	// Startup check of Cemu's Fiber class as built for iOS (src/ios/FiberIOS.cpp, Boost.Context): switch into a new
	// fiber and back on the monitor thread, with the arm64 split entry parameter. The test fiber is left suspended (it is never resumed again).
	Fiber* s_monitorFiber = nullptr;
	std::atomic_int s_cemuFiberSteps{ 0 };
	std::atomic<uint64_t> s_cemuFiberParam{ 0 };

	// declared like coreinit's __OSFiberThreadEntry on arm64: the parameter arrives as two 32-bit halves
	void CemuFiberEntry(uint32 high, uint32 low)
	{
		s_cemuFiberParam = ((uint64_t)high << 32) | low;
		s_cemuFiberSteps = 1;
		Fiber::Switch(*s_monitorFiber);
	}

	void CemuFiberSelfTest()
	{
		s_monitorFiber = Fiber::PrepareCurrentThread();
		void* const param = (void*)&s_cemuFiberSteps; // a real 64-bit host pointer, like OSHostThread*
		Fiber* testFiber = new Fiber((void (*)(void*))&CemuFiberEntry, param, nullptr);
		Fiber::Switch(*testFiber);
		const bool switched = s_cemuFiberSteps.load() == 1;
		const bool paramOk = s_cemuFiberParam.load() == (uint64_t)param;
		WiiPadLog::Write(fmt::format("diag: fiber self-test (Cemu Fiber, Boost.Context): switch into a new fiber and back: {}; entry parameter {:#x} (expected {:#x}): {}",
			switched ? "OK" : "FAILED", s_cemuFiberParam.load(), (uint64_t)param, paramOk ? "OK" : "FAILED"));
	}

	// ---------------- monitor ----------------

	struct Snapshot
	{
		uint64_t vpad, sched, play, feed, render, renderData, motion;
		static Snapshot Take()
		{
			return { vpadRead.count.load(), schedulerEvents.count.load(), audioPlay.count.load(),
				audioFeed.count.load(), audioRender.count.load(), audioRenderData.count.load(), motionSamples.count.load() };
		}
	};

	void LogHostThreads(std::unordered_map<thread_act_t, double>& lastCpu, double interval, bool withBacktraces)
	{
		auto threads = ListHostThreads();
		WiiPadLog::Write(fmt::format("diag: host threads: {}", threads.size()));
		for (auto& t : threads)
		{
			const double delta = t.cpuSeconds - lastCpu[t.port];
			lastCpu[t.port] = t.cpuSeconds;
			const bool busy = interval > 0 && delta / interval > 0.5;
			WiiPadLog::Write(fmt::format("diag:   \"{}\" {} cpu {:.2f}s (+{:.2f}s){}", t.name.empty() ? "(unnamed)" : t.name,
				RunStateName(t.runState), t.cpuSeconds, delta, busy ? " BUSY" : ""));
			if (withBacktraces && (IsInterestingThread(t.name) || busy))
			{
				uint64_t frames[24];
				const int count = SampleBacktrace(t.port, frames, 24);
				for (int i = 0; i < count; i++)
					WiiPadLog::Write(fmt::format("diag:       #{:<2} {}", i, Symbolize(frames[i])));
			}
		}
		ReleaseThreads(threads);
	}

	void MonitorThread()
	{
		::SetThreadName("WiiPadDiag");
		s_startNs = NowNs();
		std::unordered_map<thread_act_t, double> lastCpuHeartbeat, lastCpuSnapshot;
		Snapshot prev = Snapshot::Take();
		double prevT = 0.0;
		const double snapshotTimes[] = { 3, 15, 60, 180, 600 };
		size_t nextSnapshot = 0;

		WiiPadLog::Write("diag: monitor started (heartbeat every 2 s for 30 s, then every 10 s; thread snapshots at +3/15/60/180/600 s)");
		uint64_t cntfrq = 0;
		asm volatile("mrs %0, cntfrq_el0" : "=r"(cntfrq));
		WiiPadLog::Write(fmt::format("diag: PPC timer: measured host counter frequency {} Hz (cntfrq_el0 reports {} Hz); guest time stalls if this is 0 or wrong",
			_rdtscFrequency, cntfrq));
		while (true)
		{
			const double t = (NowNs() - s_startNs) / 1e9;
			if (t > 600.5)
				break;
			const double interval = t - prevT;

			// heartbeat: counters + CPU time of the emulation and GPU host threads
			const Snapshot cur = Snapshot::Take();
			std::string hostLine;
			{
				auto threads = ListHostThreads();
				for (auto& h : threads)
				{
					if (h.name.rfind("OSSched", 0) == 0 || h.name == "LatteThread")
					{
						const double delta = h.cpuSeconds - lastCpuHeartbeat[h.port];
						lastCpuHeartbeat[h.port] = h.cpuSeconds;
						hostLine += fmt::format(" | {} cpu +{:.2f}s {}", h.name, delta, RunStateName(h.runState));
					}
				}
				ReleaseThreads(threads);
			}
			if (prevT > 0.0 || t > 0.5)
			{
				WiiPadLog::Write(fmt::format(
					"diag: hb +{:.0f}s{} | sched events +{} | VPADRead +{} (total {}, last {}) | GX2Init {} flips {} | audio play {} feed +{} render +{} (with data +{}, last {}) | motion +{}",
					t, hostLine, cur.sched - prev.sched, cur.vpad - prev.vpad, cur.vpad, Ago(vpadRead),
					(uint32)LatteGPUState.gx2InitCalled, (uint32)LatteGPUState.flipCounter,
					cur.play, cur.feed - prev.feed, cur.render - prev.render, cur.renderData - prev.renderData, Ago(audioRender), cur.motion - prev.motion));
			}
			prev = cur;
			prevT = t;

			if (nextSnapshot < std::size(snapshotTimes) && t >= snapshotTimes[nextSnapshot])
			{
				WiiPadLog::Section(fmt::format("diag snapshot +{:.0f}s", t));
				LogHostThreads(lastCpuSnapshot, nextSnapshot == 0 ? 0.0 : t - snapshotTimes[nextSnapshot - 1], true);
				LogGuestThreads();
				if (nextSnapshot == 0)
				{
					CemuFiberSelfTest(); // Cemu's Fiber as built for iOS (FiberIOS.cpp)
				}
				WiiPadLog::Section("diag snapshot end");
				nextSnapshot++;
			}

			std::this_thread::sleep_for(std::chrono::seconds(t < 30 ? 2 : 10));
		}
		WiiPadLog::Write("diag: monitor stopped after 10 minutes");
	}
}

namespace WiiPadDiag
{
	void StartMonitor()
	{
		static std::atomic_bool started{ false };
		if (started.exchange(true))
			return;
		std::thread(&MonitorThread).detach();
	}
}
