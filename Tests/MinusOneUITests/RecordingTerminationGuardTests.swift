import AppKit
import XCTest
@testable import MinusOne

final class RecordingTerminationGuardTests: XCTestCase {
    func testNotRecordingTerminatesNowWithoutCallingOnSaved() {
        let guardObject = RecordingTerminationGuard()
        guardObject.isRecording = { false }
        guardObject.stopRecordingAndSave = { _ in
            XCTFail("should not save when nothing is recording")
        }

        let reply = guardObject.terminationReply {
            XCTFail("onSaved must not be called when nothing is recording")
        }

        XCTAssertEqual(reply, .terminateNow)
    }

    func testRecordingTerminatesLaterAndCallsOnSavedOnceAfterSaving() {
        let guardObject = RecordingTerminationGuard()
        guardObject.isRecording = { true }
        var finishSaving: (() -> Void)?
        guardObject.stopRecordingAndSave = { completion in
            finishSaving = completion
        }

        let expectation = expectation(description: "onSaved called")
        var onSavedCount = 0
        let reply = guardObject.terminationReply {
            onSavedCount += 1
            expectation.fulfill()
        }

        XCTAssertEqual(reply, .terminateLater)
        XCTAssertEqual(onSavedCount, 0, "onSaved must not fire before the save completes")

        finishSaving?()

        wait(for: [expectation], timeout: 1)
        XCTAssertEqual(onSavedCount, 1)
    }

    func testASaveThatNeverCompletesStillFiresOnSavedViaTimeout() {
        let guardObject = RecordingTerminationGuard()
        guardObject.isRecording = { true }
        guardObject.timeout = 0.2
        guardObject.stopRecordingAndSave = { _ in
            // never calls completion
        }

        let expectation = expectation(description: "onSaved called via timeout")
        var onSavedCount = 0
        let reply = guardObject.terminationReply {
            onSavedCount += 1
            expectation.fulfill()
        }

        XCTAssertEqual(reply, .terminateLater)
        wait(for: [expectation], timeout: 1)
        XCTAssertEqual(onSavedCount, 1)
    }

    func testASaveThatCompletesAfterTheTimeoutStillFiresOnSavedOnlyOnce() {
        let guardObject = RecordingTerminationGuard()
        guardObject.isRecording = { true }
        guardObject.timeout = 0.2
        var finishSaving: (() -> Void)?
        guardObject.stopRecordingAndSave = { completion in
            finishSaving = completion
        }

        let expectation = expectation(description: "onSaved called via timeout")
        var onSavedCount = 0
        _ = guardObject.terminationReply {
            onSavedCount += 1
            expectation.fulfill()
        }

        wait(for: [expectation], timeout: 1)
        XCTAssertEqual(onSavedCount, 1)

        // The save finally completes after the timeout already fired onSaved.
        finishSaving?()
        XCTAssertEqual(onSavedCount, 1, "onSaved must not fire a second time")
    }
}
