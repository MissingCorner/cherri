import AVFoundation
import Foundation

/// Renders a short prompt to PCM16 mono 24 kHz audio using the Mac's built-in
/// speech synthesis (offline — nothing is played out loud). Used to "brief"
/// the interpreter model by voice before live audio is fed in.
final class SpokenPromptGenerator: NSObject, AVSpeechSynthesizerDelegate, @unchecked Sendable {
    private let synthesizer = AVSpeechSynthesizer()
    private var samples: [Float] = []
    private var sourceRate: Double = 22050
    private var completion: ((Data?) -> Void)?
    private var finished = false
    private let lock = NSLock()

    /// Retains in-flight generators until their callbacks fire.
    private static var active: [SpokenPromptGenerator] = []
    private static let activeLock = NSLock()

    static func generate(text: String, completion: @escaping (Data?) -> Void) {
        let generator = SpokenPromptGenerator()
        activeLock.lock()
        active.append(generator)
        activeLock.unlock()
        generator.run(text: text) { data in
            completion(data)
            activeLock.lock()
            active.removeAll { $0 === generator }
            activeLock.unlock()
        }
    }

    /// Blocking variant for callers on a background thread. MUST NOT be
    /// called on the main thread — synthesis itself runs there.
    static func generateSync(text: String, timeout: TimeInterval = 10) -> Data? {
        assert(!Thread.isMainThread, "generateSync would deadlock on the main thread")
        guard !Thread.isMainThread else { return nil }
        let semaphore = DispatchSemaphore(value: 0)
        var result: Data?
        generate(text: text) { data in
            result = data
            semaphore.signal()
        }
        _ = semaphore.wait(timeout: .now() + timeout)
        return result
    }

    private func run(text: String, completion: @escaping (Data?) -> Void) {
        self.completion = completion

        // Speech synthesis needs a run loop; keep it on the main thread.
        DispatchQueue.main.async { [self] in
            synthesizer.delegate = self

            let utterance = AVSpeechUtterance(string: text)
            utterance.voice = AVSpeechSynthesisVoice(language: "en-US")
            utterance.rate = AVSpeechUtteranceDefaultSpeechRate

            synthesizer.write(utterance) { [weak self] buffer in
                self?.consume(buffer)
            }
        }

        // Safety net: never leave the caller hanging if synthesis stalls.
        DispatchQueue.global().asyncAfter(deadline: .now() + 15) { [weak self] in
            self?.finish()
        }
    }

    private func consume(_ buffer: AVAudioBuffer) {
        guard let pcm = buffer as? AVAudioPCMBuffer else { return }
        if pcm.frameLength == 0 {
            finish()
            return
        }
        sourceRate = pcm.format.sampleRate
        let frames = Int(pcm.frameLength)
        lock.lock()
        if let floatData = pcm.floatChannelData {
            samples.append(contentsOf: UnsafeBufferPointer(start: floatData[0], count: frames))
        } else if let intData = pcm.int16ChannelData {
            let src = UnsafeBufferPointer(start: intData[0], count: frames)
            samples.append(contentsOf: src.map { Float($0) / 32768.0 })
        }
        lock.unlock()
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        finish()
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        finish()
    }

    private func finish() {
        lock.lock()
        if finished {
            lock.unlock()
            return
        }
        finished = true
        let collected = samples
        let rate = sourceRate
        let done = completion
        completion = nil
        lock.unlock()

        guard let done else { return }
        guard !collected.isEmpty else {
            done(nil)
            return
        }
        let resampler = StreamResampler(sourceRate: rate, targetRate: 24000)
        let at24k = resampler.process(collected)
        var data = PCM.floatToPCM16(at24k)
        // Trailing silence so server-side VAD sees the end of the utterance.
        data.append(Data(count: Int(24000 * 0.8) * 2))
        done(data)
    }
}
