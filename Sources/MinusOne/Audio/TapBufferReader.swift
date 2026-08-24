import AVFoundation

/// Reads a CoreAudio IO callback's buffer list as stereo float.
///
/// Both capture paths hit the same two problems — a tap buffer that reports `frameLength == 0`,
/// and a format that may be interleaved, planar stereo, or planar mono — and both used to solve
/// them with their own private copy of this code: `AudioEngine.tapFrameCount`/`extractStereoFloat`
/// and `ClipRecorder.frameCount`/`extractStereoFloat`. The bodies were byte-identical, so a fix to
/// either (a new channel layout, a different mono policy) silently applied to one capture path and
/// not the other.
enum TapBufferReader {
    /// Frames actually present in `buffer`.
    ///
    /// A tap's `AVAudioPCMBuffer` built with `bufferListNoCopy:` doesn't always carry a frame
    /// length, so the byte count is the fallback source of truth.
    static func frameCount(for buffer: AVAudioPCMBuffer, format: AVAudioFormat) -> Int {
        if buffer.frameLength > 0 {
            return Int(buffer.frameLength)
        }

        let buffers = UnsafeMutableAudioBufferListPointer(
            UnsafeMutablePointer(mutating: buffer.audioBufferList)
        )
        guard let first = buffers.first, first.mDataByteSize > 0 else { return 0 }
        let channels = max(Int(format.channelCount), 1)
        return Int(first.mDataByteSize) / (MemoryLayout<Float>.size * channels)
    }

    /// De-interleaves (or copies) `frameCount` frames into `left`/`right`, which must each have
    /// room for that many samples. A mono source is duplicated to both sides rather than left
    /// half-silent. Returns `false` if the buffer exposes no sample data to read.
    static func extractStereoFloat(
        from buffer: AVAudioPCMBuffer,
        format: AVAudioFormat,
        left: UnsafeMutablePointer<Float>,
        right: UnsafeMutablePointer<Float>,
        frameCount: Int
    ) -> Bool {
        if format.isInterleaved {
            guard let data = buffer.audioBufferList.pointee.mBuffers.mData else { return false }
            let samples = data.assumingMemoryBound(to: Float.self)
            for frame in 0..<frameCount {
                left[frame] = samples[frame * 2]
                right[frame] = samples[frame * 2 + 1]
            }
            return true
        }

        guard let channels = buffer.floatChannelData else { return false }
        if format.channelCount >= 2 {
            left.update(from: channels[0], count: frameCount)
            right.update(from: channels[1], count: frameCount)
            return true
        }

        left.update(from: channels[0], count: frameCount)
        for frame in 0..<frameCount {
            right[frame] = channels[0][frame]
        }
        return true
    }
}
