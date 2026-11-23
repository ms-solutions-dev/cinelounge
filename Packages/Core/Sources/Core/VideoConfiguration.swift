import CoreMedia
import Foundation

/// Reads the decoder description as it is stored in MP4 and MKV.
///
/// **The difference from the transport stream is the bookkeeping, not the
/// content.** A channel sends the descriptions along in the picture stream,
/// introduced by start patterns, again and again. A file puts them **once** in the
/// header, as `CodecPrivate` — the same bytes, only in a place where you find them
/// without searching.
///
/// The two forms are called `hvcC` (HEVC) and `avcC` (H.264). They are not built
/// the same way, but both end up at the same thing: the parameter sets that
/// ``SampleAssembly/formatDescription(from:kind:lengthSize:)`` turns into a
/// description for Apple's decoder.
public enum VideoConfiguration {

    /// What comes out of the `CodecPrivate`.
    public struct Description: Sendable, Equatable {
        public var sets: TransportStream.ParameterSets
        /// How many bytes the length in front of each unit occupies — one to four.
        ///
        /// **Almost always four, but only almost always.** Anyone who does not read the
        /// value but assumes it keeps counting at the wrong place in the other files — and
        /// the decoder cannot know that it has been counted wrongly. It shows blocks or
        /// nothing.
        public var lengthSize: Int
    }

    /// Reads `hvcC` or `avcC`, depending on the kind of the picture stream.
    public static func description(
        from codecPrivate: Data, kind: TransportStream.StreamKind
    ) -> Description? {
        switch kind {
        case .hevc: hevc(codecPrivate)
        case .h264: h264(codecPrivate)
        default: nil
        }
    }

    /// `hvcC` — 22 fixed bytes, then fields per kind of parameter set.
    static func hevc(_ data: Data) -> Description? {
        let bytes = [UInt8](data)
        guard bytes.count >= 23, bytes[0] == 1 else { return nil }

        var sets = TransportStream.ParameterSets()
        let lengthSize = Int(bytes[21] & 0x03) + 1

        var offset = 23
        let arrays = Int(bytes[22])
        for _ in 0..<arrays {
            guard offset + 3 <= bytes.count else { break }
            let type = bytes[offset] & 0x3F
            let count = Int(bytes[offset + 1]) << 8 | Int(bytes[offset + 2])
            offset += 3

            for _ in 0..<count {
                guard offset + 2 <= bytes.count else { break }
                let length = Int(bytes[offset]) << 8 | Int(bytes[offset + 1])
                offset += 2
                guard offset + length <= bytes.count else { break }
                let unit = Data(bytes[offset..<(offset + length)])
                offset += length

                switch type {
                case 32: sets.vps = sets.vps ?? unit
                case 33: sets.ingest(sps: unit)
                case 34: sets.ingest(pps: unit)
                default: break
                }
            }
        }
        return Description(sets: sets, lengthSize: lengthSize)
    }

    /// `avcC` — five fixed bytes, then the SPS, then the PPS.
    ///
    /// **All sets, not the last one** (repackager review B7, 2026-09-27): Here each
    /// entry overwrote the previous one. A DVB recording with two PPS — one for the I
    /// pictures, one for the P and B pictures — thus got only one, and the decoder
    /// rejected every picture that points to the other (black picture with audio, as
    /// with the channel "TR: NOKTA TV HQ" on 2026-08-23). Collection works as in the
    /// transport stream: the first set at the front, every further one behind it — see
    /// ``TransportStream/ParameterSets/additionalPPS``.
    static func h264(_ data: Data) -> Description? {
        let bytes = [UInt8](data)
        guard bytes.count >= 7, bytes[0] == 1 else { return nil }

        var sets = TransportStream.ParameterSets()
        let lengthSize = Int(bytes[4] & 0x03) + 1

        // Byte 5 carries the **number** of SPS; the entries begin behind it.
        var offset = 6
        func read(count: Int, _ ingest: (inout TransportStream.ParameterSets, Data) -> Void) {
            for _ in 0..<count {
                guard offset + 2 <= bytes.count else { return }
                let length = Int(bytes[offset]) << 8 | Int(bytes[offset + 1])
                offset += 2
                guard offset + length <= bytes.count else { return }
                ingest(&sets, Data(bytes[offset..<(offset + length)]))
                offset += length
            }
        }

        read(count: Int(bytes[5] & 0x1F)) { $0.ingest(sps: $1) }
        offset = min(offset, bytes.count)
        guard offset < bytes.count else { return nil }
        let ppsCount = Int(bytes[offset])
        offset += 1
        read(count: ppsCount) { $0.ingest(pps: $1) }

        return Description(sets: sets, lengthSize: lengthSize)
    }

    // MARK: - Length-prefixed units

    /// Splits a frame into its units.
    ///
    /// **The counterpart to ``TransportStream/units(inElementaryStream:)``.** There
    /// start patterns are searched for, here the units are counted — and that is why
    /// it is unambiguous here: A start pattern can appear by chance in picture data, a
    /// length cannot.
    public static func units(inLengthPrefixed data: Data, lengthSize: Int) -> [Data] {
        guard (1...4).contains(lengthSize) else { return [] }
        var units: [Data] = []
        var offset = 0
        let base = data.startIndex

        while offset + lengthSize <= data.count {
            var length = 0
            for step in 0..<lengthSize { length = length << 8 | Int(data[base + offset + step]) }
            offset += lengthSize
            // A length that reaches beyond the frame means: We are counting at the wrong
            // place. Carrying on would mean guessing.
            guard length > 0, offset + length <= data.count else { break }
            units.append(data.subdata(in: (base + offset)..<(base + offset + length)))
            offset += length
        }
        return units
    }

    /// Looks for parameter sets in the frames themselves.
    ///
    /// **For the files whose `CodecPrivate` contains none.** That happens: One of the
    /// four test files has an `hvcC` of 23 bytes — the fixed fields and behind them
    /// "zero fields". The descriptions are in the picture stream there, as with a
    /// channel, only with lengths instead of start patterns.
    public static func parameterSets(
        inFrames frames: [Data], kind: TransportStream.StreamKind, lengthSize: Int
    ) -> TransportStream.ParameterSets {
        var found = TransportStream.ParameterSets()
        for frame in frames {
            let units = units(inLengthPrefixed: frame, lengthSize: lengthSize)
            found.ingest(TransportStream.parameterSets(in: units, kind: kind))
        }
        return found
    }
}
