import XCTest
@testable import MinusOne

final class UnfinishedSeparationsTests: XCTestCase {
    private func makeClip(
        title: String,
        durationSeconds: Double = 10,
        readyDurationSeconds: Double,
        processingFailed: Bool = false,
        sourceFileName: String = "source.wav"
    ) -> PracticeClip {
        PracticeClip(
            title: title,
            durationSeconds: durationSeconds,
            sourceHash: title,
            sourceFileName: sourceFileName,
            waveformPeaks: [],
            readyDurationSeconds: readyDurationSeconds,
            processingFailed: processingFailed
        )
    }

    func testFullyProcessedClipIsExcluded() {
        let clip = makeClip(title: "Done", readyDurationSeconds: 10)
        XCTAssertEqual(UnfinishedSeparations.needingResume([clip]), [])
    }

    func testFailedClipIsExcluded() {
        let clip = makeClip(title: "Failed", readyDurationSeconds: 2, processingFailed: true)
        XCTAssertEqual(UnfinishedSeparations.needingResume([clip]), [])
    }

    func testClipWithNoSourceFileNameIsExcluded() {
        let clip = makeClip(title: "NoSource", readyDurationSeconds: 2, sourceFileName: "")
        XCTAssertEqual(UnfinishedSeparations.needingResume([clip]), [])
    }

    func testUnfinishedClipIsIncluded() {
        let clip = makeClip(title: "Unfinished", readyDurationSeconds: 0)
        XCTAssertEqual(UnfinishedSeparations.needingResume([clip]), [clip])
    }

    func testOnlyGenuinelyUnfinishedClipsComeBackAndOrderIsPreserved() {
        let done = makeClip(title: "Done", readyDurationSeconds: 10)
        let failed = makeClip(title: "Failed", readyDurationSeconds: 2, processingFailed: true)
        let noSource = makeClip(title: "NoSource", readyDurationSeconds: 2, sourceFileName: "")
        let unfinishedA = makeClip(title: "UnfinishedA", readyDurationSeconds: 0)
        let unfinishedB = makeClip(title: "UnfinishedB", readyDurationSeconds: 4)

        let result = UnfinishedSeparations.needingResume([done, unfinishedA, failed, unfinishedB, noSource])

        XCTAssertEqual(result, [unfinishedA, unfinishedB])
    }
}
