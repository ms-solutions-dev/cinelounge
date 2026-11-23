import Foundation

/// Fields in H.264 — detecting them and merging them back into whole pictures.
///
/// **The occasion** (on-device finding 2026-08-23): telve2, telve3 and ayaz2 in UHD still do
/// not work, and with now tv hq no picture comes at all. All these channels are
/// **1080i25, field-coded** — and the provider puts each field into its
/// own PES packet with its own timestamp, 20 ms apart. The remuxer
/// made one sample of each: fifty half pictures per second instead of
/// twenty-five whole ones. In an MP4 file a field pair belongs in **one**
/// sample; so VideoToolbox never got a complete picture.
///
/// Proven at the byte, first field pair of Telve 2 UHD:
///
/// ```
/// PES 0  pts 2797205850  dts 2797195050  NAL [9, 7, 8, 8, 6, 5]   top field, IDR
/// PES 1  pts 2797207650  dts 2797196850  NAL [9, 6, 1]            bottom field of the same picture
/// ```
///
/// The control test that rules out the obvious explanation: "SPORT DIGITAL
/// HQ" is **real** 720p50 — progressive, fifty pictures — and plays
/// flawlessly (`first picture: 0 ms`). So it is not the frame rate
/// but the fields.
///
/// **Acts only where it has to.** If the picture parameter set says `frame_mbs_only_flag == 1`
/// (progressive), nothing is touched here; all channels running today take
/// the same path unchanged as before.
public enum H264Fields {

    /// What is needed from the picture parameter set (SPS) to detect fields.
    public struct SequenceInfo: Sendable, Equatable {
        /// `frame_mbs_only_flag == 0` means: This stream **may** carry fields.
        /// Only the slice header says whether it does.
        public let allowsFields: Bool
        /// Width of `frame_num` in the slice header — without it `field_pic_flag`
        /// cannot be found, because it stands directly after it.
        public let frameNumBits: Int
        /// Inserts two bits in the slice header (`colour_plane_id`).
        public let separateColourPlane: Bool
    }

    /// Reads the three values of ``SequenceInfo`` from an SPS.
    ///
    /// **Up to `frame_mbs_only_flag` and not one step further.** Everything before it has to be
    /// read, because Exp-Golomb numbers have no fixed width — you
    /// cannot jump, only count. Everything after it is of no interest here.
    public static func sequenceInfo(fromSPS sps: Data) -> SequenceInfo? {
        // Drop the header byte (nal_unit_type), then remove the emulation bytes: In the
        // payload `00 00 03` stands for a literal `00 00`, and a bit reader
        // without this knowledge slips from the first such place on.
        var reader = SampleAssembly.BitReader(unescaped(sps.dropFirst()))

        guard let profile = reader.bits(8) else { return nil }
        guard reader.bits(8) != nil, reader.bits(8) != nil else { return nil }  // Auflagen, Stufe
        guard reader.expGolomb() != nil else { return nil }  // seq_parameter_set_id

        var separateColourPlane = false
        // The high profiles carry the colour information before the rest.
        if [100, 110, 122, 244, 44, 83, 86, 118, 128, 138, 139, 134, 135].contains(profile) {
            guard let chroma = reader.expGolomb() else { return nil }
            if chroma == 3 {
                guard let flag = reader.bit() else { return nil }
                separateColourPlane = flag == 1
            }
            guard reader.expGolomb() != nil, reader.expGolomb() != nil else { return nil }
            guard reader.bit() != nil else { return nil }  // qpprime_y_zero_transform_bypass
            guard let scaling = reader.bit() else { return nil }
            if scaling == 1 {
                let lists = chroma == 3 ? 12 : 8
                for index in 0..<lists {
                    guard let present = reader.bit() else { return nil }
                    guard present == 1 else { continue }
                    guard skipScalingList(&reader, size: index < 6 ? 16 : 64) else { return nil }
                }
            }
        }

        guard let log2MaxFrameNumMinus4 = reader.expGolomb() else { return nil }
        guard let pocType = reader.expGolomb() else { return nil }
        switch pocType {
        case 0:
            guard reader.expGolomb() != nil else { return nil }
        case 1:
            guard reader.bit() != nil,
                reader.signedExpGolomb() != nil,
                reader.signedExpGolomb() != nil,
                let cycle = reader.expGolomb()
            else { return nil }
            for _ in 0..<cycle {
                guard reader.signedExpGolomb() != nil else { return nil }
            }
        default:
            break
        }

        guard reader.expGolomb() != nil else { return nil }  // max_num_ref_frames
        guard reader.bit() != nil else { return nil }  // gaps_in_frame_num_value_allowed
        guard reader.expGolomb() != nil, reader.expGolomb() != nil else { return nil }  // Dimensions
        guard let frameMbsOnly = reader.bit() else { return nil }

        return SequenceInfo(
            allowsFields: frameMbsOnly == 0,
            frameNumBits: log2MaxFrameNumMinus4 + 4,
            separateColourPlane: separateColourPlane
        )
    }

    /// Which field an access unit carries — or none.
    public enum Picture: Sendable, Equatable {
        /// A whole picture; nothing to pair here.
        case frame
        case topField
        case bottomField
    }

    /// Reads from the slices of an access unit whether it is a field.
    ///
    /// The **first** picture NAL (type 1 or 5) is taken; all slices of a
    /// picture carry the same value.
    public static func picture(in units: [Data], info: SequenceInfo) -> Picture? {
        guard info.allowsFields else { return .frame }

        for unit in units {
            guard let first = unit.first else { continue }
            let type = first & 0x1F
            guard type == 1 || type == 5 else { continue }

            var reader = SampleAssembly.BitReader(
                unescaped(unit.dropFirst(), atMost: sliceHeaderBytes))
            guard reader.expGolomb() != nil,  // first_mb_in_slice
                reader.expGolomb() != nil,  // slice_type
                reader.expGolomb() != nil  // pic_parameter_set_id
            else { return nil }
            if info.separateColourPlane {
                guard reader.bits(2) != nil else { return nil }
            }
            guard reader.bits(info.frameNumBits) != nil else { return nil }
            guard let isField = reader.bit() else { return nil }
            guard isField == 1 else { return .frame }
            guard let isBottom = reader.bit() else { return nil }
            return isBottom == 1 ? .bottomField : .topField
        }
        return nil
    }

    // MARK: - Kleinkram

    /// Removes the emulation bytes (`00 00 03` → `00 00`).
    ///
    /// - Parameter hoechstens: How many bytes are needed. `nil` means
    ///   "all".
    ///
    /// **The limit is the whole point** (AP7 · L2, expert review 2026-08-24):
    /// ``picture(in:info:)`` unpacked the **complete** NAL — for a
    /// 1080i channel about 25 kilobytes — to read the first eight bytes of the
    /// slice header in it. And that at **fifty fields per second**,
    /// on exactly the channels that are already disadvantaged threefold in AP2.
    ///
    /// The reserved capacity is added on top: Without it the array grows several
    /// times while appending and copies each time.
    static func unescaped(_ data: some Sequence<UInt8>, atMost: Int? = nil) -> [UInt8] {
        var out = [UInt8]()
        out.reserveCapacity(atMost ?? data.underestimatedCount)
        var zeros = 0
        for byte in data {
            if zeros == 2, byte == 3 {
                zeros = 0
                continue
            }
            out.append(byte)
            if let atMost, out.count >= atMost { return out }
            zeros = byte == 0 ? zeros + 1 : 0
        }
        return out
    }

    /// How many bytes the slice header needs at most.
    ///
    /// Eight: `first_mb_in_slice`, `slice_type` and `pic_parameter_set_id` are
    /// Exp-Golomb values of at most four bytes each in the worst case, plus
    /// `frame_num` (up to 16 bits) and two single bits. Sixteen is the
    /// double safety margin — and still three orders of magnitude
    /// less than the whole NAL.
    static let sliceHeaderBytes = 16

    private static func skipScalingList(
        _ reader: inout SampleAssembly.BitReader, size: Int
    ) -> Bool {
        var lastScale = 8
        var nextScale = 8
        for _ in 0..<size {
            if nextScale != 0 {
                guard let delta = reader.signedExpGolomb() else { return false }
                nextScale = (lastScale + delta + 256) % 256
            }
            lastScale = nextScale == 0 ? lastScale : nextScale
        }
        return true
    }
}
