import Foundation

/// Persistent index of Practice Mode clips, backed by a JSON file under Application Support.
/// Each clip's copied source audio and separated stem files live in their own subfolder.
final class ClipLibraryStore {
    private let queue = DispatchQueue(label: "com.minusone.app.practice-library")
    private let fileManager = FileManager.default
    private let libraryRootURL: URL
    private let indexURL: URL
    private var clipsByID: [UUID: PracticeClip] = [:]

    /// How `trash(_:)` disposes of a clip's folder. The Trash by default; tests swap in a plain
    /// delete so they do not leave folders in the real one.
    var disposeOfFolder: (URL) throws -> Void = { url in
        try FileManager.default.trashItem(at: url, resultingItemURL: nil)
    }

    init(rootURL: URL? = nil) {
        let resolvedRoot = rootURL ?? Self.defaultRootURL()
        libraryRootURL = resolvedRoot
        indexURL = resolvedRoot.appendingPathComponent("index.json")
        try? fileManager.createDirectory(at: clipsDirectory, withIntermediateDirectories: true)
        clipsByID = Self.loadIndex(at: indexURL)
    }

    private static func defaultRootURL() -> URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return appSupport.appendingPathComponent("MinusOne", isDirectory: true).appendingPathComponent("Library", isDirectory: true)
    }

    private var clipsDirectory: URL {
        libraryRootURL.appendingPathComponent("Clips", isDirectory: true)
    }

    // MARK: - Query

    func all() -> [PracticeClip] {
        queue.sync { Array(clipsByID.values).sorted { $0.createdAt > $1.createdAt } }
    }

    func clip(withID id: UUID) -> PracticeClip? {
        queue.sync { clipsByID[id] }
    }

    func clip(forSourceHash hash: String) -> PracticeClip? {
        queue.sync { clipsByID.values.first { $0.sourceHash == hash } }
    }

    // MARK: - Mutation

    func add(_ clip: PracticeClip) {
        queue.sync {
            clipsByID[clip.id] = clip
            persist()
        }
    }

    func update(_ clip: PracticeClip) {
        queue.sync {
            clipsByID[clip.id] = clip
            persist()
        }
    }

    /// `update` for work that outlives the moment it started — separation, peak backfill. A clip
    /// that is no longer in the library was deleted meanwhile, and writing it back would resurrect
    /// it as an entry with no files, so this ignores it.
    func updateExisting(_ clip: PracticeClip) {
        queue.sync {
            guard clipsByID[clip.id] != nil else { return }
            clipsByID[clip.id] = clip
            persist()
        }
    }

    /// Renames a clip in place. Returns the updated clip, or `nil` if the id is unknown or the
    /// new title is blank — a rename that would leave a clip with no name is treated as a
    /// cancellation, since the title is the only thing identifying it in the sidebar.
    @discardableResult
    func rename(id: UUID, to title: String) -> PracticeClip? {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return queue.sync {
            guard var clip = clipsByID[id], clip.title != trimmed else { return clipsByID[id] }
            clip.title = trimmed
            clipsByID[id] = clip
            persist()
            return clip
        }
    }

    func remove(_ id: UUID) {
        queue.sync {
            clipsByID.removeValue(forKey: id)
            persist()
            try? fileManager.removeItem(at: folder(forClipID: id))
        }
    }

    /// Removes a clip from the library and moves its folder to the Trash, so a delete can be undone
    /// from Finder. Falls back to deleting the folder if it can't be trashed.
    func trash(_ id: UUID) {
        queue.sync {
            clipsByID.removeValue(forKey: id)
            persist()
            let folder = folder(forClipID: id)
            guard fileManager.fileExists(atPath: folder.path) else { return }
            do {
                try disposeOfFolder(folder)
            } catch {
                try? fileManager.removeItem(at: folder)
            }
        }
    }

    // MARK: - File locations

    func folder(forClipID id: UUID) -> URL {
        clipsDirectory.appendingPathComponent(id.uuidString, isDirectory: true)
    }

    func ensureFolder(forClipID id: UUID) throws -> URL {
        let url = folder(forClipID: id)
        try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func stemFileURL(clipID: UUID, fileName: String) -> URL {
        folder(forClipID: clipID).appendingPathComponent(fileName)
    }

    /// Peak sidecars live in their own subfolder so a clip folder listing stays readable, and so
    /// the whole set can be deleted and regenerated without touching audio.
    func peaksFolder(forClipID id: UUID) -> URL {
        folder(forClipID: id).appendingPathComponent("peaks", isDirectory: true)
    }

    func ensurePeaksFolder(forClipID id: UUID) throws -> URL {
        let url = peaksFolder(forClipID: id)
        try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func peakFileURL(clipID: UUID, track: PeakTrack) -> URL {
        peaksFolder(forClipID: clipID).appendingPathComponent(track.fileName)
    }

    // MARK: - Persistence

    private func persist() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        do {
            let data = try encoder.encode(Array(clipsByID.values))
            try data.write(to: indexURL, options: .atomic)
        } catch {
            AppLogger.shared.error("Failed to persist Practice library index: \(error.localizedDescription)")
        }
    }

    /// Missing index file is a normal first launch and stays silent. A file that exists but
    /// fails to decode is corruption, and starting from an empty library without logging it
    /// would hide the fact that every clip just vanished from the sidebar.
    private static func loadIndex(at url: URL) -> [UUID: PracticeClip] {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return [:]
        } catch {
            AppLogger.shared.error("Failed to read Practice library index: \(error.localizedDescription)")
            return [:]
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            let clips = try decoder.decode([PracticeClip].self, from: data)
            return Dictionary(uniqueKeysWithValues: clips.map { ($0.id, $0) })
        } catch {
            AppLogger.shared.error("Failed to decode Practice library index; starting from an empty library: \(error.localizedDescription)")
            return [:]
        }
    }
}
