import AVFoundation
import CoreAudio
import Foundation

struct TapAggregateSetup {
    let tapID: AudioObjectID
    let aggregateID: AudioDeviceID
    let sampleRate: Double
    let streamFormat: AudioStreamBasicDescription
    let audioFormat: AVAudioFormat
}

@available(macOS 14.2, *)
enum ProcessTapSession {
    static func create(
        outputDeviceUID: String,
        captureScope: CaptureScope,
        selectedBundleIDs: Set<String>,
        muteBehavior: CATapMuteBehavior = .muted
    ) throws -> TapAggregateSetup {
        cleanupBeforeCreate()

        let ownProcessObject = ownProcessObjectID()
        let description: CATapDescription

        switch captureScope {
        case .allApps:
            let excludedProcesses: [AudioObjectID]
            if let ownProcessObject {
                excludedProcesses = [ownProcessObject]
            } else {
                excludedProcesses = []
            }
            description = CATapDescription(stereoGlobalTapButExcludeProcesses: excludedProcesses)
            AppLogger.shared.info("Creating global process tap (all apps)")

        case .selectedApps:
            let tappedProcesses = AudioProcessEnumerator.processObjectIDs(forBundleIDs: selectedBundleIDs)
            guard !tappedProcesses.isEmpty else {
                throw AudioEngineError.noSelectedAudioProcesses
            }
            description = CATapDescription(stereoMixdownOfProcesses: tappedProcesses)
            AppLogger.shared.info(
                "Creating selective process tap for \(tappedProcesses.count) process object(s) from \(selectedBundleIDs.count) bundle ID(s)"
            )
        }

        description.name = "MinusOne System Tap"
        let tapUUID = UUID()
        description.uuid = tapUUID
        description.muteBehavior = muteBehavior
        description.isPrivate = true

        var tapID = AudioObjectID(kAudioObjectUnknown)
        let createStatus = AudioHardwareCreateProcessTap(description, &tapID)
        guard createStatus == noErr else {
            if AudioPermission.isPermissionDeniedStatus(createStatus) {
                throw AudioEngineError.processTapPermissionDenied
            }
            throw AudioEngineError.coreAudio("Create process tap", createStatus)
        }
        guard tapID != kAudioObjectUnknown else {
            throw AudioEngineError.coreAudio("Create process tap returned noErr but tap ID is unknown", createStatus)
        }

        let streamFormat = try readTapStreamFormat(tapID: tapID)
        let sampleRate = streamFormat.mSampleRate > 0 ? streamFormat.mSampleRate : 48_000
        var mutableFormat = streamFormat
        guard let audioFormat = AVAudioFormat(streamDescription: &mutableFormat) else {
            throw AudioEngineError.unsupportedFormat("Unable to create AVAudioFormat from tap stream description")
        }

        let aggregateUID = "com.minusone.aggregate.\(UUID().uuidString)"
        let aggregateDescription: [String: Any] = [
            kAudioAggregateDeviceNameKey: "MinusOne Tap Aggregate",
            kAudioAggregateDeviceUIDKey: aggregateUID,
            kAudioAggregateDeviceMainSubDeviceKey: outputDeviceUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [
                [kAudioSubDeviceUIDKey: outputDeviceUID]
            ],
            kAudioAggregateDeviceTapListKey: [
                [
                    kAudioSubTapUIDKey: tapUUID.uuidString,
                    kAudioSubTapDriftCompensationKey: true
                ]
            ]
        ]

        var aggregateID = AudioObjectID(kAudioObjectUnknown)
        try check(
            AudioHardwareCreateAggregateDevice(
                aggregateDescription as CFDictionary,
                &aggregateID
            ),
            "Create tap aggregate device"
        )

        AppLogger.shared.info("Process tap created (tapID=\(tapID), aggregateID=\(aggregateID))")
        return TapAggregateSetup(
            tapID: tapID,
            aggregateID: aggregateID,
            sampleRate: sampleRate,
            streamFormat: streamFormat,
            audioFormat: audioFormat
        )
    }

    static func startIO(
        setup: TapAggregateSetup,
        queue: DispatchQueue,
        ioBlock: @escaping AudioDeviceIOBlock
    ) throws -> AudioDeviceIOProcID {
        var procID: AudioDeviceIOProcID?
        try check(
            AudioDeviceCreateIOProcIDWithBlock(&procID, setup.aggregateID, queue, ioBlock),
            "Create process tap IO proc"
        )
        guard let procID else {
            throw AudioEngineError.coreAudio("Process tap IO proc was nil", unspecifiedAudioStatus)
        }
        try check(AudioDeviceStart(setup.aggregateID, procID), "Start process tap aggregate")
        return procID
    }

    static func stopIO(setup: TapAggregateSetup, procID: AudioDeviceIOProcID?) {
        guard let procID else { return }
        let stopStatus = AudioDeviceStop(setup.aggregateID, procID)
        if stopStatus != noErr {
            AppLogger.shared.error("AudioDeviceStop failed: OSStatus \(stopStatus)")
        }
        let destroyStatus = AudioDeviceDestroyIOProcID(setup.aggregateID, procID)
        if destroyStatus != noErr {
            AppLogger.shared.error("AudioDeviceDestroyIOProcID failed: OSStatus \(destroyStatus)")
        }
    }

    static func destroy(_ setup: TapAggregateSetup?) {
        guard let setup else { return }

        if setup.aggregateID != kAudioObjectUnknown {
            let status = AudioHardwareDestroyAggregateDevice(setup.aggregateID)
            if status != noErr {
                AppLogger.shared.error("AudioHardwareDestroyAggregateDevice failed: OSStatus \(status)")
            }
        }

        if setup.tapID != kAudioObjectUnknown {
            let status = AudioHardwareDestroyProcessTap(setup.tapID)
            if status != noErr {
                AppLogger.shared.error("AudioHardwareDestroyProcessTap failed: OSStatus \(status)")
            }
        }
    }

    static func destroyStaleAggregates() {
        destroyStaleDevices(matching: { $0.hasPrefix("com.minusone.aggregate.") })
    }

    static func cleanupBeforeCreate() {
        destroyStaleAggregates()
    }

    private static func destroyStaleDevices(matching uidPredicate: (String) -> Bool) {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
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
        ) == noErr else { return }

        let count = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        var ids = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &dataSize,
            &ids
        ) == noErr else { return }

        for id in ids {
            guard let uid = CoreAudioDevices.device(for: id)?.uid,
                  uidPredicate(uid) else {
                continue
            }
            let status = AudioHardwareDestroyAggregateDevice(id)
            AppLogger.shared.info("Destroyed stale MinusOne aggregate \(uid) (status \(status))")
        }
    }

    private static func readTapStreamFormat(tapID: AudioObjectID) throws -> AudioStreamBasicDescription {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        let sizeStatus = AudioObjectGetPropertyDataSize(tapID, &address, 0, nil, &dataSize)
        guard sizeStatus == noErr, dataSize >= UInt32(MemoryLayout<AudioStreamBasicDescription>.size) else {
            throw AudioEngineError.coreAudio("Read tap format size", sizeStatus)
        }

        var format = AudioStreamBasicDescription()
        let status = AudioObjectGetPropertyData(tapID, &address, 0, nil, &dataSize, &format)
        guard status == noErr, format.mSampleRate > 0 else {
            throw AudioEngineError.coreAudio("Read tap format", status)
        }

        AppLogger.shared.info(
            "Tap format sampleRate=\(format.mSampleRate) channels=\(format.mChannelsPerFrame) bits=\(format.mBitsPerChannel) flags=\(format.mFormatFlags) interleaved=\(format.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0)"
        )
        return format
    }

    private static func ownProcessObjectID() -> AudioObjectID? {
        let ownPID = ProcessInfo.processInfo.processIdentifier
        var ownProcessObject = AudioObjectID(kAudioObjectUnknown)
        var translateAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var translatePID = ownPID
        var translateSize = UInt32(MemoryLayout<AudioObjectID>.size)
        let translateStatus = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &translateAddress,
            UInt32(MemoryLayout<pid_t>.size),
            &translatePID,
            &translateSize,
            &ownProcessObject
        )
        guard translateStatus == noErr, ownProcessObject != kAudioObjectUnknown else {
            return nil
        }
        return ownProcessObject
    }

    private static func check(_ status: OSStatus, _ message: String) throws {
        guard status == noErr else {
            throw AudioEngineError.coreAudio(message, status)
        }
    }
}

private let unspecifiedAudioStatus = OSStatus(-1)
