import AppKit
import CoreAudio
import Foundation

struct AudioClientProcess: Identifiable, Equatable, Hashable {
    let objectID: AudioObjectID
    let pid: pid_t
    let bundleID: String
    let displayName: String
    let isRunningOutput: Bool

    var id: String { bundleID }
}

@available(macOS 14.2, *)
enum AudioProcessEnumerator {
    static let ownBundleID = "com.minusone.app"

    /// Apps shown in the picker — all running user apps, enriched with CoreAudio process info when available.
    static func processesForAppPicker(includingSelected selectedBundleIDs: Set<String>) -> [AudioClientProcess] {
        let audioByBundleID = Dictionary(
            uniqueKeysWithValues: deduplicatedProcesses(
                from: allProcesses().filter { $0.bundleID != ownBundleID }
            ).map { ($0.bundleID, $0) }
        )

        var results: [AudioClientProcess] = []
        var seen = Set<String>()

        func append(bundleID: String, name: String?, pid: pid_t) {
            guard bundleID != ownBundleID, seen.insert(bundleID).inserted else { return }
            if let audioProcess = audioByBundleID[bundleID] {
                results.append(audioProcess)
                return
            }
            results.append(
                AudioClientProcess(
                    objectID: kAudioObjectUnknown,
                    pid: pid,
                    bundleID: bundleID,
                    displayName: name ?? displayName(for: bundleID, pid: pid),
                    isRunningOutput: false
                )
            )
        }

        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
            guard let bundleID = app.bundleIdentifier else { continue }
            append(bundleID: bundleID, name: app.localizedName, pid: app.processIdentifier)
        }

        for bundleID in selectedBundleIDs {
            append(
                bundleID: bundleID,
                name: nil,
                pid: NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first?.processIdentifier ?? 0
            )
        }

        return results.sorted {
            $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
        }
    }

    private static func deduplicatedProcesses(from processes: [AudioClientProcess]) -> [AudioClientProcess] {
        var bestByBundleID: [String: AudioClientProcess] = [:]
        for process in processes {
            if let existing = bestByBundleID[process.bundleID] {
                if process.isRunningOutput, !existing.isRunningOutput {
                    bestByBundleID[process.bundleID] = process
                }
            } else {
                bestByBundleID[process.bundleID] = process
            }
        }
        return bestByBundleID.values.sorted {
            $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
        }
    }

    static func processObjectIDs(forBundleIDs bundleIDs: Set<String>) -> [AudioObjectID] {
        guard !bundleIDs.isEmpty else { return [] }

        var seen = Set<AudioObjectID>()
        var results: [AudioObjectID] = []

        for process in allProcesses() {
            guard bundleIDs.contains(process.bundleID)
                || bundleIDs.contains(where: { process.bundleID.hasPrefix($0 + ".") })
            else { continue }
            guard seen.insert(process.objectID).inserted else { continue }
            results.append(process.objectID)
        }
        return results
    }

    private static func allProcesses() -> [AudioClientProcess] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &dataSize
        ) == noErr else {
            return []
        }

        let count = Int(dataSize) / MemoryLayout<AudioObjectID>.size
        guard count > 0 else { return [] }

        var objectIDs = [AudioObjectID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &dataSize,
            &objectIDs
        ) == noErr else {
            return []
        }

        return objectIDs.compactMap(makeProcess(from:))
    }

    private static func makeProcess(from objectID: AudioObjectID) -> AudioClientProcess? {
        guard objectID != kAudioObjectUnknown else { return nil }

        guard let pid = readPID(objectID: objectID),
              let bundleID = readBundleID(objectID: objectID),
              !bundleID.isEmpty else {
            return nil
        }

        let isRunningOutput = readUInt32Property(
            objectID: objectID,
            selector: kAudioProcessPropertyIsRunningOutput
        ) != 0

        return AudioClientProcess(
            objectID: objectID,
            pid: pid,
            bundleID: bundleID,
            displayName: displayName(for: bundleID, pid: pid),
            isRunningOutput: isRunningOutput
        )
    }

    private static func readPID(objectID: AudioObjectID) -> pid_t? {
        var pid: pid_t = 0
        var dataSize = UInt32(MemoryLayout<pid_t>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyPID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectGetPropertyData(objectID, &address, 0, nil, &dataSize, &pid) == noErr else {
            return nil
        }
        return pid
    }

    private static func readBundleID(objectID: AudioObjectID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyBundleID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize = UInt32(MemoryLayout<CFString?>.size)
        var value: CFString?
        let status = withUnsafeMutablePointer(to: &value) { pointer in
            AudioObjectGetPropertyData(objectID, &address, 0, nil, &dataSize, pointer)
        }
        guard status == noErr, let value else { return nil }
        return value as String
    }

    private static func readUInt32Property(
        objectID: AudioObjectID,
        selector: AudioObjectPropertySelector
    ) -> UInt32 {
        var value: UInt32 = 0
        var dataSize = UInt32(MemoryLayout<UInt32>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectGetPropertyData(objectID, &address, 0, nil, &dataSize, &value) == noErr else {
            return 0
        }
        return value
    }

    private static func displayName(for bundleID: String, pid: pid_t) -> String {
        if let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first,
           let name = app.localizedName, !name.isEmpty {
            return name
        }
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            let name = FileManager.default.displayName(atPath: url.path)
            if !name.isEmpty {
                return name
            }
        }
        if let app = NSRunningApplication(processIdentifier: pid),
           let name = app.localizedName, !name.isEmpty {
            return name
        }
        return bundleID
    }
}
