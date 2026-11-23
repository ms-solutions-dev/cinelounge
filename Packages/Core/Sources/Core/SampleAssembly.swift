import CoreMedia
import Foundation

/// Turns extracted picture data into finished packets for Apple's decoder.
///
/// **The seam of the whole remux effort.** In front of it are the readers — today for
/// MPEG-TS, later for MKV —, behind it Apple's tools. It is built **once** and used by both
/// readers; that is why two containers do not mean duplicate work.
///
/// ## What happens here — and what explicitly does not
///
/// **Nothing is decoded.** The picture data passes through unchanged; only its framing
/// changes. Two things are needed for that:
///
/// 1. **Start codes become lengths.** In a transport stream `00 00 01` introduces every
///    unit — the decoder searches for the pattern. In MP4, instead, **before** every unit
///    stands its length as four bytes. The same material, different bookkeeping.
/// 2. **Timestamps get a clock.** A transport stream counts in 90,000 steps per second;
///    CoreMedia wants it as ``CMTime``.
public enum SampleAssembly {

    /// The rate at which MPEG timestamps are counted — 90 kHz, as always.
    public static let timescale: Int32 = 90_000

    /// How many bytes the length before each unit occupies.
    ///
    /// Four, and that must match ``CMVideoFormatDescriptionCreateFromHEVCParameterSets``
    /// (`nalUnitHeaderLength`). If the two differ, the decoder reads lengths at the wrong place
    /// and gets nonsense — without an error message, because it cannot know that it counted
    /// wrong.
    public static let lengthPrefixSize = 4

    /// Writes units with a length prefix instead of a start code.
    ///
    /// **Parameter sets do not belong in it.** In MP4 they sit in the header of the file, not
    /// in the picture stream; sent along again, they would be data without a picture to the
    /// decoder. The caller therefore filters them out beforehand —
    /// ``TransportStream/parameterSets(in:kind:)`` finds them, and ``payloadUnits(from:kind:)``
    /// delivers exactly the rest.
    public static func lengthPrefixed(_ units: [Data]) -> Data {
        var result = Data()
        for unit in units {
            let length = UInt32(unit.count)
            result.append(UInt8((length >> 24) & 0xFF))
            result.append(UInt8((length >> 16) & 0xFF))
            result.append(UInt8((length >> 8) & 0xFF))
            result.append(UInt8(length & 0xFF))
            result.append(unit)
        }
        return result
    }

    /// The units that actually carry picture — without descriptions.
    public static func payloadUnits(
        from units: [Data], kind: TransportStream.StreamKind
    )
        -> [Data]
    {
        units.filter { unit in
            guard let first = unit.first else { return false }
            switch kind {
            case .hevc:
                // 32, 33, 34 are VPS, SPS, PPS. 35 is a delimiter (AUD) and likewise carries no picture.
                let type = (first & 0x7E) >> 1
                return !(32...35).contains(type)
            case .h264:
                let type = first & 0x1F
                return type != 7 && type != 8 && type != 9
            default:
                return true
            }
        }
    }

    /// Whether this picture stands on its own — a keyframe.
    ///
    /// **The most important property of a picture for everything that follows.** A segment must
    /// begin with a keyframe, otherwise the decoder lacks the basis for everything that comes
    /// after; and whoever jumps in in the middle when switching channels can see something only
    /// from the next one on.
    ///
    /// For HEVC these are types 16 to 21 (the IRAP group), for H.264 type 5.
    public static func isKeyframe(_ units: [Data], kind: TransportStream.StreamKind) -> Bool {
        var hasParameterSet = false
        var hasIntraSlice = false

        for unit in units {
            guard let first = unit.first else { continue }
            switch kind {
            case .hevc:
                if (16...21).contains((first & 0x7E) >> 1) { return true }
            case .h264:
                let type = first & 0x1F
                if type == 5 { return true }
                if type == 7 { hasParameterSet = true }
                // **Broadcast channels send I-frames without an IDR marking** (device finding 2026-08-16,
                // ALPA SPORT+: 241 access units, not a single NAL 5 — but a real I-frame every 0.8 s with
                // a parameter set in front of it). Whoever waits only for IDR never cuts there. An I-slice
                // counts only TOGETHER with a parameter set in the same packet — that protects against a
                // chance I in the middle of the group of pictures and gives the decoder the sets to join
                // with.
                if type == 1, isIntraSlice(unit) { hasIntraSlice = true }
            default:
                break
            }
        }
        return hasParameterSet && hasIntraSlice
    }

    /// Whether a NAL-1 slice is an I-slice (`slice_type` 2 or 7).
    ///
    /// Reads the first two Exp-Golomb numbers of the slice header: `first_mb_in_slice`, then
    /// `slice_type`. Nothing more is needed — and reading more would mean rebuilding half the
    /// standard.
    ///
    /// **Only the header goes into the reader** (AP73, 2026-10-11). The `BitReader` copies its
    /// input into a field; until then it was handed the whole slice — for a UHD picture several
    /// hundred kilobytes per picture, twenty-five times per second, for two numbers from the
    /// first bytes. ``sliceHeaderBytes`` suffice for both Exp-Golomb values even at 8K
    /// (`first_mb_in_slice` needs at most 33 bits).
    static let sliceHeaderBytes = 32

    static func isIntraSlice(_ unit: Data) -> Bool {
        var reader = BitReader(unit.dropFirst().prefix(Self.sliceHeaderBytes))
        guard reader.expGolomb() != nil, let sliceType = reader.expGolomb() else { return false }
        return sliceType == 2 || sliceType == 7
    }

    /// A small bit reader for Exp-Golomb numbers.
    struct BitReader {
        private let bytes: [UInt8]
        private var position = 0

        init(_ data: some Sequence<UInt8>) { bytes = Array(data) }

        mutating func bit() -> Int? {
            let index = position >> 3
            guard index < bytes.count else { return nil }
            let value = (bytes[index] >> (7 - (position & 7))) & 1
            position += 1
            return Int(value)
        }

        /// Several bits in a row, as a number.
        mutating func bits(_ count: Int) -> Int? {
            var result = 0
            for _ in 0..<count {
                guard let value = bit() else { return nil }
                result = (result << 1) | value
            }
            return result
        }

        /// The signed form (`se(v)`) — needed when reading the picture sets, see ``H264Fields``.
        mutating func signedExpGolomb() -> Int? {
            guard let value = expGolomb() else { return nil }
            let magnitude = (value + 1) / 2
            return value % 2 == 0 ? -magnitude : magnitude
        }

        mutating func expGolomb() -> Int? {
            var zeros = 0
            while true {
                guard let value = bit() else { return nil }
                if value == 1 { break }
                zeros += 1
                if zeros > 31 { return nil }
            }
            var result = 1
            for _ in 0..<zeros {
                guard let value = bit() else { return nil }
                result = (result << 1) | value
            }
            return result - 1
        }
    }

    /// Converts an MPEG timestamp into CoreMedia's timekeeping.
    public static func time(fromPTS pts: UInt64) -> CMTime {
        CMTime(value: CMTimeValue(pts), timescale: timescale)
    }

    /// Reads the presentation timestamp from a PES header.
    ///
    /// **It sits in five bytes, but not contiguously** — that is the quirk that does all the
    /// work here: The 33 bits are spread over five bytes and interrupted twice by marker bits.
    /// Whoever simply reads them one after the other gets a number that is off by orders of
    /// magnitude — and a picture that appears at the wrong time or not at all.
    ///
    /// `nil` if the header carries none: Not every packet has one, and an invented timestamp
    /// would be worse than none.
    public static func presentationTimestamp(inPESHeader header: Data) -> UInt64? {
        let bytes = [UInt8](header)
        // Start code, identifier, length, two flag bytes, header length: nine bytes, and only then
        // do the optional fields begin.
        guard bytes.count >= 14, bytes[0] == 0, bytes[1] == 0, bytes[2] == 1 else { return nil }

        // The upper two bits of the second flag byte say what is present: 0b10 presentation time
        // only, 0b11 decode time in addition.
        let flags = (bytes[7] & 0xC0) >> 6
        guard flags == 0b10 || flags == 0b11 else { return nil }

        return timestamp(in: bytes, at: 9)
    }

    /// Reads the decode timestamp from a PES header — or `nil`.
    ///
    /// **It exists only with picture reordering** (B-frames): Then the order of decoding differs
    /// from that of display, and the stream carries both times. Without it the writer died on
    /// backward-jumping timestamps (device finding 2026-08-16, Sola Sport Mix FHD: 37 MB received,
    /// 0 pieces — errors −11800/−16364).
    public static func decodingTimestamp(inPESHeader header: Data) -> UInt64? {
        let bytes = [UInt8](header)
        guard bytes.count >= 19, bytes[0] == 0, bytes[1] == 0, bytes[2] == 1 else { return nil }
        // Only 0b11 carries both times; the decode time directly follows the presentation time.
        guard (bytes[7] & 0xC0) >> 6 == 0b11 else { return nil }
        return timestamp(in: bytes, at: 14)
    }

    /// The five distributed bytes of an MPEG timestamp from a given position.
    private static func timestamp(in bytes: [UInt8], at start: Int) -> UInt64? {
        guard bytes.count >= start + 5 else { return nil }
        let p = Array(bytes[start..<(start + 5)])
        // Bits 32..30 from the first byte, then 15 bits each from two pairs — each pair ends on a
        // marker bit, which is skipped.
        var value = UInt64((p[0] & 0x0E) >> 1) << 30
        value |= UInt64(p[1]) << 22
        value |= UInt64((p[2] & 0xFE) >> 1) << 15
        value |= UInt64(p[3]) << 7
        value |= UInt64((p[4] & 0xFE) >> 1)
        return value
    }
}

// MARK: - Fertige Pakete

extension SampleAssembly {

    /// What can go wrong when building a packet.
    ///
    /// As an error and not as `nil`, because the causes differ and must be told apart when
    /// searching: A missing timestamp is a format problem, a rejected buffer a system problem.
    public enum AssemblyFailure: Error, Equatable {
        case noParameterSets
        case decoderRejectedParameterSets(OSStatus)
        case emptyPayload
        case bufferCreationFailed(OSStatus)
    }

    /// Builds the description that Apple's decoder needs before the first picture.
    ///
    /// **The core of the whole proof:** If Apple's own function makes something out of our
    /// extracted descriptions, its decoder understands our data. From here on, everything else
    /// is packaging.
    ///
    /// **An empty set is none** (remuxer check, 2026-09-27): An `avcC` may state a length of
    /// zero. An empty buffer without a start pointer would hang on it, and
    /// `withParameterSetPointers` would stop on unpacking — hence
    /// ``AssemblyFailure/noParameterSets``.
    public static func formatDescription(
        from sets: TransportStream.ParameterSets,
        kind: TransportStream.StreamKind,
        lengthSize: Int = SampleAssembly.lengthPrefixSize
    ) throws -> CMFormatDescription {
        var parts: [Data] = []
        switch kind {
        case .hevc:
            guard let vps = sets.vps, let sps = sets.sps, let pps = sets.pps else {
                throw AssemblyFailure.noParameterSets
            }
            parts = [vps, sps] + sets.additionalSPS + [pps] + sets.additionalPPS
        case .h264:
            guard let sps = sets.sps, let pps = sets.pps else {
                throw AssemblyFailure.noParameterSets
            }
            // **With all picture parameter sets** — the reasoning is at
            // ``TransportStream/ParameterSets/additionalPPS``. Apple's function takes any number;
            // rechecked with three sets: status 0, and both PPS are in the `avcC`.
            parts = [sps] + sets.additionalSPS + [pps] + sets.additionalPPS
        default:
            throw AssemblyFailure.noParameterSets
        }
        guard parts.allSatisfy({ !$0.isEmpty }) else { throw AssemblyFailure.noParameterSets }

        var description: CMFormatDescription?
        let status = parts.withParameterSetPointers { pointers, sizes in
            switch kind {
            case .hevc:
                CMVideoFormatDescriptionCreateFromHEVCParameterSets(
                    allocator: kCFAllocatorDefault,
                    parameterSetCount: parts.count,
                    parameterSetPointers: pointers,
                    parameterSetSizes: sizes,
                    nalUnitHeaderLength: Int32(lengthSize),
                    extensions: nil,
                    formatDescriptionOut: &description
                )
            default:
                CMVideoFormatDescriptionCreateFromH264ParameterSets(
                    allocator: kCFAllocatorDefault,
                    parameterSetCount: parts.count,
                    parameterSetPointers: pointers,
                    parameterSetSizes: sizes,
                    nalUnitHeaderLength: Int32(lengthSize),
                    formatDescriptionOut: &description
                )
            }
        }

        guard status == noErr, let description else {
            throw AssemblyFailure.decoderRejectedParameterSets(status)
        }
        return description
    }

    // MARK: - Halbbilder in der Beschreibung

    /// Writes into a format description that the stream carries **fields**.
    ///
    /// **The finding** (AP2 · U1, expert review 2026-08-24): On 2026-08-23 the viewer reported pictures
    /// that "felt dragged", and all German and Turkish channels of the tested provider are
    /// 1080i25 — two fields per frame. The app combines both into one picture
    /// (``TransportRemuxer/paired(units:piece:info:held:tally:)``) and reports a **full frame**
    /// to the decoder. It therefore does not know that it would have to deinterlace; it shows
    /// two time-offset fields as one picture, and with motion the comb is visible.
    ///
    /// `FieldCount = 2` and `FieldDetail` are the details by which the AVFoundation chain
    /// recognises this.
    ///
    /// **What is NOT claimed here:** that tvOS 26 deinterlaces as a result. The source for this
    /// expectation is VLC's source from the iOS era (`MediaSource.swift:262`), and it is not
    /// proven — ten minutes on the device decide that. The detail is correct anyway: It
    /// describes the stream as it is, and a description that lies can in no case be better than
    /// one that is right.
    ///
    /// **Top field first** is the norm for everything that comes from a broadcast chain
    /// (1080i25 and 576i50). Deliberately as a default and not as a measurement: Which field
    /// came first is known only in the first picture pair — but the description is created
    /// already from the parameter sets, i.e. before.
    public static func withFields(_ description: CMFormatDescription) -> CMFormatDescription {
        let dimensions = CMVideoFormatDescriptionGetDimensions(description)
        guard dimensions.width > 0, dimensions.height > 0 else { return description }

        var extensions =
            (CMFormatDescriptionGetExtensions(description) as? [CFString: Any]) ?? [:]
        extensions[kCMFormatDescriptionExtension_FieldCount] = 2 as CFNumber
        extensions[kCMFormatDescriptionExtension_FieldDetail] =
            kCMFormatDescriptionFieldDetail_SpatialFirstLineEarly

        var incoming: CMFormatDescription?
        let status = CMVideoFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            codecType: description.mediaSubType.rawValue,
            width: dimensions.width, height: dimensions.height,
            extensions: extensions as CFDictionary,
            formatDescriptionOut: &incoming)
        // **When in doubt, the old one.** A description without the field detail is the state of
        // before; one that did not come into existence at all would be a black picture.
        guard status == noErr, let incoming else { return description }
        return incoming
    }

    /// Turns a frame that already has lengths instead of start codes into a packet.
    ///
    /// **The path for MKV, and it is the shorter one.** What the transport-stream path laboriously
    /// produces — start codes to lengths — a file already brings along. The bytes pass through
    /// unchanged; only the times and the keyframe marking are added.
    ///
    /// **Why a decode time is set here and not for the channel:** A transport stream carries it
    /// in the packet header, MKV does not — there it has to be produced (``DecodeOrder``).
    /// Without it the writer takes the presentation order for the decode order.
    public static func sampleBuffer(
        lengthPrefixed frame: Data,
        presentationTime: CMTime,
        decodeTime: CMTime,
        duration: CMTime = .invalid,
        isKeyframe: Bool,
        format: CMFormatDescription
    ) throws -> CMSampleBuffer {
        guard !frame.isEmpty else { throw AssemblyFailure.emptyPayload }

        let block = try blockBuffer(for: frame)
        var timing = CMSampleTimingInfo(
            duration: duration,
            presentationTimeStamp: presentationTime,
            decodeTimeStamp: decodeTime
        )
        var size = frame.count

        var sample: CMSampleBuffer?
        let status = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: block,
            formatDescription: format,
            sampleCount: 1,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &size,
            sampleBufferOut: &sample
        )
        guard status == noErr, let sample else {
            throw AssemblyFailure.bufferCreationFailed(status)
        }

        if !isKeyframe { markAsDependent(sample) }
        return sample
    }

    /// Sets the "does not stand on its own" attachment.
    ///
    /// **Its absence is the statement, not its presence.** Where it is missing, the writer
    /// takes a picture for a keyframe and possibly cuts in the middle of a group of pictures.
    static func markAsDependent(_ sample: CMSampleBuffer) {
        guard
            let attachments = CMSampleBufferGetSampleAttachmentsArray(
                sample, createIfNecessary: true),
            CFArrayGetCount(attachments) > 0
        else { return }

        let entry = unsafeBitCast(
            CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
        CFDictionarySetValue(
            entry,
            Unmanaged.passUnretained(kCMSampleAttachmentKey_NotSync).toOpaque(),
            Unmanaged.passUnretained(kCFBooleanTrue).toOpaque()
        )
    }

    /// Copies bytes into a buffer that CoreMedia can pass on.
    ///
    /// The memory is copied and not borrowed: The data comes from a buffer that is reused right
    /// away — a borrowed pointer would point to the next picture shortly after.
    static func blockBuffer(for payload: Data) throws -> CMBlockBuffer {
        var block: CMBlockBuffer?
        var status = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: payload.count,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: payload.count,
            flags: 0,
            blockBufferOut: &block
        )
        guard status == noErr, let block else {
            throw AssemblyFailure.bufferCreationFailed(status)
        }

        status = payload.withUnsafeBytes { raw in
            CMBlockBufferReplaceDataBytes(
                with: raw.baseAddress!,
                blockBuffer: block,
                offsetIntoDestination: 0,
                dataLength: payload.count
            )
        }
        guard status == noErr else { throw AssemblyFailure.bufferCreationFailed(status) }
        return block
    }

    /// Turns a picture into a packet as CoreMedia expects it.
    ///
    /// **The duration is deliberately left open** (`.invalid`): For a running channel it is not
    /// fixed, and a guessed duration would shift every following picture. The player goes by
    /// the presentation times, and those are in the stream.
    public static func sampleBuffer(
        for unit: TransportStream.AccessUnit,
        kind: TransportStream.StreamKind,
        format: CMFormatDescription
    ) throws -> CMSampleBuffer {
        let payload = lengthPrefixed(payloadUnits(from: unit.units, kind: kind))
        guard !payload.isEmpty else { throw AssemblyFailure.emptyPayload }

        let block = try blockBuffer(for: payload)
        var timing = CMSampleTimingInfo(
            duration: .invalid,
            presentationTimeStamp: unit.pts.map(time(fromPTS:)) ?? .invalid,
            decodeTimeStamp: .invalid
        )
        var size = payload.count

        var sample: CMSampleBuffer?
        let status = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: block,
            formatDescription: format,
            sampleCount: 1,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &size,
            sampleBufferOut: &sample
        )
        guard status == noErr, let sample else {
            throw AssemblyFailure.bufferCreationFailed(status)
        }

        // **Without this marking the writer takes every picture for a keyframe** — and writes a
        // structure that AVFoundation accepts and then discards (code -12881, shown on 2026-08-09).
        if !isKeyframe(unit.units, kind: kind) { markAsDependent(sample) }
        return sample
    }
}

extension Array where Element == Data {

    /// Passes descriptions on to Apple's C interface.
    ///
    /// Awkward, but unavoidable: The functions expect an array of pointers, and those may be
    /// valid only within this call.
    ///
    /// **Dangling pointers stood here, and they would have left the release build without a
    /// picture** (check agent 2026-08-23). The old version took the address from
    /// `withUnsafeBufferPointer` out with it:
    ///
    /// ```swift
    /// buffers[index].withUnsafeBufferPointer { pointers.append($0.baseAddress!) }
    /// ```
    ///
    /// After that the address is invalid. In the **debug** build — and `device.sh` builds
    /// debug — the array survives by chance long enough, which is why it ran on the TV. With
    /// `-O`, `formatDescription` failed in the agent's rebuild on **every** channel with
    /// `-12712`: not a single segment.
    ///
    /// Now one contiguous block of memory is allocated and the sets are copied into it — the
    /// pointers point to valid bytes until the end of this call, and afterwards everything is
    /// gone again.
    func withParameterSetPointers<Result>(
        _ body: (UnsafePointer<UnsafePointer<UInt8>>, UnsafePointer<Int>) -> Result
    ) -> Result {
        let sets = map { [UInt8]($0) }
        let sizes = sets.map(\.count)
        var flat = [UInt8]()
        flat.reserveCapacity(sizes.reduce(0, +))
        for set in sets { flat += set }

        return flat.withUnsafeBufferPointer { storage in
            let base = storage.baseAddress!
            var pointers: [UnsafePointer<UInt8>] = []
            var offset = 0
            for size in sizes {
                pointers.append(base + offset)
                offset += size
            }
            return pointers.withUnsafeBufferPointer { pointerBuffer in
                sizes.withUnsafeBufferPointer { sizeBuffer in
                    body(pointerBuffer.baseAddress!, sizeBuffer.baseAddress!)
                }
            }
        }
    }
}
