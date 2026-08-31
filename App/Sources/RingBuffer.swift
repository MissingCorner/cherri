import Foundation
import os.lock

/// Lock-protected mono float ring buffer. Writers block briefly on the lock;
/// readers zero-fill on underrun. Sized generously so meeting latency spikes
/// don't drop audio.
final class FloatRingBuffer {
    private var buffer: [Float]
    private var readIndex = 0
    private var writeIndex = 0
    private var count = 0
    private var lock = os_unfair_lock_s()

    init(capacity: Int) {
        buffer = [Float](repeating: 0, count: capacity)
    }

    var availableToRead: Int {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        return count
    }

    func reset() {
        os_unfair_lock_lock(&lock)
        readIndex = 0
        writeIndex = 0
        count = 0
        os_unfair_lock_unlock(&lock)
    }

    func write(_ samples: [Float]) {
        write(samples, count: samples.count)
    }

    func write(_ samples: UnsafePointer<Float>, count n: Int) {
        guard n > 0 else { return }
        os_unfair_lock_lock(&lock)
        let capacity = buffer.count
        // Drop oldest data if the writer is overrunning the reader.
        if count + n > capacity {
            let overflow = count + n - capacity
            readIndex = (readIndex + overflow) % capacity
            count -= overflow
        }
        var src = 0
        var remaining = min(n, capacity)
        while remaining > 0 {
            let chunk = min(remaining, capacity - writeIndex)
            buffer.withUnsafeMutableBufferPointer { dst in
                dst.baseAddress!.advanced(by: writeIndex).update(from: samples + src, count: chunk)
            }
            writeIndex = (writeIndex + chunk) % capacity
            src += chunk
            remaining -= chunk
        }
        count = min(count + n, capacity)
        os_unfair_lock_unlock(&lock)
    }

    /// Reads up to `n` samples; zero-fills the remainder. Returns the number of
    /// real samples delivered.
    @discardableResult
    func read(into output: UnsafeMutablePointer<Float>, count n: Int) -> Int {
        guard n > 0 else { return 0 }
        os_unfair_lock_lock(&lock)
        let capacity = buffer.count
        let toRead = min(n, count)
        var dst = 0
        var remaining = toRead
        while remaining > 0 {
            let chunk = min(remaining, capacity - readIndex)
            buffer.withUnsafeBufferPointer { src in
                (output + dst).update(from: src.baseAddress!.advanced(by: readIndex), count: chunk)
            }
            readIndex = (readIndex + chunk) % capacity
            dst += chunk
            remaining -= chunk
        }
        count -= toRead
        os_unfair_lock_unlock(&lock)
        if toRead < n {
            (output + toRead).update(repeating: 0, count: n - toRead)
        }
        return toRead
    }
}
