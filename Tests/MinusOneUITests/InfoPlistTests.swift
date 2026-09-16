import XCTest

/// The updater's settings live in Info.plist, where a typo fails silently: a wrong feed URL or a
/// missing key only shows up when an update never arrives.
final class InfoPlistTests: XCTestCase {
    private func plist() throws -> [String: Any] {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // MinusOneUITests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // repo root
            .appendingPathComponent("Resources/Info.plist")
        let data = try Data(contentsOf: url)
        return try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
    }

    func testTheFeedIsTheLatestReleasesAppcast() throws {
        XCTAssertEqual(try plist()["SUFeedURL"] as? String,
                       "https://github.com/cro64/MinusOne/releases/latest/download/appcast.xml")
    }

    /// An Ed25519 public key is 32 bytes; Sparkle stores it base64-encoded.
    func testThePublicKeyIsAnEd25519Key() throws {
        let key = try XCTUnwrap(try plist()["SUPublicEDKey"] as? String, "SUPublicEDKey missing")
        let bytes = try XCTUnwrap(Data(base64Encoded: key), "SUPublicEDKey isn't base64")
        XCTAssertEqual(bytes.count, 32)
    }

    func testChecksRunAutomaticallyOnceADay() throws {
        let plist = try plist()
        XCTAssertEqual(plist["SUEnableAutomaticChecks"] as? Bool, true)
        XCTAssertEqual(plist["SUScheduledCheckInterval"] as? Int, 86400)
    }

    /// A silent install (Sparkle's own "automatically download and install" checkbox, which can be
    /// persisted into the host's user defaults from an earlier session) bypasses both the menu bar
    /// badge and the "Finish recording before updating?" guard. This key stops Sparkle from ever
    /// installing without the user explicitly choosing Install Update.
    func testAutomaticUpdatesAreDisallowed() throws {
        XCTAssertEqual(try plist()["SUAllowsAutomaticUpdates"] as? Bool, false)
    }
}
