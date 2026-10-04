#import "BuildInfo.h"

#include <string>
#include <sys/sysctl.h>

static_assert(__cplusplus >= 202002L, "Cemu requires C++20");
#if !defined(__aarch64__)
#error "Cemu iPadOS targets arm64 only"
#endif

static std::string sysctlString(const char* name)
{
	size_t size = 0;
	if (sysctlbyname(name, nullptr, &size, nullptr, 0) != 0 || size == 0)
		return "unknown";
	std::string value(size, '\0');
	if (sysctlbyname(name, value.data(), &size, nullptr, 0) != 0)
		return "unknown";
	value.resize(size > 0 ? size - 1 : 0); // drop trailing NUL
	return value;
}

@implementation BuildInfo

+ (NSString*)summary
{
	std::string text = "arm64 · C++" + std::to_string(__cplusplus / 100 % 100) +
		" · clang " + __clang_version__ +
		"\ndevice " + sysctlString("hw.machine") +
		" · built " + __DATE__ " " __TIME__;
	return [NSString stringWithUTF8String:text.c_str()];
}

@end
