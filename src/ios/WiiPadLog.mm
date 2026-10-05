#include "WiiPadLog.h"

#import <Foundation/Foundation.h>

#include <cerrno>
#include <cstdio>
#include <cstring>
#include <ctime>
#include <exception>
#include <mutex>
#include <atomic>
#include <execinfo.h>
#include <fcntl.h>
#include <pthread.h>
#include <signal.h>
#include <sys/stat.h>
#include <unistd.h>

namespace
{
	std::mutex s_mutex;
	int s_fd = -1;
	std::string s_path;
	std::string s_markerPath;
	bool s_previousUnclean = false;
	bool s_previousCrashLogsKept = false;
	std::terminate_handler s_previousTerminate = nullptr;
	std::atomic<const char*> s_stage{ nullptr };

	constexpr int kFatalSignals[] = { SIGSEGV, SIGBUS, SIGILL, SIGFPE, SIGABRT, SIGTRAP };
	struct sigaction s_previousActions[32]{};
	bool s_handlerInstalled[32]{};

	std::string Timestamp()
	{
		timespec ts{};
		clock_gettime(CLOCK_REALTIME, &ts);
		tm local{};
		localtime_r(&ts.tv_sec, &local);
		char buf[64];
		size_t n = strftime(buf, sizeof(buf), "%Y-%m-%d %H:%M:%S", &local);
		snprintf(buf + n, sizeof(buf) - n, ".%03ld", ts.tv_nsec / 1000000);
		return buf;
	}

	std::string ThreadTag()
	{
		char name[64]{};
		pthread_getname_np(pthread_self(), name, sizeof(name));
		uint64_t tid = 0;
		pthread_threadid_np(nullptr, &tid);
		char buf[96];
		if (name[0])
			snprintf(buf, sizeof(buf), "%s/%llu", name, (unsigned long long)tid);
		else
			snprintf(buf, sizeof(buf), "%s/%llu", pthread_main_np() ? "main" : "thread", (unsigned long long)tid);
		return buf;
	}

	void WriteRaw(const std::string& text)
	{
		if (s_fd < 0)
			return;
		const char* p = text.data();
		size_t left = text.size();
		while (left > 0)
		{
			ssize_t w = write(s_fd, p, left);
			if (w < 0 && errno == EINTR)
				continue;
			if (w <= 0)
				return;
			p += w;
			left -= (size_t)w;
		}
		fsync(s_fd);
	}

	// --- async-signal-safe helpers (no allocation, no locks) ---
	void SignalSafeWrite(const char* s)
	{
		if (s_fd >= 0)
			(void)!write(s_fd, s, strlen(s));
	}

	void SignalSafeWriteHex(uintptr_t v)
	{
		char buf[2 + 16 + 1];
		buf[0] = '0';
		buf[1] = 'x';
		for (int i = 0; i < 16; i++)
			buf[2 + i] = "0123456789abcdef"[(v >> ((15 - i) * 4)) & 0xF];
		buf[18] = '\0';
		SignalSafeWrite(buf);
	}

	const char* SignalName(int sig)
	{
		switch (sig)
		{
		case SIGSEGV: return "SIGSEGV (invalid memory access)";
		case SIGBUS:  return "SIGBUS (bus error / bad alignment or mapping)";
		case SIGILL:  return "SIGILL (illegal instruction)";
		case SIGFPE:  return "SIGFPE (arithmetic exception)";
		case SIGABRT: return "SIGABRT (abort: assertion, std::terminate or uncaught exception)";
		case SIGTRAP: return "SIGTRAP (trap / breakpoint)";
		default:      return "signal";
		}
	}

	void FatalSignalHandler(int sig, siginfo_t* info, void* context)
	{
		SignalSafeWrite("\n!!! FATAL ");
		SignalSafeWrite(SignalName(sig));
		SignalSafeWrite(" fault address ");
		SignalSafeWriteHex(info ? (uintptr_t)info->si_addr : 0);
		if (const char* stage = s_stage.load())
		{
			SignalSafeWrite("\n!!! last stage: ");
			SignalSafeWrite(stage);
		}
		SignalSafeWrite("\n!!! backtrace of the crashing thread:\n");
		void* frames[64];
		const int frameCount = backtrace(frames, 64);
		if (s_fd >= 0)
			backtrace_symbols_fd(frames, frameCount, s_fd); // documented not to call malloc
		SignalSafeWrite("!!! The app is crashing. See also log.txt and stdout.txt in this folder.\n");
		if (s_fd >= 0)
			fsync(s_fd);

		// chain to the previously installed handler (Cemu's ExceptionHandler or the default action)
		const struct sigaction& prev = s_previousActions[sig];
		if ((prev.sa_flags & SA_SIGINFO) && prev.sa_sigaction)
		{
			prev.sa_sigaction(sig, info, context);
			return;
		}
		if (prev.sa_handler != SIG_DFL && prev.sa_handler != SIG_IGN && prev.sa_handler != nullptr)
		{
			prev.sa_handler(sig);
			return;
		}
		signal(sig, SIG_DFL);
		raise(sig);
	}

	void UncaughtObjCException(NSException* exception)
	{
		std::string text = "Uncaught Objective-C exception: ";
		text += exception.name.UTF8String ?: "?";
		text += ": ";
		text += exception.reason.UTF8String ?: "?";
		WiiPadLog::Fatal(text);
		for (NSString* frame in exception.callStackSymbols)
			WiiPadLog::Write(std::string("    ") + (frame.UTF8String ?: ""));
	}

	// Logs what reached std::terminate (incl. Objective-C exceptions, which unwind like C++ exceptions on arm64),
	// with a backtrace taken before anything unwinds, then chains to the previously installed handler.
	// The Objective-C runtime installs its own terminate handler; chaining keeps its reporting
	// (NSSetUncaughtExceptionHandler callback, "terminating due to uncaught exception" message) intact.
	void TerminateHandler()
	{
		std::string text = "std::terminate called";
		if (std::exception_ptr ep = std::current_exception())
		{
			try
			{
				@try
				{
					std::rethrow_exception(ep);
				}
				@catch (NSException* e)
				{
					text += std::string(": uncaught Objective-C exception ") + (e.name.UTF8String ?: "?") + ": " + (e.reason.UTF8String ?: "?");
				}
			}
			catch (const std::exception& e)
			{
				text += std::string(": uncaught C++ exception: ") + e.what();
			}
			catch (...)
			{
				text += ": uncaught exception of unknown type";
			}
		}
		else
		{
			text += " without an active exception";
		}
		WiiPadLog::Fatal(text);
		WiiPadLog::Write("!!! backtrace at std::terminate (throwing frames are still on the stack):");
		void* frames[64];
		const int frameCount = backtrace(frames, 64);
		if (s_fd >= 0)
		{
			backtrace_symbols_fd(frames, frameCount, s_fd);
			fsync(s_fd);
		}
		if (s_previousTerminate)
			s_previousTerminate();
		abort();
	}

	bool FileContains(const std::string& path, const char* needle)
	{
		FILE* f = fopen(path.c_str(), "r");
		if (!f)
			return false;
		std::string content;
		char buf[4096];
		size_t n;
		while ((n = fread(buf, 1, sizeof(buf), f)) > 0)
			content.append(buf, n);
		fclose(f);
		return content.find(needle) != std::string::npos;
	}
}

namespace WiiPadLog
{
	void Open(const std::string& documentsDir)
	{
		std::lock_guard lock(s_mutex);
		if (s_fd >= 0)
			return;
		s_path = documentsDir + "/WiiPad.log";
		s_markerPath = documentsDir + "/.wiipad_session_running";

		struct stat st{};
		s_previousUnclean = stat(s_markerPath.c_str(), &st) == 0;

		// keep the previous run's logs. If it crashed (its log has a FATAL line), keep the full set as *.crash.*
		// so relaunching does not overwrite the evidence (stdout.txt holds Cemu's backtrace, log.txt is
		// rewritten by Cemu on every start). Otherwise only keep the previous WiiPad.log.
		if (s_previousUnclean && FileContains(s_path, "!!! FATAL"))
		{
			rename(s_path.c_str(), (documentsDir + "/WiiPad.crash.log").c_str());
			rename((documentsDir + "/stdout.txt").c_str(), (documentsDir + "/stdout.crash.txt").c_str());
			rename((documentsDir + "/log.txt").c_str(), (documentsDir + "/log.crash.txt").c_str());
			s_previousCrashLogsKept = true;
		}
		else
		{
			rename(s_path.c_str(), (documentsDir + "/WiiPad.previous.log").c_str());
		}

		s_fd = open(s_path.c_str(), O_WRONLY | O_CREAT | O_TRUNC | O_APPEND | O_CLOEXEC, 0644);

		// capture printf/std::cerr output (Cemu's crash handler prints its backtrace to stderr)
		std::string stdoutPath = documentsDir + "/stdout.txt";
		freopen(stdoutPath.c_str(), "w", stdout);
		freopen(stdoutPath.c_str(), "a", stderr);
		setvbuf(stdout, nullptr, _IOLBF, 0);
		setvbuf(stderr, nullptr, _IONBF, 0);

		NSSetUncaughtExceptionHandler(&UncaughtObjCException);
		s_previousTerminate = std::set_terminate(&TerminateHandler);
	}

	void Write(std::string_view line)
	{
		std::string text = Timestamp() + " [" + ThreadTag() + "] ";
		text.append(line);
		text.push_back('\n');
		std::lock_guard lock(s_mutex);
		WriteRaw(text);
	}

	void Section(std::string_view title)
	{
		Write(std::string("===== ") + std::string(title) + " =====");
	}

	void Fatal(std::string_view what)
	{
		Write(std::string("!!! FATAL: ") + std::string(what));
	}

	void InstallFatalSignalHandlers()
	{
		for (int sig : kFatalSignals)
		{
			struct sigaction current{};
			sigaction(sig, nullptr, &current);
			// don't chain to ourselves when re-installing after Cemu's ExceptionHandler_Init()
			if ((current.sa_flags & SA_SIGINFO) && current.sa_sigaction == &FatalSignalHandler)
				continue;
			struct sigaction action{};
			action.sa_sigaction = &FatalSignalHandler;
			action.sa_flags = SA_SIGINFO | SA_ONSTACK;
			sigemptyset(&action.sa_mask);
			if (sigaction(sig, &action, &s_previousActions[sig]) == 0)
				s_handlerInstalled[sig] = true;
		}
	}

	void SetStage(const char* stage)
	{
		s_stage.store(stage);
	}

	const std::string& Path()
	{
		return s_path;
	}

	bool PreviousSessionEndedUncleanly()
	{
		return s_previousUnclean;
	}

	bool PreviousSessionCrashLogsKept()
	{
		return s_previousCrashLogsKept;
	}

	void MarkSessionRunning()
	{
		int fd = open(s_markerPath.c_str(), O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0644);
		if (fd >= 0)
			close(fd);
	}

	void MarkSessionEndedCleanly()
	{
		unlink(s_markerPath.c_str());
	}
}
