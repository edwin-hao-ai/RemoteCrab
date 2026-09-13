//
//  iBridgeMicrophone.c
//  A minimal CoreAudio HAL AudioServerPlugIn that exposes ONE input-only
//  device ("iBridge Microphone") whose samples are read from the shared
//  ring fed by the iBridge Mac app.
//
//  Based on the canonical Apple AudioServerPlugIn object model
//  (driver → device → stream). Deliberately tiny: no output, no volume,
//  no sample-rate conversion — just a 48 kHz / 1 ch / Float32 input.
//
//  The render path (DoIOOperation) NEVER allocates or locks: it copies
//  from the pre-mapped ring and converts Int16 → Float32.
//

#include <CoreAudio/AudioServerPlugIn.h>
#include <CoreFoundation/CoreFoundation.h>
#include <CoreFoundation/CFPlugIn.h>
#include <CoreFoundation/CFUUID.h>
#include <stdlib.h>
#include <string.h>
#include <mach/mach_time.h>

#include "SharedRing.h"

// MARK: - Object IDs

enum {
    kObjectID_PlugIn = kAudioObjectPlugInObject, // = 1
    kObjectID_Device = 2,
    kObjectID_Stream_Input = 3,
};

// MARK: - Fixed format

#define kIB_SampleRate 48000.0
#define kIB_Channels 1

static const AudioStreamBasicDescription kIBStreamFormat = {
    .mSampleRate = kIB_SampleRate,
    .mFormatID = kAudioFormatLinearPCM,
    .mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | kAudioFormatFlagIsNonInterleaved,
    .mBytesPerPacket = 4,
    .mFramesPerPacket = 1,
    .mBytesPerFrame = 4,
    .mChannelsPerFrame = kIB_Channels,
    .mBitsPerChannel = 32,
    .mReserved = 0,
};

// MARK: - Driver object

typedef struct {
    AudioServerPlugInDriverInterface mInterface; // MUST be first
    AudioServerPlugInDriverInterface *mInterfacePointer;
    UInt32 mRefCount;
    AudioObjectID mDeviceObjectID;
    IBRing *mRing;
    int16_t *mScratch;      // preallocated render scratch (frames)
    int64_t mScratchFrames;
    UInt64 mIOCount;
    UInt64 mHostTicksPerFrame;
    UInt64 mAnchorHostTime;
    Boolean mRunning;
} iBridgeDriver;

static HRESULT iBridge_QueryInterface(void *inDriver, REFIID inUUID, LPVOID *outInterface);
static ULONG iBridge_AddRef(void *inDriver);
static ULONG iBridge_Release(void *inDriver);
static OSStatus iBridge_Initialize(AudioServerPlugInDriverRef inDriver, AudioServerPlugInHostRef inHost);
static OSStatus iBridge_CreateDevice(AudioServerPlugInDriverRef inDriver, CFDictionaryRef inDescription, const AudioServerPlugInClientInfo *inClientInfo, AudioObjectID *outDeviceObjectID);
static OSStatus iBridge_DestroyDevice(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID);
static OSStatus iBridge_AddDeviceClient(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, const AudioServerPlugInClientInfo *inClientInfo);
static OSStatus iBridge_RemoveDeviceClient(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, const AudioServerPlugInClientInfo *inClientInfo);
static OSStatus iBridge_PerformDeviceConfigurationChange(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt64 inChangeAction, void *inChangeInfo);
static OSStatus iBridge_AbortDeviceConfigurationChange(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt64 inChangeAction, void *inChangeInfo);
static Boolean iBridge_HasProperty(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress *inAddress);
static OSStatus iBridge_IsPropertySettable(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress *inAddress, Boolean *outIsSettable);
static OSStatus iBridge_GetPropertyDataSize(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress *inAddress, UInt32 inQualifierDataSize, const void *inQualifierData, UInt32 *outDataSize);
static OSStatus iBridge_GetPropertyData(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress *inAddress, UInt32 inQualifierDataSize, const void *inQualifierData, UInt32 inDataSize, UInt32 *outDataSize, void *outData);
static OSStatus iBridge_SetPropertyData(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress *inAddress, UInt32 inQualifierDataSize, const void *inQualifierData, UInt32 inDataSize, const void *inData);
static OSStatus iBridge_StartIO(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID);
static OSStatus iBridge_StopIO(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID);
static OSStatus iBridge_GetZeroTimeStamp(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID, Float64 *outSampleTime, UInt64 *outHostTime, UInt64 *outSeed);
static OSStatus iBridge_WillDoIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID, UInt32 inOperationID, Boolean *outWillDo, Boolean *outWillDoInPlace);
static OSStatus iBridge_BeginIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID, UInt32 inOperationID, UInt32 inIOBufferFrameSize, const AudioServerPlugInIOCycleInfo *inIOCycleInfo);
static OSStatus iBridge_DoIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, AudioObjectID inStreamObjectID, UInt32 inClientID, UInt32 inOperationID, UInt32 inIOBufferFrameSize, const AudioServerPlugInIOCycleInfo *inIOCycleInfo, void *ioMainBuffer, void *ioSecondaryBuffer);
static OSStatus iBridge_EndIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID, UInt32 inOperationID, UInt32 inIOBufferFrameSize, const AudioServerPlugInIOCycleInfo *inIOCycleInfo);

static AudioServerPlugInDriverInterface gInterface = {
    NULL,
    iBridge_QueryInterface,
    iBridge_AddRef,
    iBridge_Release,
    iBridge_Initialize,
    iBridge_CreateDevice,
    iBridge_DestroyDevice,
    iBridge_AddDeviceClient,
    iBridge_RemoveDeviceClient,
    iBridge_PerformDeviceConfigurationChange,
    iBridge_AbortDeviceConfigurationChange,
    iBridge_HasProperty,
    iBridge_IsPropertySettable,
    iBridge_GetPropertyDataSize,
    iBridge_GetPropertyData,
    iBridge_SetPropertyData,
    iBridge_StartIO,
    iBridge_StopIO,
    iBridge_GetZeroTimeStamp,
    iBridge_WillDoIOOperation,
    iBridge_BeginIOOperation,
    iBridge_DoIOOperation,
    iBridge_EndIOOperation,
};

// MARK: - Entry point

__attribute__((visibility("default")))
void *iBridgeMicrophone_Create(CFAllocatorRef inAllocator, CFUUIDRef inRequestedTypeUUID) {
    (void)inAllocator; (void)inRequestedTypeUUID;
    iBridgeDriver *driver = (iBridgeDriver *)calloc(1, sizeof(iBridgeDriver));
    if (!driver) return NULL;
    driver->mInterface = gInterface;
    driver->mInterfacePointer = &driver->mInterface;
    driver->mRefCount = 1;
    // Preallocate render scratch for the largest plausible IO size.
    driver->mScratchFrames = 8192;
    driver->mScratch = (int16_t *)calloc((size_t)driver->mScratchFrames, sizeof(int16_t));
    driver->mRing = IBRingOpen();
    mach_timebase_info_data_t tb;
    mach_timebase_info(&tb);
    double hostPerFrame = ((double)NSEC_PER_SEC / kIB_SampleRate) * (double)tb.denom / (double)tb.numer;
    driver->mHostTicksPerFrame = (UInt64)hostPerFrame;
    return driver;
}

// MARK: - COM-ish

static HRESULT iBridge_QueryInterface(void *inDriver, REFIID inUUID, LPVOID *outInterface) {
    (void)inUUID;
    // Only one interface is ever requested by the host; hand it back.
    *outInterface = &((iBridgeDriver *)inDriver)->mInterface;
    return S_OK;
}
static ULONG iBridge_AddRef(void *inDriver) {
    iBridgeDriver *driver = (iBridgeDriver *)inDriver;
    return (ULONG)__sync_add_and_fetch(&driver->mRefCount, 1);
}
static ULONG iBridge_Release(void *inDriver) {
    iBridgeDriver *driver = (iBridgeDriver *)inDriver;
    ULONG count = (ULONG)__sync_sub_and_fetch(&driver->mRefCount, 1);
    if (count == 0) {
        free(driver->mScratch);
        free(driver);
    }
    return count;
}

// MARK: - Lifecycle

static OSStatus iBridge_Initialize(AudioServerPlugInDriverRef inDriver, AudioServerPlugInHostRef inHost) {
    (void)inDriver; (void)inHost;
    return kAudioHardwareNoError;
}

static OSStatus iBridge_CreateDevice(AudioServerPlugInDriverRef inDriver, CFDictionaryRef inDescription,
                                     const AudioServerPlugInClientInfo *inClientInfo, AudioObjectID *outDeviceObjectID) {
    (void)inDescription; (void)inClientInfo;
    iBridgeDriver *driver = (iBridgeDriver *)inDriver;
    driver->mDeviceObjectID = kObjectID_Device;
    *outDeviceObjectID = kObjectID_Device;
    return kAudioHardwareNoError;
}
static OSStatus iBridge_DestroyDevice(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID) {
    (void)inDriver; (void)inDeviceObjectID;
    return kAudioHardwareNoError;
}
static OSStatus iBridge_AddDeviceClient(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, const AudioServerPlugInClientInfo *inClientInfo) {
    (void)inDriver; (void)inDeviceObjectID; (void)inClientInfo;
    return kAudioHardwareNoError;
}
static OSStatus iBridge_RemoveDeviceClient(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, const AudioServerPlugInClientInfo *inClientInfo) {
    (void)inDriver; (void)inDeviceObjectID; (void)inClientInfo;
    return kAudioHardwareNoError;
}
static OSStatus iBridge_PerformDeviceConfigurationChange(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt64 inChangeAction, void *inChangeInfo) {
    (void)inDriver; (void)inDeviceObjectID; (void)inChangeAction; (void)inChangeInfo;
    return kAudioHardwareNoError;
}
static OSStatus iBridge_AbortDeviceConfigurationChange(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt64 inChangeAction, void *inChangeInfo) {
    (void)inDriver; (void)inDeviceObjectID; (void)inChangeAction; (void)inChangeInfo;
    return kAudioHardwareNoError;
}

// MARK: - Properties

static Boolean hasAddress(AudioObjectID objectID, const AudioObjectPropertyAddress *addr) {
    switch (objectID) {
        case kObjectID_PlugIn:
            return addr->mSelector == kAudioObjectPropertyManufacturer ||
                   addr->mSelector == kAudioObjectPropertyOwnedObjects ||
                   addr->mSelector == kAudioPlugInPropertyBundleID ||
                   addr->mSelector == kAudioObjectPropertyCustomPropertyInfoList;
        case kObjectID_Device:
            return addr->mSelector == kAudioObjectPropertyName ||
                   addr->mSelector == kAudioObjectPropertyManufacturer ||
                   addr->mSelector == kAudioObjectPropertyOwnedObjects ||
                   addr->mSelector == kAudioObjectPropertyControlList ||
                   addr->mSelector == kAudioObjectPropertyCustomPropertyInfoList ||
                   addr->mSelector == kAudioDevicePropertyDeviceUID ||
                   addr->mSelector == kAudioDevicePropertyModelUID ||
                   addr->mSelector == kAudioDevicePropertyTransportType ||
                   addr->mSelector == kAudioDevicePropertyRelatedDevices ||
                   addr->mSelector == kAudioDevicePropertyClockDomain ||
                   addr->mSelector == kAudioDevicePropertyDeviceIsAlive ||
                   addr->mSelector == kAudioDevicePropertyDeviceIsRunning ||
                   addr->mSelector == kAudioDevicePropertyDeviceCanBeDefaultDevice ||
                   addr->mSelector == kAudioDevicePropertyDeviceCanBeDefaultSystemDevice ||
                   addr->mSelector == kAudioDevicePropertyLatency ||
                   addr->mSelector == kAudioDevicePropertyStreams ||
                   addr->mSelector == kAudioObjectPropertyControlList ||
                   addr->mSelector == kAudioDevicePropertySafetyOffset ||
                   addr->mSelector == kAudioDevicePropertyNominalSampleRate ||
                   addr->mSelector == kAudioDevicePropertyAvailableNominalSampleRates ||
                   addr->mSelector == kAudioDevicePropertyIcon ||
                   addr->mSelector == kAudioDevicePropertyIsHidden ||
                   addr->mSelector == kAudioDevicePropertyPreferredChannelsForStereo ||
                   addr->mSelector == kAudioDevicePropertyPreferredChannelLayout;
        case kObjectID_Stream_Input:
            return addr->mSelector == kAudioObjectPropertyName ||
                   addr->mSelector == kAudioObjectPropertyOwnedObjects ||
                   addr->mSelector == kAudioStreamPropertyIsActive ||
                   addr->mSelector == kAudioStreamPropertyDirection ||
                   addr->mSelector == kAudioStreamPropertyTerminalType ||
                   addr->mSelector == kAudioStreamPropertyStartingChannel ||
                   addr->mSelector == kAudioStreamPropertyLatency ||
                   addr->mSelector == kAudioStreamPropertyVirtualFormat ||
                   addr->mSelector == kAudioStreamPropertyAvailableVirtualFormats ||
                   addr->mSelector == kAudioStreamPropertyPhysicalFormat ||
                   addr->mSelector == kAudioStreamPropertyAvailablePhysicalFormats;
        default:
            return false;
    }
}

static Boolean iBridge_HasProperty(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress *inAddress) {
    (void)inDriver; (void)inClientProcessID;
    return hasAddress(inObjectID, inAddress);
}

static OSStatus iBridge_IsPropertySettable(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress *inAddress, Boolean *outIsSettable) {
    (void)inDriver; (void)inObjectID; (void)inClientProcessID; (void)inAddress;
    *outIsSettable = false;
    return kAudioHardwareNoError;
}

static UInt32 propSize(AudioObjectID objectID, const AudioObjectPropertyAddress *addr) {
    switch (addr->mSelector) {
        case kAudioObjectPropertyName:
        case kAudioObjectPropertyManufacturer:
        case kAudioDevicePropertyDeviceUID:
        case kAudioDevicePropertyModelUID:
            return sizeof(CFStringRef);
        case kAudioObjectPropertyOwnedObjects:
            return objectID == kObjectID_Device ? sizeof(AudioObjectID) : (objectID == kObjectID_PlugIn ? sizeof(AudioObjectID) : 0);
        case kAudioPlugInPropertyBundleID:
            return sizeof(CFStringRef);
        case kAudioDevicePropertyStreams:
            return sizeof(AudioObjectID);
        case kAudioDevicePropertyTransportType:
        case kAudioDevicePropertyClockDomain:
        case kAudioDevicePropertyDeviceIsAlive:
        case kAudioDevicePropertyDeviceIsRunning:
        case kAudioDevicePropertyDeviceCanBeDefaultDevice:
        case kAudioDevicePropertyDeviceCanBeDefaultSystemDevice:
        case kAudioDevicePropertyLatency: // == kAudioStreamPropertyLatency
        case kAudioDevicePropertySafetyOffset:
        case kAudioDevicePropertyIsHidden:
        case kAudioStreamPropertyIsActive:
        case kAudioStreamPropertyDirection:
        case kAudioStreamPropertyTerminalType:
        case kAudioStreamPropertyStartingChannel:
            return sizeof(UInt32);
        case kAudioDevicePropertyNominalSampleRate:
            return sizeof(Float64);
        case kAudioDevicePropertyAvailableNominalSampleRates:
            return sizeof(AudioValueRange);
        case kAudioDevicePropertyPreferredChannelLayout:
            return sizeof(AudioChannelLayout) + (sizeof(AudioChannelDescription) * kIB_Channels);
        case kAudioDevicePropertyPreferredChannelsForStereo:
            return sizeof(UInt32) * 2;
        case kAudioStreamPropertyVirtualFormat:
        case kAudioStreamPropertyPhysicalFormat:
            return sizeof(AudioStreamBasicDescription);
        case kAudioStreamPropertyAvailableVirtualFormats:
        case kAudioStreamPropertyAvailablePhysicalFormats:
            return sizeof(AudioStreamRangedDescription);
        case kAudioObjectPropertyControlList:
            return 0;
        default:
            return 0;
    }
}

static OSStatus fillProp(AudioObjectID objectID, const AudioObjectPropertyAddress *addr, UInt32 inDataSize, UInt32 *outDataSize, void *outData) {
    #define PUT(T, V) do { if (inDataSize < sizeof(T)) return kAudioHardwareBadPropertySizeError; *(T *)outData = (V); *outDataSize = sizeof(T); } while (0)
    CFStringRef s;
    switch (addr->mSelector) {
        case kAudioObjectPropertyName:
            s = objectID == kObjectID_Stream_Input ? CFSTR("iBridge Microphone Input") : CFSTR("iBridge Microphone");
            PUT(CFStringRef, s); return kAudioHardwareNoError;
        case kAudioObjectPropertyManufacturer:
            s = CFSTR("iBridge");
            PUT(CFStringRef, s); return kAudioHardwareNoError;
        case kAudioPlugInPropertyBundleID:
            s = CFSTR("com.ibridge.iBridgeMicrophone");
            PUT(CFStringRef, s); return kAudioHardwareNoError;
        case kAudioDevicePropertyDeviceUID:
            s = CFSTR("com.ibridge.iBridgeMicrophone.device");
            PUT(CFStringRef, s); return kAudioHardwareNoError;
        case kAudioDevicePropertyModelUID:
            s = CFSTR("com.ibridge.iBridgeMicrophone.model");
            PUT(CFStringRef, s); return kAudioHardwareNoError;
        case kAudioObjectPropertyOwnedObjects:
            if (objectID == kObjectID_PlugIn) { AudioObjectID v = kObjectID_Device; PUT(AudioObjectID, v); return kAudioHardwareNoError; }
            if (objectID == kObjectID_Device) { AudioObjectID v = kObjectID_Stream_Input; PUT(AudioObjectID, v); return kAudioHardwareNoError; }
            *outDataSize = 0; return kAudioHardwareNoError;
        case kAudioDevicePropertyStreams: { AudioObjectID v = kObjectID_Stream_Input; PUT(AudioObjectID, v); return kAudioHardwareNoError; }
        case kAudioObjectPropertyControlList: *outDataSize = 0; return kAudioHardwareNoError;
        case kAudioDevicePropertyTransportType: { UInt32 v = kAudioDeviceTransportTypeVirtual; PUT(UInt32, v); return kAudioHardwareNoError; }
        case kAudioDevicePropertyClockDomain: { UInt32 v = 0; PUT(UInt32, v); return kAudioHardwareNoError; }
        case kAudioDevicePropertyDeviceIsAlive: { UInt32 v = 1; PUT(UInt32, v); return kAudioHardwareNoError; }
        case kAudioDevicePropertyDeviceIsRunning: { UInt32 v = 0; PUT(UInt32, v); return kAudioHardwareNoError; }
        case kAudioDevicePropertyDeviceCanBeDefaultDevice:
        case kAudioDevicePropertyDeviceCanBeDefaultSystemDevice: { UInt32 v = 1; PUT(UInt32, v); return kAudioHardwareNoError; }
        case kAudioDevicePropertyLatency: // == kAudioStreamPropertyLatency
        case kAudioDevicePropertySafetyOffset: { UInt32 v = 0; PUT(UInt32, v); return kAudioHardwareNoError; }
        case kAudioDevicePropertyIsHidden: { UInt32 v = 0; PUT(UInt32, v); return kAudioHardwareNoError; }
        case kAudioDevicePropertyNominalSampleRate: { Float64 v = kIB_SampleRate; PUT(Float64, v); return kAudioHardwareNoError; }
        case kAudioDevicePropertyAvailableNominalSampleRates: {
            AudioValueRange r = { kIB_SampleRate, kIB_SampleRate }; PUT(AudioValueRange, r); return kAudioHardwareNoError; }
        case kAudioStreamPropertyIsActive: { UInt32 v = 1; PUT(UInt32, v); return kAudioHardwareNoError; }
        case kAudioStreamPropertyDirection: { UInt32 v = 1; PUT(UInt32, v); return kAudioHardwareNoError; } // 1 = input
        case kAudioStreamPropertyTerminalType: { UInt32 v = kAudioStreamTerminalTypeMicrophone; PUT(UInt32, v); return kAudioHardwareNoError; }
        case kAudioStreamPropertyStartingChannel: { UInt32 v = 1; PUT(UInt32, v); return kAudioHardwareNoError; }
        case kAudioStreamPropertyVirtualFormat:
        case kAudioStreamPropertyPhysicalFormat: { AudioStreamBasicDescription v = kIBStreamFormat; PUT(AudioStreamBasicDescription, v); return kAudioHardwareNoError; }
        case kAudioStreamPropertyAvailableVirtualFormats:
        case kAudioStreamPropertyAvailablePhysicalFormats: {
            AudioStreamRangedDescription d; d.mFormat = kIBStreamFormat;
            d.mSampleRateRange.mMinimum = kIB_SampleRate; d.mSampleRateRange.mMaximum = kIB_SampleRate;
            PUT(AudioStreamRangedDescription, d); return kAudioHardwareNoError; }
        case kAudioDevicePropertyPreferredChannelsForStereo: { UInt32 v[2] = {1,1}; if (inDataSize < sizeof(v)) return kAudioHardwareBadPropertySizeError; memcpy(outData, v, sizeof v); *outDataSize = sizeof v; return kAudioHardwareNoError; }
        default: return kAudioHardwareUnknownPropertyError;
    }
    #undef PUT
}

static OSStatus iBridge_GetPropertyDataSize(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress *inAddress, UInt32 inQualifierDataSize, const void *inQualifierData, UInt32 *outDataSize) {
    (void)inDriver; (void)inClientProcessID; (void)inQualifierDataSize; (void)inQualifierData;
    if (!hasAddress(inObjectID, inAddress)) return kAudioHardwareUnknownPropertyError;
    *outDataSize = propSize(inObjectID, inAddress);
    return kAudioHardwareNoError;
}

static OSStatus iBridge_GetPropertyData(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress *inAddress, UInt32 inQualifierDataSize, const void *inQualifierData, UInt32 inDataSize, UInt32 *outDataSize, void *outData) {
    (void)inDriver; (void)inClientProcessID; (void)inQualifierDataSize; (void)inQualifierData;
    if (!hasAddress(inObjectID, inAddress)) return kAudioHardwareUnknownPropertyError;
    return fillProp(inObjectID, inAddress, inDataSize, outDataSize, outData);
}

static OSStatus iBridge_SetPropertyData(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress *inAddress, UInt32 inQualifierDataSize, const void *inQualifierData, UInt32 inDataSize, const void *inData) {
    (void)inDriver; (void)inObjectID; (void)inClientProcessID; (void)inAddress; (void)inQualifierDataSize; (void)inQualifierData; (void)inDataSize; (void)inData;
    return kAudioHardwareUnknownPropertyError;
}

// MARK: - IO

static OSStatus iBridge_StartIO(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID) {
    (void)inDeviceObjectID; (void)inClientID;
    iBridgeDriver *driver = (iBridgeDriver *)inDriver;
    driver->mRunning = true;
    driver->mIOCount = 0;
    driver->mAnchorHostTime = mach_absolute_time();
    return kAudioHardwareNoError;
}
static OSStatus iBridge_StopIO(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID) {
    (void)inDeviceObjectID; (void)inClientID;
    ((iBridgeDriver *)inDriver)->mRunning = false;
    return kAudioHardwareNoError;
}
static OSStatus iBridge_GetZeroTimeStamp(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID, Float64 *outSampleTime, UInt64 *outHostTime, UInt64 *outSeed) {
    (void)inDeviceObjectID; (void)inClientID;
    iBridgeDriver *driver = (iBridgeDriver *)inDriver;
    *outSampleTime = (Float64)driver->mIOCount * 0; // filled by host cycle info
    UInt64 now = mach_absolute_time();
    UInt64 delta = now - driver->mAnchorHostTime;
    UInt64 frames = driver->mHostTicksPerFrame ? delta / driver->mHostTicksPerFrame : 0;
    *outSampleTime = (Float64)frames;
    *outHostTime = driver->mAnchorHostTime + frames * driver->mHostTicksPerFrame;
    *outSeed = 1;
    return kAudioHardwareNoError;
}
static OSStatus iBridge_WillDoIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID, UInt32 inOperationID, Boolean *outWillDo, Boolean *outWillDoInPlace) {
    (void)inDriver; (void)inDeviceObjectID; (void)inClientID;
    *outWillDo = (inOperationID == kAudioServerPlugInIOOperationReadInput);
    *outWillDoInPlace = true;
    return kAudioHardwareNoError;
}
static OSStatus iBridge_BeginIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID, UInt32 inOperationID, UInt32 inIOBufferFrameSize, const AudioServerPlugInIOCycleInfo *inIOCycleInfo) {
    (void)inDriver; (void)inDeviceObjectID; (void)inClientID; (void)inOperationID; (void)inIOBufferFrameSize; (void)inIOCycleInfo;
    return kAudioHardwareNoError;
}
static OSStatus iBridge_DoIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, AudioObjectID inStreamObjectID, UInt32 inClientID, UInt32 inOperationID, UInt32 inIOBufferFrameSize, const AudioServerPlugInIOCycleInfo *inIOCycleInfo, void *ioMainBuffer, void *ioSecondaryBuffer) {
    (void)inDeviceObjectID; (void)inStreamObjectID; (void)inClientID; (void)inIOCycleInfo; (void)ioSecondaryBuffer;
    if (inOperationID != kAudioServerPlugInIOOperationReadInput || !ioMainBuffer) return kAudioHardwareNoError;

    iBridgeDriver *driver = (iBridgeDriver *)inDriver;
    Float32 *out = (Float32 *)ioMainBuffer;
    UInt32 frames = inIOBufferFrameSize;

    if (!driver->mRing || frames > driver->mScratchFrames) {
        memset(out, 0, frames * sizeof(Float32));
        return kAudioHardwareNoError;
    }
    IBRingRead(driver->mRing, driver->mScratch, frames);
    for (UInt32 i = 0; i < frames; i++) {
        out[i] = (Float32)driver->mScratch[i] / 32768.0f;
    }
    driver->mIOCount += frames;
    return kAudioHardwareNoError;
}
static OSStatus iBridge_EndIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID, UInt32 inOperationID, UInt32 inIOBufferFrameSize, const AudioServerPlugInIOCycleInfo *inIOCycleInfo) {
    (void)inDriver; (void)inDeviceObjectID; (void)inClientID; (void)inOperationID; (void)inIOBufferFrameSize; (void)inIOCycleInfo;
    return kAudioHardwareNoError;
}
