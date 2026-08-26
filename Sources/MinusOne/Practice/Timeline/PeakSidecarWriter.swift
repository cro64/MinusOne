import Foundation

/// Appends peak columns to a sidecar as audio becomes available.
///
/// `OfflineSeparationEngine` flushes on an overlap-add hop that is not a multiple of
/// `framesPerColumn`, so appends arrive at arbitrary lengths. The accumulator below carries a
/// partial column between calls and emits only whole ones; a short column written mid-stream would
/// shift every column after it, and the drift would compound silently for the rest of the file.
/// `finish()` is the only place a short column is allowed, because nothing follows it.
final class PeakSidecarWriter {
    private let handle: FileHandle
    private let framesPerColumn: Int

    private var pendingMinimum: Float = .greatestFiniteMagnitude
    private var pendingMaximum: Float = -.greatestFiniteMagnitude
    private var pendingSquareSum: Double = 0
    private var pendingCount = 0
    private var isClosed = false
    private var isFailed = false

    init(url: URL, sampleRate: Double, framesPerColumn: Int = PeakSidecar.defaultFramesPerColumn) throws {
        self.framesPerColumn = max(1, framesPerColumn)

        let header = PeakSidecar.Header(
            sampleRate: UInt32(max(1, sampleRate.rounded())),
            framesPerColumn: UInt32(self.framesPerColumn)
        )
        try PeakSidecar.encodeHeader(header).write(to: url, options: .atomic)

        handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
    }

    func append(_ samples: [Float]) throws {
        try append(samples[...])
    }

    func append(_ samples: ArraySlice<Float>) throws {
        guard !isClosed, !isFailed else { return }
        var buffer = Data()
        for sample in samples {
            pendingMinimum = Swift.min(pendingMinimum, sample)
            pendingMaximum = Swift.max(pendingMaximum, sample)
            pendingSquareSum += Double(sample) * Double(sample)
            pendingCount += 1
            if pendingCount == framesPerColumn {
                buffer.append(PeakSidecar.encodeColumn(pendingColumn()))
                resetPending()
            }
        }
        guard !buffer.isEmpty else { return }
        do {
            try handle.write(contentsOf: buffer)
        } catch {
            // Latch: a partial write leaves the file off a 6-byte column boundary. Continuing to
            // append would put every later column out of phase and compound the drift silently,
            // whereas refusing further appends leaves a cleanly short file — a state the format
            // already handles, since the column count comes from file length.
            isFailed = true
            throw error
        }
    }

    /// Flushes the trailing partial column and closes the file. Safe to call more than once.
    func finish() throws {
        guard !isClosed else { return }
        if !isFailed, pendingCount > 0 {
            try handle.write(contentsOf: PeakSidecar.encodeColumn(pendingColumn()))
            resetPending()
        }
        try handle.close()
        isClosed = true
    }

    private func pendingColumn() -> PeakColumn {
        guard pendingCount > 0 else { return .silent }
        return PeakColumn(
            minimum: pendingMinimum,
            maximum: pendingMaximum,
            rms: Float((pendingSquareSum / Double(pendingCount)).squareRoot())
        )
    }

    private func resetPending() {
        pendingMinimum = .greatestFiniteMagnitude
        pendingMaximum = -.greatestFiniteMagnitude
        pendingSquareSum = 0
        pendingCount = 0
    }

    /// Backstop for callers that throw before reaching `finish()` — `OfflineSeparationEngine`'s
    /// finish loop sits after its separation loop, so any error inside skips it for all four
    /// writers. `FileHandle` closing on deinit is not a documented contract, so this is explicit.
    deinit {
        if !isClosed {
            try? handle.close()
        }
    }
}
