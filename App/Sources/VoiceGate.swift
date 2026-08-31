import Foundation

/// Energy-based voice-activity gate. Audio is only forwarded to the (billed)
/// API stream while speech is detected:
///
/// - Opens when the level exceeds `openThresholdDb`.
/// - Stays open with a ~0.9 s hangover after the level drops, so it doesn't
///   chop between words.
/// - While closed it keeps a 350 ms pre-roll ring; the ring is flushed when
///   the gate opens so word onsets aren't clipped.
///
/// Called only from one audio thread; `levelDb`/`isOpen` are word-sized and
/// safe to read from elsewhere for UI.
final class VoiceGate {
    private let sampleRate: Double
    private let openThresholdDb: Float = -40
    private let closeThresholdDb: Float = -46
    private let hangoverSeconds = 0.9
    private let preRollSeconds = 0.35

    private var preRoll: [Float] = []
    private let preRollMax: Int
    private var hangoverRemaining = 0

    private(set) var isOpen = false
    private(set) var levelDb: Float = -80

    init(sampleRate: Double) {
        self.sampleRate = sampleRate
        self.preRollMax = Int(sampleRate * preRollSeconds)
        preRoll.reserveCapacity(preRollMax + 4096)
    }

    private static func rmsDb(_ samples: UnsafePointer<Float>, count: Int) -> Float {
        guard count > 0 else { return -80 }
        var sum: Float = 0
        for i in 0..<count {
            sum += samples[i] * samples[i]
        }
        let rms = (sum / Float(count)).squareRoot()
        return max(20 * log10(max(rms, 1e-6)), -80)
    }

    /// Updates the level meter without gating (used when the gate is off).
    func measure(_ samples: UnsafePointer<Float>, count: Int) {
        levelDb = Self.rmsDb(samples, count: count)
    }

    /// Returns the samples to stream (including flushed pre-roll on gate
    /// open), or nil while gated shut.
    func process(_ samples: UnsafePointer<Float>, count: Int) -> [Float]? {
        levelDb = Self.rmsDb(samples, count: count)

        if levelDb > openThresholdDb {
            hangoverRemaining = Int(hangoverSeconds * sampleRate)
            if !isOpen {
                isOpen = true
                var out = preRoll
                out.append(contentsOf: UnsafeBufferPointer(start: samples, count: count))
                preRoll.removeAll(keepingCapacity: true)
                return out
            }
            return [Float](UnsafeBufferPointer(start: samples, count: count))
        }

        if isOpen {
            if levelDb > closeThresholdDb {
                hangoverRemaining = Int(hangoverSeconds * sampleRate)
            } else {
                hangoverRemaining -= count
            }
            if hangoverRemaining > 0 {
                return [Float](UnsafeBufferPointer(start: samples, count: count))
            }
            isOpen = false
        }

        // Closed: keep the most recent pre-roll worth of audio.
        preRoll.append(contentsOf: UnsafeBufferPointer(start: samples, count: count))
        if preRoll.count > preRollMax {
            preRoll.removeFirst(preRoll.count - preRollMax)
        }
        return nil
    }
}
