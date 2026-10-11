#pragma once

#include "HW/Espresso/Recompiler/IML/IMLInstruction.h"
#include "../PPCRecompiler.h"

bool PPCRecompiler_generateAArch64Code(struct PPCRecFunction_t* PPCRecFunction, struct ppcImlGenContext_t* ppcImlGenContext);
void PPCRecompiler_cleanupAArch64Code(void* code, size_t size);

void PPCRecompilerAArch64Gen_generateRecompilerInterfaceFunctions();

#if BOOST_OS_IOS
// iPadOS: a process cannot make its own memory executable. The platform layer (src/ios/WiiPadJIT) prepares an
// executable arena with a debugger's help and installs this hook: it copies finished, position-independent code into
// the arena (through a writable alias) and returns the address to execute it at, or nullptr if the arena is full or
// missing. Generated blocks only use PC-relative branches internally; everything else goes through absolute addresses
// or the jump table, so a block can be built in a heap buffer and moved.
extern void* (*g_aarch64CommitCode)(const void* code, size_t size);
#endif

// architecture specific constants
namespace IMLArchAArch64
{
	static constexpr int PHYSREG_GPR_BASE = 0;
	static constexpr int PHYSREG_GPR_COUNT = 25;
	static constexpr int PHYSREG_FPR_BASE = PHYSREG_GPR_COUNT;
	static constexpr int PHYSREG_FPR_COUNT = 31;
}; // namespace IMLArchAArch64