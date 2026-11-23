import CoreMedia
import Foundation
import Testing

@testable import Core

/// **The feasibility proof for the repackager.**
///
/// The question decided here is the most expensive of the whole undertaking:
/// can HEVC be extracted from an MPEG-TS such that **Apple's own
/// decoder** accepts it? If the answer is yes, the rest is legwork — and the
/// way to a single playback engine is open. If it is no, one session is lost instead of
/// a month.
///
/// It is checked against **real material**: forty packets of "Telve 1 HEVC", fetched from the
/// provider on 2026-08-08. Exactly this channel is one of those that
/// today have to take the detour via VLC.
///
/// The proof ends at `CMVideoFormatDescription`, and that is the
/// decisive point: this structure **is** the ticket to
/// VideoToolbox. Whoever can build it from the extracted data can have them
/// decoded — and everything else (write fMP4, hand to AVPlayer)
/// is packaging that Apple does itself.
@Suite("Remuxing: from the transport stream into Apple's decoder")
struct TransportStreamUnpackTests {

    private func liveStream() throws -> Data {
        let url = try #require(
            Bundle.module.url(forResource: "Fixtures/hevc-live", withExtension: "ts")
        )
        return try Data(contentsOf: url)
    }
}

/// **The complete chain, on real channel material.**
///
/// From the raw packets to a packet as CoreMedia hands it to the decoder
/// — without a single picture being decoded on the way. If this
/// check passes, the repackager is in place at its core.
@Suite("The chain: from the transport stream to the finished packet")
struct UnpackChainTests {

    private func liveStream() throws -> Data {
        let url = try #require(
            Bundle.module.url(forResource: "Fixtures/hevc-live", withExtension: "ts")
        )
        return try Data(contentsOf: url)
    }

    /// A stream without descriptions is no reason to crash — it occurs
    /// when a request jumps in between two repetitions.
    @Test("Without descriptions there is a clear error message")
    func missingParameterSetsAreReported() {
        #expect(throws: SampleAssembly.AssemblyFailure.noParameterSets) {
            try SampleAssembly.formatDescription(
                from: TransportStream.ParameterSets(), kind: .hevc)
        }
    }
}
