import Foundation

/// Fixed-length delay line for matching raw-path latency to the separated stream.
final class StereoDelayLine {
    private let capacity: Int
    private let mask: Int
    private let maxDelaySamples: Int
    private let left: UnsafeMutablePointer<Float>
    private let right: UnsafeMutablePointer<Float>
    private var writeIndex: Int
    private var framesProcessed: UInt64

    init(requiredDelaySamples: Int, headroomSamples: Int = 0) {
        maxDelaySamples = requiredDelaySamples
        let powerOfTwo = max(requiredDelaySamples + headroomSamples + 1, 2).roundedUpToPowerOfTwo
        capacity = powerOfTwo
        mask = powerOfTwo - 1
        left = UnsafeMutablePointer<Float>.allocate(capacity: capacity)
        right = UnsafeMutablePointer<Float>.allocate(capacity: capacity)
        left.initialize(repeating: 0, count: capacity)
        right.initialize(repeating: 0, count: capacity)
        writeIndex = requiredDelaySamples
        framesProcessed = 0
    }

    deinit {
        left.deinitialize(count: capacity)
        right.deinitialize(count: capacity)
        left.deallocate()
        right.deallocate()
    }

    func reset() {
        writeIndex = maxDelaySamples
        framesProcessed = 0
        left.update(repeating: 0, count: capacity)
        right.update(repeating: 0, count: capacity)
    }

    func isDelayReady(delaySamples: Int) -> Bool {
        framesProcessed >= UInt64(delaySamples)
    }

    func process(
        inputLeft: UnsafePointer<Float>,
        inputRight: UnsafePointer<Float>,
        outputLeft: UnsafeMutablePointer<Float>,
        outputRight: UnsafeMutablePointer<Float>,
        frameCount: Int,
        delaySamples: Int
    ) {
        guard delaySamples > 0 else {
            outputLeft.update(from: inputLeft, count: frameCount)
            outputRight.update(from: inputRight, count: frameCount)
            return
        }

        for frame in 0..<frameCount {
            let writeSlot = writeIndex & mask
            left[writeSlot] = inputLeft[frame]
            right[writeSlot] = inputRight[frame]

            let readIndex = writeIndex - delaySamples
            if readIndex < 0 {
                outputLeft[frame] = 0
                outputRight[frame] = 0
            } else {
                let readSlot = readIndex & mask
                outputLeft[frame] = left[readSlot]
                outputRight[frame] = right[readSlot]
            }
            writeIndex += 1
        }
        framesProcessed += UInt64(frameCount)
    }
}
