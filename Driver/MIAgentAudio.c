/*
 * MIAgentAudio.c
 *
 * Core Audio server plug-in (HAL virtual audio driver) for MIAgent.
 *
 * Four devices in two loopback pairs. The devices meeting apps should use
 * are one-directional and visible; each has a HIDDEN companion device
 * (kAudioDevicePropertyIsHidden) that MIAgent uses for its side of the
 * loopback, so pickers in Zoom/Teams only ever show the right direction:
 *
 *   Pair A — meeting speaker path:
 *     "Interpreter Line Output"  visible, OUTPUT-only  (Zoom speaker)
 *     "MIAgent Line Output Tap"  hidden,  INPUT-only   (app captures meeting)
 *
 *   Pair B — meeting microphone path:
 *     "Interpreter Line Input"   visible, INPUT-only   (Zoom microphone)
 *     "MIAgent Line In Feed"     hidden,  OUTPUT-only  (app plays translation)
 *
 * Each pair shares a ring buffer and a clock (common anchor + timestamp
 * sequence), so writer and reader sample times line up exactly as they did
 * when both streams lived on one device.
 *
 * Build: clang -bundle -framework CoreAudio -framework CoreFoundation
 */

#include <CoreAudio/AudioServerPlugIn.h>
#include <CoreFoundation/CoreFoundation.h>
#include <mach/mach_time.h>
#include <pthread.h>
#include <stdint.h>
#include <string.h>

// =============================================================================
// Object IDs
// =============================================================================

enum {
    kObjectID_PlugIn             = kAudioObjectPlugInObject, // 1
    kObjectID_Device_LineOut     = 2,   // visible, output-only
    kObjectID_Stream_LineOut     = 3,
    kObjectID_Device_LineOutTap  = 4,   // hidden, input-only
    kObjectID_Stream_LineOutTap  = 5,
    kObjectID_Device_LineIn      = 6,   // visible, input-only
    kObjectID_Stream_LineIn      = 7,
    kObjectID_Device_LineInFeed  = 8,   // hidden, output-only
    kObjectID_Stream_LineInFeed  = 9,
};

#define kNumDevices         4
#define kChannels           2
#define kRingFrames         16384       // also the zero-timestamp period
#define kBitsPerChannel     32
#define kBytesPerFrame      (kChannels * (kBitsPerChannel / 8))

static const Float64 kSupportedSampleRates[] = { 44100.0, 48000.0 };
#define kNumSupportedSampleRates (sizeof(kSupportedSampleRates)/sizeof(Float64))

// =============================================================================
// State
// =============================================================================

// Shared per-pair: ring buffer + clock, so both devices of a pair see the
// same sample timeline.
typedef struct {
    Float64  sampleRate;
    UInt64   anchorHostTime;
    UInt64   numberTimeStamps;
    Float64  hostTicksPerFrame;
    UInt32   runningCount;      // devices of this pair with active IO
    Float32* ring;
    pthread_mutex_t mutex;      // guards ring + clock fields
} MIAPair;

typedef struct {
    AudioObjectID deviceID;
    AudioObjectID streamID;
    bool          isInput;      // direction of the single stream
    bool          isHidden;
    CFStringRef   name;
    CFStringRef   uid;
    CFStringRef   modelUID;
    UInt64        ioRunning;    // per-device StartIO refcount
    bool          streamActive;
    MIAPair*      pair;
} MIADevice;

static Float32 gRingA[kRingFrames * kChannels];
static Float32 gRingB[kRingFrames * kChannels];

static MIAPair gPairA = {
    .sampleRate = 48000.0,
    .ring = gRingA,
    .mutex = PTHREAD_MUTEX_INITIALIZER,
};
static MIAPair gPairB = {
    .sampleRate = 48000.0,
    .ring = gRingB,
    .mutex = PTHREAD_MUTEX_INITIALIZER,
};

static MIADevice gDevices[kNumDevices] = {
    {
        .deviceID = kObjectID_Device_LineOut,
        .streamID = kObjectID_Stream_LineOut,
        .isInput = false,
        .isHidden = false,
        .streamActive = true,
        .pair = &gPairA,
    },
    {
        .deviceID = kObjectID_Device_LineOutTap,
        .streamID = kObjectID_Stream_LineOutTap,
        .isInput = true,
        .isHidden = true,
        .streamActive = true,
        .pair = &gPairA,
    },
    {
        .deviceID = kObjectID_Device_LineIn,
        .streamID = kObjectID_Stream_LineIn,
        .isInput = true,
        .isHidden = false,
        .streamActive = true,
        .pair = &gPairB,
    },
    {
        .deviceID = kObjectID_Device_LineInFeed,
        .streamID = kObjectID_Stream_LineInFeed,
        .isInput = false,
        .isHidden = true,
        .streamActive = true,
        .pair = &gPairB,
    },
};

static pthread_mutex_t gStateMutex = PTHREAD_MUTEX_INITIALIZER;
static AudioServerPlugInHostRef gPlugInHost = NULL;
static UInt32 gPlugInRefCount = 0;

// =============================================================================
// Helpers
// =============================================================================

static MIADevice* DeviceForID(AudioObjectID objectID)
{
    for (int i = 0; i < kNumDevices; i++) {
        if (gDevices[i].deviceID == objectID) return &gDevices[i];
    }
    return NULL;
}

static MIADevice* DeviceForStreamID(AudioObjectID objectID)
{
    for (int i = 0; i < kNumDevices; i++) {
        if (gDevices[i].streamID == objectID) return &gDevices[i];
    }
    return NULL;
}

static void FillASBD(AudioStreamBasicDescription* asbd, Float64 sampleRate)
{
    memset(asbd, 0, sizeof(*asbd));
    asbd->mSampleRate       = sampleRate;
    asbd->mFormatID         = kAudioFormatLinearPCM;
    asbd->mFormatFlags      = kAudioFormatFlagIsFloat | kAudioFormatFlagsNativeEndian | kAudioFormatFlagIsPacked;
    asbd->mBytesPerPacket   = kBytesPerFrame;
    asbd->mFramesPerPacket  = 1;
    asbd->mBytesPerFrame    = kBytesPerFrame;
    asbd->mChannelsPerFrame = kChannels;
    asbd->mBitsPerChannel   = kBitsPerChannel;
}

static void RecomputeHostTicksPerFrame(MIAPair* pair)
{
    struct mach_timebase_info tb;
    mach_timebase_info(&tb);
    Float64 ticksPerSecond = ((Float64)tb.denom / (Float64)tb.numer) * 1000000000.0;
    pair->hostTicksPerFrame = ticksPerSecond / pair->sampleRate;
}

// =============================================================================
// COM plumbing
// =============================================================================

static AudioServerPlugInDriverInterface gDriverInterface;
static AudioServerPlugInDriverInterface* gDriverInterfacePtr = &gDriverInterface;
static AudioServerPlugInDriverRef gDriverRef = &gDriverInterfacePtr;

static HRESULT MIA_QueryInterface(void* inDriver, REFIID inUUID, LPVOID* outInterface)
{
    if (outInterface == NULL) return E_POINTER;
    if (inDriver != gDriverRef) return E_POINTER;
    CFUUIDRef requested = CFUUIDCreateFromUUIDBytes(NULL, inUUID);
    HRESULT result = E_NOINTERFACE;
    if (CFEqual(requested, IUnknownUUID) || CFEqual(requested, kAudioServerPlugInDriverInterfaceUUID)) {
        pthread_mutex_lock(&gStateMutex);
        gPlugInRefCount++;
        pthread_mutex_unlock(&gStateMutex);
        *outInterface = gDriverRef;
        result = S_OK;
    }
    CFRelease(requested);
    return result;
}

static ULONG MIA_AddRef(void* inDriver)
{
    if (inDriver != gDriverRef) return 0;
    pthread_mutex_lock(&gStateMutex);
    if (gPlugInRefCount < UINT32_MAX) gPlugInRefCount++;
    ULONG result = gPlugInRefCount;
    pthread_mutex_unlock(&gStateMutex);
    return result;
}

static ULONG MIA_Release(void* inDriver)
{
    if (inDriver != gDriverRef) return 0;
    pthread_mutex_lock(&gStateMutex);
    if (gPlugInRefCount > 0) gPlugInRefCount--;
    ULONG result = gPlugInRefCount;
    pthread_mutex_unlock(&gStateMutex);
    return result;
}

static OSStatus MIA_Initialize(AudioServerPlugInDriverRef inDriver, AudioServerPlugInHostRef inHost)
{
    if (inDriver != gDriverRef) return kAudioHardwareBadObjectError;
    gPlugInHost = inHost;

    gDevices[0].name     = CFSTR("Interpreter Line Output");
    gDevices[0].uid      = CFSTR("MIAgent:InterpreterLineOut");
    gDevices[0].modelUID = CFSTR("MIAgent:InterpreterLineOutModel");

    gDevices[1].name     = CFSTR("MIAgent Line Output Tap");
    gDevices[1].uid      = CFSTR("MIAgent:InterpreterLineOutTap");
    gDevices[1].modelUID = CFSTR("MIAgent:InterpreterLineOutTapModel");

    gDevices[2].name     = CFSTR("Interpreter Line Input");
    gDevices[2].uid      = CFSTR("MIAgent:InterpreterLineIn");
    gDevices[2].modelUID = CFSTR("MIAgent:InterpreterLineInModel");

    gDevices[3].name     = CFSTR("MIAgent Line In Feed");
    gDevices[3].uid      = CFSTR("MIAgent:InterpreterLineInFeed");
    gDevices[3].modelUID = CFSTR("MIAgent:InterpreterLineInFeedModel");

    RecomputeHostTicksPerFrame(&gPairA);
    RecomputeHostTicksPerFrame(&gPairB);
    return 0;
}

static OSStatus MIA_CreateDevice(AudioServerPlugInDriverRef inDriver,
                                 CFDictionaryRef inDescription,
                                 const AudioServerPlugInClientInfo* inClientInfo,
                                 AudioObjectID* outDeviceObjectID)
{
    (void)inDriver; (void)inDescription; (void)inClientInfo; (void)outDeviceObjectID;
    return kAudioHardwareUnsupportedOperationError;
}

static OSStatus MIA_DestroyDevice(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID)
{
    (void)inDriver; (void)inDeviceObjectID;
    return kAudioHardwareUnsupportedOperationError;
}

static OSStatus MIA_AddDeviceClient(AudioServerPlugInDriverRef inDriver,
                                    AudioObjectID inDeviceObjectID,
                                    const AudioServerPlugInClientInfo* inClientInfo)
{
    (void)inDriver; (void)inDeviceObjectID; (void)inClientInfo;
    return 0;
}

static OSStatus MIA_RemoveDeviceClient(AudioServerPlugInDriverRef inDriver,
                                       AudioObjectID inDeviceObjectID,
                                       const AudioServerPlugInClientInfo* inClientInfo)
{
    (void)inDriver; (void)inDeviceObjectID; (void)inClientInfo;
    return 0;
}

static OSStatus MIA_PerformDeviceConfigurationChange(AudioServerPlugInDriverRef inDriver,
                                                     AudioObjectID inDeviceObjectID,
                                                     UInt64 inChangeAction,
                                                     void* inChangeInfo)
{
    (void)inDriver; (void)inChangeInfo;
    MIADevice* dev = DeviceForID(inDeviceObjectID);
    if (dev == NULL) return kAudioHardwareBadObjectError;

    Float64 newRate = (Float64)inChangeAction;
    bool valid = false;
    for (size_t i = 0; i < kNumSupportedSampleRates; i++) {
        if (kSupportedSampleRates[i] == newRate) { valid = true; break; }
    }
    if (!valid) return kAudioHardwareBadPropertySizeError;

    pthread_mutex_lock(&dev->pair->mutex);
    dev->pair->sampleRate = newRate;
    RecomputeHostTicksPerFrame(dev->pair);
    pthread_mutex_unlock(&dev->pair->mutex);
    return 0;
}

static OSStatus MIA_AbortDeviceConfigurationChange(AudioServerPlugInDriverRef inDriver,
                                                   AudioObjectID inDeviceObjectID,
                                                   UInt64 inChangeAction,
                                                   void* inChangeInfo)
{
    (void)inDriver; (void)inDeviceObjectID; (void)inChangeAction; (void)inChangeInfo;
    return 0;
}

// =============================================================================
// Property helpers — PlugIn object
// =============================================================================

static Boolean PlugIn_HasProperty(const AudioObjectPropertyAddress* addr)
{
    switch (addr->mSelector) {
        case kAudioObjectPropertyBaseClass:
        case kAudioObjectPropertyClass:
        case kAudioObjectPropertyOwner:
        case kAudioObjectPropertyManufacturer:
        case kAudioObjectPropertyOwnedObjects:
        case kAudioPlugInPropertyDeviceList:
        case kAudioPlugInPropertyTranslateUIDToDevice:
        case kAudioPlugInPropertyResourceBundle:
            return true;
        default:
            return false;
    }
}

static OSStatus PlugIn_GetPropertyDataSize(const AudioObjectPropertyAddress* addr,
                                           UInt32 qualifierSize, const void* qualifier,
                                           UInt32* outSize)
{
    (void)qualifierSize; (void)qualifier;
    switch (addr->mSelector) {
        case kAudioObjectPropertyBaseClass:
        case kAudioObjectPropertyClass:
            *outSize = sizeof(AudioClassID); break;
        case kAudioObjectPropertyOwner:
            *outSize = sizeof(AudioObjectID); break;
        case kAudioObjectPropertyManufacturer:
            *outSize = sizeof(CFStringRef); break;
        case kAudioObjectPropertyOwnedObjects:
        case kAudioPlugInPropertyDeviceList:
            *outSize = kNumDevices * sizeof(AudioObjectID); break;
        case kAudioPlugInPropertyTranslateUIDToDevice:
            *outSize = sizeof(AudioObjectID); break;
        case kAudioPlugInPropertyResourceBundle:
            *outSize = sizeof(CFStringRef); break;
        default:
            return kAudioHardwareUnknownPropertyError;
    }
    return 0;
}

static OSStatus PlugIn_GetPropertyData(const AudioObjectPropertyAddress* addr,
                                       UInt32 qualifierSize, const void* qualifier,
                                       UInt32 inDataSize, UInt32* outDataSize, void* outData)
{
    switch (addr->mSelector) {
        case kAudioObjectPropertyBaseClass:
            if (inDataSize < sizeof(AudioClassID)) return kAudioHardwareBadPropertySizeError;
            *((AudioClassID*)outData) = kAudioObjectClassID;
            *outDataSize = sizeof(AudioClassID);
            break;
        case kAudioObjectPropertyClass:
            if (inDataSize < sizeof(AudioClassID)) return kAudioHardwareBadPropertySizeError;
            *((AudioClassID*)outData) = kAudioPlugInClassID;
            *outDataSize = sizeof(AudioClassID);
            break;
        case kAudioObjectPropertyOwner:
            if (inDataSize < sizeof(AudioObjectID)) return kAudioHardwareBadPropertySizeError;
            *((AudioObjectID*)outData) = kAudioObjectUnknown;
            *outDataSize = sizeof(AudioObjectID);
            break;
        case kAudioObjectPropertyManufacturer:
            if (inDataSize < sizeof(CFStringRef)) return kAudioHardwareBadPropertySizeError;
            *((CFStringRef*)outData) = CFSTR("Missing Corner");
            *outDataSize = sizeof(CFStringRef);
            break;
        case kAudioObjectPropertyOwnedObjects:
        case kAudioPlugInPropertyDeviceList: {
            UInt32 maxItems = inDataSize / sizeof(AudioObjectID);
            AudioObjectID* list = (AudioObjectID*)outData;
            UInt32 n = 0;
            for (int i = 0; i < kNumDevices && n < maxItems; i++) {
                list[n++] = gDevices[i].deviceID;
            }
            *outDataSize = n * sizeof(AudioObjectID);
            break;
        }
        case kAudioPlugInPropertyTranslateUIDToDevice: {
            if (inDataSize < sizeof(AudioObjectID)) return kAudioHardwareBadPropertySizeError;
            if (qualifierSize != sizeof(CFStringRef) || qualifier == NULL) return kAudioHardwareBadPropertySizeError;
            CFStringRef requestedUID = *((CFStringRef*)qualifier);
            AudioObjectID found = kAudioObjectUnknown;
            for (int i = 0; i < kNumDevices; i++) {
                if (gDevices[i].uid != NULL && CFEqual(requestedUID, gDevices[i].uid)) {
                    found = gDevices[i].deviceID;
                    break;
                }
            }
            *((AudioObjectID*)outData) = found;
            *outDataSize = sizeof(AudioObjectID);
            break;
        }
        case kAudioPlugInPropertyResourceBundle:
            if (inDataSize < sizeof(CFStringRef)) return kAudioHardwareBadPropertySizeError;
            *((CFStringRef*)outData) = CFSTR("");
            *outDataSize = sizeof(CFStringRef);
            break;
        default:
            return kAudioHardwareUnknownPropertyError;
    }
    return 0;
}

// =============================================================================
// Property helpers — Device objects
// =============================================================================

static Boolean Device_HasProperty(MIADevice* dev, const AudioObjectPropertyAddress* addr)
{
    (void)dev;
    switch (addr->mSelector) {
        case kAudioObjectPropertyBaseClass:
        case kAudioObjectPropertyClass:
        case kAudioObjectPropertyOwner:
        case kAudioObjectPropertyName:
        case kAudioObjectPropertyManufacturer:
        case kAudioObjectPropertyOwnedObjects:
        case kAudioDevicePropertyDeviceUID:
        case kAudioDevicePropertyModelUID:
        case kAudioDevicePropertyTransportType:
        case kAudioDevicePropertyRelatedDevices:
        case kAudioDevicePropertyClockDomain:
        case kAudioDevicePropertyDeviceIsAlive:
        case kAudioDevicePropertyDeviceIsRunning:
        case kAudioObjectPropertyControlList:
        case kAudioDevicePropertyNominalSampleRate:
        case kAudioDevicePropertyAvailableNominalSampleRates:
        case kAudioDevicePropertyIsHidden:
        case kAudioDevicePropertyZeroTimeStampPeriod:
        case kAudioDevicePropertyStreams:
        case kAudioDevicePropertyDeviceCanBeDefaultDevice:
        case kAudioDevicePropertyDeviceCanBeDefaultSystemDevice:
        case kAudioDevicePropertyLatency:
        case kAudioDevicePropertySafetyOffset:
        case kAudioDevicePropertyPreferredChannelsForStereo:
        case kAudioDevicePropertyPreferredChannelLayout:
            return true;
        default:
            return false;
    }
}

static Boolean Device_IsPropertySettable(MIADevice* dev, const AudioObjectPropertyAddress* addr)
{
    (void)dev;
    switch (addr->mSelector) {
        case kAudioDevicePropertyNominalSampleRate:
            return true;
        default:
            return false;
    }
}

static OSStatus Device_GetPropertyDataSize(MIADevice* dev, const AudioObjectPropertyAddress* addr,
                                           UInt32 qualifierSize, const void* qualifier, UInt32* outSize)
{
    (void)qualifierSize; (void)qualifier; (void)dev;
    switch (addr->mSelector) {
        case kAudioObjectPropertyBaseClass:
        case kAudioObjectPropertyClass:
            *outSize = sizeof(AudioClassID); break;
        case kAudioObjectPropertyOwner:
            *outSize = sizeof(AudioObjectID); break;
        case kAudioObjectPropertyName:
        case kAudioObjectPropertyManufacturer:
        case kAudioDevicePropertyDeviceUID:
        case kAudioDevicePropertyModelUID:
            *outSize = sizeof(CFStringRef); break;
        case kAudioObjectPropertyOwnedObjects:
            *outSize = sizeof(AudioObjectID); break;
        case kAudioDevicePropertyTransportType:
        case kAudioDevicePropertyClockDomain:
        case kAudioDevicePropertyDeviceIsAlive:
        case kAudioDevicePropertyDeviceIsRunning:
        case kAudioDevicePropertyIsHidden:
        case kAudioDevicePropertyZeroTimeStampPeriod:
        case kAudioDevicePropertyDeviceCanBeDefaultDevice:
        case kAudioDevicePropertyDeviceCanBeDefaultSystemDevice:
        case kAudioDevicePropertyLatency:
        case kAudioDevicePropertySafetyOffset:
            *outSize = sizeof(UInt32); break;
        case kAudioDevicePropertyRelatedDevices:
            *outSize = sizeof(AudioObjectID); break;
        case kAudioObjectPropertyControlList:
            *outSize = 0; break;
        case kAudioDevicePropertyNominalSampleRate:
            *outSize = sizeof(Float64); break;
        case kAudioDevicePropertyAvailableNominalSampleRates:
            *outSize = kNumSupportedSampleRates * sizeof(AudioValueRange); break;
        case kAudioDevicePropertyStreams: {
            bool matches =
                addr->mScope == kAudioObjectPropertyScopeGlobal ||
                (addr->mScope == kAudioObjectPropertyScopeInput && dev->isInput) ||
                (addr->mScope == kAudioObjectPropertyScopeOutput && !dev->isInput);
            *outSize = matches ? sizeof(AudioObjectID) : 0;
            break;
        }
        case kAudioDevicePropertyPreferredChannelsForStereo:
            *outSize = 2 * sizeof(UInt32); break;
        case kAudioDevicePropertyPreferredChannelLayout:
            *outSize = offsetof(AudioChannelLayout, mChannelDescriptions) + kChannels * sizeof(AudioChannelDescription);
            break;
        default:
            return kAudioHardwareUnknownPropertyError;
    }
    return 0;
}

static OSStatus Device_GetPropertyData(MIADevice* dev, const AudioObjectPropertyAddress* addr,
                                       UInt32 qualifierSize, const void* qualifier,
                                       UInt32 inDataSize, UInt32* outDataSize, void* outData)
{
    (void)qualifierSize; (void)qualifier;
    switch (addr->mSelector) {
        case kAudioObjectPropertyBaseClass:
            if (inDataSize < sizeof(AudioClassID)) return kAudioHardwareBadPropertySizeError;
            *((AudioClassID*)outData) = kAudioObjectClassID;
            *outDataSize = sizeof(AudioClassID);
            break;
        case kAudioObjectPropertyClass:
            if (inDataSize < sizeof(AudioClassID)) return kAudioHardwareBadPropertySizeError;
            *((AudioClassID*)outData) = kAudioDeviceClassID;
            *outDataSize = sizeof(AudioClassID);
            break;
        case kAudioObjectPropertyOwner:
            if (inDataSize < sizeof(AudioObjectID)) return kAudioHardwareBadPropertySizeError;
            *((AudioObjectID*)outData) = kObjectID_PlugIn;
            *outDataSize = sizeof(AudioObjectID);
            break;
        case kAudioObjectPropertyName:
            if (inDataSize < sizeof(CFStringRef)) return kAudioHardwareBadPropertySizeError;
            *((CFStringRef*)outData) = (CFStringRef)CFRetain(dev->name);
            *outDataSize = sizeof(CFStringRef);
            break;
        case kAudioObjectPropertyManufacturer:
            if (inDataSize < sizeof(CFStringRef)) return kAudioHardwareBadPropertySizeError;
            *((CFStringRef*)outData) = CFSTR("Missing Corner");
            *outDataSize = sizeof(CFStringRef);
            break;
        case kAudioObjectPropertyOwnedObjects: {
            UInt32 maxItems = inDataSize / sizeof(AudioObjectID);
            AudioObjectID* list = (AudioObjectID*)outData;
            UInt32 n = 0;
            if (maxItems > 0) list[n++] = dev->streamID;
            *outDataSize = n * sizeof(AudioObjectID);
            break;
        }
        case kAudioDevicePropertyDeviceUID:
            if (inDataSize < sizeof(CFStringRef)) return kAudioHardwareBadPropertySizeError;
            *((CFStringRef*)outData) = (CFStringRef)CFRetain(dev->uid);
            *outDataSize = sizeof(CFStringRef);
            break;
        case kAudioDevicePropertyModelUID:
            if (inDataSize < sizeof(CFStringRef)) return kAudioHardwareBadPropertySizeError;
            *((CFStringRef*)outData) = (CFStringRef)CFRetain(dev->modelUID);
            *outDataSize = sizeof(CFStringRef);
            break;
        case kAudioDevicePropertyTransportType:
            if (inDataSize < sizeof(UInt32)) return kAudioHardwareBadPropertySizeError;
            *((UInt32*)outData) = kAudioDeviceTransportTypeVirtual;
            *outDataSize = sizeof(UInt32);
            break;
        case kAudioDevicePropertyRelatedDevices: {
            UInt32 maxItems = inDataSize / sizeof(AudioObjectID);
            AudioObjectID* list = (AudioObjectID*)outData;
            UInt32 n = 0;
            if (maxItems > 0) list[n++] = dev->deviceID;
            *outDataSize = n * sizeof(AudioObjectID);
            break;
        }
        case kAudioDevicePropertyClockDomain:
            if (inDataSize < sizeof(UInt32)) return kAudioHardwareBadPropertySizeError;
            *((UInt32*)outData) = 0;
            *outDataSize = sizeof(UInt32);
            break;
        case kAudioDevicePropertyDeviceIsAlive:
            if (inDataSize < sizeof(UInt32)) return kAudioHardwareBadPropertySizeError;
            *((UInt32*)outData) = 1;
            *outDataSize = sizeof(UInt32);
            break;
        case kAudioDevicePropertyDeviceIsRunning:
            if (inDataSize < sizeof(UInt32)) return kAudioHardwareBadPropertySizeError;
            pthread_mutex_lock(&gStateMutex);
            *((UInt32*)outData) = (dev->ioRunning > 0) ? 1 : 0;
            pthread_mutex_unlock(&gStateMutex);
            *outDataSize = sizeof(UInt32);
            break;
        case kAudioObjectPropertyControlList:
            *outDataSize = 0;
            break;
        case kAudioDevicePropertyNominalSampleRate:
            if (inDataSize < sizeof(Float64)) return kAudioHardwareBadPropertySizeError;
            pthread_mutex_lock(&dev->pair->mutex);
            *((Float64*)outData) = dev->pair->sampleRate;
            pthread_mutex_unlock(&dev->pair->mutex);
            *outDataSize = sizeof(Float64);
            break;
        case kAudioDevicePropertyAvailableNominalSampleRates: {
            UInt32 maxItems = inDataSize / sizeof(AudioValueRange);
            AudioValueRange* ranges = (AudioValueRange*)outData;
            UInt32 n = 0;
            for (size_t i = 0; i < kNumSupportedSampleRates && n < maxItems; i++) {
                ranges[n].mMinimum = kSupportedSampleRates[i];
                ranges[n].mMaximum = kSupportedSampleRates[i];
                n++;
            }
            *outDataSize = n * sizeof(AudioValueRange);
            break;
        }
        case kAudioDevicePropertyIsHidden:
            if (inDataSize < sizeof(UInt32)) return kAudioHardwareBadPropertySizeError;
            *((UInt32*)outData) = dev->isHidden ? 1 : 0;
            *outDataSize = sizeof(UInt32);
            break;
        case kAudioDevicePropertyZeroTimeStampPeriod:
            if (inDataSize < sizeof(UInt32)) return kAudioHardwareBadPropertySizeError;
            *((UInt32*)outData) = kRingFrames;
            *outDataSize = sizeof(UInt32);
            break;
        case kAudioDevicePropertyStreams: {
            UInt32 maxItems = inDataSize / sizeof(AudioObjectID);
            AudioObjectID* list = (AudioObjectID*)outData;
            UInt32 n = 0;
            bool matches =
                addr->mScope == kAudioObjectPropertyScopeGlobal ||
                (addr->mScope == kAudioObjectPropertyScopeInput && dev->isInput) ||
                (addr->mScope == kAudioObjectPropertyScopeOutput && !dev->isInput);
            if (matches && maxItems > 0) list[n++] = dev->streamID;
            *outDataSize = n * sizeof(AudioObjectID);
            break;
        }
        case kAudioDevicePropertyDeviceCanBeDefaultDevice:
            if (inDataSize < sizeof(UInt32)) return kAudioHardwareBadPropertySizeError;
            *((UInt32*)outData) = dev->isHidden ? 0 : 1;
            *outDataSize = sizeof(UInt32);
            break;
        case kAudioDevicePropertyDeviceCanBeDefaultSystemDevice:
            if (inDataSize < sizeof(UInt32)) return kAudioHardwareBadPropertySizeError;
            *((UInt32*)outData) = 0;
            *outDataSize = sizeof(UInt32);
            break;
        case kAudioDevicePropertyLatency:
        case kAudioDevicePropertySafetyOffset:
            if (inDataSize < sizeof(UInt32)) return kAudioHardwareBadPropertySizeError;
            *((UInt32*)outData) = 0;
            *outDataSize = sizeof(UInt32);
            break;
        case kAudioDevicePropertyPreferredChannelsForStereo: {
            if (inDataSize < 2 * sizeof(UInt32)) return kAudioHardwareBadPropertySizeError;
            UInt32* channels = (UInt32*)outData;
            channels[0] = 1;
            channels[1] = 2;
            *outDataSize = 2 * sizeof(UInt32);
            break;
        }
        case kAudioDevicePropertyPreferredChannelLayout: {
            UInt32 needed = offsetof(AudioChannelLayout, mChannelDescriptions) + kChannels * sizeof(AudioChannelDescription);
            if (inDataSize < needed) return kAudioHardwareBadPropertySizeError;
            AudioChannelLayout* layout = (AudioChannelLayout*)outData;
            layout->mChannelLayoutTag = kAudioChannelLayoutTag_UseChannelDescriptions;
            layout->mChannelBitmap = 0;
            layout->mNumberChannelDescriptions = kChannels;
            for (UInt32 i = 0; i < kChannels; i++) {
                layout->mChannelDescriptions[i].mChannelLabel = kAudioChannelLabel_Left + i;
                layout->mChannelDescriptions[i].mChannelFlags = 0;
                memset(layout->mChannelDescriptions[i].mCoordinates, 0, sizeof(layout->mChannelDescriptions[i].mCoordinates));
            }
            *outDataSize = needed;
            break;
        }
        default:
            return kAudioHardwareUnknownPropertyError;
    }
    return 0;
}

static OSStatus Device_SetPropertyData(MIADevice* dev, const AudioObjectPropertyAddress* addr,
                                       UInt32 inDataSize, const void* inData)
{
    switch (addr->mSelector) {
        case kAudioDevicePropertyNominalSampleRate: {
            if (inDataSize != sizeof(Float64)) return kAudioHardwareBadPropertySizeError;
            Float64 newRate = *((const Float64*)inData);
            bool valid = false;
            for (size_t i = 0; i < kNumSupportedSampleRates; i++) {
                if (kSupportedSampleRates[i] == newRate) { valid = true; break; }
            }
            if (!valid) return kAudioDeviceUnsupportedFormatError;
            pthread_mutex_lock(&dev->pair->mutex);
            Float64 oldRate = dev->pair->sampleRate;
            pthread_mutex_unlock(&dev->pair->mutex);
            if (newRate != oldRate && gPlugInHost != NULL) {
                gPlugInHost->RequestDeviceConfigurationChange(gPlugInHost, dev->deviceID, (UInt64)newRate, NULL);
            }
            break;
        }
        default:
            return kAudioHardwareUnknownPropertyError;
    }
    return 0;
}

// =============================================================================
// Property helpers — Stream objects
// =============================================================================

static Boolean Stream_HasProperty(const AudioObjectPropertyAddress* addr)
{
    switch (addr->mSelector) {
        case kAudioObjectPropertyBaseClass:
        case kAudioObjectPropertyClass:
        case kAudioObjectPropertyOwner:
        case kAudioStreamPropertyIsActive:
        case kAudioStreamPropertyDirection:
        case kAudioStreamPropertyTerminalType:
        case kAudioStreamPropertyStartingChannel:
        case kAudioStreamPropertyLatency:
        case kAudioStreamPropertyVirtualFormat:
        case kAudioStreamPropertyPhysicalFormat:
        case kAudioStreamPropertyAvailableVirtualFormats:
        case kAudioStreamPropertyAvailablePhysicalFormats:
            return true;
        default:
            return false;
    }
}

static Boolean Stream_IsPropertySettable(const AudioObjectPropertyAddress* addr)
{
    switch (addr->mSelector) {
        case kAudioStreamPropertyIsActive:
        case kAudioStreamPropertyVirtualFormat:
        case kAudioStreamPropertyPhysicalFormat:
            return true;
        default:
            return false;
    }
}

static OSStatus Stream_GetPropertyDataSize(const AudioObjectPropertyAddress* addr, UInt32* outSize)
{
    switch (addr->mSelector) {
        case kAudioObjectPropertyBaseClass:
        case kAudioObjectPropertyClass:
            *outSize = sizeof(AudioClassID); break;
        case kAudioObjectPropertyOwner:
            *outSize = sizeof(AudioObjectID); break;
        case kAudioStreamPropertyIsActive:
        case kAudioStreamPropertyDirection:
        case kAudioStreamPropertyTerminalType:
        case kAudioStreamPropertyStartingChannel:
        case kAudioStreamPropertyLatency:
            *outSize = sizeof(UInt32); break;
        case kAudioStreamPropertyVirtualFormat:
        case kAudioStreamPropertyPhysicalFormat:
            *outSize = sizeof(AudioStreamBasicDescription); break;
        case kAudioStreamPropertyAvailableVirtualFormats:
        case kAudioStreamPropertyAvailablePhysicalFormats:
            *outSize = kNumSupportedSampleRates * sizeof(AudioStreamRangedDescription); break;
        default:
            return kAudioHardwareUnknownPropertyError;
    }
    return 0;
}

static OSStatus Stream_GetPropertyData(MIADevice* dev, const AudioObjectPropertyAddress* addr,
                                       UInt32 inDataSize, UInt32* outDataSize, void* outData)
{
    switch (addr->mSelector) {
        case kAudioObjectPropertyBaseClass:
            if (inDataSize < sizeof(AudioClassID)) return kAudioHardwareBadPropertySizeError;
            *((AudioClassID*)outData) = kAudioObjectClassID;
            *outDataSize = sizeof(AudioClassID);
            break;
        case kAudioObjectPropertyClass:
            if (inDataSize < sizeof(AudioClassID)) return kAudioHardwareBadPropertySizeError;
            *((AudioClassID*)outData) = kAudioStreamClassID;
            *outDataSize = sizeof(AudioClassID);
            break;
        case kAudioObjectPropertyOwner:
            if (inDataSize < sizeof(AudioObjectID)) return kAudioHardwareBadPropertySizeError;
            *((AudioObjectID*)outData) = dev->deviceID;
            *outDataSize = sizeof(AudioObjectID);
            break;
        case kAudioStreamPropertyIsActive:
            if (inDataSize < sizeof(UInt32)) return kAudioHardwareBadPropertySizeError;
            pthread_mutex_lock(&gStateMutex);
            *((UInt32*)outData) = dev->streamActive ? 1 : 0;
            pthread_mutex_unlock(&gStateMutex);
            *outDataSize = sizeof(UInt32);
            break;
        case kAudioStreamPropertyDirection:
            if (inDataSize < sizeof(UInt32)) return kAudioHardwareBadPropertySizeError;
            *((UInt32*)outData) = dev->isInput ? 1 : 0;
            *outDataSize = sizeof(UInt32);
            break;
        case kAudioStreamPropertyTerminalType:
            if (inDataSize < sizeof(UInt32)) return kAudioHardwareBadPropertySizeError;
            *((UInt32*)outData) = dev->isInput ? kAudioStreamTerminalTypeMicrophone : kAudioStreamTerminalTypeSpeaker;
            *outDataSize = sizeof(UInt32);
            break;
        case kAudioStreamPropertyStartingChannel:
            if (inDataSize < sizeof(UInt32)) return kAudioHardwareBadPropertySizeError;
            *((UInt32*)outData) = 1;
            *outDataSize = sizeof(UInt32);
            break;
        case kAudioStreamPropertyLatency:
            if (inDataSize < sizeof(UInt32)) return kAudioHardwareBadPropertySizeError;
            *((UInt32*)outData) = 0;
            *outDataSize = sizeof(UInt32);
            break;
        case kAudioStreamPropertyVirtualFormat:
        case kAudioStreamPropertyPhysicalFormat:
            if (inDataSize < sizeof(AudioStreamBasicDescription)) return kAudioHardwareBadPropertySizeError;
            pthread_mutex_lock(&dev->pair->mutex);
            FillASBD((AudioStreamBasicDescription*)outData, dev->pair->sampleRate);
            pthread_mutex_unlock(&dev->pair->mutex);
            *outDataSize = sizeof(AudioStreamBasicDescription);
            break;
        case kAudioStreamPropertyAvailableVirtualFormats:
        case kAudioStreamPropertyAvailablePhysicalFormats: {
            UInt32 maxItems = inDataSize / sizeof(AudioStreamRangedDescription);
            AudioStreamRangedDescription* descs = (AudioStreamRangedDescription*)outData;
            UInt32 n = 0;
            for (size_t i = 0; i < kNumSupportedSampleRates && n < maxItems; i++) {
                FillASBD(&descs[n].mFormat, kSupportedSampleRates[i]);
                descs[n].mSampleRateRange.mMinimum = kSupportedSampleRates[i];
                descs[n].mSampleRateRange.mMaximum = kSupportedSampleRates[i];
                n++;
            }
            *outDataSize = n * sizeof(AudioStreamRangedDescription);
            break;
        }
        default:
            return kAudioHardwareUnknownPropertyError;
    }
    return 0;
}

static OSStatus Stream_SetPropertyData(MIADevice* dev, const AudioObjectPropertyAddress* addr,
                                       UInt32 inDataSize, const void* inData)
{
    switch (addr->mSelector) {
        case kAudioStreamPropertyIsActive: {
            if (inDataSize != sizeof(UInt32)) return kAudioHardwareBadPropertySizeError;
            bool active = (*((const UInt32*)inData)) != 0;
            pthread_mutex_lock(&gStateMutex);
            dev->streamActive = active;
            pthread_mutex_unlock(&gStateMutex);
            break;
        }
        case kAudioStreamPropertyVirtualFormat:
        case kAudioStreamPropertyPhysicalFormat: {
            if (inDataSize != sizeof(AudioStreamBasicDescription)) return kAudioHardwareBadPropertySizeError;
            const AudioStreamBasicDescription* asbd = (const AudioStreamBasicDescription*)inData;
            if (asbd->mFormatID != kAudioFormatLinearPCM ||
                asbd->mChannelsPerFrame != kChannels ||
                asbd->mBitsPerChannel != kBitsPerChannel) {
                return kAudioDeviceUnsupportedFormatError;
            }
            bool valid = false;
            for (size_t i = 0; i < kNumSupportedSampleRates; i++) {
                if (kSupportedSampleRates[i] == asbd->mSampleRate) { valid = true; break; }
            }
            if (!valid) return kAudioDeviceUnsupportedFormatError;
            pthread_mutex_lock(&dev->pair->mutex);
            Float64 oldRate = dev->pair->sampleRate;
            pthread_mutex_unlock(&dev->pair->mutex);
            if (asbd->mSampleRate != oldRate && gPlugInHost != NULL) {
                gPlugInHost->RequestDeviceConfigurationChange(gPlugInHost, dev->deviceID, (UInt64)asbd->mSampleRate, NULL);
            }
            break;
        }
        default:
            return kAudioHardwareUnknownPropertyError;
    }
    return 0;
}

// =============================================================================
// Property dispatch
// =============================================================================

static Boolean MIA_HasProperty(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID,
                               pid_t inClientPID, const AudioObjectPropertyAddress* inAddress)
{
    (void)inClientPID;
    if (inDriver != gDriverRef || inAddress == NULL) return false;

    if (inObjectID == kObjectID_PlugIn) {
        return PlugIn_HasProperty(inAddress);
    }
    MIADevice* dev = DeviceForID(inObjectID);
    if (dev != NULL) {
        return Device_HasProperty(dev, inAddress);
    }
    if (DeviceForStreamID(inObjectID) != NULL) {
        return Stream_HasProperty(inAddress);
    }
    return false;
}

static OSStatus MIA_IsPropertySettable(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID,
                                       pid_t inClientPID, const AudioObjectPropertyAddress* inAddress,
                                       Boolean* outIsSettable)
{
    (void)inClientPID;
    if (inDriver != gDriverRef || inAddress == NULL || outIsSettable == NULL) return kAudioHardwareBadObjectError;

    if (inObjectID == kObjectID_PlugIn) {
        if (!PlugIn_HasProperty(inAddress)) return kAudioHardwareUnknownPropertyError;
        *outIsSettable = false;
        return 0;
    }
    MIADevice* dev = DeviceForID(inObjectID);
    if (dev != NULL) {
        if (!Device_HasProperty(dev, inAddress)) return kAudioHardwareUnknownPropertyError;
        *outIsSettable = Device_IsPropertySettable(dev, inAddress);
        return 0;
    }
    if (DeviceForStreamID(inObjectID) != NULL) {
        if (!Stream_HasProperty(inAddress)) return kAudioHardwareUnknownPropertyError;
        *outIsSettable = Stream_IsPropertySettable(inAddress);
        return 0;
    }
    return kAudioHardwareBadObjectError;
}

static OSStatus MIA_GetPropertyDataSize(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID,
                                        pid_t inClientPID, const AudioObjectPropertyAddress* inAddress,
                                        UInt32 inQualifierDataSize, const void* inQualifierData,
                                        UInt32* outDataSize)
{
    (void)inClientPID;
    if (inDriver != gDriverRef || inAddress == NULL || outDataSize == NULL) return kAudioHardwareBadObjectError;

    if (inObjectID == kObjectID_PlugIn) {
        return PlugIn_GetPropertyDataSize(inAddress, inQualifierDataSize, inQualifierData, outDataSize);
    }
    MIADevice* dev = DeviceForID(inObjectID);
    if (dev != NULL) {
        return Device_GetPropertyDataSize(dev, inAddress, inQualifierDataSize, inQualifierData, outDataSize);
    }
    if (DeviceForStreamID(inObjectID) != NULL) {
        return Stream_GetPropertyDataSize(inAddress, outDataSize);
    }
    return kAudioHardwareBadObjectError;
}

static OSStatus MIA_GetPropertyData(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID,
                                    pid_t inClientPID, const AudioObjectPropertyAddress* inAddress,
                                    UInt32 inQualifierDataSize, const void* inQualifierData,
                                    UInt32 inDataSize, UInt32* outDataSize, void* outData)
{
    (void)inClientPID;
    if (inDriver != gDriverRef || inAddress == NULL || outDataSize == NULL || outData == NULL) return kAudioHardwareBadObjectError;

    if (inObjectID == kObjectID_PlugIn) {
        return PlugIn_GetPropertyData(inAddress, inQualifierDataSize, inQualifierData, inDataSize, outDataSize, outData);
    }
    MIADevice* dev = DeviceForID(inObjectID);
    if (dev != NULL) {
        return Device_GetPropertyData(dev, inAddress, inQualifierDataSize, inQualifierData, inDataSize, outDataSize, outData);
    }
    dev = DeviceForStreamID(inObjectID);
    if (dev != NULL) {
        return Stream_GetPropertyData(dev, inAddress, inDataSize, outDataSize, outData);
    }
    return kAudioHardwareBadObjectError;
}

static OSStatus MIA_SetPropertyData(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID,
                                    pid_t inClientPID, const AudioObjectPropertyAddress* inAddress,
                                    UInt32 inQualifierDataSize, const void* inQualifierData,
                                    UInt32 inDataSize, const void* inData)
{
    (void)inClientPID; (void)inQualifierDataSize; (void)inQualifierData;
    if (inDriver != gDriverRef || inAddress == NULL) return kAudioHardwareBadObjectError;

    if (inObjectID == kObjectID_PlugIn) {
        return kAudioHardwareUnknownPropertyError;
    }
    MIADevice* dev = DeviceForID(inObjectID);
    if (dev != NULL) {
        return Device_SetPropertyData(dev, inAddress, inDataSize, inData);
    }
    dev = DeviceForStreamID(inObjectID);
    if (dev != NULL) {
        return Stream_SetPropertyData(dev, inAddress, inDataSize, inData);
    }
    return kAudioHardwareBadObjectError;
}

// =============================================================================
// IO
// =============================================================================

static OSStatus MIA_StartIO(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID)
{
    (void)inClientID;
    if (inDriver != gDriverRef) return kAudioHardwareBadObjectError;
    MIADevice* dev = DeviceForID(inDeviceObjectID);
    if (dev == NULL) return kAudioHardwareBadObjectError;

    pthread_mutex_lock(&gStateMutex);
    if (dev->ioRunning == UINT64_MAX) {
        pthread_mutex_unlock(&gStateMutex);
        return kAudioHardwareIllegalOperationError;
    }
    if (dev->ioRunning == 0) {
        pthread_mutex_lock(&dev->pair->mutex);
        if (dev->pair->runningCount == 0) {
            // First device of this pair: establish the shared clock.
            dev->pair->numberTimeStamps = 0;
            dev->pair->anchorHostTime = mach_absolute_time();
            RecomputeHostTicksPerFrame(dev->pair);
            memset(dev->pair->ring, 0, kRingFrames * kChannels * sizeof(Float32));
        }
        dev->pair->runningCount++;
        pthread_mutex_unlock(&dev->pair->mutex);
    }
    dev->ioRunning++;
    pthread_mutex_unlock(&gStateMutex);
    return 0;
}

static OSStatus MIA_StopIO(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID)
{
    (void)inClientID;
    if (inDriver != gDriverRef) return kAudioHardwareBadObjectError;
    MIADevice* dev = DeviceForID(inDeviceObjectID);
    if (dev == NULL) return kAudioHardwareBadObjectError;

    pthread_mutex_lock(&gStateMutex);
    if (dev->ioRunning == 0) {
        pthread_mutex_unlock(&gStateMutex);
        return kAudioHardwareIllegalOperationError;
    }
    dev->ioRunning--;
    if (dev->ioRunning == 0) {
        pthread_mutex_lock(&dev->pair->mutex);
        if (dev->pair->runningCount > 0) dev->pair->runningCount--;
        pthread_mutex_unlock(&dev->pair->mutex);
    }
    pthread_mutex_unlock(&gStateMutex);
    return 0;
}

static OSStatus MIA_GetZeroTimeStamp(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID,
                                     UInt32 inClientID, Float64* outSampleTime, UInt64* outHostTime, UInt64* outSeed)
{
    (void)inClientID;
    if (inDriver != gDriverRef) return kAudioHardwareBadObjectError;
    MIADevice* dev = DeviceForID(inDeviceObjectID);
    if (dev == NULL) return kAudioHardwareBadObjectError;
    MIAPair* pair = dev->pair;

    pthread_mutex_lock(&pair->mutex);
    UInt64 currentHostTime = mach_absolute_time();
    Float64 hostTicksPerPeriod = pair->hostTicksPerFrame * (Float64)kRingFrames;
    Float64 nextHostTime = (Float64)pair->anchorHostTime + ((Float64)(pair->numberTimeStamps + 1)) * hostTicksPerPeriod;
    if (nextHostTime <= (Float64)currentHostTime) {
        pair->numberTimeStamps++;
    }
    *outSampleTime = (Float64)(pair->numberTimeStamps * kRingFrames);
    *outHostTime = pair->anchorHostTime + (UInt64)(((Float64)pair->numberTimeStamps) * hostTicksPerPeriod);
    *outSeed = 1;
    pthread_mutex_unlock(&pair->mutex);
    return 0;
}

static OSStatus MIA_WillDoIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID,
                                      UInt32 inClientID, UInt32 inOperationID,
                                      Boolean* outWillDo, Boolean* outWillDoInPlace)
{
    (void)inClientID;
    if (inDriver != gDriverRef) return kAudioHardwareBadObjectError;
    MIADevice* dev = DeviceForID(inDeviceObjectID);
    if (dev == NULL) return kAudioHardwareBadObjectError;

    bool willDo = false;
    switch (inOperationID) {
        case kAudioServerPlugInIOOperationReadInput:
            willDo = dev->isInput;
            break;
        case kAudioServerPlugInIOOperationWriteMix:
            willDo = !dev->isInput;
            break;
        default:
            break;
    }
    if (outWillDo) *outWillDo = willDo;
    if (outWillDoInPlace) *outWillDoInPlace = true;
    return 0;
}

static OSStatus MIA_BeginIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID,
                                     UInt32 inClientID, UInt32 inOperationID, UInt32 inIOBufferFrameSize,
                                     const AudioServerPlugInIOCycleInfo* inIOCycleInfo)
{
    (void)inDriver; (void)inDeviceObjectID; (void)inClientID; (void)inOperationID;
    (void)inIOBufferFrameSize; (void)inIOCycleInfo;
    return 0;
}

static OSStatus MIA_DoIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID,
                                  AudioObjectID inStreamObjectID, UInt32 inClientID, UInt32 inOperationID,
                                  UInt32 inIOBufferFrameSize, const AudioServerPlugInIOCycleInfo* inIOCycleInfo,
                                  void* ioMainBuffer, void* ioSecondaryBuffer)
{
    (void)inStreamObjectID; (void)inClientID; (void)ioSecondaryBuffer;
    if (inDriver != gDriverRef) return kAudioHardwareBadObjectError;
    MIADevice* dev = DeviceForID(inDeviceObjectID);
    if (dev == NULL) return kAudioHardwareBadObjectError;
    if (ioMainBuffer == NULL || inIOCycleInfo == NULL) return kAudioHardwareIllegalOperationError;
    if (inIOBufferFrameSize == 0 || inIOBufferFrameSize > kRingFrames) return kAudioHardwareIllegalOperationError;
    MIAPair* pair = dev->pair;

    if (inOperationID == kAudioServerPlugInIOOperationReadInput && dev->isInput) {
        Float32* out = (Float32*)ioMainBuffer;
        int64_t startFrame = (int64_t)inIOCycleInfo->mInputTime.mSampleTime;
        int64_t start = ((startFrame % kRingFrames) + kRingFrames) % kRingFrames;
        UInt32 firstChunk = (UInt32)((kRingFrames - start) < inIOBufferFrameSize ? (kRingFrames - start) : inIOBufferFrameSize);
        UInt32 secondChunk = inIOBufferFrameSize - firstChunk;

        pthread_mutex_lock(&pair->mutex);
        memcpy(out, pair->ring + start * kChannels, firstChunk * kBytesPerFrame);
        memset(pair->ring + start * kChannels, 0, firstChunk * kBytesPerFrame);
        if (secondChunk > 0) {
            memcpy(out + firstChunk * kChannels, pair->ring, secondChunk * kBytesPerFrame);
            memset(pair->ring, 0, secondChunk * kBytesPerFrame);
        }
        pthread_mutex_unlock(&pair->mutex);
    } else if (inOperationID == kAudioServerPlugInIOOperationWriteMix && !dev->isInput) {
        const Float32* in = (const Float32*)ioMainBuffer;
        int64_t startFrame = (int64_t)inIOCycleInfo->mOutputTime.mSampleTime;
        int64_t start = ((startFrame % kRingFrames) + kRingFrames) % kRingFrames;
        UInt32 firstChunk = (UInt32)((kRingFrames - start) < inIOBufferFrameSize ? (kRingFrames - start) : inIOBufferFrameSize);
        UInt32 secondChunk = inIOBufferFrameSize - firstChunk;

        pthread_mutex_lock(&pair->mutex);
        memcpy(pair->ring + start * kChannels, in, firstChunk * kBytesPerFrame);
        if (secondChunk > 0) {
            memcpy(pair->ring, in + firstChunk * kChannels, secondChunk * kBytesPerFrame);
        }
        pthread_mutex_unlock(&pair->mutex);
    }
    return 0;
}

static OSStatus MIA_EndIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID,
                                   UInt32 inClientID, UInt32 inOperationID, UInt32 inIOBufferFrameSize,
                                   const AudioServerPlugInIOCycleInfo* inIOCycleInfo)
{
    (void)inDriver; (void)inDeviceObjectID; (void)inClientID; (void)inOperationID;
    (void)inIOBufferFrameSize; (void)inIOCycleInfo;
    return 0;
}

// =============================================================================
// Interface table + factory
// =============================================================================

static AudioServerPlugInDriverInterface gDriverInterface = {
    NULL,
    MIA_QueryInterface,
    MIA_AddRef,
    MIA_Release,
    MIA_Initialize,
    MIA_CreateDevice,
    MIA_DestroyDevice,
    MIA_AddDeviceClient,
    MIA_RemoveDeviceClient,
    MIA_PerformDeviceConfigurationChange,
    MIA_AbortDeviceConfigurationChange,
    MIA_HasProperty,
    MIA_IsPropertySettable,
    MIA_GetPropertyDataSize,
    MIA_GetPropertyData,
    MIA_SetPropertyData,
    MIA_StartIO,
    MIA_StopIO,
    MIA_GetZeroTimeStamp,
    MIA_WillDoIOOperation,
    MIA_BeginIOOperation,
    MIA_DoIOOperation,
    MIA_EndIOOperation
};

// Entry point named in Info.plist CFPlugInFactories.
void* MIAgentAudio_Create(CFAllocatorRef inAllocator, CFUUIDRef inRequestedTypeUUID);
void* MIAgentAudio_Create(CFAllocatorRef inAllocator, CFUUIDRef inRequestedTypeUUID)
{
    (void)inAllocator;
    if (CFEqual(inRequestedTypeUUID, kAudioServerPlugInTypeUUID)) {
        return gDriverRef;
    }
    return NULL;
}
