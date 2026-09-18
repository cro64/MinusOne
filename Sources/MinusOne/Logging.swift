import Foundation
import os

final class AppLogger {
    static let shared = AppLogger()

    private let logger = Logger(subsystem: "com.minusone.app", category: "MinusOne")
    private let queue = DispatchQueue(label: "com.minusone.app.log-file")

    /// Where log lines are appended. Unit tests exercise real logging code paths (e.g.
    /// UpdateController, RecordingTerminationGuard, ClipImportService all log through
    /// AppLogger.shared), and their lines used to land in the author's real
    /// ~/Library/Logs/MinusOne/MinusOne.log — the same file the updater's diagnosis depends
    /// on — which made that log misleading. When running under XCTest, write to a scratch file
    /// in the temp directory instead; otherwise behave exactly as before. `internal` (not
    /// private) so tests can assert on it.
    let logFileURL: URL

    private init() {
        if NSClassFromString("XCTestCase") != nil {
            logFileURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("MinusOne-tests.log")
        } else {
            let baseURL = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Logs", isDirectory: true)
                .appendingPathComponent("MinusOne", isDirectory: true)
            try? FileManager.default.createDirectory(at: baseURL, withIntermediateDirectories: true)
            logFileURL = baseURL.appendingPathComponent("MinusOne.log")
        }
    }

    func info(_ message: String) {
        logger.info("\(message, privacy: .public)")
        append("INFO", message)
    }

    func warning(_ message: String) {
        logger.warning("\(message, privacy: .public)")
        append("WARN", message)
    }

    func error(_ message: String) {
        logger.error("\(message, privacy: .public)")
        append("ERROR", message)
    }

    private func append(_ level: String, _ message: String) {
        queue.async { [logFileURL] in
            let line = "\(Self.timestamp()) [\(level)] \(message)\n"
            guard let data = line.data(using: .utf8) else { return }

            if FileManager.default.fileExists(atPath: logFileURL.path) {
                if let handle = try? FileHandle(forWritingTo: logFileURL) {
                    _ = try? handle.seekToEnd()
                    try? handle.write(contentsOf: data)
                    try? handle.close()
                }
            } else {
                try? data.write(to: logFileURL, options: .atomic)
            }
        }
    }

    private static func timestamp() -> String {
        ISO8601DateFormatter().string(from: Date())
    }
}
