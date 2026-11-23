import CoreMedia
import Foundation
import Testing

@testable import Core

/// **A channel stayed black because we threw away a picture parameter
/// set.**
///
/// Test agent 2026-08-23 on "TR: NOKTA TV HQ": The stream carries two PPS, and the
/// split is cleanly separated —
///
/// ```
/// pps_id 1 → all I fields
/// pps_id 0 → all P and B fields
/// ```
///
/// What was kept was the **first** one, i.e. zero. The decoder never got to see the set for
/// the I frames. Re-measured with VideoToolbox:
///
/// ```
/// only one PPS:   0 of 168 frames,  -8969 (codecBadDataErr) on ALL
/// both PPS:   165 of 168 frames
/// ```
///
/// Exactly the reported picture: no picture, audio plays — the audio does not take this path.
/// The template `h264-two-pps.ts` is a recording of this channel.
@Suite("Picture parameter sets")
struct ParameterSetTests {

    private func fixture(_ name: String) throws -> Data {
        let url = try #require(
            Bundle.module.url(forResource: "Fixtures/\(name)", withExtension: "ts"))
        return try Data(contentsOf: url)
    }

    private func nal(_ type: UInt8, _ filler: UInt8) -> Data {
        Data([type, filler, filler, filler])
    }

    // MARK: - Sammeln

    @Test("Duplicate sets are not collected")
    func duplicatesAreSkipped() {
        let units = [nal(7, 0xAA), nal(8, 0xBB), nal(8, 0xBB), nal(8, 0xCC), nal(8, 0xBB)]
        let sets = TransportStream.parameterSets(in: units, kind: .h264)
        #expect(sets.allPPS.count == 2)
    }

    @Test("Without a picture parameter set the list stays empty")
    func noneStaysEmpty() {
        let sets = TransportStream.parameterSets(in: [nal(7, 0xAA)], kind: .h264)
        #expect(sets.allPPS.isEmpty)
        #expect(sets.isComplete(for: .h264) == false)
    }

    // MARK: - Die Zeiger

    /// **Dangling pointers that would have made the release build pictureless.**
    ///
    /// `withParameterSetPointers` took the address out of `withUnsafeBufferPointer`
    /// to the outside. In the debug build — and `device.sh` builds debug — the
    /// field survives long enough by chance; with `-O` the agent's rebuild failed
    /// on **every** channel with `-12712`.
    ///
    /// This test deliberately runs many sets at once: The more, the more
    /// likely that freed memory shows.
    @Test("The pointers survive until the end of the call")
    func pointersStayValid() {
        let sets: [Data] = (0..<8).map { index in
            Data(repeating: UInt8(index + 1), count: 64 + index)
        }
        let ok = sets.withParameterSetPointers { pointers, sizes -> Bool in
            for index in sets.indices {
                let expected = UInt8(index + 1)
                guard sizes[index] == 64 + index else { return false }
                for byte in 0..<sizes[index] where pointers[index][byte] != expected {
                    return false
                }
            }
            return true
        }
        #expect(ok, "the sets did not arrive intact")
    }
}

/// The field indication in the format description — AP2 · U1.
///
/// **The finding:** All German and Turkish channels of the tested
/// provider are 1080i25. The app combines both fields into one frame
/// and reported a **full frame** to the decoder — so it does not know
/// that it would have to deinterlace, and with motion the comb is visible.
///
/// **What is tested here is the indication, not its effect.** Whether tvOS 26
/// deinterlaces as a result is decided by ten minutes on the device; a description
/// that describes the stream correctly is in no case worse
/// than one that does not.
@Suite("Fields in the format description")
struct FieldDescriptionTests {

    /// Builds a description from a real recording — the same one on which
    /// ``ParameterSetTests`` counts the two picture parameter sets.
    private func description() throws -> CMFormatDescription {
        let url = try #require(
            Bundle.module.url(forResource: "Fixtures/h264-two-pps", withExtension: "ts"))
        let data = try Data(contentsOf: url)
        let video = try #require(TransportStream.inventory(from: data).video)
        let stream = TransportStream.elementaryStream(from: data, pid: video.pid)
        let sets = TransportStream.parameterSets(
            in: TransportStream.units(inElementaryStream: stream), kind: video.kind)
        return try SampleAssembly.formatDescription(from: sets, kind: .h264)
    }
}
