import AppKit
import XCTest
@testable import MinusOne

final class ClipDeleteTests: XCTestCase {
    private var root: URL!
    private var store: ClipLibraryStore!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClipDelete-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        store = ClipLibraryStore(rootURL: root)
        store.disposeOfFolder = { try FileManager.default.removeItem(at: $0) }
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func addClip() throws -> PracticeClip {
        let clip = PracticeClip(title: "Doomed", durationSeconds: 10, sourceHash: UUID().uuidString,
                                sourceFileName: "source.caf", waveformPeaks: [Float](repeating: 0.5, count: 8))
        store.add(clip)
        let folder = try store.ensureFolder(forClipID: clip.id)
        try Data([1, 2, 3]).write(to: folder.appendingPathComponent("source.caf"))
        return clip
    }

    func testTrashRemovesTheClipAndItsFolder() throws {
        let clip = try addClip()
        store.trash(clip.id)
        XCTAssertNil(store.clip(withID: clip.id))
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.folder(forClipID: clip.id).path))
    }

    /// A separation still running when the clip is deleted reports back through this path; it must
    /// not put the clip back in the library.
    func testALateBackgroundUpdateDoesNotResurrectADeletedClip() throws {
        var clip = try addClip()
        store.trash(clip.id)
        clip.readyDurationSeconds = 5
        store.updateExisting(clip)
        XCTAssertNil(store.clip(withID: clip.id))
        XCTAssertTrue(store.all().isEmpty)
    }

    func testTheSidebarDropsTheRowAndTellsTheDeck() throws {
        let clip = try addClip()
        let sidebar = ClipSidebarViewController(libraryStore: store)
        sidebar.loadView()
        sidebar.reloadClips()
        var deleted: UUID?
        sidebar.onDeleteClip = { deleted = $0 }

        sidebar.deleteClip(id: clip.id)

        XCTAssertEqual(deleted, clip.id)
        XCTAssertNil(store.clip(withID: clip.id))
    }

    func testTheContextMenuOffersRenameShowInFinderAndDelete() throws {
        _ = try addClip()
        let sidebar = ClipSidebarViewController(libraryStore: store)
        sidebar.loadView()
        sidebar.reloadClips()
        let menu = sidebar.menuForTesting(row: 0)
        XCTAssertEqual(menu.items.filter { !$0.isSeparatorItem }.map(\.title), ["Rename…", "Show in Finder", "Delete"])
    }
}
