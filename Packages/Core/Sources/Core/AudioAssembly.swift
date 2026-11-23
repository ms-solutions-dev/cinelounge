import AudioToolbox
import CoreMedia
import Foundation

/// Turns AAC audio in the transport stream into packets the way CoreMedia expects them.
///
/// **The audio arrives differently from the picture.** Picture data lies in units with
/// start patterns, and one PES packet carries exactly one picture. AAC lies as a sequence of
/// **ADTS frames**, and one PES packet carries several of them — with exactly one timestamp
/// for the first. The time of the others is computed: Each frame carries 1024 samples, and
/// from that its duration follows down to the sample.
///
/// **The ADTS header is thrown out.** It is packaging for transport; in MP4 the same
/// information stands exactly once in the track description. Whoever sends it along hands
/// the decoder seven bytes before every frame that it takes for audio.
public enum AudioAssembly {

    /// How many samples an AAC frame carries. Fixed in the format.
    public static let samplesPerFrame = 1024

    /// The sample rates that the header points to via an index.
    static let sampleRates = [
        96000, 88200, 64000, 48000, 44100, 32000,
        24000, 22050, 16000, 12000, 11025, 8000, 7350,
    ]

    public enum AudioFailure: Error, Equatable {
        case noFrames
        case descriptionRejected(OSStatus)
        case bufferCreationFailed(OSStatus)
    }

    /// What is in the header of an ADTS frame.
    public struct ADTSHeader: Sendable, Equatable {
        public let sampleRateIndex: Int
        public let channelConfiguration: Int
        /// 2 for AAC-LC. In the header it is stored decreased by one.
        public let objectType: Int
        /// 7 bytes without checksum, 9 with.
        public let headerSize: Int
        /// The length of the whole frame **including** the header.
        public let frameLength: Int

        public var sampleRate: Int {
            sampleRateIndex < sampleRates.count ? sampleRates[sampleRateIndex] : 48000
        }

        /// **Not the same as the layout number.** At 7 the stream holds eight channels; everything
        /// above is not provided for. For our purposes the simple mapping is enough — the
        /// description needs nothing more than the channel count.
        public var channels: Int { channelConfiguration == 7 ? 8 : channelConfiguration }
    }

    /// Reads a header at this position, if there is one.
    ///
    /// **More than the sync pattern is checked.** The twelve set bits occur by chance in audio
    /// data; without the extra checks one would find frames in the middle of noise and read
    /// nonsense from there on.
    public static func header(at offset: Int, in data: Data) -> ADTSHeader? {
        let base = data.startIndex + offset
        guard base + 7 <= data.endIndex else { return nil }

        let b = { (i: Int) -> Int in Int(data[base + i]) }
        guard b(0) == 0xFF, (b(1) & 0xF6) == 0xF0 else { return nil }

        let hasCRC = (b(1) & 0x01) == 0
        let objectType = ((b(2) >> 6) & 0x03) + 1
        let sampleRateIndex = (b(2) >> 2) & 0x0F
        let channelConfiguration = ((b(2) & 0x01) << 2) | ((b(3) >> 6) & 0x03)
        let frameLength = ((b(3) & 0x03) << 11) | (b(4) << 3) | ((b(5) >> 5) & 0x07)
        let headerSize = hasCRC ? 9 : 7

        guard sampleRateIndex < sampleRates.count,
            channelConfiguration >= 1, channelConfiguration <= 7,
            frameLength > headerSize
        else { return nil }

        return ADTSHeader(
            sampleRateIndex: sampleRateIndex,
            channelConfiguration: channelConfiguration,
            objectType: objectType,
            headerSize: headerSize,
            frameLength: frameLength
        )
    }

    /// A frame without its header.
    public struct Frame: Sendable, Equatable {
        public let header: ADTSHeader
        /// The bare AAC content, without the ADTS header.
        public let payload: Data
    }

    /// Splits a PES payload into frames.
    ///
    /// **Keeps going where it stumbles.** With a live channel you start in the middle of the
    /// stream, and the first bytes are often half a frame. Whoever gives up then has no audio at
    /// every channel switch; whoever moves on one byte and searches again finds the next start.
    public static func frames(in data: Data) -> [Frame] {
        var result: [Frame] = []
        var offset = 0

        while offset < data.count {
            guard let header = header(at: offset, in: data) else {
                offset += 1
                continue
            }
            let start = data.startIndex + offset
            guard start + header.frameLength <= data.endIndex else { break }

            let payload = data[(start + header.headerSize)..<(start + header.frameLength)]
            result.append(Frame(header: header, payload: Data(payload)))
            offset += header.frameLength
        }
        return result
    }

    // MARK: - Für CoreMedia

    /// Builds the track description for the audio.
    ///
    /// **Without a "magic cookie", and that is the lesson of half an evening.** The obvious move
    /// is to pass along the two bytes of AudioSpecificConfig from the ADTS header — the same
    /// information, just once instead of before every frame. CoreMedia accepts it,
    /// `AVAssetWriter` accepts every audio packet, reports no error — and writes **no audio
    /// track**. Picture yes, audio gone, without a word.
    ///
    /// The reason: For `kAudioFormatMPEG4AAC`, CoreMedia expects a complete `esds` structure as
    /// the cookie, not the bare configuration. Whoever supplies the wrong kind supplies something
    /// unreadable — and where nothing can be read, no track arises.
    ///
    /// Without a cookie, CoreMedia builds the structure itself, from sample rate, channel count
    /// and frame length. Confirmed by a counter-check: the same frames, once with and once
    /// without — with a cookie zero audio tracks, without one a track.
    public static func formatDescription(for header: ADTSHeader) throws -> CMFormatDescription {
        try formatDescription(sampleRate: header.sampleRate, channels: header.channels)
    }

    /// Reads sample rate and channel count from the description that MKV stores.
    ///
    /// **Two bytes in which everything is:** five bits of object type, four bits for the sample
    /// rate as a table index, four bits for the channel layout. Exactly the information that for
    /// a channel is read from every single frame header — a file says it once and is done.
    ///
    /// `nil` if the sample rate is spelled out instead of given as a table index; then the track
    /// table knows better.
    public static func configuration(
        fromAudioSpecificConfig config: Data
    )
        -> (sampleRate: Int, channels: Int)?
    {
        guard config.count >= 2 else { return nil }
        let base = config.startIndex
        let first = Int(config[base])
        let second = Int(config[base + 1])

        let index = ((first & 0x07) << 1) | ((second >> 7) & 0x01)
        let channelConfiguration = (second >> 3) & 0x0F
        guard index < sampleRates.count, channelConfiguration > 0 else { return nil }

        return (sampleRates[index], channelConfiguration == 7 ? 8 : channelConfiguration)
    }

    /// The two bytes of AudioSpecificConfig for sample rate and channel count.
    ///
    /// Five bits of object type (2 = AAC-LC), four bits of sample rate as a table index, four
    /// bits of channel layout — the same structure that a Matroska brings along as
    /// `CodecPrivate`. For a channel it is nowhere; it is rebuilt from the ADTS header.
    static func audioSpecificConfig(sampleRate: Int, channels: Int) -> Data? {
        guard let index = sampleRates.firstIndex(of: sampleRate) else { return nil }
        let configuration = channels == 8 ? 7 : channels
        guard (1...7).contains(configuration) else { return nil }
        let objectType = 2
        let first = UInt8((objectType << 3) | (index >> 1))
        let second = UInt8(((index & 1) << 7) | (configuration << 3))
        return Data([first, second])
    }

    /// The "magic cookie" for AAC — a complete `esds` structure.
    ///
    /// **Without it the channel stays mute, and that is measured** (2026-08-11): The remuxed stream
    /// carried an audio track of the right length, `ffprobe` read it as `aac` — but without
    /// `extradata` and with the wrong channel count. ffmpeg decodes that anyway, because it
    /// guesses the description from the first frame; **Apple's decoder does not.**
    /// `AVAssetReader` delivered zero packets and the error `'bada'` — for the viewer: picture
    /// plays, no audio.
    ///
    /// **The earlier finding "with a cookie no audio track" was right and the lesson drawn from
    /// it wrong.** Back then the bare two bytes of the AudioSpecificConfig were passed;
    /// CoreMedia expects the whole `esds` structure for `kAudioFormatMPEG4AAC` — and where
    /// something unreadable stands, no track arises. The conclusion "so no cookie at all"
    /// swapped one cause for another: Instead of no audio track there was one that nobody can
    /// open.
    ///
    /// The structure is that of the MPEG-4 systems description: ES_Descriptor (0x03) over
    /// DecoderConfigDescriptor (0x04) over DecoderSpecificInfo (0x05), plus an
    /// SLConfigDescriptor (0x06). All lengths stay below 128 and therefore fit in one byte each.
    static func magicCookie(sampleRate: Int, channels: Int) -> Data? {
        guard let config = audioSpecificConfig(sampleRate: sampleRate, channels: channels)
        else { return nil }

        var decoderSpecific = Data([0x05, UInt8(config.count)])
        decoderSpecific.append(config)

        var decoderConfig = Data([
            0x40,  // Objekttyp: MPEG-4 AAC
            0x15,  // Stream type: audio (0x05 << 2), not upstream, reservation set
            0x00, 0x00, 0x00,  // Buffer size — 0 means "unknown"
            0x00, 0x00, 0x00, 0x00,  // Spitzenrate
            0x00, 0x00, 0x00, 0x00,  // Durchschnittsrate
        ])
        decoderConfig.append(decoderSpecific)
        var payload = Data([0x04, UInt8(decoderConfig.count)])
        payload.append(decoderConfig)

        // The SL part carries no information but must be there.
        payload.append(contentsOf: [0x06, 0x01, 0x02])

        var cookie = Data([0x03, UInt8(payload.count + 3)])
        cookie.append(contentsOf: [0x00, 0x00, 0x00])  // ES ID and flags
        cookie.append(payload)
        return cookie
    }

    public static func formatDescription(
        sampleRate: Int, channels: Int
    ) throws
        -> CMFormatDescription
    {
        var asbd = AudioStreamBasicDescription(
            mSampleRate: Float64(sampleRate),
            // **One format identifier for all ADTS cases.** The header has only two bits for the object
            // type and thus knows Main, LC, SSR and LTP; HE-AAC appears there as LC and is recognized by
            // the decoder from the content. A separate identifier for it would be a statement that the
            // stream does not provide at all.
            mFormatID: kAudioFormatMPEG4AAC,
            mFormatFlags: 0,
            mBytesPerPacket: 0,
            mFramesPerPacket: UInt32(samplesPerFrame),
            mBytesPerFrame: 0,
            mChannelsPerFrame: UInt32(channels),
            mBitsPerChannel: 0,
            mReserved: 0
        )

        var description: CMFormatDescription?
        // The cookie is passed along if it can be built — see
        // ``magicCookie(sampleRate:channels:)``. If it cannot be built (unknown sample rate), the
        // old way remains: a track without a description is still better than none at all.
        let cookie = magicCookie(sampleRate: sampleRate, channels: channels)
        let status =
            cookie.map { cookie in
                cookie.withUnsafeBytes { bytes in
                    CMAudioFormatDescriptionCreate(
                        allocator: kCFAllocatorDefault,
                        asbd: &asbd,
                        layoutSize: 0,
                        layout: nil,
                        magicCookieSize: bytes.count,
                        magicCookie: bytes.baseAddress,
                        extensions: nil,
                        formatDescriptionOut: &description
                    )
                }
            }
            ?? CMAudioFormatDescriptionCreate(
                allocator: kCFAllocatorDefault,
                asbd: &asbd,
                layoutSize: 0,
                layout: nil,
                magicCookieSize: 0,
                magicCookie: nil,
                extensions: nil,
                formatDescriptionOut: &description
            )

        guard status == noErr, let description else {
            throw AudioFailure.descriptionRejected(status)
        }
        return description
    }

    /// Turns a frame into a packet with time and duration.
    ///
    /// **Unlike with the picture, the duration is known here and is set.** An AAC frame is always
    /// 1024 samples long; the timescale is the sample rate, so that the calculation comes out
    /// without remainder. If the duration stayed open, AVFoundation would have to estimate it
    /// from the distance to the next frame — and the last frame of a segment has no next one.
    public static func sampleBuffer(
        for frame: Frame,
        at time: CMTime,
        format: CMFormatDescription
    ) throws -> CMSampleBuffer {
        try sampleBuffer(
            payload: frame.payload,
            at: time,
            duration: CMTime(
                value: CMTimeValue(samplesPerFrame),
                timescale: CMTimeScale(frame.header.sampleRate)),
            format: format
        )
    }

    /// The same for a frame that is already available bare.
    ///
    /// **The path for MKV.** There is no ADTS header before the data — the description sits in
    /// the file header, and the frame is only payload. That both paths converge here is the
    /// point: There is one place where audio packets arise, not two.
    public static func sampleBuffer(
        payload: Data,
        at time: CMTime,
        duration: CMTime,
        format: CMFormatDescription
    ) throws -> CMSampleBuffer {
        guard !payload.isEmpty else { throw AudioFailure.noFrames }

        let block: CMBlockBuffer
        do {
            block = try SampleAssembly.blockBuffer(for: payload)
        } catch SampleAssembly.AssemblyFailure.bufferCreationFailed(let status) {
            throw AudioFailure.bufferCreationFailed(status)
        }

        var timing = CMSampleTimingInfo(
            duration: duration,
            presentationTimeStamp: time,
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
            throw AudioFailure.bufferCreationFailed(status)
        }
        return sample
    }

    /// All frames of a PES packet with their times.
    ///
    /// **The timestamp applies to the first frame**; the others are counted up. Whoever gave all
    /// of them the same time would put two tenths of a second of audio on the same instant —
    /// AVFoundation accepts that and then plays with a growing offset to the picture.
    public static func sampleBuffers(
        in payload: TransportStream.ElementaryPayload,
        format: CMFormatDescription
    ) throws -> [CMSampleBuffer] {
        guard let pts = payload.pts else { throw AudioFailure.noFrames }
        let start = SampleAssembly.time(fromPTS: pts)

        return try frames(in: payload.data).enumerated().map { index, frame in
            let offset = CMTime(
                value: CMTimeValue(index * samplesPerFrame),
                timescale: CMTimeScale(frame.header.sampleRate))
            return try sampleBuffer(for: frame, at: start + offset, format: format)
        }
    }
}
