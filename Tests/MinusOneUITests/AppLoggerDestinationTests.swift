import XCTest
@testable import MinusOne

/// AppLogger's file destination must be isolated under XCTest so unit-test log lines never
/// land in the author's real ~/Library/Logs/MinusOne/MinusOne.log — the file the updater's
/// diagnosis depends on.
final class AppLoggerDestinationTests: XCTestCase {
    func testLogFileURLIsNotUnderRealLogsDirectory() {
        let realLogsDir = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs", isDirectory: true)
            .appendingPathComponent("MinusOne", isDirectory: true)

        XCTAssertFalse(
            AppLogger.shared.logFileURL.path.hasPrefix(realLogsDir.path),
            "test process must not log to \(realLogsDir.path), got \(AppLogger.shared.logFileURL.path)"
        )
    }

    func testWritingDoesNotTouchTheRealLogFile() throws {
        let realLogURL = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs", isDirectory: true)
            .appendingPathComponent("MinusOne", isDirectory: true)
            .appendingPathComponent("MinusOne.log")

        guard let before = try? FileManager.default.attributesOfItem(atPath: realLogURL.path) else {
            throw XCTSkip("No real log file at \(realLogURL.path) to compare against.")
        }

        AppLogger.shared.info("AppLoggerDestinationTests probe line — should never reach the real log")

        // Log writes are dispatched async onto a private serial queue; give it a moment.
        let expectation = XCTestExpectation(description: "log write settles")
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) { expectation.fulfill() }
        wait(for: [expectation], timeout: 1.0)

        let after = try? FileManager.default.attributesOfItem(atPath: realLogURL.path)
        XCTAssertEqual(before[.size] as? UInt64, after?[.size] as? UInt64, "real log file size must not change")
        XCTAssertEqual(
            before[.modificationDate] as? Date,
            after?[.modificationDate] as? Date,
            "real log file modification date must not change"
        )
    }
}
