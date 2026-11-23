import CoreMedia
import Foundation

/// Reads the header of an AC-3 or E-AC-3 frame.
///
/// **Not the special case it was long thought to be.** In the media library, 974 of 1408
/// titles carry AC-3 as an audio track — it is the most common audio format in the
/// catalog, not the exception. Without this reader the whole remuxer would be useless for
/// two thirds of the movies.
///
/// ## Why there is no description from the file header
///
/// AAC puts its description in `CodecPrivate`, two bytes, done. AC-3 does not — the track
/// table names only the format. Everything else is in the **first frame of the stream**:
/// sample rate, channel count, frame length. So you have to start reading to know what you
/// are reading.
public enum AC3Audio {

    /// What a frame header reveals.
    ///
    /// **The raw fields are included, and there is a reason.** The description a MP4 needs
    /// cannot be built from sample rate and channel count alone — there the format wants to
    /// see its own identifiers again (see ``configurationAtom``).
    public struct FrameInfo: Sendable, Equatable {
        public let isEnhanced: Bool
        public let sampleRate: Int
        public let channels: Int
        /// Samples per frame — always 1536 for AC-3, variable for E-AC-3.
        public let samplesPerFrame: Int
        /// Length of the frame in bytes, when the header provides it.
        public let frameSize: Int?

        var fscod: Int
        var bsid: Int
        var bsmod: Int
        var acmod: Int
        var lfeon: Int
        /// Table index of the bitrate — contained in the header only for AC-3.
        var bitrateCode: Int
        /// Bitrate in kbit/s, computed from frame length and frame duration.
        var dataRate: Int
    }

    static let syncword: UInt16 = 0x0B77
    static let sampleRates = [48000, 44100, 32000]
    /// Half rates when `fscod` points to the extension (E-AC-3 only).
    static let halfSampleRates = [24000, 22050, 16000]

    /// Channels per `acmod`, without the low-frequency channel.
    static let channelsPerMode = [2, 1, 2, 3, 3, 4, 4, 5]

    /// Bitrates in kbit/s, indexed halved by `frmsizecod`.
    static let bitrates = [
        32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320, 384, 448, 512, 576, 640,
    ]

    /// Liest den Kopf am Anfang dieser Daten.
    public static func info(in data: Data) -> FrameInfo? {
        let base = data.startIndex
        guard data.count >= 6 else { return nil }
        let byte = { (index: Int) -> Int in Int(data[base + index]) }
        guard byte(0) == 0x0B, byte(1) == 0x77 else { return nil }

        // **The identifier decides the whole further layout** — and it sits in the same place as
        // in the old version. This is the one spot where the two formats touch.
        let bsid = byte(5) >> 3
        return bsid > 10 ? enhanced(data) : classic(data)
    }

    /// AC-3, as it has looked since the Laserdisc.
    static func classic(_ data: Data) -> FrameInfo? {
        let base = data.startIndex
        guard data.count >= 7 else { return nil }
        let byte = { (index: Int) -> Int in Int(data[base + index]) }

        let fscod = byte(4) >> 6
        let frmsizecod = byte(4) & 0x3F
        guard fscod < sampleRates.count, frmsizecod < bitrates.count * 2 else { return nil }

        let acmod = byte(6) >> 5
        // After `acmod`, depending on the channel layout, one to three extra fields follow, and
        // only then the low-frequency channel. The number of bits before it depends on the channel
        // layout.
        var bits = 3
        if acmod & 0x01 != 0, acmod != 1 { bits += 2 }
        if acmod & 0x04 != 0 { bits += 2 }
        if acmod == 0x02 { bits += 2 }
        let lfe = (byte(6) >> (7 - bits)) & 0x01

        let rate = sampleRates[fscod]
        // The frame length is stored as a word count in a table; it follows from bitrate and
        // sample rate, because AC-3 has a fixed frame duration.
        let kilobits = bitrates[frmsizecod / 2]
        var size = kilobits * 1000 * 1536 / rate / 8
        if fscod == 1 { size += frmsizecod % 2 }  // 44.1 kHz does not divide evenly.

        return FrameInfo(
            isEnhanced: false,
            sampleRate: rate,
            channels: channelsPerMode[acmod] + lfe,
            samplesPerFrame: 1536,
            frameSize: size,
            fscod: fscod,
            bsid: byte(5) >> 3,
            bsmod: byte(5) & 0x07,
            acmod: acmod,
            lfeon: lfe,
            bitrateCode: frmsizecod / 2,
            dataRate: kilobits
        )
    }

    /// E-AC-3, whose header is built differently from the old one.
    static func enhanced(_ data: Data) -> FrameInfo? {
        let base = data.startIndex
        guard data.count >= 6 else { return nil }
        let byte = { (index: Int) -> Int in Int(data[base + index]) }

        let frmsiz = ((byte(2) & 0x07) << 8) | byte(3)
        let fscod = byte(4) >> 6
        let numblkscod = (byte(4) >> 4) & 0x03
        let acmod = (byte(4) >> 1) & 0x07
        let lfe = byte(4) & 0x01

        let rate: Int
        let blocks: Int
        if fscod == 3 {
            // **The half sample rate sits where the block count is.** Whoever overlooks this takes
            // 24 kHz for 48 kHz — and the audio runs at double speed, with a cause that looks like a
            // bug in the decoder.
            guard numblkscod < halfSampleRates.count else { return nil }
            rate = halfSampleRates[numblkscod]
            blocks = 6
        } else {
            rate = sampleRates[fscod]
            blocks = [1, 2, 3, 6][numblkscod]
        }

        let size = (frmsiz + 1) * 2
        let samples = blocks * 256

        return FrameInfo(
            isEnhanced: true,
            sampleRate: rate,
            channels: channelsPerMode[acmod] + lfe,
            samplesPerFrame: samples,
            frameSize: size,
            fscod: fscod,
            bsid: byte(5) >> 3,
            // **The identifier for the intended use is not at a fixed position in E-AC-3**, but behind
            // fields of variable length. Zero means "complete main program" and is right for
            // everything found in a media library.
            bsmod: 0,
            acmod: acmod,
            lfeon: lfe,
            bitrateCode: 0,
            dataRate: size * 8 * rate / samples / 1000
        )
    }

    // MARK: - Die Beschreibung, die ein MP4 verlangt

    /// Builds the field that must sit next to the audio track in the MP4 — `dac3`/`dec3`.
    ///
    /// **The place where AAC and AC-3 differ, and it cost a day.** For AAC, CoreMedia builds
    /// the missing details itself; for AC-3 it does not. The writer accepts the audio packets
    /// anyway, reports no error and creates an audio track — just one without this field. The
    /// player then rejects the finished file with `-12848` ("This media may be damaged") and
    /// no hint of what is missing.
    ///
    /// **Confirmed by a counter-check on 2026-08-10:** the same frames, the same description, once
    /// with and once without this field — without it the file is rejected, with it it plays.
    /// The header grows by exactly 13 bytes.
    ///
    /// What it contains are the raw identifiers from the frame header: sample rate, version,
    /// channel layout, low-frequency channel, bitrate. None of that can be recomputed from
    /// "48 kHz, six channels" — that is why an `ASBD` is not enough here.
    public static func configurationAtom(for info: FrameInfo) -> (name: String, data: Data) {
        var bits = BitWriter()
        if info.isEnhanced {
            bits.write(info.dataRate, 13)
            bits.write(0, 3)  // One substream; more does not occur in files.
            bits.write(info.fscod, 2)
            bits.write(info.bsid, 5)
            bits.write(0, 1)
            bits.write(0, 1)  // asvc
            bits.write(info.bsmod, 3)
            bits.write(info.acmod, 3)
            bits.write(info.lfeon, 1)
            bits.write(0, 3)
            bits.write(0, 4)  // no dependent substreams
            bits.write(0, 1)
            return ("dec3", bits.data)
        }
        bits.write(info.fscod, 2)
        bits.write(info.bsid, 5)
        bits.write(info.bsmod, 3)
        bits.write(info.acmod, 3)
        bits.write(info.lfeon, 1)
        bits.write(info.bitrateCode, 5)
        bits.write(0, 5)
        return ("dac3", bits.data)
    }

    /// Writes bit fields that do not lie on byte boundaries.
    struct BitWriter {
        private(set) var data = Data()
        private var accumulator = 0
        private var filled = 0

        mutating func write(_ value: Int, _ count: Int) {
            for step in stride(from: count - 1, through: 0, by: -1) {
                accumulator = (accumulator << 1) | ((value >> step) & 1)
                filled += 1
                if filled == 8 {
                    data.append(UInt8(accumulator & 0xFF))
                    accumulator = 0
                    filled = 0
                }
            }
        }
    }

    /// Builds the description for Apple's decoder.
    public static func formatDescription(for info: FrameInfo) throws -> CMFormatDescription {
        var asbd = AudioStreamBasicDescription(
            mSampleRate: Float64(info.sampleRate),
            mFormatID: info.isEnhanced ? kAudioFormatEnhancedAC3 : kAudioFormatAC3,
            mFormatFlags: 0,
            mBytesPerPacket: 0,
            mFramesPerPacket: UInt32(info.samplesPerFrame),
            mBytesPerFrame: 0,
            mChannelsPerFrame: UInt32(info.channels),
            mBitsPerChannel: 0,
            mReserved: 0
        )

        let atom = configurationAtom(for: info)
        let extensions: [CFString: Any] = [
            kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms:
                [atom.name: atom.data] as CFDictionary
        ]

        var description: CMFormatDescription?
        let status = CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            asbd: &asbd,
            layoutSize: 0,
            layout: nil,
            magicCookieSize: 0,
            magicCookie: nil,
            extensions: extensions as CFDictionary,
            formatDescriptionOut: &description
        )
        guard status == noErr, let description else {
            throw AudioAssembly.AudioFailure.descriptionRejected(status)
        }
        return description
    }
}
