#include "IOSAudioAPI.h"
#include "WiiPadLog.h"
#include "WiiPadDiagnostics.h"

#import <AVFAudio/AVFAudio.h>
#import <AudioToolbox/AudioToolbox.h>

namespace
{
	std::string OSStatusText(OSStatus status)
	{
		// four-character codes are common for AudioUnit errors
		const uint32 v = (uint32)status;
		char cc[5] = { (char)(v >> 24), (char)(v >> 16), (char)(v >> 8), (char)v, 0 };
		bool printable = true;
		for (int i = 0; i < 4; i++)
			printable &= cc[i] >= 32 && cc[i] < 127;
		return printable ? fmt::format("{} ('{}')", (int)status, cc) : fmt::format("{}", (int)status);
	}

	OSStatus RenderCallback(void* refCon, AudioUnitRenderActionFlags* flags, const AudioTimeStamp* timeStamp,
		UInt32 busNumber, UInt32 frameCount, AudioBufferList* ioData)
	{
		auto* api = (IOSAudioAPI*)refCon;
		for (UInt32 i = 0; i < ioData->mNumberBuffers; i++)
			api->Render((uint8*)ioData->mBuffers[i].mData, ioData->mBuffers[i].mDataByteSize);
		return noErr;
	}
}

bool IOSAudioAPI::InitializeStatic()
{
	@autoreleasepool
	{
		AVAudioSession* session = AVAudioSession.sharedInstance;
		NSError* error = nil;
		if (![session setCategory:AVAudioSessionCategoryPlayback error:&error])
		{
			WiiPadLog::Write(std::string("audio: AVAudioSession setCategory(Playback) failed: ") + (error.localizedDescription.UTF8String ?: "?"));
			return false;
		}
		[session setPreferredSampleRate:48000 error:nil]; // a preference only; the AudioUnit converts if the hardware differs
		if (![session setActive:YES error:&error])
		{
			WiiPadLog::Write(std::string("audio: AVAudioSession setActive failed: ") + (error.localizedDescription.UTF8String ?: "?"));
			return false;
		}
		WiiPadLog::Write(fmt::format("audio: backend initialized (AudioUnit RemoteIO, AVAudioSession Playback, hardware {} Hz, {} output channels, route {})",
			(int)session.sampleRate, (int)session.outputNumberOfChannels,
			session.currentRoute.outputs.firstObject.portName.UTF8String ?: "?"));
		return true;
	}
}

std::vector<IAudioAPI::DeviceDescriptionPtr> IOSAudioAPI::GetDevices()
{
	// iOS routes output itself (speaker, headphones, AirPlay); expose one "default" device, matching config.tv_device
	return { std::make_shared<IOSDeviceDescription>() };
}

IOSAudioAPI::IOSAudioAPI(uint32 samplerate, uint32 channels, uint32 samples_per_block, uint32 bits_per_sample)
	: IAudioAPI(samplerate, channels, samples_per_block, bits_per_sample)
{
	auto fail = [this](const char* what, OSStatus status) {
		const std::string text = fmt::format("audio: device error: {} failed ({})", what, OSStatusText(status));
		WiiPadLog::Write(text);
		if (m_unit)
		{
			AudioComponentInstanceDispose((AudioComponentInstance)m_unit);
			m_unit = nullptr;
		}
		throw std::runtime_error(text); // caught by snd_core::AXOut_init ("can't initialize tv audio")
	};

	if (bits_per_sample != 16)
		throw std::runtime_error(fmt::format("audio: unsupported sample size {} bits", bits_per_sample));

	AudioComponentDescription desc{};
	desc.componentType = kAudioUnitType_Output;
	desc.componentSubType = kAudioUnitSubType_RemoteIO;
	desc.componentManufacturer = kAudioUnitManufacturer_Apple;
	AudioComponent component = AudioComponentFindNext(nullptr, &desc);
	if (!component)
		fail("AudioComponentFindNext(RemoteIO)", -1);

	AudioComponentInstance unit = nullptr;
	OSStatus status = AudioComponentInstanceNew(component, &unit);
	if (status != noErr)
		fail("AudioComponentInstanceNew", status);
	m_unit = unit;

	// format Cemu feeds: interleaved signed 16-bit native-endian PCM
	AudioStreamBasicDescription format{};
	format.mSampleRate = samplerate;
	format.mFormatID = kAudioFormatLinearPCM;
	format.mFormatFlags = kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked;
	format.mChannelsPerFrame = channels;
	format.mBitsPerChannel = 16;
	format.mBytesPerFrame = channels * 2;
	format.mFramesPerPacket = 1;
	format.mBytesPerPacket = format.mBytesPerFrame;
	status = AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &format, sizeof(format));
	if (status != noErr)
		fail("AudioUnitSetProperty(StreamFormat)", status);

	AURenderCallbackStruct callback{};
	callback.inputProc = &RenderCallback;
	callback.inputProcRefCon = this;
	status = AudioUnitSetProperty(unit, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0, &callback, sizeof(callback));
	if (status != noErr)
		fail("AudioUnitSetProperty(SetRenderCallback)", status);

	status = AudioUnitInitialize(unit);
	if (status != noErr)
		fail("AudioUnitInitialize", status);

	m_buffer.reserve((size_t)m_bytesPerBlock * kBlockCount);
	WiiPadLog::Write(fmt::format("audio: stream created ({} Hz, {} ch, 16-bit, {} frames per block, delay {} blocks)",
		samplerate, channels, samples_per_block, GetAudioDelay()));
}

IOSAudioAPI::~IOSAudioAPI()
{
	if (m_unit)
	{
		Stop();
		AudioUnitUninitialize((AudioComponentInstance)m_unit);
		AudioComponentInstanceDispose((AudioComponentInstance)m_unit);
		m_unit = nullptr;
	}
}

bool IOSAudioAPI::NeedAdditionalBlocks() const
{
	WiiPadDiag::schedulerEvents.Hit(); // called by AXOut_update from the PPC scheduler's idle loop
	std::shared_lock lock(m_mutex);
	return m_buffer.size() < GetAudioDelay() * m_bytesPerBlock;
}

bool IOSAudioAPI::FeedBlock(sint16* data)
{
	WiiPadDiag::audioFeed.Hit();
	// diagnostics are logged here (emulation thread), never on the realtime audio thread
	if (!m_loggedFirstFeed)
	{
		m_loggedFirstFeed = true;
		WiiPadLog::Write("audio: first samples submitted by the game (TV)");
	}
	if (!m_loggedFirstRender && m_renderedSamples.load(std::memory_order_relaxed))
	{
		m_loggedFirstRender = true;
		WiiPadLog::Write("audio: first game samples played by the audio device");
	}

	std::unique_lock lock(m_mutex);
	if (m_buffer.capacity() <= m_buffer.size() + m_bytesPerBlock)
	{
		if (!m_loggedDrop)
		{
			m_loggedDrop = true;
			lock.unlock();
			WiiPadLog::Write("audio: buffer full, dropping blocks (device not consuming; logged once)");
		}
		return false;
	}
	m_buffer.insert(m_buffer.end(), (uint8*)data, (uint8*)data + m_bytesPerBlock);
	return true;
}

void IOSAudioAPI::Render(uint8* output, size_t bytes)
{
	WiiPadDiag::audioRender.Hit();
	std::unique_lock lock(m_mutex);
	const size_t copied = std::min(m_buffer.size(), bytes);
	if (copied > 0)
	{
		memcpy(output, m_buffer.data(), copied);
		m_buffer.erase(m_buffer.begin(), m_buffer.begin() + copied);
	}
	lock.unlock();
	if (copied < bytes)
	{
		memset(output + copied, 0, bytes - copied);
		if (copied == 0)
			m_underruns.fetch_add(1, std::memory_order_relaxed);
	}
	if (copied == 0)
		return;
	WiiPadDiag::audioRenderData.Hit();
	m_renderedSamples.store(true, std::memory_order_relaxed);

	// volume (config tv_volume, 0..100), as CubebAPI does through cubeb_stream_set_volume
	const sint32 volume = m_volume;
	if (volume < 100)
	{
		sint16* samples = (sint16*)output;
		const size_t count = copied / sizeof(sint16);
		for (size_t i = 0; i < count; i++)
			samples[i] = (sint16)((sint32)samples[i] * volume / 100);
	}
}

bool IOSAudioAPI::Play()
{
	if (m_isPlaying)
		return true;
	WiiPadDiag::audioPlay.Hit();
	const OSStatus status = AudioOutputUnitStart((AudioComponentInstance)m_unit);
	if (status != noErr)
	{
		WiiPadLog::Write(fmt::format("audio: device error: AudioOutputUnitStart failed ({})", OSStatusText(status)));
		return false;
	}
	m_isPlaying = true;
	WiiPadLog::Write("audio: output started");
	return true;
}

bool IOSAudioAPI::Stop()
{
	if (!m_isPlaying)
		return true;
	const OSStatus status = AudioOutputUnitStop((AudioComponentInstance)m_unit);
	if (status != noErr)
	{
		WiiPadLog::Write(fmt::format("audio: device error: AudioOutputUnitStop failed ({})", OSStatusText(status)));
		return false;
	}
	m_isPlaying = false;
	WiiPadLog::Write("audio: output stopped");
	return true;
}
