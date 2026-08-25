import Foundation

/// On-disk peak format for one track: a 20-byte header followed by `Int16` min/max/RMS triples.
///
/// The available column count is derived from the file's byte length and never from a header
/// field. That single decision is what lets a sidecar be appended to while separation runs — a
/// half-written file simply reads short, so there is no partial-write special casing and no
/// second readiness mechanism running parallel to `PracticeClip.readyDurationSeconds`.
enum PeakSidecar {
    static let magic: [UInt8] = Array("M1PK".utf8)
    static let version: UInt16 = 1
    static let headerByteCount = 20
    static let bytesPerColumn = 6
    static let defaultFramesPerColumn = 256
    /// `Int16.max`, as the scale factor between -1...1 samples and stored integers.
    static let sampleScale: Float = 32_767

    struct Header: Equatable {
        var sampleRate: UInt32
        var framesPerColumn: UInt32
    }

    enum SidecarError: Error, LocalizedError {
        case tooShort
        case badMagic
        case unsupportedVersion(UInt16)

        var errorDescription: String? {
            switch self {
            case .tooShort: return "Peak file is shorter than its header."
            case .badMagic: return "File is not a MinusOne peak sidecar."
            case .unsupportedVersion(let version): return "Unsupported peak file version \(version)."
            }
        }
    }

    static func encodeHeader(_ header: Header) -> Data {
        var data = Data(capacity: headerByteCount)
        data.append(contentsOf: magic)
        data.append(contentsOf: littleEndianBytes(version))
        data.append(contentsOf: littleEndianBytes(UInt16(0)))          // flags, reserved
        data.append(contentsOf: littleEndianBytes(header.sampleRate))
        data.append(contentsOf: littleEndianBytes(header.framesPerColumn))
        data.append(contentsOf: littleEndianBytes(UInt32(0)))          // reserved
        return data
    }

    static func decodeHeader(_ data: Data) throws -> Header {
        guard data.count >= headerByteCount else { throw SidecarError.tooShort }
        let base = data.startIndex
        guard Array(data[base..<(base + 4)]) == magic else { throw SidecarError.badMagic }
        let fileVersion = readUInt16(data, at: base + 4)
        guard fileVersion == version else { throw SidecarError.unsupportedVersion(fileVersion) }
        return Header(
            sampleRate: readUInt32(data, at: base + 8),
            framesPerColumn: readUInt32(data, at: base + 12)
        )
    }

    static func encodeColumn(_ column: PeakColumn) -> Data {
        var data = Data(capacity: bytesPerColumn)
        for value in [column.minimum, column.maximum, column.rms] {
            let scaled = Int(( max(-1, min(1, value)) * sampleScale).rounded())
            data.append(contentsOf: littleEndianBytes(UInt16(bitPattern: Int16(clamping: scaled))))
        }
        return data
    }

    // MARK: - Byte helpers

    private static func littleEndianBytes(_ value: UInt16) -> [UInt8] {
        [UInt8(value & 0xFF), UInt8((value >> 8) & 0xFF)]
    }

    private static func littleEndianBytes(_ value: UInt32) -> [UInt8] {
        (0..<4).map { UInt8((value >> (8 * $0)) & 0xFF) }
    }

    fileprivate static func readUInt16(_ data: Data, at index: Data.Index) -> UInt16 {
        UInt16(data[index]) | (UInt16(data[index + 1]) << 8)
    }

    private static func readUInt32(_ data: Data, at index: Data.Index) -> UInt32 {
        (0..<4).reduce(UInt32(0)) { $0 | (UInt32(data[index + $1]) << (8 * UInt32($1))) }
    }
}

/// Random-access reader over a peak sidecar.
///
/// The file is memory-mapped rather than copied: a 4-minute track is ~250 KB and there are five of
/// them per clip, so mapping keeps the whole set effectively free.
final class PeakSidecarReader {
    let header: PeakSidecar.Header
    private let data: Data

    init(contentsOf url: URL) throws {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        self.header = try PeakSidecar.decodeHeader(data)
        self.data = data
    }

    var columnCount: Int {
        max(0, (data.count - PeakSidecar.headerByteCount) / PeakSidecar.bytesPerColumn)
    }

    var columnsPerSecond: Double {
        let framesPerColumn = max(1, Double(header.framesPerColumn))
        return Double(header.sampleRate) / framesPerColumn
    }

    /// How much of the track has peaks written for it — during separation, less than the clip.
    var availableDuration: Double {
        Double(columnCount) / max(columnsPerSecond, 0.001)
    }

    /// Out-of-range indices are silent rather than fatal: the unseparated tail is read this way.
    func column(at index: Int) -> PeakColumn {
        guard index >= 0, index < columnCount else { return .silent }
        let base = data.startIndex + PeakSidecar.headerByteCount + index * PeakSidecar.bytesPerColumn
        func value(_ offset: Int) -> Float {
            let raw = Int16(bitPattern: PeakSidecar.readUInt16(data, at: base + offset))
            return Float(raw) / PeakSidecar.sampleScale
        }
        return PeakColumn(minimum: value(0), maximum: value(2), rms: value(4))
    }
}
