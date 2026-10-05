#pragma once

// WiiPad diagnostic log: Documents/WiiPad.log
//
// Written line by line with write()+fsync(), so the file is complete up to the moment of a crash
// (unlike Cemu's own log.txt, which is flushed by a background thread). Readable on the iPad via
// Files > On My iPad > WiiPad, so failures can be diagnosed without Xcode.

#include <string>
#include <string_view>

namespace WiiPadLog
{
	// Opens the log (rotating the previous one to WiiPad.previous.log), redirects stdout/stderr to
	// Documents/stdout.txt and installs fatal handlers. Safe to call more than once.
	void Open(const std::string& documentsDir);

	void Write(std::string_view line);                  // "<time> [thread] line"
	void Section(std::string_view title);               // visual separator
	void Fatal(std::string_view what);                  // FATAL line, always flushed

	// Installs SIGSEGV/SIGBUS/SIGILL/SIGFPE/SIGABRT/SIGTRAP handlers that write one FATAL line and then
	// chain to whatever handler was installed before (e.g. Cemu's ExceptionHandler, which writes log.txt).
	// Call again after CemuCommonInit() so the chain includes Cemu's handler.
	void InstallFatalSignalHandlers();

	// Current boot stage (a string literal with static lifetime). Printed by the fatal signal handler so a
	// crash during title launch shows where it happened.
	void SetStage(const char* stage);

	const std::string& Path();

	// Session marker: lets the next launch detect a crash or forced kill of this one.
	bool PreviousSessionEndedUncleanly();
	void MarkSessionRunning();
	void MarkSessionEndedCleanly();
}
