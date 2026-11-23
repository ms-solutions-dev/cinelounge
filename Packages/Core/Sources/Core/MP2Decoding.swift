import Foundation
import MP2Synthesis

/// A custom decoder for MPEG-1/2 Audio Layer II — the audio format of
/// classic broadcasting.
///
/// **Why it exists** (on-device finding 2026-08-22, confirmed on the device): tvOS ships
/// no Layer II decoder. `AudioFormatGetProperty` lists MP3, AAC, AC-3
/// and PCM — Layer II is missing, and `AVAudioConverter` refuses to be set up.
/// The Mac has the decoder, which is why every check on the computer lied. The Turkish
/// national channels (Telve 2/3, TV KAYIN, TELE KIR — DVB has broadcast
/// Layer II since the nineties) stayed silent, and their picture stuttered on top of that: without
/// an audio track AVPlayer does not clock the picture off the audio clock.
///
/// **Why written by hand and not a library:** project rule since the
/// VLC removal — no third-party dependency in the playback path. Layer II is forgiving
/// for that: subband decomposition with linear quantisation, no
/// Huffman tables, no hybrid filter bank as in MP3.
///
/// **Why it looks like C** (on-device finding 2026-08-22, evening): the first
/// version worked with nested Swift arrays — and could not reach real time on the
/// Apple TV in a debug build (85 frames are 2 s of broadcast and
/// took 3 s; startup 14 s instead of 0.8 s, audio fell 6.7 s behind, the player
/// starved). Without the optimiser **every** index access there pays check and
/// management costs, and the synthesis does ~190 000 multiplications per
/// frame. Hence: flat buffers, raw pointers, overflow-free integer
/// arithmetic (`&*`/`&+` — the value ranges are proven, see the
/// comments at the loops). The computer forgives the pretty version,
/// the device does not.
///
/// The structure follows kjmp2 by Martin J. Fiedler (© 2006–2013,
/// zlib-style licence; this Swift version is a marked
/// port). The tables are those of the standard (ISO 11172-3 Table
/// 3-B.2/3-B.3), taken over mechanically from the reference — nobody types in 512 window
/// coefficients without error. Fixed point like the original:
/// the result is deterministic and bit-identical on every device.
///
/// Checked against Apple's own decoder on the computer — see
/// `MP2DecodingTests`: same frames in, cross-correlation of the outputs.
public struct MP2Decoder {

    /// Samples per frame and channel — always 1152 for Layer II.
    public static let samplesPerFrame = 1152

    // MARK: - Zustand

    /// The delay register of the synthesis filter bank, both channels in
    /// one flat buffer (channel 1 from 1024). **It carries sound from frame to
    /// frame** — whoever discards it between frames gets a click every
    /// 24 ms.
    private var v = [Int32](repeating: 0, count: 2048)
    private var vOffset = 0

    /// The requantised values of a group: `[ch × 96 + sb × 3 + nr]`.
    private var samples = [Int32](repeating: 0, count: 192)

    public init() {}

    // MARK: - Der Rahmen

    /// Decodes a whole Layer II frame.
    ///
    /// - Returns: 1152 samples per channel, **interleaved as stereo** (for
    ///   mono both channels are equal) — or `nil` if the frame is not
    ///   Layer II. A broken frame in the middle of the stream yields silence
    ///   instead of a crash: the reader reads zeros past the end of the frame.
    public mutating func decode(_ frame: Data) -> [Int16]? {
        let bytes = [UInt8](frame)
        guard bytes.count >= 4, bytes[0] == 0xFF, (bytes[1] & 0xF6) == 0xF4 else { return nil }

        var reader = BitReader(bytes: bytes, from: 2)

        let bitrateIndex = reader.take(4) - 1
        guard bitrateIndex >= 0, bitrateIndex <= 13 else { return nil }
        var samplingIndex = reader.take(2)
        guard samplingIndex != 3 else { return nil }
        var rateIndex = bitrateIndex
        let isMPEG2 = (bytes[1] & 0x08) == 0
        if isMPEG2 {
            samplingIndex += 4
            rateIndex += 14
        }
        _ = reader.take(1)  // Padding bit — the caller determines the frame length
        _ = reader.take(1)  // privates Bit
        let mode = reader.take(2)

        // With joint stereo the upper subbands share one allocation.
        var bound: Int
        if mode == 1 {
            bound = (reader.take(2) + 1) << 2
        } else {
            _ = reader.take(2)
            bound = mode == 3 ? 0 : 32
        }

        _ = reader.take(4)  // Emphasis — irrelevant for the values
        if (bytes[1] & 1) == 0 { _ = reader.take(16) }  // CRC

        // Which allocation table applies — by bitrate per channel and sample rate.
        let tableIndex: Int
        let sblimit: Int
        if isMPEG2 {
            tableIndex = 2
            sblimit = 30
        } else {
            let byChannels = Self.quantStep1[mode == 3 ? 0 : 1][rateIndex]
            let packed = Self.quantStep2[byChannels][samplingIndex]
            sblimit = packed & 63
            tableIndex = packed >> 6
        }
        if bound > sblimit { bound = sblimit }

        // Allocation: which quantiser per subband and channel (index into
        // ``quantizerTable`` plus one; zero means silence).
        var allocation = [Int](repeating: 0, count: 64)
        for sb in 0..<bound {
            allocation[sb] = Self.readAllocation(&reader, sb: sb, table: tableIndex)
            allocation[32 + sb] = Self.readAllocation(&reader, sb: sb, table: tableIndex)
        }
        for sb in bound..<sblimit {
            let shared = Self.readAllocation(&reader, sb: sb, table: tableIndex)
            allocation[sb] = shared
            allocation[32 + sb] = shared
        }

        // Scale factor selection and scale factors, flat: `[ch × 96 + sb × 3 + part]`.
        let channels = mode == 3 ? 1 : 2
        var scfsi = [Int](repeating: 0, count: 64)
        for sb in 0..<sblimit {
            for ch in 0..<channels where allocation[(ch << 5) + sb] != 0 {
                scfsi[(ch << 5) + sb] = reader.take(2)
            }
            if channels == 1 { scfsi[32 + sb] = scfsi[sb] }
        }
        var scalefactor = [Int](repeating: 0, count: 192)
        for sb in 0..<sblimit {
            for ch in 0..<channels where allocation[(ch << 5) + sb] != 0 {
                let base = ch * 96 + sb * 3
                switch scfsi[(ch << 5) + sb] {
                case 0:
                    scalefactor[base] = reader.take(6)
                    scalefactor[base + 1] = reader.take(6)
                    scalefactor[base + 2] = reader.take(6)
                case 1:
                    let shared = reader.take(6)
                    scalefactor[base] = shared
                    scalefactor[base + 1] = shared
                    scalefactor[base + 2] = reader.take(6)
                case 2:
                    let shared = reader.take(6)
                    scalefactor[base] = shared
                    scalefactor[base + 1] = shared
                    scalefactor[base + 2] = shared
                default:
                    scalefactor[base] = reader.take(6)
                    let shared = reader.take(6)
                    scalefactor[base + 1] = shared
                    scalefactor[base + 2] = shared
                }
            }
            if channels == 1 {
                let base = sb * 3
                scalefactor[96 + base] = scalefactor[base]
                scalefactor[96 + base + 1] = scalefactor[base + 1]
                scalefactor[96 + base + 2] = scalefactor[base + 2]
            }
        }

        // Read values (Swift — light work), synthesis in C: the filter bank
        // does ~190 000 multiplications per frame, and the device's debug build
        // cannot do that in Swift in real time — the full reasoning
        // is in `MP2Synthesis/include/mp2synthesis.h`.
        var pcm = [Int16](repeating: 0, count: Self.samplesPerFrame * 2)
        var offset = Int32(vOffset)

        v.withUnsafeMutableBufferPointer { vp in
            samples.withUnsafeMutableBufferPointer { sp in
                Self.n.withUnsafeBufferPointer { np in
                    Self.window.withUnsafeBufferPointer { dp in
                        pcm.withUnsafeMutableBufferPointer { pp in
                            var out = 0
                            for part in 0..<3 {
                                for _ in 0..<4 {
                                    // One group: three values per subband.
                                    for sb in 0..<bound {
                                        for ch in 0..<2 {
                                            Self.readSamples(
                                                &reader,
                                                quantizer: allocation[(ch << 5) + sb],
                                                scalefactor: scalefactor[ch * 96 + sb * 3 + part],
                                                into: sp.baseAddress! + ch * 96 + sb * 3)
                                        }
                                    }
                                    for sb in bound..<sblimit {
                                        Self.readSamples(
                                            &reader,
                                            quantizer: allocation[sb],
                                            scalefactor: scalefactor[sb * 3 + part],
                                            into: sp.baseAddress! + sb * 3)
                                        let base = sb * 3
                                        sp[96 + base] = sp[base]
                                        sp[96 + base + 1] = sp[base + 1]
                                        sp[96 + base + 2] = sp[base + 2]
                                    }
                                    for ch in 0..<2 {
                                        for sb in sblimit..<32 {
                                            let base = ch * 96 + sb * 3
                                            sp[base] = 0
                                            sp[base + 1] = 0
                                            sp[base + 2] = 0
                                        }
                                    }

                                    mp2_synthesize_granule(
                                        vp.baseAddress!, &offset, sp.baseAddress!,
                                        np.baseAddress!, dp.baseAddress!,
                                        pp.baseAddress! + out)
                                    out += 192
                                }
                            }
                        }
                    }
                }
            }
        }
        vOffset = Int(offset)
        return pcm
    }

    // MARK: - Reading and recomputing

    /// Reads the allocation of a subband and returns the quantiser index
    /// (1…17) — zero means: no bits, silence.
    private static func readAllocation(_ reader: inout BitReader, sb: Int, table: Int) -> Int {
        let packed = Int(quantStep3[table][sb])
        return Int(quantStep4[packed & 15][reader.take(packed >> 4)])
    }

    /// Reads three values of a subband and requantises them —
    /// fixed-point arithmetic as in the reference, so the result
    /// stays deterministic. Writes directly into the flat buffer.
    private static func readSamples(
        _ reader: inout BitReader, quantizer: Int, scalefactor rawScale: Int,
        into out: UnsafeMutablePointer<Int32>
    ) {
        guard quantizer != 0 else {
            out[0] = 0
            out[1] = 0
            out[2] = 0
            return
        }
        let q = quantizerTable[quantizer - 1]

        // Resolve the scale factor: three base values, one halving every three steps.
        var scale = 0
        if rawScale != 63 {
            let shift = rawScale / 3
            scale = (scfBase[rawScale % 3] + ((1 << shift) >> 1)) >> shift
        }

        var raw0: Int
        var raw1: Int
        var raw2: Int
        if q.grouping {
            // Three values share one codeword.
            var value = reader.take(q.bits)
            raw0 = value % q.levels
            value /= q.levels
            raw1 = value % q.levels
            raw2 = value / q.levels
        } else {
            raw0 = reader.take(q.bits)
            raw1 = reader.take(q.bits)
            raw2 = reader.take(q.bits)
        }

        let renorm = 65536 / (q.levels + 1)
        let mid = ((q.levels + 1) >> 1) - 1
        let high = scale >> 12
        let low = scale & 4095
        var value = (mid - raw0) * renorm
        out[0] = Int32((value * high + ((value * low + 2048) >> 12)) >> 12)
        value = (mid - raw1) * renorm
        out[1] = Int32((value * high + ((value * low + 2048) >> 12)) >> 12)
        value = (mid - raw2) * renorm
        out[2] = Int32((value * high + ((value * low + 2048) >> 12)) >> 12)
    }

    // MARK: - Der Bitleser

    /// Reads the frame bit by bit through a 24-bit window.
    ///
    /// Past the end of the frame come **zeros** — the reference keeps reading there
    /// unchecked, and that is exactly what Swift must not do.
    private struct BitReader {
        private let bytes: [UInt8]
        private var position: Int
        private var window: Int
        private var bitsInWindow: Int

        init(bytes: [UInt8], from index: Int) {
            self.bytes = bytes
            self.position = index + 1
            self.window = Int(bytes[index]) << 16
            self.bitsInWindow = 8
            refill()
        }

        mutating func take(_ count: Int) -> Int {
            let result = window >> (24 - count)
            window = (window << count) & 0xFF_FFFF
            bitsInWindow -= count
            refill()
            return result
        }

        private mutating func refill() {
            while bitsInWindow < 16 {
                let byte = position < bytes.count ? Int(bytes[position]) : 0
                position += 1
                window |= byte << (16 - bitsInWindow)
                bitsInWindow += 8
            }
        }
    }

    // MARK: - Die Tabellen der Norm

    /// The base values of the scale factors: 2, 2^(2/3) and 2^(1/3), as
    /// 24-bit fixed point.
    private static let scfBase = [0x0200_0000, 0x0196_5FEA, 0x0142_8A30]

    /// A quantiser: number of levels, whether three values share a codeword, bits.
    private struct Quantizer {
        let levels: Int
        let grouping: Bool
        let bits: Int
    }

    private static let quantizerTable: [Quantizer] = [
        .init(levels: 3, grouping: true, bits: 5),
        .init(levels: 5, grouping: true, bits: 7),
        .init(levels: 7, grouping: false, bits: 3),
        .init(levels: 9, grouping: true, bits: 10),
        .init(levels: 15, grouping: false, bits: 4),
        .init(levels: 31, grouping: false, bits: 5),
        .init(levels: 63, grouping: false, bits: 6),
        .init(levels: 127, grouping: false, bits: 7),
        .init(levels: 255, grouping: false, bits: 8),
        .init(levels: 511, grouping: false, bits: 9),
        .init(levels: 1023, grouping: false, bits: 10),
        .init(levels: 2047, grouping: false, bits: 11),
        .init(levels: 4095, grouping: false, bits: 12),
        .init(levels: 8191, grouping: false, bits: 13),
        .init(levels: 16383, grouping: false, bits: 14),
        .init(levels: 32767, grouping: false, bits: 15),
        .init(levels: 65535, grouping: false, bits: 16),
    ]

    /// Bitrate class by channel count and bitrate index (Table 3-B.2).
    private static let quantStep1: [[Int]] = [
        [0, 0, 1, 1, 1, 2, 2, 2, 2, 2, 2, 2, 2, 2],  // Mono
        [0, 0, 0, 0, 0, 0, 1, 1, 1, 2, 2, 2, 2, 2],  // Stereo
    ]

    /// Class and sample rate → table choice (above) and subband limit (below).
    private static let quantStep2: [[Int]] = [
        [8, 8, 12],  // 3-B.2c/d — niedrige Raten
        [27 | 64, 27 | 64, 27 | 64],  // 3-B.2a
        [30 | 64, 27 | 64, 30 | 64],  // 3-B.2b at 44.1 and 32 kHz
    ]

    /// Subband → allocation bits (above) and row choice (below).
    private static let quantStep3: [[UInt8]] = [
        // Low rates (3-B.2c and d)
        [
            0x44, 0x44,
            0x34, 0x34, 0x34, 0x34, 0x34, 0x34, 0x34, 0x34, 0x34, 0x34,
        ],
        // High rates (3-B.2a and b)
        [
            0x43, 0x43, 0x43,
            0x42, 0x42, 0x42, 0x42, 0x42, 0x42, 0x42, 0x42,
            0x31, 0x31, 0x31, 0x31, 0x31, 0x31, 0x31, 0x31, 0x31, 0x31, 0x31, 0x31,
            0x20, 0x20, 0x20, 0x20, 0x20, 0x20, 0x20,
        ],
        // MPEG-2 with half sample rates (ISO 13818-3, B.2)
        [
            0x45, 0x45, 0x45, 0x45,
            0x34, 0x34, 0x34, 0x34, 0x34, 0x34, 0x34,
            0x24, 0x24, 0x24, 0x24, 0x24, 0x24, 0x24, 0x24, 0x24, 0x24,
            0x24, 0x24, 0x24, 0x24, 0x24, 0x24, 0x24, 0x24, 0x24,
        ],
    ]

    /// Row and allocation read → quantiser index.
    private static let quantStep4: [[UInt8]] = [
        [0, 1, 2, 17],
        [0, 1, 2, 3, 4, 5, 6, 17],
        [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 17],
        [0, 1, 3, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17],
        [0, 1, 2, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 17],
        [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15],
    ]

    /// The synthesis matrixing: N[i][j] = 256 · cos((16+i)(2j+1)·π/64),
    /// computed at run time as in the reference — with the same truncation
    /// toward zero, so the values are bit-identical.
    private static let n: [Int32] = {
        var table = [Int32](repeating: 0, count: 64 * 32)
        for i in 0..<64 {
            for j in 0..<32 {
                table[(i << 5) + j] = Int32(
                    256.0 * cos(Double((16 + i) * ((j << 1) + 1)) * 0.0490873852123405))
            }
        }
        return table
    }()

    /// The synthesis window of the standard (ISO 11172-3, Table 3-B.3) as
    /// 16-bit fixed point — taken over mechanically from the reference.
    private static let window: [Int32] = [
        0, 0, 0, 0, 0, 0, 0, -1,
        -1, -1, -1, -2, -2, -3, -3, -4,
        -4, -5, -6, -6, -7, -8, -9, -10,
        -12, -13, -15, -16, -18, -20, -23, -25,
        -28, -30, -34, -37, -40, -44, -48, -52,
        -57, -62, -67, -72, -78, -84, -90, -96,
        -103, -110, -116, -124, -131, -138, -146, -153,
        -160, -168, -175, -182, -189, -195, -201, -207,
        213, 218, 222, 225, 227, 228, 228, 227,
        224, 221, 215, 208, 200, 189, 177, 163,
        146, 127, 106, 83, 57, 29, -1, -35,
        -71, -110, -152, -196, -243, -293, -346, -400,
        -458, -518, -580, -644, -710, -778, -847, -918,
        -990, -1063, -1136, -1209, -1282, -1355, -1427, -1497,
        -1566, -1633, -1697, -1758, -1816, -1869, -1918, -1961,
        -2000, -2031, -2056, -2074, -2084, -2086, -2079, -2062,
        2037, 2000, 1952, 1893, 1822, 1739, 1644, 1535,
        1414, 1280, 1131, 970, 794, 605, 402, 185,
        -44, -287, -544, -813, -1094, -1387, -1691, -2005,
        -2329, -2662, -3003, -3350, -3704, -4062, -4424, -4787,
        -5152, -5516, -5878, -6236, -6588, -6934, -7270, -7596,
        -7909, -8208, -8490, -8754, -8997, -9218, -9415, -9584,
        -9726, -9837, -9915, -9958, -9965, -9934, -9862, -9749,
        -9591, -9388, -9138, -8839, -8491, -8091, -7639, -7133,
        6574, 5959, 5288, 4561, 3776, 2935, 2037, 1082,
        70, -997, -2121, -3299, -4532, -5817, -7153, -8539,
        -9974, -11454, -12979, -14547, -16154, -17798, -19477, -21188,
        -22928, -24693, -26481, -28288, -30111, -31946, -33790, -35639,
        -37488, -39335, -41175, -43005, -44820, -46616, -48389, -50136,
        -51852, -53533, -55177, -56777, -58332, -59837, -61288, -62683,
        -64018, -65289, -66493, -67628, -68691, -69678, -70589, -71419,
        -72168, -72834, -73414, -73907, -74312, -74629, -74855, -74991,
        75038, 74992, 74856, 74630, 74313, 73908, 73415, 72835,
        72169, 71420, 70590, 69679, 68692, 67629, 66494, 65290,
        64019, 62684, 61289, 59838, 58333, 56778, 55178, 53534,
        51853, 50137, 48390, 46617, 44821, 43006, 41176, 39336,
        37489, 35640, 33791, 31947, 30112, 28289, 26482, 24694,
        22929, 21189, 19478, 17799, 16155, 14548, 12980, 11455,
        9975, 8540, 7154, 5818, 4533, 3300, 2122, 998,
        -69, -1081, -2036, -2934, -3775, -4560, -5287, -5958,
        6574, 7134, 7640, 8092, 8492, 8840, 9139, 9389,
        9592, 9750, 9863, 9935, 9966, 9959, 9916, 9838,
        9727, 9585, 9416, 9219, 8998, 8755, 8491, 8209,
        7910, 7597, 7271, 6935, 6589, 6237, 5879, 5517,
        5153, 4788, 4425, 4063, 3705, 3351, 3004, 2663,
        2330, 2006, 1692, 1388, 1095, 814, 545, 288,
        45, -184, -401, -604, -793, -969, -1130, -1279,
        -1413, -1534, -1643, -1738, -1821, -1892, -1951, -1999,
        2037, 2063, 2080, 2087, 2085, 2075, 2057, 2032,
        2001, 1962, 1919, 1870, 1817, 1759, 1698, 1634,
        1567, 1498, 1428, 1356, 1283, 1210, 1137, 1064,
        991, 919, 848, 779, 711, 645, 581, 519,
        459, 401, 347, 294, 244, 197, 153, 111,
        72, 36, 2, -28, -56, -82, -105, -126,
        -145, -162, -176, -188, -199, -207, -214, -220,
        -223, -226, -227, -227, -226, -224, -221, -217,
        213, 208, 202, 196, 190, 183, 176, 169,
        161, 154, 147, 139, 132, 125, 117, 111,
        104, 97, 91, 85, 79, 73, 68, 63,
        58, 53, 49, 45, 41, 38, 35, 31,
        29, 26, 24, 21, 19, 17, 16, 14,
        13, 11, 10, 9, 8, 7, 7, 6,
        5, 5, 4, 4, 3, 3, 2, 2,
        2, 2, 1, 1, 1, 1, 1, 1,
    ]
}
