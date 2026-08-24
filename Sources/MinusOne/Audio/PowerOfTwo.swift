import Foundation

extension Int {
    /// The smallest power of two greater than or equal to `self` (never below 1).
    ///
    /// The audio buffers wrap their read/write indices with a bitmask rather than a modulus, which
    /// only works on a power-of-two capacity — so each of them has to round its requested size up.
    /// `RollingStereoBuffer` and `StereoDelayLine` each had their own identical `nextPowerOfTwo`;
    /// `StereoRingBuffer` instead `precondition`s that its caller already did the rounding.
    var roundedUpToPowerOfTwo: Int {
        var result = 1
        while result < self {
            result <<= 1
        }
        return result
    }
}
