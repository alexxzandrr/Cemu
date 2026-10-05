#import "CemuBridge.h"

#include "WiiPadLog.h"
#include "WiiPadTouchController.h"
#include "WiiPadDiagnostics.h"
#include "audio/IAudioAPI.h"

#include "Cafe/CafeSystem.h"
#include "Cafe/Filesystem/fsc.h"
#include "Cafe/HW/Latte/Core/Latte.h"
#include "Cafe/TitleList/TitleInfo.h"
#include "Cafe/TitleList/TitleList.h"
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
#include <thread>

// provided by src/main.cpp
void CemuCommonInit();
extern void (*g_cemuCommonInitStageCallback)(const char* stage, bool begin);
// provided by src/Cafe/CafeSystem.cpp
extern void (*g_cemuTitleLaunchStageCallback)(const char* stage, bool begin);

static NSString* const kCemuBridgeErrorDomain = @"WiiPad.CemuBridge";
static NSString* const kSavedTitleBookmarkKey = @"WiiPadSavedTitleBookmark";

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

	// ---------------- Phase 2A: title launch ----------------

	const char* TitleFormatName(TitleInfo::TitleDataFormat format)
	{
		switch (format)
		{
		case TitleInfo::TitleDataFormat::HOST_FS: return "extracted folder (code/content/meta)";
		case TitleInfo::TitleDataFormat::WUD: return "disc image (.wud/.wux)";
		case TitleInfo::TitleDataFormat::WIIU_ARCHIVE: return "Wii U archive (.wua)";
		case TitleInfo::TitleDataFormat::NUS: return "NUS (title.tmd)";
		case TitleInfo::TitleDataFormat::WUHB: return "Wii U homebrew bundle (.wuhb)";
		default: return "invalid";
		}
	}

	std::string InvalidReasonText(TitleInfo::InvalidReason reason)
	{
		switch (reason)
		{
		case TitleInfo::InvalidReason::BAD_PATH_OR_INACCESSIBLE: return "the path is not accessible";
		case TitleInfo::InvalidReason::UNKNOWN_FORMAT: return "not a recognized Wii U title. Pick the title's root folder (with code, content and meta) or a .wua / .wud / .wux / .wuhb / .rpx file";
		case TitleInfo::InvalidReason::NO_DISC_KEY: return "the disc image cannot be decrypted: put a keys.txt with this title's disc key into WiiPad's Documents folder";
		case TitleInfo::InvalidReason::NO_TITLE_TIK: return "the title cannot be decrypted because title.tik (or the meta .xml files) is missing";
		default: return "invalid title (unknown reason)";
		}
	}

	std::atomic_bool s_monitorStop{ false };

	void OnTitleLaunchStage(const char* stage, bool begin)
	{
		WiiPadLog::SetStage(stage);
		if (strstr(stage, "RPX/RPL loading"))
			WiiPadLog::Write(begin ? "RPX/RPL loading started (coreinit + main executable)" : "RPX/RPL loading completed");
		else if (strstr(stage, "game initialization") && !begin)
			WiiPadLog::Write("game initialization completed (coreinit entrypoint returned)");
		else if (strstr(stage, "PPC scheduler"))
			WiiPadLog::Write("PPC scheduler started: game code now runs on the single-core interpreter");
		else
			WiiPadLog::Write(fmt::format("boot stage {}: {}", begin ? "begin" : "end  ", stage));
	}

	// CafeSystem calls back into the frontend through this interface (desktop: MainWindow).
	class WiiPadSystemImplementation : public CafeSystem::SystemImplementation
	{
	public:
		void CafeRecreateCanvas() override
		{
			WiiPadLog::Write("CafeSystem requested a canvas recreation (not supported in Phase 2A; ignored)");
		}

		void CafePPCProcessExit() override
		{
			auto status = CafeSystem::GetForegroundTitleReturnStatus();
			WiiPadLog::Write(fmt::format("emulated title process exited (return status {})", status ? std::to_string(*status) : std::string("unknown")));
		}
	};
	WiiPadSystemImplementation s_systemImplementation;

	// Read-only check of the mounted code folder before launch. CafeSystem's LoadMainExecutable() runs on the
	// launch thread and traps (cemu_assert) if no .rpx exists; catching that case here keeps it a reportable error.
	bool MountedCodeFolderHasRPX(std::string& firstRpx)
	{
		sint32 status = 0;
		FSCVirtualFile* dir = fsc_openDirIterator("/internal/current_title/code/", &status);
		if (!dir)
			return false;
		FSCDirEntry entry;
		bool found = false;
		while (fsc_nextDir(dir, &entry))
		{
			size_t len = strlen(entry.path);
			if (len >= 4 && boost::iequals(entry.path + len - 4, ".rpx"))
			{
				firstRpx = entry.path;
				found = true;
				break;
			}
		}
		fsc_close(dir);
		return found;
	}

	// Logs how far the running title gets: GPU init, the game's GX2Init() call and presented frames.
	void StartProgressMonitor()
	{
		std::thread([] {
			SetThreadName("WiiPadMonitor");
			bool gpuInit = false;
			uint32 gx2Init = 0, flips = 0;
			const auto start = std::chrono::steady_clock::now();
			while (!s_monitorStop && std::chrono::steady_clock::now() - start < std::chrono::minutes(5))
			{
				const double t = std::chrono::duration<double>(std::chrono::steady_clock::now() - start).count();
				if (!gpuInit && g_isGPUInitFinished)
				{
					gpuInit = true;
					WiiPadLog::Write(fmt::format("progress +{:.1f}s: GPU thread initialized (renderer, shader cache)", t));
				}
				if (LatteGPUState.gx2InitCalled != gx2Init)
				{
					gx2Init = LatteGPUState.gx2InitCalled;
					WiiPadLog::Write(fmt::format("progress +{:.1f}s: game called GX2Init() (count {})", t, gx2Init));
				}
				const uint32 f = LatteGPUState.flipCounter;
				if (f != flips && (flips == 0 || f / 60 != flips / 60))
					WiiPadLog::Write(fmt::format("progress +{:.1f}s: {} frames presented", t, f));
				flips = f;
				std::this_thread::sleep_for(std::chrono::milliseconds(250));
			}
			WiiPadLog::Write(fmt::format("progress monitor stopped (GPU init {}, GX2Init calls {}, frames {})", gpuInit ? "yes" : "no", gx2Init, flips));
		}).detach();
	}
}

@implementation CemuBridge
{
	std::mutex _mutex;
	BOOL _coreInitialized;
	BOOL _rendererInitialized;
	BOOL _shutDown; // Cemu's global state cannot be re-initialized in the same process
	NSString* _logPath;
	// Phase 2A title state
	NSURL* _titleURL;           // kept alive while security-scoped access is held
	BOOL _titleAccessStarted;
	BOOL _titlePrepareAttempted; // CafeSystem was asked to mount/prepare a title (no second attempt per session)
	BOOL _titleLaunched;
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
	if (WiiPadLog::PreviousSessionCrashLogsKept())
		WiiPadLog::Write("NOTE: the previous session crashed. Its logs were kept as WiiPad.crash.log, stdout.crash.txt and log.crash.txt");
	else if (WiiPadLog::PreviousSessionEndedUncleanly())
		WiiPadLog::Write("NOTE: the previous session did not shut down cleanly (app closed or killed). Its log is WiiPad.previous.log");
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

		// audio: CemuCommonInit loaded the config; select the iOS backend for this session (in memory only).
		// Cubeb is not built for iOS (its AudioUnit backend uses macOS-only Core Audio APIs).
		if (IAudioAPI::IsAudioAPIAvailable(IAudioAPI::AudioUnitIOS))
		{
			GetConfig().audio_api = IAudioAPI::AudioUnitIOS;
			GetConfig().tv_device = L"default";
			WiiPadLog::Write(fmt::format("audio: TV output -> AudioUnit (iOS) default device, volume {}%; GamePad audio: {}",
				GetConfig().tv_volume, GetConfig().pad_device.empty() ? "off (no device configured, Cemu default)" : "configured"));
		}
		else
			WiiPadLog::Write("audio: device error: the iOS audio backend is not available (see the 'audio:' lines above); the title will run without sound");
		WiiPadLog::Write(fmt::format("graphics API in config: {}", GetConfig().graphic_api == GraphicAPI::kMetal ? "Metal" : "other"));
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

- (BOOL)titleLaunched
{
	return _titleLaunched;
}

- (nullable NSURL*)savedTitleURL
{
	NSData* bookmark = [NSUserDefaults.standardUserDefaults dataForKey:kSavedTitleBookmarkKey];
	if (!bookmark)
		return nil;
	BOOL stale = NO;
	NSError* error = nil;
	NSURL* url = [NSURL URLByResolvingBookmarkData:bookmark options:0 relativeToURL:nil bookmarkDataIsStale:&stale error:&error];
	if (!url)
	{
		WiiPadLog::Write("saved title bookmark could not be resolved: " + ToStd(error.localizedDescription));
		return nil;
	}
	if (stale)
		WiiPadLog::Write("saved title bookmark is stale; it is refreshed when the title is opened");
	return url;
}

- (nullable NSString*)launchTitleAtURL:(NSURL*)url error:(NSError**)error
{
	std::lock_guard lock(_mutex);
	auto fail = [&](const std::string& message) -> NSString* {
		WiiPadLog::Write("title load failed: " + message);
		if (error)
			*error = MakeError([NSString stringWithUTF8String:message.c_str()]);
		return nil;
	};

	WiiPadLog::Section("CemuBridge: load title");
	WiiPadLog::Write("title URL selected: " + ToStd(url.lastPathComponent));
	if (_titleLaunched)
		return fail("a title is already running. Restart WiiPad to load another title.");
	if (_titlePrepareAttempted)
		return fail("a previous title failed after Cemu started preparing it. Restart WiiPad before loading another title.");
	if (_shutDown || !_coreInitialized || !_rendererInitialized)
		return fail("the Cemu core and Metal renderer must be initialized first (restart WiiPad).");

	// --- security-scoped access (held for the rest of the session) ---
	if (_titleAccessStarted && _titleURL)
	{
		[_titleURL stopAccessingSecurityScopedResource];
		_titleAccessStarted = NO;
	}
	_titleURL = url;
	_titleAccessStarted = [url startAccessingSecurityScopedResource];
	WiiPadLog::Write(_titleAccessStarted ? "security-scoped access started"
		: "security-scoped access not required for this URL (e.g. inside WiiPad's own container)");

	// bookmark so the same title can be reopened next session without the picker
	NSError* bookmarkError = nil;
	NSData* bookmark = [url bookmarkDataWithOptions:0 includingResourceValuesForKeys:nil relativeToURL:nil error:&bookmarkError];
	if (bookmark)
		[NSUserDefaults.standardUserDefaults setObject:bookmark forKey:kSavedTitleBookmarkKey];
	else
		WiiPadLog::Write("could not save a bookmark for this title: " + ToStd(bookmarkError.localizedDescription));

	// --- resolve to a POSIX path Cemu can use while access is held ---
	const fs::path titlePath = _utf8ToPath(url.fileSystemRepresentation);
	WiiPadLog::Write("resolved title path: " + _pathToUtf8(titlePath));
	std::error_code ec;
	const bool exists = fs::exists(titlePath, ec);
	const bool isDirectory = exists && fs::is_directory(titlePath, ec);
	if (!exists)
		return fail(fmt::format("the selected item is not accessible at its path ({}). If it is in iCloud Drive, download it first or store it On My iPad.",
			ec ? ec.message() : "does not exist"));
	WiiPadLog::Write(fmt::format("path is accessible ({})", isDirectory ? "folder" : fmt::format("file, {} bytes", fs::file_size(titlePath, ec))));

	try
	{
		// --- identify the title (same logic as the desktop MainWindow::FileLoad) ---
		TitleInfo launchTitle{ titlePath };
		CafeSystem::PREPARE_STATUS_CODE result;
		if (launchTitle.IsValid())
		{
			WiiPadLog::Write(fmt::format("title metadata loaded: \"{}\", title id {:016x}, version {}, format {}",
				launchTitle.GetMetaTitleName(), launchTitle.GetAppTitleId(), launchTitle.GetAppTitleVersion(), TitleFormatName(launchTitle.GetFormat())));
			CafeTitleList::AddTitleFromPath(titlePath);
			TitleId baseTitleId;
			if (!CafeTitleList::FindBaseTitleId(launchTitle.GetAppTitleId(), baseTitleId))
				return fail("unable to launch: the base files for this title were not found (an update or DLC was selected instead of the game).");
			WiiPadLog::Write(fmt::format("Cafe boot requested: CafeSystem::PrepareForegroundTitle({:016x})", baseTitleId));
			_titlePrepareAttempted = YES;
			result = CafeSystem::PrepareForegroundTitle(baseTitleId);
		}
		else
		{
			const CafeTitleFileType fileType = isDirectory ? CafeTitleFileType::UNKNOWN : DetermineCafeSystemFileType(titlePath);
			if (fileType == CafeTitleFileType::RPX || fileType == CafeTitleFileType::ELF)
			{
				WiiPadLog::Write(fmt::format("title metadata: none (standalone {}); Cafe boot requested: CafeSystem::PrepareForegroundTitleFromStandaloneRPX",
					fileType == CafeTitleFileType::RPX ? "RPX" : "ELF"));
				_titlePrepareAttempted = YES;
				result = CafeSystem::PrepareForegroundTitleFromStandaloneRPX(titlePath);
			}
			else
				return fail("unable to load: " + InvalidReasonText(launchTitle.GetInvalidReason()) + ".");
		}

		switch (result)
		{
		case CafeSystem::PREPARE_STATUS_CODE::SUCCESS:
			break;
		case CafeSystem::PREPARE_STATUS_CODE::INVALID_RPX:
			return fail("Cemu reported an invalid RPX executable (PREPARE_STATUS_CODE::INVALID_RPX). See log.txt.");
		case CafeSystem::PREPARE_STATUS_CODE::UNABLE_TO_MOUNT:
			return fail("Cemu could not mount the title (PREPARE_STATUS_CODE::UNABLE_TO_MOUNT): game meta files missing, inaccessible or invalid. See log.txt.");
		default:
			return fail(fmt::format("Cemu failed to prepare the title (status {}). See log.txt.", (int)result));
		}
		WiiPadLog::Write(fmt::format("title prepared: \"{}\" ({:016x})", CafeSystem::GetForegroundTitleName(), CafeSystem::GetForegroundTitleId()));

		std::string rpx;
		if (launchTitle.IsValid())
		{
			if (!MountedCodeFolderHasRPX(rpx))
				return fail("the title's code folder contains no .rpx executable, so Cemu cannot boot it.");
			WiiPadLog::Write("main executable found: code/" + rpx);
		}

		// --- boot ---
		// input: on-screen controls as the emulated Wii U GamePad (Cemu's InputManager / VPADController)
		if (!WiiPadInput::ConnectGamePad())
			WiiPadLog::Write("input: continuing without GamePad input");

		CafeSystem::SetImplementation(&s_systemImplementation);
		g_cemuTitleLaunchStageCallback = &OnTitleLaunchStage;
		WiiPadLog::SetStage("game initialization started");
		WiiPadLog::Write("game initialization started: CafeSystem::LaunchForegroundTitle() (CPU: single-core interpreter)");
		CafeSystem::LaunchForegroundTitle();
		_titleLaunched = YES;
		StartProgressMonitor();
		WiiPadDiag::StartMonitor(); // diagnostic-only: emulation/GPU/audio/input heartbeat and thread snapshots
		LogMemoryState("after LaunchForegroundTitle");
		return [NSString stringWithUTF8String:CafeSystem::GetForegroundTitleName().c_str()];
	}
	catch (const std::exception& ex)
	{
		return fail(std::string("game initialization failed: C++ exception: ") + ex.what());
	}
}

- (void)setGamePadButton:(WiiPadButton)button pressed:(BOOL)pressed
{
	WiiPadInput::SetButton((WiiPadInput::Button)button, pressed);
}

- (void)setGamePadStick:(NSInteger)stick x:(float)x y:(float)y
{
	WiiPadInput::SetStick((int)stick, x, y);
}

- (void)setGameViewTouchDown:(BOOL)down x:(float)x y:(float)y
{
	if (!_titleLaunched)
		return;
	WiiPadInput::SetTouch(down, x, y);
}

- (void)shutdown
{
	std::lock_guard lock(_mutex);
	WiiPadLog::Section("CemuBridge: shutdown");
	if (_titleLaunched)
	{
		// Stopping a running title (CafeSystem::ShutdownTitle) is not wired up in Phase 2A.
		WiiPadLog::Write("a title is running: in-app shutdown is not supported in Phase 2A. Close WiiPad from the app switcher.");
		cemuLog_waitForFlush();
		return;
	}
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
	if (_titleAccessStarted && _titleURL)
	{
		[_titleURL stopAccessingSecurityScopedResource];
		_titleAccessStarted = NO;
		WiiPadLog::Write("security-scoped access stopped");
	}
	cemuLog_waitForFlush();
	LogMemoryState("after shutdown");
	_shutDown = YES;
	WiiPadLog::Write("shutdown complete");
	WiiPadLog::MarkSessionEndedCleanly();
}

@end
