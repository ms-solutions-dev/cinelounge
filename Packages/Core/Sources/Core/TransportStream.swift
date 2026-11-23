import Foundation

/// Reads the structure of an MPEG-TS — what is in it and where.
///
/// **Why the app has to do this itself** (decision of 2026-08-08): The goal is to end
/// up with **a single** playback engine — Apple's own, with AirPlay, the system
/// bar and everything that hangs off it. Today only one thing stands in the way: a
/// channel delivers HEVC in an MPEG-TS, and AVFoundation does not accept that
/// combination (Apple DevForum 132291).
///
/// **This is not a codec problem but a packaging problem.** The Apple TV decodes
/// HEVC in hardware, without any help. What is missing is the path from the
/// container to the decoder — and that can be built without decoding a single
/// line of video: pull the pictures out of the TS, put them into fMP4 unchanged,
/// hand them to AVFoundation. Apple still does the decoding.
///
/// This reader is the first step of that and at the same time answers a second
/// question that comes before any work: **What is actually inside the channels?**
/// Where MPEG-2 shows up, even the nicest repackaging does not help — this
/// hardware does not decode it.
///
/// ## How a transport stream is built
///
/// The structure is defined in ISO/IEC 13818-1 and can be explained in one
/// sentence: **188 bytes per packet, the first always `0x47`.** Every packet
/// carries an identifier (PID) that says what it belongs to. Two of them lead to
/// the goal:
///
/// - **PID 0** is the program table (PAT). For each program it names the
///   identifier of its description.
/// - That description (**PMT**) lists the streams: one type and one identifier
///   each — this is where it says whether the picture is H.264 or HEVC and the
///   audio AAC or AC-3.
public enum TransportStream {

    /// The length of a packet. Unchanged since the format exists.
    public static let packetSize = 188
    public static let syncByte: UInt8 = 0x47

    /// The identifier of the program table — always zero.
    static let patPID: UInt16 = 0

    /// What is in a stream, in the numbering of the specification.
    ///
    /// **Only the types that can occur here**, and the rest as `other`: A complete
    /// table would have forty entries, of which thirty-eight never appear — and each
    /// of them would be a line that distracts from what matters when reading.
    public enum StreamKind: Sendable, Equatable {
        case h264
        case hevc
        /// **The limit of this entire undertaking.** No Apple TV decodes MPEG-2; where
        /// that shows up, no repackaging helps.
        case mpeg2Video
        case aac
        case ac3
        case eac3
        /// MPEG audio, Layer I to III — the audio format of classic broadcasting (DVB in
        /// Europe, the Turkish national channels). Long wrongly believed to be "Apple
        /// cannot do that"; in fact CoreAudio decodes all three layers (verified 2026-08-16
        /// on a real frame). Read and packaged by ``MPEGAudio``.
        case mp2Audio
        /// DTS (Coherent Acoustics, 2026-09-04): The core is transcoded to AAC in the app —
        /// ``DTSTranscoder``. Matroska only; DTS does not occur in broadcast streams in
        /// this region.
        case dts
        /// **Subtitles that travel inside the stream** (AP6, 2026-09-03): Teletext
        /// (EN 300 706, descriptor `0x56`) and DVB subtitles (EN 300 743, `0x59`). Both
        /// travel as private PES data in the same type `0x06` as AC-3. They are
        /// **recognized, not yet read** — the "catalog" line names them so that the next
        /// report says which channels carry them at all. Neither audio nor picture:
        /// ``claimAudio`` never latches onto a text stream.
        case teletext
        case dvbSubtitle
        case other(UInt8)

        /// Whether this device can decode the stream at all — and therefore whether
        /// repackaging helps.
        ///
        /// **Deliberately not called "supported".** This does not say what the app can
        /// do, but what the hardware can do. The difference is the whole point: whatever
        /// is `false` here stays black, no matter how much work we put into it.
        public var isHardwareDecodable: Bool {
            switch self {
            case .h264, .hevc, .aac, .ac3, .eac3: true
            // For audio the software decoder is enough — it costs no picture.
            case .mp2Audio, .dts: true
            case .mpeg2Video: false
            case .teletext, .dvbSubtitle: false
            case .other: false
            }
        }

        /// Whether this stream carries subtitles.
        public var isSubtitle: Bool {
            switch self {
            case .teletext, .dvbSubtitle: true
            default: false
            }
        }

        public var isVideo: Bool {
            switch self {
            case .h264, .hevc, .mpeg2Video: true
            default: false
            }
        }

        /// The name for reports and diagnostics.
        public var name: String {
            switch self {
            case .h264: "H.264"
            case .hevc: "HEVC"
            case .mpeg2Video: "MPEG-2"
            case .aac: "AAC"
            case .ac3: "AC-3"
            case .eac3: "E-AC-3"
            case .mp2Audio: "MP2"
            case .dts: "DTS"
            case .teletext: "Teletext"
            case .dvbSubtitle: "DVB-Untertitel"
            case .other(let raw): String(format: "Typ 0x%02X", raw)
            }
        }

        /// The mapping from the specification, table 2-34.
        ///
        /// - Parameter descriptors: The descriptions of the stream from the program
        ///   table. **For type 0x06 they are not an extra, they ARE the answer:** 0x06
        ///   only means "private PES data", and what is inside is told only by the
        ///   descriptor — this is how DVB packages its AC-3 audio (on-device finding
        ///   2026-08-22, "A2 UHD": the diagnostics said "audio type 0x06", the channel stayed
        ///   silent, although the AC-3 path had long been ready in the codebase).
        static func from(streamType: UInt8, descriptors: Data = Data()) -> StreamKind {
            switch streamType {
            case 0x02: .mpeg2Video
            case 0x03, 0x04: .mp2Audio
            case 0x06: fromPrivateData(descriptors)
            case 0x0F, 0x11: .aac
            case 0x1B: .h264
            case 0x24: .hevc
            case 0x81: .ac3
            case 0x87: .eac3
            default: .other(streamType)
            }
        }

        /// What is in a private PES stream — read from the DVB descriptors (ETSI
        /// EN 300 468): 0x6A is AC-3, 0x7A E-AC-3, 0x05 the registration with the format
        /// tag as four letters. Without a known description it honestly stays at "type
        /// 0x06" — teletext and DVB subtitles travel the same way and are not audio.
        static func fromPrivateData(_ descriptors: Data) -> StreamKind {
            let bytes = Array(descriptors)
            var index = 0
            var text: StreamKind?
            while index + 2 <= bytes.count {
                let tag = bytes[index]
                let length = Int(bytes[index + 1])
                switch tag {
                case 0x6A: return .ac3
                case 0x7A: return .eac3
                case 0x05 where length >= 4:
                    // format_identifier — "AC-3" als ASCII.
                    let id = bytes[(index + 2)...].prefix(4)
                    if Array(id) == [0x41, 0x43, 0x2D, 0x33] { return .ac3 }
                // An audio tag beats a text tag — that is why the result is remembered here and
                // only answered at the end.
                case 0x56, 0x46: text = .teletext
                case 0x59: text = .dvbSubtitle
                default: break
                }
                index += 2 + length
            }
            return text ?? .other(0x06)
        }
    }

    /// A single stream inside the transport stream.
    public struct Elementary: Sendable, Equatable {
        public let pid: UInt16
        public let kind: StreamKind
        /// The language from the program table (ISO-639 descriptor, `deu`, `tur`) —
        /// `nil` if the channel names none. **For audio track selection** (AP6, 2026-09-03):
        /// Without it every track would just be called "Track 2".
        public let language: String?

        public init(pid: UInt16, kind: StreamKind, language: String? = nil) {
            self.pid = pid
            self.kind = kind
            self.language = language
        }
    }

    /// What a stream contains.
    public struct Inventory: Sendable, Equatable {
        public var streams: [Elementary] = []

        public var video: Elementary? { streams.first { $0.kind.isVideo } }
        public var audio: Elementary? { streams.first { !$0.kind.isVideo } }

        /// All audio streams the device can output — in the order of the table, the main
        /// version first.
        public var audioStreams: [Elementary] {
            streams.filter { !$0.kind.isVideo && $0.kind.isHardwareDecodable }
        }

        /// The subtitle streams — teletext and DVB, with a language where one is given.
        public var subtitleStreams: [Elementary] {
            streams.filter(\.kind.isSubtitle)
        }

        /// Whether this device can decode everything in it.
        ///
        /// The one question that matters: Where it is `true`, repackaging is enough;
        /// where it is `false`, a foreign decoder is needed.
        public var isFullyHardwareDecodable: Bool {
            !streams.isEmpty && streams.allSatisfy(\.kind.isHardwareDecodable)
        }

        /// A line for the report — "HEVC + AAC".
        public var summary: String {
            streams.isEmpty ? "empty" : streams.map(\.kind.name).joined(separator: " + ")
        }
    }

    // MARK: - Lesen

    /// Reads the program table and the stream description from the first packets.
    ///
    /// **A few kilobytes are enough.** PAT and PMT are repeated continuously so that
    /// a receiver can join at any time — anyone who wants to classify a channel does
    /// not have to download it, only look at it. That is why a provider's entire
    /// catalog can be screened without playing it.
    ///
    /// A stream that already starts in the middle of a packet is not forced: If the
    /// sync byte is not found at the start, it is searched for. That happens when a
    /// request jumps into the middle.
    public static func inventory(from data: Data) -> Inventory {
        var result = Inventory()
        guard let start = firstPacketOffset(in: data) else { return result }

        var pmtPID: UInt16?

        var offset = start
        while offset + packetSize <= data.count {
            let packet = data[offset..<(offset + packetSize)]
            offset += packetSize

            guard packet.first == syncByte else {
                // Alignment is lost — search again instead of guessing.
                guard let next = firstPacketOffset(in: data, from: offset) else { break }
                offset = next
                continue
            }

            let pid = Self.pid(of: packet)

            if pid == patPID, pmtPID == nil {
                pmtPID = firstProgramPID(inPAT: payload(of: packet))
            } else if let pmtPID, pid == pmtPID, result.streams.isEmpty {
                result.streams = streams(inPMT: payload(of: packet))
                // Found both — reading on would only bring repetitions.
                if !result.streams.isEmpty { break }
            }
        }

        return result
    }

    /// Looks for the next aligned packet.
    ///
    /// **A single `0x47` is not sufficient as proof** — the byte occurs constantly in
    /// picture data. Only when a second one stands 188 bytes later is it the packet
    /// boundary; otherwise one would latch onto a coincidence and read nothing but
    /// nonsense from there on.
    static func firstPacketOffset(in data: Data, from start: Int = 0) -> Int? {
        let base = data.startIndex
        var index = base + start
        let limit = data.endIndex - packetSize
        while index <= limit {
            if data[index] == syncByte,
                index + packetSize >= data.endIndex || data[index + packetSize] == syncByte
            {
                return index - base
            }
            index += 1
        }
        return nil
    }

    /// One byte of a packet — **via the index of the parent data**.
    ///
    /// **The finding** (AP7 · L3, expert review 2026-08-24): Per 188-byte packet there
    /// were four heap allocations, and on the delivery thread — exactly where the
    /// channel is not being accepted in the meantime: per megabyte of input 22,312
    /// malloc/free pairs and 4.17 MB of memcpy.
    ///
    /// **And the obvious fix would have been wrong.** `packet[1]` instead of
    /// `Array(packet)[1]` crashes: Three of the four call sites pass `Data`
    /// **slices** (`data[offset..<offset+188]`), and a slice keeps the indices of its
    /// parent data — `Array(...)` reset them to zero as a side effect, and the access
    /// relied on exactly that. The correct way is the index **relative to the
    /// start**.
    @inline(__always)
    static func byte(_ packet: Data, _ offset: Int) -> UInt8 {
        packet[packet.startIndex + offset]
    }

    static func pid(of packet: Data) -> UInt16 {
        (UInt16(byte(packet, 1) & 0x1F) << 8) | UInt16(byte(packet, 2))
    }

    /// The payload of a packet, without header and without adaptation field.
    ///
    /// The adaptation field carries timing information and padding bytes; its length
    /// is in its first byte. Anyone who skips over it starts in the middle of a
    /// table.
    static func payload(of packet: Data) -> Data {
        let hasAdaptation = (byte(packet, 3) & 0x20) != 0
        let hasPayload = (byte(packet, 3) & 0x10) != 0
        guard hasPayload else { return Data() }

        var start = 4
        if hasAdaptation {
            start = 5 + Int(byte(packet, 4))
        }
        guard start < packet.count else { return Data() }

        // If a table starts here, a pointer to its start comes first. It is almost
        // always zero, but not always.
        let pointer = Int(byte(packet, start))
        let tableStart = start + 1 + pointer
        guard tableStart < packet.count else { return Data() }
        return Data(packet[(packet.startIndex + tableStart)...])
    }

    /// The identifier of the first program description from the program table.
    ///
    /// **The first program is enough.** A channel transmits one; there are several
    /// only in real multiplexes, and those do not occur with IPTV.
    static func firstProgramPID(inPAT table: Data) -> UInt16? {
        let bytes = Array(table)
        // Table identifier 0x00 = PAT. Everything else is not our table.
        guard bytes.count > 8, bytes[0] == 0x00 else { return nil }

        let sectionLength = (Int(bytes[1] & 0x0F) << 8) | Int(bytes[2])
        // The header (8 bytes from the table identifier) and checksum (4) are not part
        // of it.
        let entriesEnd = min(3 + sectionLength - 4, bytes.count)
        var index = 8
        while index + 4 <= entriesEnd {
            let programNumber = (UInt16(bytes[index]) << 8) | UInt16(bytes[index + 1])
            let pid = (UInt16(bytes[index + 2] & 0x1F) << 8) | UInt16(bytes[index + 3])
            // Program 0 points to the network table, not to content.
            if programNumber != 0 { return pid }
            index += 4
        }
        return nil
    }

    /// The streams from a program description.
    /// The language from the ISO-639 descriptor (tag `0x0A`): three letters, then the
    /// kind (original, commentary, audio description). The first language is taken;
    /// hardly any channel names more.
    static func language(in descriptors: Data) -> String? {
        let bytes = Array(descriptors)
        var index = 0
        while index + 2 <= bytes.count {
            let tag = bytes[index]
            let length = Int(bytes[index + 1])
            let end = min(index + 2 + length, bytes.count)
            if tag == 0x0A, index + 5 <= end {
                let code = String(decoding: bytes[(index + 2)..<(index + 5)], as: UTF8.self)
                    .lowercased()
                if code.allSatisfy({ $0.isLetter }) { return code }
            }
            index = end
        }
        return nil
    }

    static func streams(inPMT table: Data) -> [Elementary] {
        let bytes = Array(table)
        guard bytes.count > 12, bytes[0] == 0x02 else { return [] }

        let sectionLength = (Int(bytes[1] & 0x0F) << 8) | Int(bytes[2])
        let end = min(3 + sectionLength - 4, bytes.count)

        // Before the streams comes a description of the program itself, of variable
        // length.
        let programInfoLength = (Int(bytes[10] & 0x0F) << 8) | Int(bytes[11])
        var index = 12 + programInfoLength

        var found: [Elementary] = []
        while index + 5 <= end {
            let type = bytes[index]
            let pid = (UInt16(bytes[index + 1] & 0x1F) << 8) | UInt16(bytes[index + 2])
            let infoLength = (Int(bytes[index + 3] & 0x0F) << 8) | Int(bytes[index + 4])
            // The descriptions of the stream — for type 0x06 THEY carry the information
            // about what is inside. See ``StreamKind/fromPrivateData``.
            let descriptorEnd = min(index + 5 + infoLength, end)
            let descriptors =
                index + 5 <= descriptorEnd
                ? Data(bytes[(index + 5)..<descriptorEnd]) : Data()
            found.append(
                Elementary(
                    pid: pid, kind: StreamKind.from(streamType: type, descriptors: descriptors),
                    language: language(in: descriptors))
            )
            index += 5 + infoLength
        }
        return found
    }
}

// MARK: - Die Bilddaten herausholen

extension TransportStream {

    /// Assembles the elementary stream of a channel from its packets.
    ///
    /// **The second step toward the repackager.** What comes out here is exactly what
    /// Apple's decoder needs — the same pictures, only without the transport stream
    /// packaging. Nothing is decoded; bytes are rearranged.
    ///
    /// A transport stream cuts every picture into 188-byte morsels and wraps a
    /// second layer of packaging (PES) around it that carries timing information.
    /// Both are stripped off here: The morsels become a stream again, and the PES
    /// headers disappear.
    public static func elementaryStream(from data: Data, pid wanted: UInt16) -> Data {
        guard let start = firstPacketOffset(in: data) else { return Data() }

        var result = Data()
        var offset = start

        while offset + packetSize <= data.count {
            let packet = data[offset..<(offset + packetSize)]
            offset += packetSize

            guard packet.first == syncByte else {
                guard let next = firstPacketOffset(in: data, from: offset) else { break }
                offset = next
                continue
            }
            guard pid(of: packet) == wanted else { continue }

            let startsUnit = (byte(packet, 1) & 0x40) != 0
            var payloadStart = 4
            if (byte(packet, 3) & 0x20) != 0 { payloadStart = 5 + Int(byte(packet, 4)) }
            guard (byte(packet, 3) & 0x10) != 0, payloadStart < packet.count else { continue }

            var chunk = Array(packet[(packet.startIndex + payloadStart)...])

            // At the start of a unit comes the PES header. Its length is variable and is
            // given in the ninth byte — anyone who skips over it pushes timestamps into the
            // middle of the picture data.
            if startsUnit, chunk.count > 8, chunk[0] == 0, chunk[1] == 0, chunk[2] == 1 {
                let headerLength = Int(chunk[8])
                let skip = 9 + headerLength
                guard skip <= chunk.count else { continue }
                chunk = Array(chunk[skip...])
            }

            result.append(contentsOf: chunk)
        }

        return result
    }

    /// Splits an elementary stream into its units (NAL units).
    ///
    /// H.264 and HEVC write their data as a sequence of units, each introduced by
    /// `00 00 01` or `00 00 00 01`. Both lengths occur — anyone who knows only one
    /// loses every second unit.
    ///
    /// The units are returned **without** their introducer: In fMP4 each unit is
    /// preceded by its length instead of a start pattern, and the introducer would be
    /// a foreign body there.
    public static func units(inElementaryStream data: Data) -> [Data] {
        let bytes = [UInt8](data)
        guard bytes.count > 4 else { return [] }

        var starts: [(index: Int, length: Int)] = []
        var index = 0
        while index + 3 < bytes.count {
            if bytes[index] == 0, bytes[index + 1] == 0 {
                if bytes[index + 2] == 1 {
                    starts.append((index, 3))
                    index += 3
                    continue
                }
                if bytes[index + 2] == 0, bytes[index + 3] == 1 {
                    starts.append((index, 4))
                    index += 4
                    continue
                }
            }
            index += 1
        }

        var units: [Data] = []
        for (position, start) in starts.enumerated() {
            let from = start.index + start.length
            let to = position + 1 < starts.count ? starts[position + 1].index : bytes.count
            guard from < to else { continue }
            units.append(Data(bytes[from..<to]))
        }
        return units
    }

    /// The descriptions Apple's decoder needs before the first picture.
    ///
    /// **Without them no decoder can start** — they tell it resolution, color depth
    /// and tool set. In the transport stream they are repeated continuously so that a
    /// receiver can join at any time; in fMP4 they appear exactly once, in the file
    /// header.
    ///
    /// HEVC carries three of them, H.264 two. They sit in the top bits of the first
    /// byte of a unit — for HEVC in bits 1 to 6, for H.264 in the lowest five.
    public struct ParameterSets: Sendable, Equatable {
        public var vps: Data?
        public var sps: Data?
        public var pps: Data?

        /// **The remaining picture parameter sets** — and without them a channel stayed
        /// black permanently (check agent 2026-08-23, "TR: NOKTA TV HQ").
        ///
        /// An H.264 stream may carry several PPS, each with its own identifier, and every
        /// picture says in its slice header which one it means. For NOKTA TV HQ the split
        /// is cleanly separated:
        ///
        /// ```
        /// pps_id 1 → all I fields   (20 in 20 s)
        /// pps_id 0 → all P and B fields
        /// ```
        ///
        /// Here there was only one field, and `parameterSets(in:kind:)` kept the
        /// **first** set — the zero. So the decoder never got to see the set for the
        /// I-pictures, and every single picture referred to something that did not
        /// exist. Re-measured with VideoToolbox:
        ///
        /// ```
        /// one PPS only:  0 of 168 pictures,  -8969 (codecBadDataErr) on ALL
        /// both PPS:      165 of 168 pictures
        /// ```
        ///
        /// That is exactly the reported symptom: no picture, audio plays — because the
        /// audio does not take this path at all.
        ///
        /// Kept separate from the first one and not as a list, so that ``pps`` and
        /// ``isComplete(for:)`` remain what they were.
        public var additionalPPS: [Data] = []

        /// All picture parameter sets in the order in which they arrived.
        public var allPPS: [Data] { pps.map { [$0] + additionalPPS } ?? [] }

        /// **The remaining sequence parameter sets** — the same situation as with
        /// ``additionalPPS``, only rarer: An `avcC` or `hvcC` may carry several SPS, each
        /// with its own identifier, and a PPS refers to its own. Until 2026-09-27 the
        /// header reader overwrote each with the next (repackager review B7) — only the
        /// last one arrived.
        public var additionalSPS: [Data] = []

        /// All sequence parameter sets in the order in which they arrived.
        public var allSPS: [Data] { sps.map { [$0] + additionalSPS } ?? [] }

        /// Takes in an SPS — the first becomes ``sps``, every further one not yet seen
        /// lands in ``additionalSPS``.
        mutating func ingest(sps unit: Data) {
            guard !unit.isEmpty else { return }
            if sps == nil {
                sps = unit
            } else if sps != unit, !additionalSPS.contains(unit) {
                additionalSPS.append(unit)
            }
        }

        /// Takes in a PPS — the first becomes ``pps``, every further one not yet seen
        /// lands in ``additionalPPS``. Duplicates are dropped: The sets usually appear
        /// again before every keyframe.
        mutating func ingest(pps unit: Data) {
            guard !unit.isEmpty else { return }
            if pps == nil {
                pps = unit
            } else if pps != unit, !additionalPPS.contains(unit) {
                additionalPPS.append(unit)
            }
        }

        /// Takes in everything from `other` that is still missing here.
        mutating func ingest(_ other: ParameterSets) {
            vps = vps ?? other.vps
            for unit in other.allSPS { ingest(sps: unit) }
            for unit in other.allPPS { ingest(pps: unit) }
        }

        /// Whether everything the decoder needs is together.
        ///
        /// For HEVC all three are required, for H.264 there is no VPS.
        public func isComplete(for kind: StreamKind) -> Bool {
            switch kind {
            case .hevc: vps != nil && sps != nil && pps != nil
            case .h264: sps != nil && pps != nil
            default: false
            }
        }
    }

    public static func parameterSets(in units: [Data], kind: StreamKind) -> ParameterSets {
        var found = ParameterSets()
        for unit in units {
            guard let first = unit.first else { continue }
            switch kind {
            case .hevc:
                switch (first & 0x7E) >> 1 {
                case 32: found.vps = found.vps ?? unit
                case 33: found.sps = found.sps ?? unit
                case 34: found.pps = found.pps ?? unit
                default: break
                }
            case .h264:
                switch first & 0x1F {
                case 7: found.sps = found.sps ?? unit
                case 8:
                    // **Collect all of them, not just the first** — rationale at
                    // ``ParameterSets/additionalPPS``.
                    found.ingest(pps: unit)
                default: break
                }
            default:
                break
            }
        }
        return found
    }
}

// MARK: - Bilder mit ihrer Zeit

extension TransportStream {

    /// A picture together with the time at which it is to be shown.
    public struct AccessUnit: Sendable, Equatable {
        /// The presentation time in MPEG ticks (90 kHz). `nil` if the packet carried
        /// none — not every one does.
        public let pts: UInt64?
        /// The units of this picture, without start pattern.
        public let units: [Data]
    }

    /// Splits the stream of a channel into pictures with timestamps.
    ///
    /// **The difference from ``elementaryStream(from:pid:)`` is time.** There a
    /// continuous stream is produced, good for inspection; here delimited pictures
    /// are produced, and each knows when it is to be shown. Without these boundaries
    /// no packet could be built for Apple's decoder — it wants to know where a
    /// picture ends and when it is its turn.
    ///
    /// The transport stream draws the boundaries itself: A set "a unit starts here"
    /// flag marks the start of the next picture.
    public static func accessUnits(from data: Data, pid wanted: UInt16) -> [AccessUnit] {
        payloads(from: data, pid: wanted).compactMap { payload in
            let units = units(inElementaryStream: payload.data)
            return units.isEmpty ? nil : AccessUnit(pts: payload.pts, units: units)
        }
    }

    /// The content of a PES packet together with its timestamp — raw.
    ///
    /// **There are no units to split for audio.** Picture data comes in units with
    /// start patterns; AAC comes as a sequence of ADTS frames, AC-3 as a sequence of
    /// sync frames. Both need the same packet loop but different evaluation — that is
    /// why the loop lives here and the evaluation above it.
    public struct ElementaryPayload: Sendable, Equatable {
        public let pts: UInt64?
        public let data: Data
    }

    /// Splits the stream of a channel into PES packets with timestamps.
    public static func payloads(from data: Data, pid wanted: UInt16) -> [ElementaryPayload] {
        guard let start = firstPacketOffset(in: data) else { return [] }

        var result: [ElementaryPayload] = []
        var pending = Data()
        var pendingPTS: UInt64?
        var hasStarted = false

        func flush() {
            guard hasStarted, !pending.isEmpty else { return }
            result.append(ElementaryPayload(pts: pendingPTS, data: pending))
            pending = Data()
        }

        var offset = start
        while offset + packetSize <= data.count {
            let packet = data[offset..<(offset + packetSize)]
            offset += packetSize

            guard packet.first == syncByte else {
                guard let next = firstPacketOffset(in: data, from: offset) else { break }
                offset = next
                continue
            }
            guard pid(of: packet) == wanted else { continue }

            var payloadStart = 4
            if (byte(packet, 3) & 0x20) != 0 { payloadStart = 5 + Int(byte(packet, 4)) }
            guard (byte(packet, 3) & 0x10) != 0, payloadStart < packet.count else { continue }

            let chunk = Array(packet[(packet.startIndex + payloadStart)...])

            if (byte(packet, 1) & 0x40) != 0 {
                // A new packet begins — the previous one is thereby complete.
                flush()
                hasStarted = true
                pendingPTS = SampleAssembly.presentationTimestamp(inPESHeader: Data(chunk))

                guard chunk.count > 8, chunk[0] == 0, chunk[1] == 0, chunk[2] == 1 else { continue }
                let skip = 9 + Int(chunk[8])
                guard skip <= chunk.count else { continue }
                pending.append(contentsOf: chunk[skip...])
            } else if hasStarted {
                pending.append(contentsOf: chunk)
            }
        }

        // **The last picture goes along.** It has no successor to complete it — without
        // this line the last picture would be lost on every request, and with short
        // morsels that would be a noticeable share.
        flush()
        return result
    }
}
