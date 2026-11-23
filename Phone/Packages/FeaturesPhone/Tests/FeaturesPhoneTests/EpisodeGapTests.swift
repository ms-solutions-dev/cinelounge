import Testing

@testable import FeaturesPhone

/// Why a series page shows no episodes.
///
/// **Measured on 2026-08-22 in the TV project: 958 of 4,974 series — 19.3 %.** At the
/// provider iptvhost about a fifth of the series in the panel carry no episode entries.
/// **A series page without episodes and without a Play button cannot be told apart from an
/// app error** — and for this provider it is none.
///
/// **Two cases and not one**, because they lead to different next steps:
/// "The provider has none" is information about the catalog, "the fetch failed"
/// about the network. A common sentence would be wrong for one of the two.
@Suite("Episode gap")
@MainActor
struct EpisodeGapTests {

    @Test("Without loading, no gap is established")
    func noneBeforeLoading() {
        let model = DetailModel(identifier: "morrowfeld", source: nil, rule: .pending)

        #expect(model.episodeGap == .none)
    }

    /// **The three cases are distinguishable and stay so.** Whoever merges them
    /// gets a sentence that sends them the wrong way on every second occurrence — the same
    /// type of error as "No answer from the media server" above a
    /// server that answers in 50 ms.
    @Test("The three cases are distinct")
    func threeCases() {
        #expect(DetailModel.EpisodeGap.none != .providerHasNone)
        #expect(DetailModel.EpisodeGap.providerHasNone != .fetchFailed)
        #expect(DetailModel.EpisodeGap.none != .fetchFailed)
    }
}
