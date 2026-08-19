import AudioToolbox
import CoreAudio
import Foundation

struct AudioDevice: Identifiable, Equatable {
    let id: AudioDeviceID
    let name: String
    let uid: String
    let inputChannelCount: UInt32
    let outputChannelCount: UInt32

    var isBlackHole: Bool {
        name.localizedCaseInsensitiveContains("BlackHole")
            || uid.localizedCaseInsensitiveContains("BlackHole")
    }

    var isOutputCapable: Bool {
        outputChannelCount > 0
    }

    var isInputCapable: Bool {
        inputChannelCount > 0
    }
}

enum CoreAudioDevices {
    static func allDevices() -> [AudioDevice] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        let sizeStatus = AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &dataSize
        )
        guard sizeStatus == noErr else {
            AppLogger.shared.error("Unable to read CoreAudio device list size: \(sizeStatus)")
            return []
        }

        let count = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        var ids = [AudioDeviceID](repeating: 0, count: count)
        let dataStatus = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &dataSize,
            &ids
        )
        guard dataStatus == noErr else {
            AppLogger.shared.error("Unable to read CoreAudio device list: \(dataStatus)")
            return []
        }

        return ids.compactMap(device(for:))
    }

    static func defaultOutputDeviceID() -> AudioDeviceID? {
        readDeviceID(selector: kAudioHardwarePropertyDefaultOutputDevice)
    }

    static func defaultSystemOutputDeviceID() -> AudioDeviceID? {
        readDeviceID(selector: kAudioHardwarePropertyDefaultSystemOutputDevice)
    }

    static func setDefaultOutputDevice(_ id: AudioDeviceID) throws {
        try setDefaultDevice(id, selector: kAudioHardwarePropertyDefaultOutputDevice)
        try setDefaultDevice(id, selector: kAudioHardwarePropertyDefaultSystemOutputDevice)
    }

    static func outputDevices() -> [AudioDevice] {
        allDevices().filter { $0.isOutputCapable && !$0.isBlackHole }
    }

    /// Input-capable devices, for the Practice recorder's source picker. BlackHole is excluded for
    /// the same reason it is in `outputDevices()`: it's MinusOne's own loopback plumbing, and
    /// recording "from" it would capture whatever the app is already routing through it.
    static func inputDevices() -> [AudioDevice] {
        allDevices().filter { $0.isInputCapable && !$0.isBlackHole }
    }

    static func blackHoleDevice() -> AudioDevice? {
        allDevices().first { $0.isBlackHole }
    }

    static func logDeviceSnapshot(reason: String) {
        let devices = allDevices()
        AppLogger.shared.info("CoreAudio device snapshot (\(reason)): \(devices.count) devices")

        if devices.isEmpty {
            AppLogger.shared.error("CoreAudio returned zero devices. This usually means the app is not seeing the user audio session or coreaudiod needs a restart.")
        }

        for device in devices {
            AppLogger.shared.info(
                "Device id=\(device.id) name=\"\(device.name)\" uid=\"\(device.uid)\" input=\(device.inputChannelCount) output=\(device.outputChannelCount)"
            )
        }
    }

    static func device(withUID uid: String) -> AudioDevice? {
        allDevices().first { $0.uid == uid }
    }

    static func device(for id: AudioDeviceID) -> AudioDevice? {
        guard id != kAudioObjectUnknown else { return nil }

        let name = stringProperty(id: id, selector: kAudioObjectPropertyName) ?? "Unknown Device"
        let uid = stringProperty(id: id, selector: kAudioDevicePropertyDeviceUID) ?? "\(id)"
        let inputChannels = channelCount(id: id, scope: kAudioDevicePropertyScopeInput)
        let outputChannels = channelCount(id: id, scope: kAudioDevicePropertyScopeOutput)

        return AudioDevice(
            id: id,
            name: name,
            uid: uid,
            inputChannelCount: inputChannels,
            outputChannelCount: outputChannels
        )
    }

    private static func readDeviceID(selector: AudioObjectPropertySelector) -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID = AudioDeviceID(kAudioObjectUnknown)
        var dataSize = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &dataSize,
            &deviceID
        )
        guard status == noErr, deviceID != kAudioObjectUnknown else { return nil }
        return deviceID
    }

    private static func setDefaultDevice(_ id: AudioDeviceID, selector: AudioObjectPropertySelector) throws {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var mutableID = id
        let status = AudioObjectSetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            UInt32(MemoryLayout<AudioDeviceID>.size),
            &mutableID
        )
        guard status == noErr else {
            throw AudioEngineError.coreAudio("Unable to set default output device", status)
        }
    }

    private static func stringProperty(id: AudioDeviceID, selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize = UInt32(MemoryLayout<CFString?>.size)
        var value: CFString?
        let status = withUnsafeMutablePointer(to: &value) { pointer in
            AudioObjectGetPropertyData(id, &address, 0, nil, &dataSize, pointer)
        }
        guard status == noErr, let value else { return nil }
        return value as String
    }

    private static func channelCount(id: AudioDeviceID, scope: AudioObjectPropertyScope) -> UInt32 {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        let sizeStatus = AudioObjectGetPropertyDataSize(id, &address, 0, nil, &dataSize)
        guard sizeStatus == noErr, dataSize > 0 else { return 0 }

        let rawPointer = UnsafeMutableRawPointer.allocate(
            byteCount: Int(dataSize),
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { rawPointer.deallocate() }

        let status = AudioObjectGetPropertyData(id, &address, 0, nil, &dataSize, rawPointer)
        guard status == noErr else { return 0 }

        let bufferList = UnsafeMutableAudioBufferListPointer(
            rawPointer.bindMemory(to: AudioBufferList.self, capacity: 1)
        )
        return bufferList.reduce(UInt32(0)) { $0 + $1.mNumberChannels }
    }
}
