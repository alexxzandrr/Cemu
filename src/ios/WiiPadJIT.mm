// JIT arena for Cemu's AArch64 recompiler on iPadOS 26+ (TXM) through StikDebug's breakpoint protocol. See WiiPadJIT.h.

#include "WiiPadJIT.h"
#include "WiiPadLog.h"

#import <Foundation/Foundation.h>

#include <libkern/OSCacheControl.h>
#include <mach/mach.h>
#include <mach/vm_map.h>
#include <unistd.h>

#include <atomic>
#include <chrono>
#include <cstring>
#include <mutex>
#include <thread>

#include <fmt/format.h>

// libsystem_kernel; not declared in the iOS SDK headers
extern "C" int csops(pid_t pid, unsigned int ops, void* useraddr, size_t usersize);

// Cafe/HW/Espresso/Recompiler/BackendAArch64 (BOOST_OS_IOS): where finished recompiler code is committed
extern void* (*g_aarch64CommitCode)(const void* code, size_t size);

// StikJIT INTEGRATION.md: selector in x16, arguments in x0/x1, result in x0, `brk #0xf00d`.
// Executing these without the debug server attached raises SIGTRAP and kills the process: callers check CS_DEBUGGED.
extern "C" __attribute__((noinline, naked)) void* WiiPadJIT26PrepareRegion(void* /*address*/, size_t /*length*/)
{
	__asm__ volatile(
		"mov x16, #1\n"
		"brk #0xf00d\n"
		"ret\n");
}

extern "C" __attribute__((noinline, naked)) void WiiPadJIT26Detach()
{
	__asm__ volatile(
		"mov x16, #0\n"
		"brk #0xf00d\n"
		"ret\n");
}

namespace
{
	constexpr unsigned kCsOpsStatus = 0;
	constexpr unsigned kCsGetTaskAllow = 0x00000004;
	constexpr unsigned kCsDebugged = 0x10000000;

	constexpr size_t kPage = 16 * 1024;
	constexpr size_t kMB = 1024 * 1024;
	// tried in order; the debug server touches every page while preparing (~275 ms per 64 MB on an M3)
	constexpr size_t kRegionSizes[] = { 256 * kMB, 128 * kMB, 64 * kMB };
	constexpr size_t kSelfTestBytes = kPage; // first page: self-test code; recompiler code starts after it
	constexpr size_t kCodeAlign = 64;         // cache line
	constexpr size_t kUsageLogStep = 16 * kMB;

	std::mutex s_mutex;           // EnableArena and Commit
	uintptr_t s_rx = 0;           // executable address of the arena
	uintptr_t s_rw = 0;           // writable alias of the same pages
	size_t s_size = 0;
	std::atomic<size_t> s_used{ 0 };
	std::atomic<bool> s_ready{ false };
	bool s_enableAttempted = false;
	bool s_fullLogged = false;
	size_t s_nextUsageLog = kUsageLogStep;

	void Log(const std::string& line)
	{
		WiiPadLog::Write("jit: " + line);
	}

	std::string ProtString(vm_prot_t p)
	{
		std::string s;
		s += (p & VM_PROT_READ) ? 'r' : '-';
		s += (p & VM_PROT_WRITE) ? 'w' : '-';
		s += (p & VM_PROT_EXECUTE) ? 'x' : '-';
		return s;
	}

	// Logs the VM entry that contains addr; returns its current protection (0 if unmapped).
	vm_prot_t DescribeMapping(const char* what, uintptr_t addr)
	{
		vm_address_t start = (vm_address_t)addr;
		vm_size_t size = 0;
		vm_region_basic_info_data_64_t info{};
		mach_msg_type_number_t count = VM_REGION_BASIC_INFO_COUNT_64;
		mach_port_t object = MACH_PORT_NULL;
		kern_return_t kr = vm_region_64(mach_task_self(), &start, &size, VM_REGION_BASIC_INFO_64,
			(vm_region_info_t)&info, &count, &object);
		if (kr != KERN_SUCCESS || start > addr || addr >= start + size)
		{
			Log(fmt::format("{} 0x{:x}: not mapped (vm_region kr {})", what, addr, kr));
			return 0;
		}
		Log(fmt::format("{} 0x{:x}: entry 0x{:x}+{} KB, prot {} max {}", what, addr, (uintptr_t)start, size / 1024,
			ProtString(info.protection), ProtString(info.max_protection)));
		return info.protection;
	}

	void WriteCode(uintptr_t offset, std::initializer_list<uint32_t> words)
	{
		uint32_t* dst = (uint32_t*)(s_rw + offset);
		size_t i = 0;
		for (uint32_t w : words)
			dst[i++] = w;
		sys_icache_invalidate((void*)(s_rx + offset), words.size() * 4);
	}

	// Gate 0's tests, in the reserved first page. Each execution is logged first: if iOS kills the process
	// (CODESIGNING "Invalid Page", no crash log in the app), WiiPad.previous.log ends at that line.
	bool SelfTest(const char* phase)
	{
		using Fn0 = int (*)();
		using Fn2 = int (*)(int, int);
		WriteCode(0, { 0x52800540 /* movz w0, #42 */, 0xD65F03C0 /* ret */ });
		WriteCode(64, { 0x0B010000 /* add w0, w0, w1 */, 0xD65F03C0 /* ret */ });
		Log(fmt::format("[{}] self-test: executing generated code at 0x{:x}", phase, s_rx));
		const int r1 = ((Fn0)s_rx)();
		const int r2 = ((Fn2)(s_rx + 64))(40, 2);
		WriteCode(0, { 0x52809A40 /* movz w0, #1234 */ }); // patch code that already ran
		const int r3 = ((Fn0)s_rx)();
		const bool ok = r1 == 42 && r2 == 42 && r3 == 1234;
		Log(fmt::format("[{}] self-test {} ({}, {}, {})", phase, ok ? "passed" : "FAILED", r1, r2, r3));
		return ok;
	}

	// g_aarch64CommitCode: copies finished recompiler code into the arena, returns its executable address
	void* Commit(const void* code, size_t size)
	{
		if (!s_ready || size == 0)
			return nullptr;
		std::lock_guard lock(s_mutex);
		const size_t offset = (s_used + kCodeAlign - 1) & ~(kCodeAlign - 1);
		if (offset + size > s_size)
		{
			if (!s_fullLogged)
			{
				s_fullLogged = true;
				Log(fmt::format("arena full ({} MB): further functions stay in the interpreter", s_size / kMB));
			}
			return nullptr;
		}
		std::memcpy((void*)(s_rw + offset), code, size);
		sys_icache_invalidate((void*)(s_rx + offset), size);
		s_used = offset + size;
		if (s_used >= s_nextUsageLog)
		{
			Log(fmt::format("arena: {} MB of {} MB used", s_used / kMB, s_size / kMB));
			s_nextUsageLog += kUsageLogStep;
		}
		return (void*)(s_rx + offset);
	}

	// returns the RX address, or 0
	uintptr_t RequestRegion(size_t size)
	{
		Log(fmt::format("JIT26PrepareRegion(NULL, {} MB)", size / kMB));
		auto t0 = std::chrono::steady_clock::now();
		void* r = WiiPadJIT26PrepareRegion(nullptr, size);
		auto ms = std::chrono::duration_cast<std::chrono::milliseconds>(std::chrono::steady_clock::now() - t0).count();
		const uintptr_t rx = (uintptr_t)r;
		Log(fmt::format("JIT26PrepareRegion returned 0x{:x} after {} ms", rx, ms));
		// an unserviced breakpoint can leave garbage in x0: require a page-aligned, mapped, executable result,
		// and the last page as well (the whole length must be there)
		if (!rx || (rx % kPage) != 0)
			return 0;
		if (!(DescribeMapping("region start", rx) & VM_PROT_EXECUTE))
			return 0;
		if (!(DescribeMapping("region end", rx + size - kPage) & VM_PROT_EXECUTE))
			return 0;
		return rx;
	}
}

namespace WiiPadJIT
{
	CodeSignStatus GetCodeSignStatus()
	{
		CodeSignStatus st;
		uint32_t flags = 0;
		if (csops(getpid(), kCsOpsStatus, &flags, sizeof(flags)) == 0)
		{
			st.ok = true;
			st.flags = flags;
			st.getTaskAllow = (flags & kCsGetTaskAllow) != 0;
			st.debugged = (flags & kCsDebugged) != 0;
		}
		return st;
	}

	bool ArenaReady() { return s_ready; }
	size_t ArenaSize() { return s_size; }
	size_t ArenaUsed() { return s_used; }

	std::string DescribeStatus()
	{
		if (s_ready)
			return fmt::format("JIT ready · {} MB code arena, {:.1f} MB used", s_size / kMB, s_used / (double)kMB);
		const CodeSignStatus st = GetCodeSignStatus();
		if (!st.ok)
			return "code signing status unavailable";
		return fmt::format("JIT off · get-task-allow: {} · debugger attached: {}", st.getTaskAllow ? "yes" : "NO",
			st.debugged ? "yes" : "no");
	}

	std::string EnableArena()
	{
		std::lock_guard lock(s_mutex);
		if (s_ready)
			return fmt::format("JIT is already enabled ({} MB).", s_size / kMB);

		WiiPadLog::Section("JIT arena");
		NSOperatingSystemVersion v = [NSProcessInfo processInfo].operatingSystemVersion;
		const CodeSignStatus st = GetCodeSignStatus();
		Log(fmt::format("iPadOS {}.{}.{}, csops ok {}, flags 0x{:08x}, get-task-allow {}, CS_DEBUGGED {}",
			(int)v.majorVersion, (int)v.minorVersion, (int)v.patchVersion, st.ok, st.flags, st.getTaskAllow, st.debugged));

		if (!st.getTaskAllow)
		{
			Log("not enabled: no get-task-allow; the sideloading tool must sign with a development profile");
			return "Failed: WiiPad is signed without get-task-allow, so no debugger can attach.";
		}
		if (!st.debugged)
		{
			Log("not enabled: no debugger attached (CS_DEBUGGED missing); a brk now would kill the process");
			return "Not enabled: StikDebug is not attached yet.";
		}
		if (s_enableAttempted)
		{
			// the debugger was detached by the previous attempt; a brk without it would kill the process
			Log("not enabled: an earlier attempt in this session already detached the debugger");
			return "Failed earlier in this session; restart WiiPad and enable JIT again.";
		}
		s_enableAttempted = true;

		// 1. executable region from the debug server (NULL address: passing our own mapping "succeeds" without
		//    the pages ever becoming executable, Play! CodeGen #34)
		for (size_t size : kRegionSizes)
		{
			s_rx = RequestRegion(size);
			if (s_rx)
			{
				s_size = size;
				break;
			}
			std::this_thread::sleep_for(std::chrono::milliseconds(500)); // the script can be briefly busy
		}
		if (!s_rx)
		{
			Log("FAILED: the debug server did not provide an executable region; detaching");
			WiiPadJIT26Detach();
			return "Failed: StikDebug attached but did not provide executable memory (see WiiPad.log).";
		}

		// 2. writable alias of the same pages (W^X: we never write through the RX address)
		vm_address_t rw = 0;
		vm_prot_t cur = 0, max = 0;
		kern_return_t kr = vm_remap(mach_task_self(), &rw, s_size, 0, VM_FLAGS_ANYWHERE, mach_task_self(),
			(vm_address_t)s_rx, FALSE, &cur, &max, VM_INHERIT_NONE);
		Log(fmt::format("vm_remap -> kr {} at 0x{:x} (cur {} max {})", kr, (uintptr_t)rw, ProtString(cur), ProtString(max)));
		if (kr == KERN_SUCCESS)
		{
			kr = vm_protect(mach_task_self(), rw, s_size, FALSE, VM_PROT_READ | VM_PROT_WRITE);
			Log(fmt::format("vm_protect(alias, rw-) -> kr {}", kr));
		}
		if (kr != KERN_SUCCESS)
		{
			Log("FAILED: could not create a writable alias; detaching");
			WiiPadJIT26Detach();
			return fmt::format("Failed: executable memory but no writable alias (kr {}).", kr);
		}
		s_rw = rw;

		// 3. one write into every page while attached. Gate 0: pages written before the detach could be rewritten
		//    and executed after it; a page written for the first time after the detach was not tested.
		auto t0 = std::chrono::steady_clock::now();
		for (size_t off = 0; off < s_size; off += kPage)
			*(volatile uint32_t*)(s_rw + off) = 0xD4200000; // brk #0: a stray jump traps instead of sliding
		sys_icache_invalidate((void*)s_rx, s_size);
		Log(fmt::format("touched {} pages through the alias in {} ms", s_size / kPage,
			std::chrono::duration_cast<std::chrono::milliseconds>(std::chrono::steady_clock::now() - t0).count()));

		if (!SelfTest("attached"))
		{
			WiiPadJIT26Detach();
			return "Failed: generated code returned wrong results (see WiiPad.log).";
		}

		// 4. detach: StikDebug is not needed while playing (Gate 0)
		Log("calling JIT26Detach");
		WiiPadJIT26Detach();
		Log(fmt::format("detached; CS_DEBUGGED now {}", GetCodeSignStatus().debugged));
		if (!SelfTest("detached"))
			return "Failed: generated code stopped working after the detach (see WiiPad.log).";

		s_used = kSelfTestBytes;
		g_aarch64CommitCode = &Commit;
		s_ready = true;
		Log(fmt::format("arena ready: {} MB at 0x{:x} (alias 0x{:x}); the recompiler can be used for the next title",
			s_size / kMB, s_rx, s_rw));
		return fmt::format("JIT enabled: {} MB code arena ready. The next title uses the recompiler.", s_size / kMB);
	}
}
