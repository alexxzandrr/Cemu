// WiiPad: pause and resume a running title. See WiiPadPause.h.

#include "WiiPadPause.h"
#include "WiiPadLog.h"

#include "Cafe/CafeSystem.h"
#include "Cafe/OS/libs/coreinit/coreinit_Thread.h"
#include "Cafe/OS/libs/coreinit/coreinit_Scheduler.h"

#include <mutex>
#include <vector>

namespace snd_core
{
	void AXOut_updateDevicePlayState(bool isPlaying); // ax_out.cpp
}

namespace
{
	std::mutex s_mutex;
	bool s_paused = false;
	std::vector<MPTR> s_suspended; // threads this module suspended (resume only these)
}

namespace WiiPadPause
{
	bool Pause(const char* reason)
	{
		std::lock_guard lock(s_mutex);
		if (s_paused || !CafeSystem::IsTitleRunning())
			return false;

		s_suspended.clear();
		__OSLockScheduler();
		srwlock_activeThreadList.LockRead();
		for (sint32 i = 0; i < activeThreadCount; i++)
		{
			auto* thread = (OSThread_t*)memory_getPointerFromVirtualOffset(activeThread[i]);
			if (!thread || thread->state == OSThread_t::THREAD_STATE::STATE_NONE ||
				thread->state == OSThread_t::THREAD_STATE::STATE_MORIBUND)
				continue;
			coreinit::__OSSuspendThreadNolock(thread);
			s_suspended.push_back(activeThread[i]);
		}
		srwlock_activeThreadList.UnlockRead();
		__OSUnlockScheduler();

		snd_core::AXOut_updateDevicePlayState(false);
		s_paused = true;
		WiiPadLog::Write(fmt::format("pause: title paused ({}), {} guest threads suspended", reason, s_suspended.size()));
		return true;
	}

	bool Resume(const char* reason)
	{
		std::lock_guard lock(s_mutex);
		if (!s_paused)
			return false;
		s_paused = false;
		if (!CafeSystem::IsTitleRunning())
		{
			s_suspended.clear();
			return false;
		}

		size_t resumed = 0;
		__OSLockScheduler();
		srwlock_activeThreadList.LockRead();
		for (MPTR mptr : s_suspended)
		{
			// the thread must still be in the active list (not ended and its memory reused meanwhile)
			bool stillActive = false;
			for (sint32 i = 0; i < activeThreadCount; i++)
				if (activeThread[i] == mptr) { stillActive = true; break; }
			if (!stillActive)
				continue;
			auto* thread = (OSThread_t*)memory_getPointerFromVirtualOffset(mptr);
			if (thread->suspendCounter > 0)
			{
				coreinit::__OSResumeThreadInternal(thread, 1);
				resumed++;
			}
		}
		srwlock_activeThreadList.UnlockRead();
		__OSUnlockScheduler();
		s_suspended.clear();

		snd_core::AXOut_updateDevicePlayState(true);
		WiiPadLog::Write(fmt::format("pause: title resumed ({}), {} guest threads resumed", reason, resumed));
		return true;
	}

	bool IsPaused()
	{
		std::lock_guard lock(s_mutex);
		return s_paused;
	}
}
