import CAtomics
import Foundation

/// Lock-free rolling stereo buffer indexed by absolute sample position.
final class RollingStereoBuffer {
    let capacity: Int
    private let mask: Int
    private let left: UnsafeMutablePointer<Float>
    private let right: UnsafeMutablePointer<Float>
    private let totalWritten: UnsafeMutablePointer<mo_atomic_uint64_t>

    init(capacitySamples: Int) {
        let powerOfTwo = max(capacitySamples, 2).roundedUpToPowerOfTwo
        capacity = powerOfTwo
        mask = powerOfTwo - 1
        left = UnsafeMutablePointer<Float>.allocate(capacity: powerOfTwo)
        right = UnsafeMutablePointer<Float>.allocate(capacity: powerOfTwo)
        left.initialize(repeating: 0, count: powerOfTwo)
        right.initialize(repeating: 0, count: powerOfTwo)
        totalWritten = UnsafeMutablePointer<mo_atomic_uint64_t>.allocate(capacity: 1)
        mo_atomic_uint64_init(totalWritten, 0)
    }

    deinit {
        left.deinitialize(count: capacity)
        right.deinitialize(count: capacity)
        left.deallocate()
        right.deallocate()
        totalWritten.deallocate()
    }

    func reset() {
        mo_atomic_uint64_store(totalWritten, 0)
    }

    var writePosition: UInt64 {
        mo_atomic_uint64_load(totalWritten)
    }

    func write(left inputLeft: UnsafePointer<Float>, right inputRight: UnsafePointer<Float>, frameCount: Int) {
        var position = mo_atomic_uint64_load(totalWritten)
        for frame in 0..<frameCount {
            let slot = Int(position) & mask
            left[slot] = inputLeft[frame]
            right[slot] = inputRight[frame]
            position += 1
        }
        mo_atomic_uint64_store(totalWritten, position)
    }

    func read(
        atAbsolutePosition position: UInt64,
        left outputLeft: UnsafeMutablePointer<Float>,
        right outputRight: UnsafeMutablePointer<Float>,
        frameCount: Int
    ) {
        for frame in 0..<frameCount {
            let slot = Int(position + UInt64(frame)) & mask
            outputLeft[frame] = left[slot]
            outputRight[frame] = right[slot]
        }
    }

    func copyWindow(
        endingBefore endPosition: UInt64,
        length: Int,
        intoLeft outputLeft: UnsafeMutablePointer<Float>,
        intoRight outputRight: UnsafeMutablePointer<Float>
    ) {
        guard endPosition >= UInt64(length) else {
            outputLeft.update(repeating: 0, count: length)
            outputRight.update(repeating: 0, count: length)
            return
        }
        let start = endPosition - UInt64(length)
        for frame in 0..<length {
            let slot = Int(start + UInt64(frame)) & mask
            outputLeft[frame] = left[slot]
            outputRight[frame] = right[slot]
        }
    }

    func accumulate(
        left inputLeft: UnsafePointer<Float>,
        right inputRight: UnsafePointer<Float>,
        frameCount: Int,
        atAbsolutePosition startPosition: UInt64
    ) {
        for frame in 0..<frameCount {
            let slot = Int(startPosition + UInt64(frame)) & mask
            left[slot] += inputLeft[frame]
            right[slot] += inputRight[frame]
        }
    }

    func overwrite(
        left inputLeft: UnsafePointer<Float>,
        right inputRight: UnsafePointer<Float>,
        frameCount: Int,
        atAbsolutePosition startPosition: UInt64
    ) {
        for frame in 0..<frameCount {
            let slot = Int(startPosition + UInt64(frame)) & mask
            left[slot] = inputLeft[frame]
            right[slot] = inputRight[frame]
        }
    }

    func crossfadeThenOverwrite(
        left inputLeft: UnsafePointer<Float>,
        right inputRight: UnsafePointer<Float>,
        crossfadeLength: Int,
        overwriteLength: Int,
        atAbsolutePosition startPosition: UInt64
    ) {
        for frame in 0..<crossfadeLength {
            let blend = Float(frame) / Float(max(crossfadeLength - 1, 1))
            let slot = Int(startPosition + UInt64(frame)) & mask
            left[slot] = left[slot] * (1 - blend) + inputLeft[frame] * blend
            right[slot] = right[slot] * (1 - blend) + inputRight[frame] * blend
        }

        let overwriteStart = crossfadeLength
        for frame in 0..<overwriteLength {
            let slot = Int(startPosition + UInt64(overwriteStart + frame)) & mask
            left[slot] = inputLeft[overwriteStart + frame]
            right[slot] = inputRight[overwriteStart + frame]
        }
    }

    func clearSamples() {
        left.update(repeating: 0, count: capacity)
        right.update(repeating: 0, count: capacity)
    }
}
