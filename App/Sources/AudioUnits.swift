import AudioToolbox
import CoreAudio
import Foundation

enum AudioUnitError: Error, LocalizedError {
    case componentNotFound
    case osStatus(String, OSStatus)

    var errorDescription: String? {
        switch self {
        case .componentNotFound: return "AUHAL audio component not found"
        case .osStatus(let stage, let status): return "\(stage) failed (OSStatus \(status))"
        }
    }
}

private func check(_ status: OSStatus, _ stage: String) throws {
    guard status == noErr else { throw AudioUnitError.osStatus(stage, status) }
}

private func makeHALUnit() throws -> AudioUnit {
    var desc = AudioComponentDescription(
        componentType: kAudioUnitType_Output,
        componentSubType: kAudioUnitSubType_HALOutput,
        componentManufacturer: kAudioUnitManufacturer_Apple,
        componentFlags: 0,
        componentFlagsMask: 0)
    guard let component = AudioComponentFindNext(nil, &desc) else {
        throw AudioUnitError.componentNotFound
    }
    var unit: AudioUnit?
    try check(AudioComponentInstanceNew(component, &unit), "AudioComponentInstanceNew")
    guard let audioUnit = unit else { throw AudioUnitError.componentNotFound }
    return audioUnit
}

private func interleavedFloatASBD(rate: Double, channels: UInt32) -> AudioStreamBasicDescription {
    AudioStreamBasicDescription(
        mSampleRate: rate,
        mFormatID: kAudioFormatLinearPCM,
        mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagsNativeEndian | kAudioFormatFlagIsPacked,
        mBytesPerPacket: 4 * channels,
        mFramesPerPacket: 1,
        mBytesPerFrame: 4 * channels,
        mChannelsPerFrame: channels,
        mBitsPerChannel: 32,
        mReserved: 0)
}

/// Common surface for the two mic-capture implementations (plain AUHAL and
/// echo-cancelled VoiceProcessingIO).
protocol AudioCapturing: AnyObject {
    var onAudio: ((UnsafePointer<Float>, Int) -> Void)? { get set }
    var sampleRate: Double { get }
    func start() throws
    func stop()
}

// MARK: - Capture

/// Captures audio from a specific device via AUHAL and delivers MONO float
/// samples at the device's nominal sample rate.
final class CaptureUnit: AudioCapturing {
    private var unit: AudioUnit?
    private let deviceID: AudioDeviceID
    private(set) var sampleRate: Double = 48000
    private var channels: UInt32 = 2
    private var scratch: UnsafeMutablePointer<Float>?
    private var mono: UnsafeMutablePointer<Float>?
    private var scratchCapacity = 0

    /// Called on the audio IO thread with mono samples at `sampleRate`.
    var onAudio: ((UnsafePointer<Float>, Int) -> Void)?

    init(deviceID: AudioDeviceID) {
        self.deviceID = deviceID
    }

    func start() throws {
        let unit = try makeHALUnit()
        self.unit = unit

        var enable: UInt32 = 1
        var disable: UInt32 = 0
        try check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO,
                                       kAudioUnitScope_Input, 1, &enable, UInt32(MemoryLayout<UInt32>.size)),
                  "enable input")
        try check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO,
                                       kAudioUnitScope_Output, 0, &disable, UInt32(MemoryLayout<UInt32>.size)),
                  "disable output")

        var device = deviceID
        try check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice,
                                       kAudioUnitScope_Global, 0, &device, UInt32(MemoryLayout<AudioDeviceID>.size)),
                  "set capture device")

        sampleRate = AudioDevices.nominalSampleRate(deviceID)
        let deviceChannels = AudioDevices.info(for: deviceID)?.inputChannels ?? 2
        channels = deviceChannels >= 2 ? 2 : 1

        var format = interleavedFloatASBD(rate: sampleRate, channels: channels)
        try check(AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat,
                                       kAudioUnitScope_Output, 1, &format,
                                       UInt32(MemoryLayout<AudioStreamBasicDescription>.size)),
                  "set capture client format")

        scratchCapacity = 8192
        scratch = UnsafeMutablePointer<Float>.allocate(capacity: scratchCapacity * Int(channels))
        mono = UnsafeMutablePointer<Float>.allocate(capacity: scratchCapacity)

        var callback = AURenderCallbackStruct(
            inputProc: captureCallback,
            inputProcRefCon: Unmanaged.passUnretained(self).toOpaque())
        try check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_SetInputCallback,
                                       kAudioUnitScope_Global, 0, &callback,
                                       UInt32(MemoryLayout<AURenderCallbackStruct>.size)),
                  "set input callback")

        try check(AudioUnitInitialize(unit), "initialize capture unit")
        try check(AudioOutputUnitStart(unit), "start capture unit")
    }

    func stop() {
        if let unit {
            AudioOutputUnitStop(unit)
            AudioUnitUninitialize(unit)
            AudioComponentInstanceDispose(unit)
        }
        unit = nil
        scratch?.deallocate()
        mono?.deallocate()
        scratch = nil
        mono = nil
    }

    fileprivate func render(_ ioActionFlags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
                            _ inTimeStamp: UnsafePointer<AudioTimeStamp>,
                            _ inBusNumber: UInt32,
                            _ inNumberFrames: UInt32) -> OSStatus {
        guard let unit, let scratch, let mono, Int(inNumberFrames) <= scratchCapacity else { return noErr }

        var bufferList = AudioBufferList(
            mNumberBuffers: 1,
            mBuffers: AudioBuffer(
                mNumberChannels: channels,
                mDataByteSize: inNumberFrames * 4 * channels,
                mData: UnsafeMutableRawPointer(scratch)))

        let status = AudioUnitRender(unit, ioActionFlags, inTimeStamp, inBusNumber, inNumberFrames, &bufferList)
        guard status == noErr else { return status }

        let frames = Int(inNumberFrames)
        if channels == 2 {
            for i in 0..<frames {
                mono[i] = (scratch[i * 2] + scratch[i * 2 + 1]) * 0.5
            }
        } else {
            mono.update(from: scratch, count: frames)
        }
        onAudio?(mono, frames)
        return noErr
    }
}

// MARK: - Echo-cancelled capture (VoiceProcessingIO)

/// Captures the microphone through Apple's voice-processing I/O unit, which
/// runs acoustic echo cancellation: audio played to the reference output
/// device (our ducked original + translated overdub, and any other system
/// audio on that device) is subtracted from what the mic hears. This is the
/// same AEC FaceTime and Safari use, so open speakers stop feeding the
/// meeting audio back into the outbound translator.
///
/// The unit's output element is bound to the reference device and renders
/// silence — it exists only to give the echo canceller its far-end signal
/// path. Delivers MONO float samples at `sampleRate`.
final class VoiceProcessingCaptureUnit: AudioCapturing {
    private var unit: AudioUnit?
    private let micDeviceID: AudioDeviceID
    private let referenceOutputDeviceID: AudioDeviceID
    private(set) var sampleRate: Double = 48000
    private var scratch: UnsafeMutablePointer<Float>?
    private var scratchCapacity = 0

    var onAudio: ((UnsafePointer<Float>, Int) -> Void)?

    init(micDeviceID: AudioDeviceID, referenceOutputDeviceID: AudioDeviceID) {
        self.micDeviceID = micDeviceID
        self.referenceOutputDeviceID = referenceOutputDeviceID
    }

    func start() throws {
        var desc = AudioComponentDescription(
            componentType: kAudioUnitType_Output,
            componentSubType: kAudioUnitSubType_VoiceProcessingIO,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0,
            componentFlagsMask: 0)
        guard let component = AudioComponentFindNext(nil, &desc) else {
            throw AudioUnitError.componentNotFound
        }
        var newUnit: AudioUnit?
        try check(AudioComponentInstanceNew(component, &newUnit), "create VPIO unit")
        guard let unit = newUnit else { throw AudioUnitError.componentNotFound }
        self.unit = unit

        // Both elements enabled: input (1) is the mic, output (0) carries the
        // AEC reference to the speakers (we render silence into it).
        var enable: UInt32 = 1
        try check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO,
                                       kAudioUnitScope_Input, 1, &enable, UInt32(MemoryLayout<UInt32>.size)),
                  "VPIO enable input")
        try check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO,
                                       kAudioUnitScope_Output, 0, &enable, UInt32(MemoryLayout<UInt32>.size)),
                  "VPIO enable output")

        // VPIO (unlike plain AUHAL) accepts a separate device per element.
        var micDevice = micDeviceID
        try check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice,
                                       kAudioUnitScope_Global, 1, &micDevice, UInt32(MemoryLayout<AudioDeviceID>.size)),
                  "VPIO set mic device")
        var outDevice = referenceOutputDeviceID
        try check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice,
                                       kAudioUnitScope_Global, 0, &outDevice, UInt32(MemoryLayout<AudioDeviceID>.size)),
                  "VPIO set reference output device")

        // Keep VPIO from ducking the rest of the system's audio on this
        // device — our own overdub mix plays there and must stay audible.
        if #available(macOS 14.0, *) {
            var ducking = AUVoiceIOOtherAudioDuckingConfiguration(
                mEnableAdvancedDucking: false,
                mDuckingLevel: .min)
            _ = AudioUnitSetProperty(unit, kAUVoiceIOProperty_OtherAudioDuckingConfiguration,
                                     kAudioUnitScope_Global, 0, &ducking,
                                     UInt32(MemoryLayout<AUVoiceIOOtherAudioDuckingConfiguration>.size))
        }

        // Mono capture at the mic's nominal rate; VPIO's DSP is mono anyway.
        sampleRate = AudioDevices.nominalSampleRate(micDeviceID)
        var captureFormat = interleavedFloatASBD(rate: sampleRate, channels: 1)
        try check(AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat,
                                       kAudioUnitScope_Output, 1, &captureFormat,
                                       UInt32(MemoryLayout<AudioStreamBasicDescription>.size)),
                  "VPIO set capture format")

        // Silence render into the output element.
        let outputRate = AudioDevices.nominalSampleRate(referenceOutputDeviceID)
        var renderFormat = interleavedFloatASBD(rate: outputRate, channels: 1)
        try check(AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat,
                                       kAudioUnitScope_Input, 0, &renderFormat,
                                       UInt32(MemoryLayout<AudioStreamBasicDescription>.size)),
                  "VPIO set render format")
        var renderCallback = AURenderCallbackStruct(
            inputProc: vpioSilenceCallback,
            inputProcRefCon: nil)
        try check(AudioUnitSetProperty(unit, kAudioUnitProperty_SetRenderCallback,
                                       kAudioUnitScope_Input, 0, &renderCallback,
                                       UInt32(MemoryLayout<AURenderCallbackStruct>.size)),
                  "VPIO set silence render callback")

        scratchCapacity = 8192
        scratch = UnsafeMutablePointer<Float>.allocate(capacity: scratchCapacity)

        var inputCallback = AURenderCallbackStruct(
            inputProc: vpioCaptureCallback,
            inputProcRefCon: Unmanaged.passUnretained(self).toOpaque())
        try check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_SetInputCallback,
                                       kAudioUnitScope_Global, 1, &inputCallback,
                                       UInt32(MemoryLayout<AURenderCallbackStruct>.size)),
                  "VPIO set input callback")

        try check(AudioUnitInitialize(unit), "initialize VPIO unit")
        try check(AudioOutputUnitStart(unit), "start VPIO unit")
    }

    func stop() {
        if let unit {
            AudioOutputUnitStop(unit)
            AudioUnitUninitialize(unit)
            AudioComponentInstanceDispose(unit)
        }
        unit = nil
        scratch?.deallocate()
        scratch = nil
    }

    fileprivate func render(_ ioActionFlags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
                            _ inTimeStamp: UnsafePointer<AudioTimeStamp>,
                            _ inBusNumber: UInt32,
                            _ inNumberFrames: UInt32) -> OSStatus {
        guard let unit, let scratch, Int(inNumberFrames) <= scratchCapacity else { return noErr }
        var bufferList = AudioBufferList(
            mNumberBuffers: 1,
            mBuffers: AudioBuffer(
                mNumberChannels: 1,
                mDataByteSize: inNumberFrames * 4,
                mData: UnsafeMutableRawPointer(scratch)))
        let status = AudioUnitRender(unit, ioActionFlags, inTimeStamp, inBusNumber, inNumberFrames, &bufferList)
        guard status == noErr else { return status }
        onAudio?(scratch, Int(inNumberFrames))
        return noErr
    }
}

private func vpioCaptureCallback(inRefCon: UnsafeMutableRawPointer,
                                 ioActionFlags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
                                 inTimeStamp: UnsafePointer<AudioTimeStamp>,
                                 inBusNumber: UInt32,
                                 inNumberFrames: UInt32,
                                 ioData: UnsafeMutablePointer<AudioBufferList>?) -> OSStatus {
    let capture = Unmanaged<VoiceProcessingCaptureUnit>.fromOpaque(inRefCon).takeUnretainedValue()
    return capture.render(ioActionFlags, inTimeStamp, inBusNumber, inNumberFrames)
}

private func vpioSilenceCallback(inRefCon: UnsafeMutableRawPointer,
                                 ioActionFlags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
                                 inTimeStamp: UnsafePointer<AudioTimeStamp>,
                                 inBusNumber: UInt32,
                                 inNumberFrames: UInt32,
                                 ioData: UnsafeMutablePointer<AudioBufferList>?) -> OSStatus {
    if let ioData {
        let buffers = UnsafeMutableAudioBufferListPointer(ioData)
        for buffer in buffers {
            if let data = buffer.mData {
                memset(data, 0, Int(buffer.mDataByteSize))
            }
        }
    }
    ioActionFlags.pointee.insert(.unitRenderAction_OutputIsSilence)
    return noErr
}

private func captureCallback(inRefCon: UnsafeMutableRawPointer,
                             ioActionFlags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
                             inTimeStamp: UnsafePointer<AudioTimeStamp>,
                             inBusNumber: UInt32,
                             inNumberFrames: UInt32,
                             ioData: UnsafeMutablePointer<AudioBufferList>?) -> OSStatus {
    let capture = Unmanaged<CaptureUnit>.fromOpaque(inRefCon).takeUnretainedValue()
    return capture.render(ioActionFlags, inTimeStamp, inBusNumber, inNumberFrames)
}

// MARK: - Playback

/// Plays audio to a specific device via AUHAL. The `renderMono` closure fills
/// mono samples at the device's nominal rate; they are duplicated to stereo.
final class PlaybackUnit {
    private var unit: AudioUnit?
    private let deviceID: AudioDeviceID
    private(set) var sampleRate: Double = 48000
    private var monoBuffer: UnsafeMutablePointer<Float>?
    private var monoCapacity = 0

    /// Called on the audio IO thread; must fill `count` mono samples.
    var renderMono: ((UnsafeMutablePointer<Float>, Int) -> Void)?

    init(deviceID: AudioDeviceID) {
        self.deviceID = deviceID
    }

    func start() throws {
        let unit = try makeHALUnit()
        self.unit = unit

        var device = deviceID
        try check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice,
                                       kAudioUnitScope_Global, 0, &device, UInt32(MemoryLayout<AudioDeviceID>.size)),
                  "set playback device")

        sampleRate = AudioDevices.nominalSampleRate(deviceID)
        var format = interleavedFloatASBD(rate: sampleRate, channels: 2)
        try check(AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat,
                                       kAudioUnitScope_Input, 0, &format,
                                       UInt32(MemoryLayout<AudioStreamBasicDescription>.size)),
                  "set playback client format")

        monoCapacity = 8192
        monoBuffer = UnsafeMutablePointer<Float>.allocate(capacity: monoCapacity)

        var callback = AURenderCallbackStruct(
            inputProc: playbackCallback,
            inputProcRefCon: Unmanaged.passUnretained(self).toOpaque())
        try check(AudioUnitSetProperty(unit, kAudioUnitProperty_SetRenderCallback,
                                       kAudioUnitScope_Input, 0, &callback,
                                       UInt32(MemoryLayout<AURenderCallbackStruct>.size)),
                  "set render callback")

        try check(AudioUnitInitialize(unit), "initialize playback unit")
        try check(AudioOutputUnitStart(unit), "start playback unit")
    }

    func stop() {
        if let unit {
            AudioOutputUnitStop(unit)
            AudioUnitUninitialize(unit)
            AudioComponentInstanceDispose(unit)
        }
        unit = nil
        monoBuffer?.deallocate()
        monoBuffer = nil
    }

    fileprivate func render(frames: UInt32, ioData: UnsafeMutablePointer<AudioBufferList>?) -> OSStatus {
        guard let ioData else { return noErr }
        let buffers = UnsafeMutableAudioBufferListPointer(ioData)
        guard let first = buffers.first, let dataPtr = first.mData else { return noErr }
        let out = dataPtr.assumingMemoryBound(to: Float.self)
        let n = Int(frames)

        guard let monoBuffer, n <= monoCapacity, let renderMono else {
            out.update(repeating: 0, count: n * 2)
            return noErr
        }
        renderMono(monoBuffer, n)
        for i in 0..<n {
            out[i * 2] = monoBuffer[i]
            out[i * 2 + 1] = monoBuffer[i]
        }
        return noErr
    }
}

private func playbackCallback(inRefCon: UnsafeMutableRawPointer,
                              ioActionFlags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
                              inTimeStamp: UnsafePointer<AudioTimeStamp>,
                              inBusNumber: UInt32,
                              inNumberFrames: UInt32,
                              ioData: UnsafeMutablePointer<AudioBufferList>?) -> OSStatus {
    let playback = Unmanaged<PlaybackUnit>.fromOpaque(inRefCon).takeUnretainedValue()
    return playback.render(frames: inNumberFrames, ioData: ioData)
}
