import Foundation

/// Reads the structure of an MKV file — elements, tracks, blocks.
///
/// **Matroska is not a format but a nesting order.** Everything in it is
/// an element: an ID, a length, a content — and the content is
/// elements again. That makes reading simple and the file at the same time
/// unpredictable: no table says where anything is. In one test file
/// `Tracks` comes before `Info`, in the next after it; whoever relies on an
/// order fails to read half the library.
///
/// **This only reads, it does not interpret.** What is picture and what is audio
/// is for the caller to decide — the same separation as with
/// ``TransportStreamReader``, and for the same reason: the output behind both
/// readers is the same.
public enum Matroska {

    // MARK: - Variable-length numbers

    /// A number whose length is in its first byte.
    ///
    /// **The building block everything else stands on.** The leading zero bits
    /// count how many bytes follow: `1xxxxxxx` is one, `01xxxxxx` is
    /// two, and so on up to eight. IDs keep this marker bit
    /// (they are compared as a whole), lengths lose it.
    public struct VarInt: Equatable, Sendable {
        public let value: UInt64
        /// How many bytes were read — the caller must advance.
        public let width: Int
        /// Whether all data bits were set: "length unknown".
        public let isUnknown: Bool
    }

    /// Maximum length of such a number — eight bytes, as the format demands.
    static let maximumVarIntWidth = 8

    public static func varint(in data: Data, at offset: Int, keepMarker: Bool = false) -> VarInt? {
        guard offset >= 0, offset < data.count else { return nil }
        let base = data.startIndex + offset
        let first = data[base]
        // A zero byte would mean "more than eight bytes" — that does not exist, and the
        // spot is thereby refuted as an element start.
        guard first != 0 else { return nil }

        var width = 1
        var mask: UInt8 = 0x80
        while first & mask == 0 {
            mask >>= 1
            width += 1
        }
        guard offset + width <= data.count else { return nil }

        let marker = mask
        var payload = UInt64(first & (marker &- 1))
        var whole = UInt64(first)
        for step in 1..<width {
            let byte = UInt64(data[base + step])
            payload = (payload << 8) | byte
            whole = (whole << 8) | byte
        }

        let allOnes = (UInt64(1) << UInt64(7 * width)) &- 1
        return VarInt(
            value: keepMarker ? whole : payload,
            width: width,
            isUnknown: payload == allOnes
        )
    }

    // MARK: - Elemente

    /// An element with ID, head length and content length.
    public struct Element: Equatable, Sendable {
        public let id: UInt32
        /// ID and length field together — this is how far away the content sits.
        public let headerSize: Int
        /// Length of the content, or `nil` if it was left open.
        ///
        /// **Open lengths are not an error.** Whoever writes a file while
        /// recording does not yet know the length of the segment. Such
        /// files are everywhere; the reader has to recognise their end by what
        /// comes after.
        public let size: Int?

        public var totalSize: Int? { size.map { headerSize + $0 } }
    }

    public static func element(in data: Data, at offset: Int) -> Element? {
        guard let id = varint(in: data, at: offset, keepMarker: true),
            id.width <= 4,
            let size = varint(in: data, at: offset + id.width)
        else { return nil }

        let identifier = UInt32(truncatingIfNeeded: id.value)

        // Above two billion bytes is no longer a sensible length for a **leaf**,
        // but a wrong turn in the middle of picture data. For the
        // containers this explicitly does not apply: the segment carries the length of the
        // whole file — and with the old, blanket limit the
        // reader declared every feature film over two gigabytes "not Matroska"
        // (on-device finding 2026-08-15, Draikliak at 6.35 GB: the remuxer silently fell through
        // to VLC, whose seek loaded from byte zero). The episode files
        // of the catalog are under the limit — that is why remuxing worked
        // there and failed precisely for the large films. The
        // upper limit for containers now only guards against overflow.
        let limit = descendable.contains(identifier) ? UInt64(Int.max / 2) : UInt64(Int32.max)
        guard size.isUnknown || size.value <= limit else { return nil }

        return Element(
            id: identifier,
            headerSize: id.width + size.width,
            size: size.isUnknown ? nil : Int(size.value)
        )
    }

    // MARK: - Kennungen

    /// The IDs that matter.
    ///
    /// There are a few hundred; here are those needed for remuxing.
    /// Everything else is skipped without naming it — an
    /// element whose length you know does not have to be understood.
    public enum ID {
        public static let ebml: UInt32 = 0x1A45_DFA3
        public static let segment: UInt32 = 0x1853_8067
        public static let info: UInt32 = 0x1549_A966
        public static let timestampScale: UInt32 = 0x2AD7_B1
        public static let duration: UInt32 = 0x4489
        public static let tracks: UInt32 = 0x1654_AE6B
        public static let trackEntry: UInt32 = 0xAE
        public static let trackNumber: UInt32 = 0xD7
        public static let trackType: UInt32 = 0x83
        public static let codecID: UInt32 = 0x86
        public static let codecPrivate: UInt32 = 0x63A2
        public static let language: UInt32 = 0x22B5_9C
        public static let languageBCP47: UInt32 = 0x22B5_9D
        public static let trackName: UInt32 = 0x536E
        public static let flagDefault: UInt32 = 0x88
        public static let flagForced: UInt32 = 0x55AA
        public static let defaultDuration: UInt32 = 0x23E3_83
        public static let video: UInt32 = 0xE0
        public static let pixelWidth: UInt32 = 0xB0
        public static let pixelHeight: UInt32 = 0xBA
        public static let audio: UInt32 = 0xE1
        public static let samplingFrequency: UInt32 = 0xB5
        public static let channels: UInt32 = 0x9F
        public static let bitDepth: UInt32 = 0x6264
        public static let contentEncodings: UInt32 = 0x6D80
        public static let cluster: UInt32 = 0x1F43_B675
        public static let clusterTimestamp: UInt32 = 0xE7
        public static let simpleBlock: UInt32 = 0xA3
        public static let blockGroup: UInt32 = 0xA0
        public static let block: UInt32 = 0xA1
        public static let blockDuration: UInt32 = 0x9B
        public static let referenceBlock: UInt32 = 0xFB
        public static let cues: UInt32 = 0x1C53_BB6B
        public static let cuePoint: UInt32 = 0xBB
        public static let cueTime: UInt32 = 0xB3
        public static let cueTrackPositions: UInt32 = 0xB7
        public static let cueTrack: UInt32 = 0xF7
        public static let cueClusterPosition: UInt32 = 0xF1
        public static let seek: UInt32 = 0x4DBB
        public static let seekID: UInt32 = 0x53AB
        public static let seekPosition: UInt32 = 0x53AC
        public static let attachments: UInt32 = 0x1941_A469
        public static let chapters: UInt32 = 0x1043_A770
        public static let tags: UInt32 = 0x1254_C367
        public static let seekHead: UInt32 = 0x114D_9B74
        public static let void: UInt32 = 0xEC
        public static let crc32: UInt32 = 0xBF
    }

    /// Elements that are entered rather than read in one go.
    ///
    /// **The selection is a memory decision.** A segment is the whole
    /// file, a cluster several megabytes — waiting for those before the first
    /// picture comes out would mean, for an episode, holding a gigabyte in memory.
    /// Nothing small is entered; it is read
    /// once it is completely there.
    static let descendable: Set<UInt32> = [
        ID.segment, ID.cluster, ID.blockGroup,
    ]

    // MARK: - Werte lesen

    static func unsigned(_ data: Data) -> UInt64 {
        data.reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
    }

    /// Floating-point numbers are stored in four or eight bytes — both occur.
    static func float(_ data: Data) -> Double? {
        switch data.count {
        case 4: return Double(Float(bitPattern: UInt32(truncatingIfNeeded: unsigned(data))))
        case 8: return Double(bitPattern: unsigned(data))
        default: return nil
        }
    }

    static func text(_ data: Data) -> String {
        // Strings may be padded with null bytes; they are not part
        // of the value and would otherwise silently break every comparison.
        String(decoding: data.prefix { $0 != 0 }, as: UTF8.self)
    }
}
