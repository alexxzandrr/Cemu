// iPadOS implementation of util/Fiber/Fiber.h (desktop Unix: util/Fiber/FiberUnix.cpp).
//
// FiberUnix.cpp uses getcontext/makecontext/swapcontext, which iOS does not implement: getcontext returns -1 with
// ENOTSUP and swapcontext does not switch. Cemu's PPC scheduler idle loop and every emulated PPC thread run on
// fibers, so with ucontext no guest code runs at all. This version uses Boost.Context's fcontext primitives
// (make_fcontext / jump_fcontext, hand-written arm64 Mach-O assembly in libboost_context) with the same interface
// and semantics: a fiber has its own 2 MB stack, Switch() suspends the current fiber and resumes the target.
//
// Diagnostics (multi-core investigation): every fiber records which host thread is running it. Switching to a fiber
// that is still running on some host thread (its saved context is stale) is reported with full detail and aborts
// cleanly, instead of jumping to garbage (which iOS kills as a code-signing "Invalid Page" with no crash log).

#include "util/Fiber/Fiber.h"
#include "WiiPadLog.h"

#include <boost/context/detail/fcontext.hpp>

#include <atomic>
#include <cstdlib>
#include <dlfcn.h>
#include <pthread.h>

namespace bctx = boost::context::detail;

namespace
{
	struct FiberContext
	{
		bctx::fcontext_t context = nullptr;    // where to resume this fiber; set each time it is switched away from
		void (*entryPoint)(void*) = nullptr;   // fibers with their own stack only
		void* userParam = nullptr;
		void* privateData = nullptr;

		// diagnostics
		uint32_t id = 0;                              // creation order
		std::atomic<uint64_t> runningOn{ 0 };         // host thread id currently executing this fiber, 0 = suspended
		std::atomic<uint64_t> lastSuspendedOn{ 0 };   // host thread id it was last switched away from
		char lastThreadName[32] = {};                 // name of that host thread
	};

	thread_local Fiber* sCurrentFiber{};
	thread_local FiberContext* sCurrentContext{};

	std::atomic<uint32_t> sNextFiberId{ 1 };
	std::atomic<uint64_t> sMigrations{ 0 };

	constexpr size_t kStackSize = 2 * 1024 * 1024; // same as FiberUnix.cpp

	uint64_t HostThreadId()
	{
		uint64_t tid = 0;
		pthread_threadid_np(nullptr, &tid);
		return tid;
	}

	std::string HostThreadName()
	{
		char name[64]{};
		pthread_getname_np(pthread_self(), name, sizeof(name));
		return name[0] ? name : "(unnamed)";
	}

	std::string DescribeFiber(const FiberContext* f)
	{
		if (!f)
			return "null";
		std::string kind = "thread fiber (PrepareCurrentThread)";
		if (f->entryPoint)
		{
			Dl_info info{};
			kind = (dladdr((void*)f->entryPoint, &info) && info.dli_sname) ? info.dli_sname : "entry ?";
		}
		return fmt::format("fiber #{} [{}] userParam {} privateData {} running on {} | last suspended on {} \"{}\"",
			f->id, kind, f->userParam, f->privateData, f->runningOn.load(), f->lastSuspendedOn.load(), f->lastThreadName);
	}

	// called on the fiber that has just been resumed, for the fiber it was resumed from (now suspended)
	void MarkSuspended(FiberContext* left, bctx::fcontext_t context, uint64_t hostThread, const char* hostThreadName)
	{
		left->context = context;
		left->lastSuspendedOn.store(hostThread, std::memory_order_relaxed);
		strlcpy(left->lastThreadName, hostThreadName, sizeof(left->lastThreadName));
		left->runningOn.store(0, std::memory_order_release); // context is valid from here on
	}

	// First activation of a fiber created with an entry point. transfer.data is the FiberContext of the fiber
	// that switched to us; transfer.fctx is where that fiber resumes.
	void FiberTrampoline(bctx::transfer_t transfer)
	{
		char name[32]{};
		pthread_getname_np(pthread_self(), name, sizeof(name));
		MarkSuspended(static_cast<FiberContext*>(transfer.data), transfer.fctx, HostThreadId(), name);
		FiberContext* self = sCurrentContext;
#ifdef __arm64__
		// Same calling convention as FiberUnix.cpp on arm64, which passes the parameter to makecontext() split into two
		// 32-bit halves (makecontext arguments are ints). Entry points depend on it: coreinit's __OSFiberThreadEntry is
		// declared as (uint32 high, uint32 low) under __arm64__ and rebuilds the pointer from the halves.
		const uint64 param = (uint64)self->userParam;
		reinterpret_cast<void (*)(uint32, uint32)>(self->entryPoint)((uint32)(param >> 32), (uint32)param);
#else
		self->entryPoint(self->userParam);
#endif
		abort(); // Cemu's fiber entry points never return; they switch away
	}
}

Fiber::Fiber(void (*FiberEntryPoint)(void* userParam), void* userParam, void* privateData) : m_privateData(privateData)
{
	auto* ctx = new FiberContext();
	ctx->entryPoint = FiberEntryPoint;
	ctx->userParam = userParam;
	ctx->privateData = privateData;
	ctx->id = sNextFiberId.fetch_add(1);
	m_stackPtr = malloc(kStackSize);
	// the stack grows down: make_fcontext takes the top of the stack
	ctx->context = bctx::make_fcontext(static_cast<uint8*>(m_stackPtr) + kStackSize, kStackSize, &FiberTrampoline);
	m_implData = ctx; // runningOn = 0: suspended, ready to be started
}

Fiber::Fiber(void* privateData) : m_privateData(privateData)
{
	// the calling thread's own stack; its context is captured when it first switches away
	auto* ctx = new FiberContext();
	ctx->privateData = privateData;
	ctx->id = sNextFiberId.fetch_add(1);
	ctx->runningOn.store(HostThreadId());
	m_implData = ctx;
	m_stackPtr = nullptr;
}

Fiber::~Fiber()
{
	if (m_stackPtr)
		free(m_stackPtr);
	delete static_cast<FiberContext*>(m_implData);
}

Fiber* Fiber::PrepareCurrentThread(void* privateData)
{
	cemu_assert_debug(sCurrentFiber == nullptr);
	sCurrentFiber = new Fiber(privateData);
	sCurrentContext = static_cast<FiberContext*>(sCurrentFiber->m_implData);
	return sCurrentFiber;
}

void Fiber::Switch(Fiber& targetFiber)
{
	FiberContext* leaving = sCurrentContext;
	FiberContext* target = static_cast<FiberContext*>(targetFiber.m_implData);
	const uint64_t self = HostThreadId();

	// ownership checks (diagnostics): the leaving fiber must be the one running here, and the target must be suspended
	if (leaving->runningOn.load(std::memory_order_relaxed) != self)
	{
		WiiPadLog::Fatal(fmt::format("Fiber::Switch on host thread {} \"{}\": the current fiber is not marked as running here. current: {}; target: {}",
			self, HostThreadName(), DescribeFiber(leaving), DescribeFiber(target)));
		abort();
	}
	uint64_t expected = 0;
	if (target == leaving || !target->runningOn.compare_exchange_strong(expected, self, std::memory_order_acquire))
	{
		WiiPadLog::Fatal(fmt::format("Fiber::Switch on host thread {} \"{}\" to a fiber that is still running (its saved context is stale). "
			"target: {}; switching from: {}; fiber migrations so far: {}",
			self, HostThreadName(), DescribeFiber(target), DescribeFiber(leaving), sMigrations.load()));
		abort();
	}
	const uint64_t lastOn = target->lastSuspendedOn.load(std::memory_order_relaxed);
	if (lastOn != 0 && lastOn != self)
	{
		const uint64_t n = sMigrations.fetch_add(1) + 1;
		if (n <= 5)
			WiiPadLog::Write(fmt::format("diag: fiber migration #{}: {} resumed on host thread {} \"{}\"", n, DescribeFiber(target), self, HostThreadName()));
	}

	sCurrentFiber = &targetFiber;
	sCurrentContext = target;
	std::atomic_thread_fence(std::memory_order_seq_cst);
	// suspends here; returns when some fiber switches back to this one (possibly on another host thread)
	bctx::transfer_t transfer = bctx::jump_fcontext(target->context, leaving);
	std::atomic_thread_fence(std::memory_order_seq_cst);
	// the fiber that resumed us is now suspended: record where it continues
	char resumedName[32]{};
	pthread_getname_np(pthread_self(), resumedName, sizeof(resumedName));
	MarkSuspended(static_cast<FiberContext*>(transfer.data), transfer.fctx, HostThreadId(), resumedName);
}

void* Fiber::GetFiberPrivateData()
{
	return sCurrentFiber->m_privateData;
}
