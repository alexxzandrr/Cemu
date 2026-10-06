// iPadOS implementation of util/Fiber/Fiber.h (desktop Unix: util/Fiber/FiberUnix.cpp).
//
// FiberUnix.cpp uses getcontext/makecontext/swapcontext, which iOS does not implement: getcontext returns -1 with
// ENOTSUP and swapcontext does not switch. Cemu's PPC scheduler idle loop and every emulated PPC thread run on
// fibers, so with ucontext no guest code runs at all. This version uses Boost.Context's fcontext primitives
// (make_fcontext / jump_fcontext, hand-written arm64 Mach-O assembly in libboost_context) with the same interface
// and semantics: a fiber has its own 2 MB stack, Switch() suspends the current fiber and resumes the target.
// See docs/ipados/PHASE2_CHECKPOINT.md.

#include "util/Fiber/Fiber.h"

#include <boost/context/detail/fcontext.hpp>

#include <atomic>
#include <cstdlib>

namespace bctx = boost::context::detail;

namespace
{
	struct FiberContext
	{
		bctx::fcontext_t context = nullptr;    // where to resume this fiber; set each time it is switched away from
		void (*entryPoint)(void*) = nullptr;   // fibers with their own stack only
		void* userParam = nullptr;
	};

	thread_local Fiber* sCurrentFiber{};
	thread_local FiberContext* sCurrentContext{};

	constexpr size_t kStackSize = 2 * 1024 * 1024; // same as FiberUnix.cpp

	// First activation of a fiber created with an entry point. transfer.data is the FiberContext of the fiber
	// that switched to us; transfer.fctx is where that fiber resumes.
	void FiberTrampoline(bctx::transfer_t transfer)
	{
		static_cast<FiberContext*>(transfer.data)->context = transfer.fctx;
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
	m_stackPtr = malloc(kStackSize);
	// the stack grows down: make_fcontext takes the top of the stack
	ctx->context = bctx::make_fcontext(static_cast<uint8*>(m_stackPtr) + kStackSize, kStackSize, &FiberTrampoline);
	m_implData = ctx;
}

Fiber::Fiber(void* privateData) : m_privateData(privateData)
{
	// the calling thread's own stack; its context is captured when it first switches away
	m_implData = new FiberContext();
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

	// Switching to the fiber that is already running is a no-op. Cemu does this in multi-core mode: on a non-main core
	// __OSThreadSwitchToNext re-queues the current guest thread and may pick it again. FiberUnix's swapcontext(ctx, ctx)
	// saves and immediately restores the same context, i.e. returns; jump_fcontext would instead jump to the fiber's
	// stale context from its previous suspension (crash: CODESIGNING "Invalid Page" on OSSched[core=2]).
	if (target == leaving)
		return;

	sCurrentFiber = &targetFiber;
	sCurrentContext = target;
	std::atomic_thread_fence(std::memory_order_seq_cst);
	// suspends here; returns when some fiber switches back to this one (possibly on another host thread)
	bctx::transfer_t transfer = bctx::jump_fcontext(target->context, leaving);
	std::atomic_thread_fence(std::memory_order_seq_cst);
	// record where the fiber that resumed us can itself be resumed (still under Cemu's scheduler lock)
	static_cast<FiberContext*>(transfer.data)->context = transfer.fctx;
}

void* Fiber::GetFiberPrivateData()
{
	return sCurrentFiber->m_privateData;
}
