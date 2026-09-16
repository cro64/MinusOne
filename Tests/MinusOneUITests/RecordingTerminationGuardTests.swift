import AppKit
import XCTest
@testable import MinusOne

final class RecordingTerminationGuardTests: XCTestCase {
    func testNotRecordingTerminatesNowWithoutCallingOnSavedOrAsking() {
        let guardObject = RecordingTerminationGuard()
        guardObject.isRecording = { false }
        guardObject.askToStopRecording = {
            XCTFail("should not ask when nothing is recording")
            return true
        }
        guardObject.stopRecordingAndSave = { _ in
            XCTFail("should not save when nothing is recording")
        }

        let reply = guardObject.terminationReply {
            XCTFail("onSaved must not be called when nothing is recording")
        }

        XCTAssertEqual(reply, .terminateNow)
    }

    func testRecordingAndCancellingQuitReturnsTerminateCancelWithoutSaving() {
        let guardObject = RecordingTerminationGuard()
        guardObject.isRecording = { true }
        guardObject.askToStopRecording = { false }
        guardObject.stopRecordingAndSave = { _ in
            XCTFail("should not save when the quit is cancelled")
        }

        let reply = guardObject.terminationReply {
            XCTFail("onSaved must not be called when the quit is cancelled")
        }

        XCTAssertEqual(reply, .terminateCancel)
    }

    func testRecordingTerminatesLaterAndCallsOnSavedOnceAfterSaving() {
        let guardObject = RecordingTerminationGuard()
        guardObject.isRecording = { true }
        guardObject.askToStopRecording = { true }
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
        guardObject.askToStopRecording = { true }
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
        guardObject.askToStopRecording = { true }
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

    /// A synchronous `stopRecordingAndSave` completion must never run `onSaved` before
    /// `terminationReply` has returned `.terminateLater` to the caller — replying to AppKit before
    /// that return can hang the quit.
    func testSynchronousSaveDoesNotCallOnSavedBeforeReturning() {
        let guardObject = RecordingTerminationGuard()
        guardObject.isRecording = { true }
        guardObject.askToStopRecording = { true }
        guardObject.stopRecordingAndSave = { completion in
            completion()
        }

        let expectation = expectation(description: "onSaved called")
        var onSavedCount = 0
        let reply = guardObject.terminationReply {
            onSavedCount += 1
            expectation.fulfill()
        }
        let onSavedCountRightAfterReturning = onSavedCount

        XCTAssertEqual(reply, .terminateLater)
        XCTAssertEqual(onSavedCountRightAfterReturning, 0, "onSaved must not fire before terminationReply returns")

        wait(for: [expectation], timeout: 1)
        XCTAssertEqual(onSavedCount, 1)
    }
}
