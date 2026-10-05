#pragma once

// iPadOS audio output backend for Cemu's IAudioAPI (desktop equivalents: CubebAPI, XAudio2API).
// Plays 16-bit interleaved PCM blocks through the RemoteIO AudioUnit. Buffering follows CubebAPI:
// FeedBlock() appends to a byte queue, the render callback drains it and pads with silence.
// Registered in IAudioAPI.cpp under #if BOOST_OS_IOS. Plain C++ header (included from IAudioAPI.cpp).

#include "audio/IAudioAPI.h"

#include <atomic>
#include <shared_mutex>
#include <vector>

class IOSAudioAPI : public IAudioAPI
{
public:
	class IOSDeviceDescription : public DeviceDescription
	{
	public:
		IOSDeviceDescription() : DeviceDescription(L"Default Device") {}
		std::wstring GetIdentifier() const override { return L"default"; }
	};

	IOSAudioAPI(uint32 samplerate, uint32 channels, uint32 samples_per_block, uint32 bits_per_sample);
	~IOSAudioAPI() override;

	AudioAPI GetType() const override { return AudioUnitIOS; }
	bool NeedAdditionalBlocks() const override;
	bool FeedBlock(sint16* data) override;
	bool Play() override;
	bool Stop() override;

	static bool InitializeStatic();
	static std::vector<DeviceDescriptionPtr> GetDevices();

	// called on the realtime audio thread; fills `bytes` of output
	void Render(uint8* output, size_t bytes);

private:
	void* m_unit = nullptr; // AudioComponentInstance
	bool m_isPlaying = false;

	mutable std::shared_mutex m_mutex;
	std::vector<uint8> m_buffer;

	// diagnostics (logged once, never from the audio thread)
	bool m_loggedFirstFeed = false;
	bool m_loggedFirstRender = false;
	bool m_loggedDrop = false;
	std::atomic_bool m_renderedSamples{ false };
	std::atomic_uint32_t m_underruns{ 0 };
};
