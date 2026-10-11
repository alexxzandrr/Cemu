// Phase 3 Gate 0: JIT feasibility test on iOS 26+ (TXM) through StikDebug's breakpoint protocol. See WiiPadJIT.h.

#include "WiiPadJIT.h"
#include "WiiPadLog.h"

#import <Foundation/Foundation.h>

#include <libkern/OSCacheControl.h>
#include <mach/mach.h>
#include <mach/vm_map.h>
#include <unistd.h>

#include <chrono>
#include <cstring>
#include <thread>

#include <fmt/format.h>

// libsystem_kernel; not declared in the iOS SDK headers
extern "C" int csops(pid_t pid, unsigned int ops, void* useraddr, size_t usersize);

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

	constexpr size_t kRegionSize = 64 * 1024 * 1024; // what a real recompiler arena would reserve up front
	constexpr size_t kPage = 16 * 1024;

	// kept for the rest of the session: a second run (after detach) reuses the region instead of asking again
	uintptr_t s_rx = 0;
	uintptr_t s_rw = 0;
	bool s_detached = false;

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

	// Each execution is logged first: if iOS kills the process (CODESIGNING "Invalid Page", no crash log in the
	// app), WiiPad.previous.log ends at that line.
	bool RunTests(const char* phase)
	{
		using Fn0 = int (*)();
		using Fn2 = int (*)(int, int);

		// 1: generated function, first page
		WriteCode(0, { 0x52800540 /* movz w0, #42 */, 0xD65F03C0 /* ret */ });
		Log(fmt::format("[{}] executing test 1 (return 42) at 0x{:x}", phase, s_rx));
		int r1 = ((Fn0)s_rx)();
		Log(fmt::format("[{}] test 1 returned {}", phase, r1));

		// 2: a page far into the region, with arguments
		const uintptr_t off2 = kPage * 1000 + 64;
		WriteCode(off2, { 0x0B010000 /* add w0, w0, w1 */, 0xD65F03C0 /* ret */ });
		Log(fmt::format("[{}] executing test 2 (40 + 2) at 0x{:x}", phase, s_rx + off2));
		int r2 = ((Fn2)(s_rx + off2))(40, 2);
		Log(fmt::format("[{}] test 2 returned {}", phase, r2));

		// 3: patch already-executed code in place (what a recompiler does when it links or invalidates blocks)
		WriteCode(0, { 0x52809A40 /* movz w0, #1234 */ });
		Log(fmt::format("[{}] executing test 3 (patched, return 1234)", phase));
		int r3 = ((Fn0)s_rx)();
		Log(fmt::format("[{}] test 3 returned {}", phase, r3));

		// 4: a small timing check: call the generated function in a loop
		auto t0 = std::chrono::steady_clock::now();
		int sum = 0;
		for (int i = 0; i < 1000000; i++)
			sum += ((Fn2)(s_rx + off2))(i & 7, 1);
		auto us = std::chrono::duration_cast<std::chrono::microseconds>(std::chrono::steady_clock::now() - t0).count();
		Log(fmt::format("[{}] test 4: 1M calls in {} us (checksum {})", phase, us, sum));

		const bool ok = r1 == 42 && r2 == 42 && r3 == 1234 && sum == 4500000;
		Log(fmt::format("[{}] tests {}", phase, ok ? "PASSED" : "FAILED (wrong results)"));
		return ok;
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

	std::string DescribeStatus()
	{
		const CodeSignStatus st = GetCodeSignStatus();
		if (!st.ok)
			return "code signing status unavailable";
		return fmt::format("get-task-allow: {} · debugger attached: {}{}", st.getTaskAllow ? "yes" : "NO",
			st.debugged ? "yes" : "no", s_rx ? " · JIT region ready" : "");
	}

	std::string RunGate0(bool detachAfter)
	{
		WiiPadLog::Section("JIT Gate 0");
		NSOperatingSystemVersion v = [NSProcessInfo processInfo].operatingSystemVersion;
		const CodeSignStatus st = GetCodeSignStatus();
		Log(fmt::format("iPadOS {}.{}.{}, csops ok {}, flags 0x{:08x}, get-task-allow {}, CS_DEBUGGED {}",
			(int)v.majorVersion, (int)v.minorVersion, (int)v.patchVersion, st.ok, st.flags, st.getTaskAllow, st.debugged));

		if (!st.getTaskAllow)
		{
			Log("FAILED: no get-task-allow; the sideloading tool must sign with a development profile");
			return "Failed: WiiPad is signed without get-task-allow, so no debugger can attach (see WiiPad.log).";
		}
		if (!st.debugged)
		{
			Log("not run: no debugger attached (CS_DEBUGGED missing); a brk now would kill the process");
			return "Not run: StikDebug is not attached yet.";
		}
		if (s_detached)
			return "Already detached in this session; restart WiiPad and enable JIT again to rerun.";

		if (!s_rx)
		{
			// NULL address: the debug server allocates the region. Passing our own mapping "succeeds" without the
			// region ever becoming executable (Play! CodeGen #34). The script can be briefly busy: retry.
			for (int attempt = 1; attempt <= 3 && !s_rx; attempt++)
			{
				Log(fmt::format("JIT26PrepareRegion(NULL, {} MB), attempt {}", kRegionSize >> 20, attempt));
				auto t0 = std::chrono::steady_clock::now();
				void* r = WiiPadJIT26PrepareRegion(nullptr, kRegionSize);
				auto ms = std::chrono::duration_cast<std::chrono::milliseconds>(std::chrono::steady_clock::now() - t0).count();
				const uintptr_t rx = (uintptr_t)r;
				Log(fmt::format("JIT26PrepareRegion returned 0x{:x} after {} ms", rx, ms));
				// an unserviced breakpoint can leave garbage in x0: require a page-aligned, mapped, executable result
				if (rx && (rx % kPage) == 0 && (DescribeMapping("RX region", rx) & VM_PROT_EXECUTE))
					s_rx = rx;
				else
					std::this_thread::sleep_for(std::chrono::milliseconds(500));
			}
			if (!s_rx)
			{
				Log("FAILED: the debug server did not provide an executable region");
				return "Failed: StikDebug attached but no executable region was provided (see WiiPad.log).";
			}

			// writable alias of the same pages (W^X: we never write through the RX address)
			vm_address_t rw = 0;
			vm_prot_t cur = 0, max = 0;
			kern_return_t kr = vm_remap(mach_task_self(), &rw, kRegionSize, 0, VM_FLAGS_ANYWHERE, mach_task_self(),
				(vm_address_t)s_rx, FALSE, &cur, &max, VM_INHERIT_NONE);
			Log(fmt::format("vm_remap -> kr {} at 0x{:x} (cur {} max {})", kr, (uintptr_t)rw, ProtString(cur), ProtString(max)));
			if (kr == KERN_SUCCESS)
			{
				kr = vm_protect(mach_task_self(), rw, kRegionSize, FALSE, VM_PROT_READ | VM_PROT_WRITE);
				Log(fmt::format("vm_protect(alias, rw-) -> kr {}", kr));
			}
			if (kr != KERN_SUCCESS)
			{
				Log("FAILED: could not create a writable alias");
				return fmt::format("Failed: executable region at 0x{:x}, but no writable alias (kr {}).", s_rx, kr);
			}
			s_rw = rw;
			DescribeMapping("RW alias", s_rw);
			DescribeMapping("RX region (after alias)", s_rx);
		}

		if (!RunTests("attached"))
			return "Failed: generated code ran but returned wrong results (see WiiPad.log).";

		if (!detachAfter)
		{
			Log("GATE 0 PASSED (debugger attached)");
			return "Passed: WiiPad generated, ran and patched code while StikDebug is attached.";
		}

		Log("calling JIT26Detach");
		WiiPadJIT26Detach();
		s_detached = true;
		Log(fmt::format("detached; CS_DEBUGGED now {}", GetCodeSignStatus().debugged));
		DescribeMapping("RX region (after detach)", s_rx);
		if (!RunTests("detached"))
			return "Partly passed: code ran while attached; after detach it returned wrong results.";
		Log("GATE 0 PASSED (also after detach)");
		return "Passed: code generation keeps working after StikDebug detaches.";
	}
}
