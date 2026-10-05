// TEMPORARY startup diagnostics (Phase 1B crash investigation). Remove once the dyld initializer abort is understood.
//
// The device crash is an abort inside dyld's callInitializer, i.e. before main() and before CemuBridge's logger exists.
// This file is part of the app target, so its object file is linked before the libCemuCore.a members and its
// constructor runs before Cemu's ~2300 static initializers. It records to Documents/WiiPad-startup.log:
//   - that WiiPad's static initialization started
//   - every C++ exception thrown by code linked into the WiiPad executable (type + throwing frames),
//     via a __cxa_throw hook that forwards to libc++abi
//   - the fatal signal (SIGABRT etc.) with a backtrace
// Only async-signal-safe calls are used in the signal handler. No Cemu code or behaviour is changed.

#include <dlfcn.h>
#include <execinfo.h>
#include <fcntl.h>
#include <mach-o/dyld.h>
#include <signal.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <typeinfo>
#include <unistd.h>

extern "C" char* __cxa_demangle(const char* mangled, char* buf, size_t* len, int* status);

namespace
{
	int s_fd = -1;
	int s_throwCount = 0;
	char s_lastThrowType[256] = "(none)";

	void W(const char* s)
	{
		if (s_fd >= 0 && s)
			(void)!write(s_fd, s, strlen(s));
	}

	void WHex(uintptr_t v)
	{
		char buf[19] = "0x";
		for (int i = 0; i < 16; i++)
			buf[2 + i] = "0123456789abcdef"[(v >> ((15 - i) * 4)) & 0xF];
		buf[18] = 0;
		W(buf);
	}

	void WDec(long v)
	{
		char buf[24];
		int n = 0;
		bool neg = v < 0;
		unsigned long u = neg ? -(unsigned long)v : (unsigned long)v;
		do { buf[n++] = '0' + (u % 10); u /= 10; } while (u && n < 22);
		if (neg) buf[n++] = '-';
		for (int i = n - 1; i >= 0; i--) (void)!write(s_fd, &buf[i], 1);
	}

	void Flush()
	{
		if (s_fd >= 0)
			fsync(s_fd);
	}

	// Not async-signal-safe (dladdr/demangle): only used outside the signal handler.
	void WFrames(void* const* frames, int count)
	{
		for (int i = 0; i < count; i++)
		{
			Dl_info info{};
			W("    #"); WDec(i); W(" ");
			if (dladdr(frames[i], &info) && info.dli_fname)
			{
				const char* image = strrchr(info.dli_fname, '/');
				W(image ? image + 1 : info.dli_fname);
				W(" +"); WHex((uintptr_t)frames[i] - (uintptr_t)info.dli_fbase);
				if (info.dli_sname)
				{
					int status = 0;
					char* demangled = __cxa_demangle(info.dli_sname, nullptr, nullptr, &status);
					W("  "); W(status == 0 && demangled ? demangled : info.dli_sname);
					W(" +"); WDec((long)((uintptr_t)frames[i] - (uintptr_t)info.dli_saddr));
					free(demangled);
				}
			}
			else
			{
				WHex((uintptr_t)frames[i]);
			}
			W("\n");
		}
	}

	void FatalSignal(int sig, siginfo_t* info, void*)
	{
		W("\n!!! fatal signal "); WDec(sig);
		W(sig == SIGABRT ? " (SIGABRT)" : sig == SIGSEGV ? " (SIGSEGV)" : sig == SIGBUS ? " (SIGBUS)" : "");
		W(", fault address "); WHex(info ? (uintptr_t)info->si_addr : 0);
		W("\n    C++ throws recorded so far: "); WDec(s_throwCount);
		W(", last thrown type: "); W(s_lastThrowType);
		W("\n    backtrace at the signal:\n");
		void* frames[48];
		int n = backtrace(frames, 48);
		backtrace_symbols_fd(frames, n, s_fd);
		Flush();
		signal(sig, SIG_DFL);
		raise(sig);
	}

	__attribute__((constructor)) void WiiPadStartupDiagnostics()
	{
		const char* home = getenv("HOME");
		if (!home)
			return;
		char path[1024];
		strlcpy(path, home, sizeof(path));
		strlcat(path, "/Documents", sizeof(path));
		mkdir(path, 0755);
		strlcat(path, "/WiiPad-startup.log", sizeof(path));
		s_fd = open(path, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0644);

		W("WiiPad startup diagnostics\n");
		W("1. WiiPad image static initialization started (this is the first initializer of the app's own objects)\n");
		W("   main image header "); WHex((uintptr_t)_dyld_get_image_header(0));
		W(", slide "); WHex((uintptr_t)_dyld_get_image_vmaddr_slide(0)); W("\n");
		W("2. Cemu static initializers run next. If the app aborts before main(), the cause is recorded below.\n");
		Flush();

		const int signals[] = { SIGABRT, SIGSEGV, SIGBUS, SIGILL, SIGTRAP, SIGFPE };
		for (int sig : signals)
		{
			struct sigaction action{};
			action.sa_sigaction = &FatalSignal;
			action.sa_flags = SA_SIGINFO;
			sigemptyset(&action.sa_mask);
			sigaction(sig, &action, nullptr);
		}
	}
}

// Hook for C++ exceptions thrown by code linked into the WiiPad executable (Cemu, xbyak, boost, ...).
// Exceptions thrown inside system dylibs (e.g. libc++.dylib) do not pass through here.
extern "C" [[noreturn]] void __cxa_throw(void* thrownException, std::type_info* tinfo, void (*dest)(void*))
{
	using ThrowFn = void (*)(void*, std::type_info*, void (*)(void*));
	static ThrowFn realThrow = (ThrowFn)dlsym(RTLD_NEXT, "__cxa_throw");

	s_throwCount++;
	const char* mangled = tinfo ? tinfo->name() : "?";
	int status = 0;
	char* demangled = __cxa_demangle(mangled, nullptr, nullptr, &status);
	strlcpy(s_lastThrowType, status == 0 && demangled ? demangled : mangled, sizeof(s_lastThrowType));
	free(demangled);

	if (s_throwCount <= 20)
	{
		W("\nC++ throw #"); WDec(s_throwCount); W(": type "); W(s_lastThrowType); W("\n  thrown from:\n");
		void* frames[24];
		int n = backtrace(frames, 24);
		WFrames(frames + 1, n - 1); // skip this hook
		Flush();
	}

	realThrow(thrownException, tinfo, dest);
	__builtin_unreachable();
}
