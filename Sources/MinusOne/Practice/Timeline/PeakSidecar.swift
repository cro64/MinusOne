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

    /// Reads `count` columns starting at `start`, in one pass over the mapped bytes.
    ///
    /// `column(at:)` costs six bounds-checked `Data` subscripts per column. A lane zoomed all the
    /// way out asks for every stored column — ~41,000 for a four-minute clip — and there are four
    /// lanes, so the scalar path is the one thing on the render route that scales with clip length.
    /// This binds the mapped region once and reads straight out of it.
    ///
    /// Out-of-range indices read `.silent` rather than trapping: the unseparated tail is read this
    /// way on every frame while separation runs.
    func columns(from start: Int, count: Int) -> [PeakColumn] {
        guard count > 0 else { return [] }
        var result = [PeakColumn](repeating: .silent, count: count)
        let available = columnCount
        guard available > 0 else { return result }

        let scale = PeakSidecar.sampleScale
        data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            let body = base.advanced(by: PeakSidecar.headerByteCount)
            for offset in 0..<count {
                let index = start + offset
                guard index >= 0, index < available else { continue }
                let byteOffset = index * PeakSidecar.bytesPerColumn
                // Inlined rather than routed through a nested helper, to avoid a per-call
                // closure allocation under -Onone. (Measured: this alone was not the dominant
                // debug-build cost — see PeakBulkReadTests and spec §14 — but it is free to avoid
                // and it is one less heap allocation on a hot loop.) `loadUnaligned`, not `load`:
                // the body starts at byte 20 and strides by 6, so a column's Int16s are only ever
                // 2-byte aligned, and `load` traps on that.
                let minimum = body.loadUnaligned(fromByteOffset: byteOffset, as: Int16.self)
                let maximum = body.loadUnaligned(fromByteOffset: byteOffset + 2, as: Int16.self)
                let rms = body.loadUnaligned(fromByteOffset: byteOffset + 4, as: Int16.self)
                result[offset] = PeakColumn(
                    minimum: Float(Int16(littleEndian: minimum)) / scale,
                    maximum: Float(Int16(littleEndian: maximum)) / scale,
                    rms: Float(Int16(littleEndian: rms)) / scale
                )
            }
        }
        return result
    }
}
