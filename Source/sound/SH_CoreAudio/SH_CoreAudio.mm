#include "SH_CoreAudio.h"
#include <assert.h>
#include <cstring>
#include <mutex>

CSH_CoreAudio::CSH_CoreAudio()
{
	for(int i = 0; i < MAX_BUFFERS; i++)
	{
		m_buffers[i].data = new int16[BUFFER_SAMPLES * 2]; // stereo
		m_buffers[i].inUse = false;
		m_availableBufferIndices.push_back(i);
	}
	SetupAudioUnit();
}

CSH_CoreAudio::~CSH_CoreAudio()
{
	TeardownAudioUnit();
	for(int i = 0; i < MAX_BUFFERS; i++)
	{
		delete[] m_buffers[i].data;
		m_buffers[i].data = nullptr;
	}
}

CSoundHandler* CSH_CoreAudio::HandlerFactory()
{
	return new CSH_CoreAudio();
}

void CSH_CoreAudio::SetupAudioUnit()
{
	AudioComponentDescription desc = {};
	desc.componentType = kAudioUnitType_Output;
#if TARGET_OS_IPHONE
	desc.componentSubType = kAudioUnitSubType_RemoteIO;
#else
	desc.componentSubType = kAudioUnitSubType_DefaultOutput;
#endif
	desc.componentManufacturer = kAudioUnitManufacturer_Apple;

	AudioComponent component = AudioComponentFindNext(nullptr, &desc);
	if(!component) return;

	OSStatus status = AudioComponentInstanceNew(component, &m_audioUnit);
	if(status != noErr) return;

	// Set output format: stereo 16-bit PCM at 48000 Hz
	AudioStreamBasicDescription format = {};
	format.mSampleRate = 48000.0;
	format.mFormatID = kAudioFormatLinearPCM;
	format.mFormatFlags = kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked;
	format.mBitsPerChannel = 16;
	format.mChannelsPerFrame = 2;
	format.mFramesPerPacket = 1;
	format.mBytesPerFrame = format.mBitsPerChannel / 8 * format.mChannelsPerFrame;
	format.mBytesPerPacket = format.mBytesPerFrame * format.mFramesPerPacket;

	status = AudioUnitSetProperty(m_audioUnit,
	                              kAudioUnitProperty_StreamFormat,
	                              kAudioUnitScope_Input,
	                              0, &format, sizeof(format));
	if(status != noErr)
	{
		AudioComponentInstanceDispose(m_audioUnit);
		m_audioUnit = nullptr;
		return;
	}

	// Set render callback
	AURenderCallbackStruct callbackStruct = {};
	callbackStruct.inputProc = RenderCallback;
	callbackStruct.inputProcRefCon = this;

	status = AudioUnitSetProperty(m_audioUnit,
	                              kAudioUnitProperty_SetRenderCallback,
	                              kAudioUnitScope_Input,
	                              0, &callbackStruct, sizeof(callbackStruct));
	if(status != noErr)
	{
		AudioComponentInstanceDispose(m_audioUnit);
		m_audioUnit = nullptr;
		return;
	}

	status = AudioUnitInitialize(m_audioUnit);
	if(status != noErr)
	{
		AudioComponentInstanceDispose(m_audioUnit);
		m_audioUnit = nullptr;
		return;
	}

	status = AudioOutputUnitStart(m_audioUnit);
	if(status == noErr)
	{
		m_audioUnitRunning = true;
	}
}

void CSH_CoreAudio::TeardownAudioUnit()
{
	if(m_audioUnit)
	{
		if(m_audioUnitRunning)
		{
			AudioOutputUnitStop(m_audioUnit);
			m_audioUnitRunning = false;
		}
		AudioUnitUninitialize(m_audioUnit);
		AudioComponentInstanceDispose(m_audioUnit);
		m_audioUnit = nullptr;
	}
}

OSStatus CSH_CoreAudio::RenderCallback(
    void* inRefCon,
    AudioUnitRenderActionFlags* ioActionFlags,
    const AudioTimeStamp* inTimeStamp,
    UInt32 inBusNumber,
    UInt32 inNumberFrames,
    AudioBufferList* ioData)
{
	auto handler = static_cast<CSH_CoreAudio*>(inRefCon);
	int16* outputBuffer = static_cast<int16*>(ioData->mBuffers[0].mData);
	UInt32 bytesNeeded = inNumberFrames * 2 * sizeof(int16); // stereo

	UInt32 bytesWritten = 0;

	std::lock_guard<std::mutex> lock(handler->m_bufferMutex);

	while(bytesWritten < bytesNeeded && !handler->m_queuedBufferIndices.empty())
	{
		int bufIdx = handler->m_queuedBufferIndices.front();
		auto& buf = handler->m_buffers[bufIdx];

		uint32 samplesRemaining = buf.sampleCount - buf.readOffset;
		uint32 framesToCopy = (bytesNeeded - bytesWritten) / (2 * sizeof(int16));
		uint32 samplesToCopy = std::min(samplesRemaining, framesToCopy * 2u);

		memcpy(reinterpret_cast<uint8*>(outputBuffer) + bytesWritten,
		       buf.data + buf.readOffset,
		       samplesToCopy * sizeof(int16));

		bytesWritten += samplesToCopy * sizeof(int16);
		buf.readOffset += samplesToCopy;

		if(buf.readOffset >= buf.sampleCount)
		{
			buf.inUse = false;
			buf.readOffset = 0;
			handler->m_queuedBufferIndices.pop_front();
			handler->m_availableBufferIndices.push_back(bufIdx);
		}
	}

	// Fill remaining with silence
	if(bytesWritten < bytesNeeded)
	{
		memset(reinterpret_cast<uint8*>(outputBuffer) + bytesWritten, 0, bytesNeeded - bytesWritten);
	}

	return noErr;
}

void CSH_CoreAudio::Reset()
{
	std::lock_guard<std::mutex> lock(m_bufferMutex);
	for(int i = 0; i < MAX_BUFFERS; i++)
	{
		m_buffers[i].inUse = false;
		m_buffers[i].readOffset = 0;
	}
	m_availableBufferIndices.clear();
	m_queuedBufferIndices.clear();
	for(int i = 0; i < MAX_BUFFERS; i++)
	{
		m_availableBufferIndices.push_back(i);
	}
}

void CSH_CoreAudio::RecycleBuffers()
{
	// Buffer recycling happens in the render callback
}

bool CSH_CoreAudio::HasFreeBuffers()
{
	std::lock_guard<std::mutex> lock(m_bufferMutex);
	return !m_availableBufferIndices.empty();
}

void CSH_CoreAudio::Write(int16* samples, unsigned int sampleCount, unsigned int sampleRate)
{
	std::lock_guard<std::mutex> lock(m_bufferMutex);
	if(m_availableBufferIndices.empty()) return;

	int bufIdx = m_availableBufferIndices.front();
	m_availableBufferIndices.pop_front();

	auto& buf = m_buffers[bufIdx];
	uint32 copyCount = std::min(static_cast<uint32>(sampleCount), static_cast<uint32>(BUFFER_SAMPLES * 2));
	memcpy(buf.data, samples, copyCount * sizeof(int16));
	buf.sampleCount = copyCount;
	buf.sampleRate = sampleRate;
	buf.readOffset = 0;
	buf.inUse = true;

	m_queuedBufferIndices.push_back(bufIdx);
}
