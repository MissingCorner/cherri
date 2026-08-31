import Foundation

/// Streaming polyphase windowed-sinc resampler (mono). Unlike linear
/// interpolation, this low-pass filters properly, so downsampling (e.g.
/// 48 kHz → 24 kHz for the API) doesn't alias high-frequency content into
/// the speech band. 32 taps × 128 phases is transparent for speech at
/// negligible CPU cost.
final class StreamResampler {
    private let ratio: Double        // source samples advanced per output sample
    private let taps: Int
    private let phases: Int
    private let center: Int
    private var table: [Float]       // phases rows × taps coefficients
    private var buffer: [Float] = [] // history + pending source samples
    private var position: Double     // fractional read index into `buffer`
    private var primed = false

    init(sourceRate: Double, targetRate: Double, taps requestedTaps: Int? = nil, phases: Int = 128) {
        self.ratio = sourceRate / targetRate
        // Heavier decimation needs a longer filter to keep the anti-aliasing
        // transition band narrow (e.g. 48k->16k would alias with 32 taps).
        let taps = requestedTaps ?? max(32, Int((sourceRate / targetRate).rounded(.up)) * 16)
        self.taps = taps
        self.phases = phases
        self.center = taps / 2 - 1
        self.position = Double(taps / 2 - 1)

        // Cutoff at 90% of the narrower Nyquist, in cycles per source sample.
        let fc = 0.45 * min(1.0, targetRate / sourceRate)
        table = [Float](repeating: 0, count: phases * taps)
        for p in 0..<phases {
            let frac = Double(p) / Double(phases)
            var row = [Double](repeating: 0, count: taps)
            var sum = 0.0
            for k in 0..<taps {
                let n = Double(k - center) - frac
                let x = 2.0 * fc * n
                let sinc = x == 0 ? 1.0 : sin(.pi * x) / (.pi * x)
                // Blackman window across the tap span.
                let t = min(max((Double(k) - frac) / Double(taps - 1), 0), 1)
                let window = 0.42 - 0.5 * cos(2 * .pi * t) + 0.08 * cos(4 * .pi * t)
                row[k] = 2.0 * fc * sinc * window
                sum += row[k]
            }
            // Normalize DC gain to 1 so levels are preserved.
            for k in 0..<taps where sum != 0 {
                table[p * taps + k] = Float(row[k] / sum)
            }
        }
    }

    func process(_ input: [Float]) -> [Float] {
        input.withUnsafeBufferPointer { buf in
            process(buf.baseAddress!, count: buf.count)
        }
    }

    func process(_ input: UnsafePointer<Float>, count: Int) -> [Float] {
        guard count > 0 else { return [] }
        if !primed {
            // Pre-fill history with the first sample to avoid a start click.
            buffer = [Float](repeating: input[0], count: taps)
            primed = true
        }
        buffer.append(contentsOf: UnsafeBufferPointer(start: input, count: count))

        var output: [Float] = []
        output.reserveCapacity(Int(Double(count) / ratio) + 2)

        // The convolution window for output at source-time T spans
        // [floor(T) - center, floor(T) - center + taps - 1].
        while true {
            let i = Int(position.rounded(.down))
            let start = i - center
            guard start + taps <= buffer.count else { break }
            let frac = position - Double(i)
            let phase = min(Int(frac * Double(phases)), phases - 1)

            var acc: Float = 0
            table.withUnsafeBufferPointer { tbl in
                buffer.withUnsafeBufferPointer { src in
                    let coeffs = tbl.baseAddress! + phase * taps
                    let samples = src.baseAddress! + start
                    for k in 0..<taps {
                        acc += samples[k] * coeffs[k]
                    }
                }
            }
            output.append(acc)
            position += ratio
        }

        // Drop consumed samples, keeping enough history for the next window.
        let drop = min(Int(position.rounded(.down)) - center, buffer.count)
        if drop > 0 {
            buffer.removeFirst(drop)
            position -= Double(drop)
        }
        return output
    }

    func reset() {
        buffer.removeAll()
        position = Double(taps / 2 - 1)
        primed = false
    }
}

enum PCM {
    /// Float32 mono [-1, 1] -> little-endian PCM16 bytes.
    static func floatToPCM16(_ samples: [Float]) -> Data {
        var data = Data(capacity: samples.count * 2)
        for sample in samples {
            let clamped = max(-1.0, min(1.0, sample))
            let value = Int16(clamped * 32767.0)
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }
        return data
    }

    /// Little-endian PCM16 bytes -> Float32 mono.
    static func pcm16ToFloat(_ data: Data) -> [Float] {
        let sampleCount = data.count / 2
        var samples = [Float](repeating: 0, count: sampleCount)
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            for i in 0..<sampleCount {
                let lo = UInt16(raw[i * 2])
                let hi = UInt16(raw[i * 2 + 1])
                let value = Int16(bitPattern: (hi << 8) | lo)
                samples[i] = Float(value) / 32768.0
            }
        }
        return samples
    }
}
