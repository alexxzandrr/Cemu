#import "CemuBridge.h"

#include "WiiPadLog.h"

#include "Cafe/CafeSystem.h"
#include "Cafe/HW/Latte/Core/LatteOverlay.h"
#include "Cafe/HW/Latte/Renderer/Metal/MetalRenderer.h"
#include "Cafe/HW/Latte/Renderer/Renderer.h"
#include "Cafe/HW/MMU/MMU.h"
#include "Cemu/Logging/CemuLogging.h"
#include "Cemu/ncrypto/ncrypto.h"
#include "config/ActiveSettings.h"
#include "config/CemuConfig.h"
#include "config/NetworkSettings.h"
#include "gui/interface/WindowSystem.h"
#include "util/helpers/helpers.h"

#include <mach/mach.h>
#include <os/proc.h>
#include <sys/mman.h>
#include <sys/sysctl.h>

// provided by src/main.cpp
void CemuCommonInit();
extern void (*g_cemuCommonInitStageCallback)(const char* stage, bool begin);

static NSString* const kCemuBridgeErrorDomain = @"WiiPad.CemuBridge";

namespace
{
	std::string ToStd(NSString* s)
	{
		return s ? std::string(s.UTF8String) : std::string();
	}

	std::string SysctlString(const char* name)
	{
		size_t size = 0;
		if (sysctlbyname(name, nullptr, &size, nullptr, 0) != 0 || size == 0)
			return "unknown";
		std::string value(size, '\0');
		if (sysctlbyname(name, value.data(), &size, nullptr, 0) != 0)
			return "unknown";
		value.resize(strnlen(value.c_str(), value.size()));
		return value;
	}

	uint64 SysctlU64(const char* name)
	{
		uint64 value = 0;
		size_t size = sizeof(value);
		if (sysctlbyname(name, &value, &size, nullptr, 0) != 0)
			return 0;
		return value;
	}

	std::string MB(uint64 bytes)
	{
		return fmt::format("{} MB", bytes / (1024 * 1024));
	}

	void LogMemoryState(const char* when)
	{
		task_vm_info_data_t vm{};
		mach_msg_type_number_t count = TASK_VM_INFO_COUNT;
		std::string footprint = "unavailable";
		std::string virtualSize = "unavailable";
		if (task_info(mach_task_self(), TASK_VM_INFO, (task_info_t)&vm, &count) == KERN_SUCCESS)
		{
			footprint = MB(vm.phys_footprint);
			virtualSize = MB(vm.virtual_size);
		}
		WiiPadLog::Write(fmt::format("memory ({}): available to app {}, footprint {}, virtual size {}",
			when, MB(os_proc_available_memory()), footprint, virtualSize));
	}

	// Cemu's memory_init() reserves one contiguous 4 GB range for the Wii U address space.
	// iPadOS may refuse that without the extended-virtual-addressing entitlement, so probe it first
	// and log the result: if the probe fails, CafeSystem::Initialize() is expected to fail too.
	void ProbeGuestAddressSpace()
	{
		const size_t size = 0x100000000ULL;
		void* p = mmap(nullptr, size, PROT_NONE, MAP_PRIVATE | MAP_ANON, -1, 0);
		if (p == MAP_FAILED)
		{
			WiiPadLog::Write(fmt::format("memory probe: reserving 4 GB of address space FAILED (errno {}: {}). "
				"Cemu's memory_init() needs this; the extended-virtual-addressing entitlement is likely required.",
				errno, strerror(errno)));
			return;
		}
		WiiPadLog::Write(fmt::format("memory probe: reserving 4 GB of address space OK (at {})", p));
		munmap(p, size);
	}

	void CreateDirectories(const fs::path& path)
	{
		std::error_code ec;
		fs::create_directories(path, ec);
		WiiPadLog::Write(fmt::format("  dir {} {}", _pathToUtf8(path), ec ? "FAILED: " + ec.message() : "ok"));
	}

	// Same files the desktop GUI creates on first start (wxgui/CemuApp.cpp: CreateDefaultCemuFiles,
	// CreateDefaultMLCFiles). Returns false if the MLC folder is not writable.
	bool CreateDefaultFiles()
	{
		CreateDirectories(ActiveSettings::GetConfigPath("controllerProfiles"));
		CreateDirectories(ActiveSettings::GetUserDataPath("memorySearcher"));

		const fs::path mlc = ActiveSettings::GetMlcPath();
		const fs::path directories[] = {
			mlc,
			mlc / "sys",
			mlc / "usr",
			mlc / "usr/title/00050000",
			mlc / "usr/title/0005000c",
			mlc / "usr/title/0005000e",
			mlc / "usr/save/00050010/1004a000/user/common/db",
			mlc / "usr/save/00050010/1004a100/user/common/db",
			mlc / "usr/save/00050010/1004a200/user/common/db",
			mlc / "sys/title/0005001b/1005c000/content",
		};
		for (auto& dir : directories)
		{
			std::error_code ec;
			fs::create_directories(dir, ec);
			if (ec)
			{
				WiiPadLog::Fatal(fmt::format("cannot create MLC directory {}: {}", _pathToUtf8(dir), ec.message()));
				return false;
			}
		}
		try
		{
			const fs::path langDir = mlc / "sys/title/0005001b/1005c000/content";
			const fs::path langFile = langDir / "language.txt";
			if (!fs::exists(langFile))
			{
				std::ofstream file(langFile);
				const char* langStrings[] = { "ja", "en", "fr", "de", "it", "es", "zh", "ko", "nl", "pt", "ru", "zh" };
				for (const char* lang : langStrings)
					file << fmt::format(R"("{}",)", lang) << std::endl;
			}
			const fs::path countryFile = langDir / "country.txt";
			if (!fs::exists(countryFile))
			{
				std::ofstream file(countryFile);
				for (sint32 i = 0; i < (sint32)NCrypto::GetCountryCount(); i++)
				{
					const char* countryCode = NCrypto::GetCountryAsString(i);
					if (boost::iequals(countryCode, "NN"))
						file << "NULL," << std::endl;
					else
						file << fmt::format(R"("{}",)", countryCode) << std::endl;
				}
			}
			const fs::path dummyFile = mlc / "writetestdummy";
			{
				std::ofstream file(dummyFile);
				if (!file.is_open())
				{
					WiiPadLog::Fatal("MLC folder is not writable: " + _pathToUtf8(mlc));
					return false;
				}
			}
			fs::remove(dummyFile);
		}
		catch (const std::exception& ex)
		{
			WiiPadLog::Fatal(std::string("creating default MLC files failed: ") + ex.what());
			return false;
		}
		WiiPadLog::Write("default MLC files ok: " + _pathToUtf8(mlc));
		return true;
	}

	void OnCemuInitStage(const char* stage, bool begin)
	{
		WiiPadLog::Write(fmt::format("CemuCommonInit: {} {}", begin ? "begin" : "end  ", stage));
		if (!begin && strcmp(stage, "CafeSystem") == 0)
		{
			WiiPadLog::Write(fmt::format("CafeSystem: Wii U memory space base {}", (void*)memory_base));
			LogMemoryState("after CafeSystem init");
		}
	}

	NSError* MakeError(NSString* message)
	{
		return [NSError errorWithDomain:kCemuBridgeErrorDomain code:1 userInfo:@{ NSLocalizedDescriptionKey: message }];
	}

	void LogMetalDevice()
	{
		MTL::Device* device = MTL::CreateSystemDefaultDevice();
		if (!device)
		{
			WiiPadLog::Fatal("Metal: MTLCreateSystemDefaultDevice returned nil (no Metal device)");
			return;
		}
		WiiPadLog::Write(fmt::format("Metal device: {}", device->name()->utf8String()));
		std::string families;
		const std::pair<MTL::GPUFamily, const char*> checks[] = {
			{ MTL::GPUFamilyApple7, "Apple7" }, { MTL::GPUFamilyApple8, "Apple8" }, { MTL::GPUFamilyApple9, "Apple9" },
			{ MTL::GPUFamilyMetal3, "Metal3" },
		};
		for (auto& [family, name] : checks)
		{
			if (device->supportsFamily(family))
				families += std::string(families.empty() ? "" : ", ") + name;
		}
		WiiPadLog::Write("Metal families: " + (families.empty() ? std::string("none of Apple7/8/9/Metal3") : families));
		WiiPadLog::Write(fmt::format("Metal: unified memory {}, recommended working set {}, max buffer {}",
			device->hasUnifiedMemory() ? "yes" : "no", MB(device->recommendedMaxWorkingSetSize()), MB(device->maxBufferLength())));
		if (@available(iOS 16.4, *))
			WiiPadLog::Write(fmt::format("Metal: BC texture compression {}", device->supportsBCTextureCompression() ? "supported" : "NOT supported (software decode needed)"));
		device->release();
	}
}

@implementation CemuBridge
{
	std::mutex _mutex;
	BOOL _coreInitialized;
	BOOL _rendererInitialized;
	BOOL _shutDown; // Cemu's global state cannot be re-initialized in the same process
	NSString* _logPath;
}

+ (CemuBridge*)shared
{
	static CemuBridge* instance;
	static dispatch_once_t once;
	dispatch_once(&once, ^{
		instance = [[CemuBridge alloc] initPrivate];
	});
	return instance;
}

- (instancetype)initPrivate
{
	self = [super init];
	if (!self)
		return nil;

	NSString* documents = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
	WiiPadLog::Open(ToStd(documents));
	WiiPadLog::InstallFatalSignalHandlers();
	_logPath = [NSString stringWithUTF8String:WiiPadLog::Path().c_str()];

	NSDictionary* info = NSBundle.mainBundle.infoDictionary;
	WiiPadLog::Section("WiiPad startup");
	WiiPadLog::Write(fmt::format("app {} ({}), Cemu {}", ToStd(info[@"CFBundleShortVersionString"]), ToStd(info[@"CFBundleVersion"]), BUILD_VERSION_WITH_NAME_STRING));
	WiiPadLog::Write(fmt::format("device {} ({}), {} {}", SysctlString("hw.machine"), SysctlString("hw.model"),
		ToStd(UIDevice.currentDevice.systemName), ToStd(UIDevice.currentDevice.systemVersion)));
	WiiPadLog::Write(fmt::format("cpu cores {}, physical RAM {}", (int)NSProcessInfo.processInfo.activeProcessorCount, MB(SysctlU64("hw.memsize"))));
	LogMemoryState("startup");
	if (WiiPadLog::PreviousSessionEndedUncleanly())
		WiiPadLog::Write("NOTE: the previous session did not shut down cleanly (crash or app killed). Its log is WiiPad.previous.log");
	WiiPadLog::MarkSessionRunning();
	return self;
}

- (NSString*)logPath
{
	return _logPath;
}

- (BOOL)coreInitialized
{
	return _coreInitialized;
}

- (BOOL)rendererInitialized
{
	return _rendererInitialized;
}

- (void)log:(NSString*)message
{
	WiiPadLog::Write("app: " + ToStd(message));
}

- (BOOL)initializeCoreWithError:(NSError**)error
{
	std::lock_guard lock(_mutex);
	if (_coreInitialized)
		return YES;
	if (_shutDown)
	{
		if (error)
			*error = MakeError(@"The core was shut down. Restart WiiPad to initialize it again.");
		return NO;
	}

	WiiPadLog::Section("CemuBridge: initialize core");
	try
	{
		// --- paths ---
		NSString* documents = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
		NSString* caches = NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES).firstObject;
		const fs::path userData = _utf8ToPath(ToStd(documents));       // visible in the Files app
		const fs::path cache = _utf8ToPath(ToStd(caches)) / "Cemu";     // shader caches etc.; system may purge
		const fs::path data = _utf8ToPath(ToStd(NSBundle.mainBundle.resourcePath)); // read-only bundle resources
		const fs::path exe = _utf8ToPath(ToStd(NSBundle.mainBundle.executablePath));
		WiiPadLog::Write("path user data + config: " + _pathToUtf8(userData));
		WiiPadLog::Write("path cache: " + _pathToUtf8(cache));
		WiiPadLog::Write("path data (bundle): " + _pathToUtf8(data));

		std::set<fs::path> failedWriteAccess;
		ActiveSettings::SetPaths(false, exe, userData, userData, cache, data, failedWriteAccess);
		for (auto& path : failedWriteAccess)
			WiiPadLog::Fatal("no write access: " + _pathToUtf8(path));
		WiiPadLog::Write("path mlc01: " + _pathToUtf8(ActiveSettings::GetMlcPath()));
		WiiPadLog::Write("path Cemu log: " + _pathToUtf8(cemuLog_GetLogFilePath()));

		if (!CreateDefaultFiles())
		{
			if (error)
				*error = MakeError(@"Could not create the default Cemu folders in Documents. See WiiPad.log.");
			return NO;
		}

		// --- config (mirrors wxgui/CemuApp::OnInit) ---
		const fs::path settingsPath = ActiveSettings::GetConfigPath("settings.xml");
		GetConfigHandle().SetFilename(settingsPath.generic_wstring());
		std::error_code ec;
		const bool firstStart = !fs::exists(settingsPath, ec);
		WiiPadLog::Write(fmt::format("config: {} ({})", _pathToUtf8(settingsPath), firstStart ? "first start, writing defaults" : "exists"));
		if (firstStart)
			GetConfigHandle().Save();
		NetworkConfig::LoadOnce();
		ActiveSettings::Init();
		LatteOverlay_init();

		// --- memory ---
		LogMemoryState("before CemuCommonInit");
		ProbeGuestAddressSpace();

		// --- CemuCommonInit ---
		WiiPadLog::Write(fmt::format("CPU mode: {} (forced on iPadOS, no JIT)", ActiveSettings::GetCPUMode() == CPUMode::SinglecoreInterpreter ? "single-core interpreter" : "UNEXPECTED"));
		WiiPadLog::Write("CemuCommonInit: start");
		g_cemuCommonInitStageCallback = &OnCemuInitStage;
		CemuCommonInit();
		g_cemuCommonInitStageCallback = nullptr;
		WiiPadLog::Write("CemuCommonInit: end (success)");

		// Cemu's ExceptionHandler_Init() replaced our signal handlers; chain ours in front of it again
		WiiPadLog::InstallFatalSignalHandlers();

		WiiPadLog::Write(fmt::format("audio: no backend in this build (Cubeb disabled for Phase 1B); graphics API in config: {}",
			GetConfig().graphic_api == GraphicAPI::kMetal ? "Metal" : "other"));
		LogMemoryState("after CemuCommonInit");
		_coreInitialized = YES;
		return YES;
	}
	catch (const std::exception& ex)
	{
		g_cemuCommonInitStageCallback = nullptr;
		WiiPadLog::Fatal(std::string("C++ exception during core init: ") + ex.what());
		if (error)
			*error = MakeError([NSString stringWithFormat:@"Core initialization failed: %s", ex.what()]);
		return NO;
	}
}

- (BOOL)initializeRendererInView:(UIView*)view error:(NSError**)error
{
	if (![NSThread isMainThread])
	{
		WiiPadLog::Fatal("initializeRendererInView must be called on the main thread");
		if (error)
			*error = MakeError(@"initializeRendererInView must be called on the main thread");
		return NO;
	}
	std::lock_guard lock(_mutex);
	if (_rendererInitialized)
		return YES;
	if (!_coreInitialized)
	{
		if (error)
			*error = MakeError(@"Initialize the core before the renderer");
		return NO;
	}

	WiiPadLog::Section("CemuBridge: initialize Metal renderer");
	try
	{
		LogMetalDevice();

		CGSize points = view.bounds.size;
		if (points.width < 1 || points.height < 1)
		{
			WiiPadLog::Write("host view has no size yet; using 1280x720 pt");
			points = CGSizeMake(1280, 720);
		}
		CGFloat scale = view.traitCollection.displayScale > 0 ? view.traitCollection.displayScale : 2.0;

		auto& windowInfo = WindowSystem::GetWindowInfo();
		windowInfo.window_main.backend = WindowSystem::WindowHandleInfo::Backend::UIKit;
		windowInfo.window_main.display = nullptr;
		windowInfo.window_main.surface = (__bridge void*)view;
		windowInfo.canvas_main = windowInfo.window_main;
		windowInfo.width = (int)points.width;
		windowInfo.height = (int)points.height;
		windowInfo.phys_width = (int)(points.width * scale);
		windowInfo.phys_height = (int)(points.height * scale);
		windowInfo.dpi_scale = scale;
		windowInfo.pad_open = false;
		windowInfo.is_fullscreen = true;
		windowInfo.app_active = true;
		WiiPadLog::Write(fmt::format("host view {}x{} pt, scale {}", (int)points.width, (int)points.height, (double)scale));

		WiiPadLog::Write("MetalRenderer: constructing");
		g_renderer = std::make_unique<MetalRenderer>();
		WiiPadLog::Write("MetalRenderer: constructed");

		WiiPadLog::Write("MetalRenderer: InitializeLayer (main)");
		MetalRenderer::GetInstance()->InitializeLayer({ (sint32)points.width, (sint32)points.height }, true);
		WiiPadLog::Write("MetalRenderer: layer ready. Full renderer setup (shader cache, overlay) runs at game launch in Phase 2.");

		_rendererInitialized = YES;
		return YES;
	}
	catch (const std::exception& ex)
	{
		WiiPadLog::Fatal(std::string("C++ exception during renderer init: ") + ex.what());
		g_renderer.reset();
		if (error)
			*error = MakeError([NSString stringWithFormat:@"Metal renderer initialization failed: %s", ex.what()]);
		return NO;
	}
}

- (void)shutdown
{
	std::lock_guard lock(_mutex);
	WiiPadLog::Section("CemuBridge: shutdown");
	if (_rendererInitialized)
	{
		WiiPadLog::Write("MetalRenderer: shutting down layer");
		MetalRenderer::GetInstance()->ShutdownLayer(true);
		g_renderer.reset();
		_rendererInitialized = NO;
		WiiPadLog::Write("MetalRenderer: destroyed");
	}
	if (_coreInitialized)
	{
		WiiPadLog::Write("CafeSystem: shutting down");
		CafeSystem::Shutdown();
		_coreInitialized = NO;
		WiiPadLog::Write("CafeSystem: shut down");
	}
	cemuLog_waitForFlush();
	LogMemoryState("after shutdown");
	_shutDown = YES;
	WiiPadLog::Write("shutdown complete");
	WiiPadLog::MarkSessionEndedCleanly();
}

@end
