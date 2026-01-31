#pragma once

#include <deque>
#include <AudioToolbox/AudioToolbox.h>
#include "../SoundHandler.h"

class CSH_CoreAudio : public CSoundHandler
{
public:
	enum
	{
		MAX_BUFFERS = 25,
		BUFFER_SAMPLES = 2048,
	};

	CSH_CoreAudio();
	virtual ~CSH_CoreAudio();

	static CSoundHandler* HandlerFactory();

	void Reset() override;
	void Write(int16*, unsigned int, unsigned int) override;
	bool HasFreeBuffers() override;
	void RecycleBuffers() override;

private:
	struct AudioBuffer
	{
		int16* data = nullptr;
		uint32 sampleCount = 0;
		uint32 sampleRate = 0;
		uint32 readOffset = 0;
		bool inUse = false;
	};

	static OSStatus RenderCallback(
	    void* inRefCon,
	    AudioUnitRenderActionFlags* ioActionFlags,
	    const AudioTimeStamp* inTimeStamp,
	    UInt32 inBusNumber,
	    UInt32 inNumberFrames,
	    AudioBufferList* ioData);

	void SetupAudioUnit();
	void TeardownAudioUnit();

	AudioComponentInstance m_audioUnit = nullptr;
	bool m_audioUnitRunning = false;

	AudioBuffer m_buffers[MAX_BUFFERS];
	std::deque<int> m_availableBufferIndices;
	std::deque<int> m_queuedBufferIndices;

	// Lock-free ring buffer approach: use atomic for thread safety
	// between audio render thread and emulator thread
	std::mutex m_bufferMutex;
};
