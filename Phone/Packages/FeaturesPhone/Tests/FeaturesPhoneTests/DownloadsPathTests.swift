import Flows
import Testing

@testable import FeaturesPhone

/// The six states that name the downloads — **and until 2026-09-08 did not lead there.**
///
/// **The finding had been in the roadmap since 2026-09-06:** "Six error states point to
/// 'Meanwhile in downloads', and `import Vorrat` has zero hits." The button did not appear
/// at all — ``StateBlock`` draws none without an operator, and `secondaryAction` was not
/// set at any of the fourteen call sites. Built like that, it was right; a button into the
/// void is worse than none. It is just that downloads did not exist at the time.
@Suite("Path into downloads")
struct DownloadsPathTests {

    /// **Exactly six, and the number is the brake.** Whoever introduces a seventh state with
    /// "Meanwhile in downloads" must register it here — otherwise its side path names a place
    /// it does not lead to, and on screen that looks like text without a button.
    @Test("Six states lead into downloads")
    func six() {
        let lead = PlaybackPhase.allCases.filter(\.sidePathLeadsToDownloads)
        #expect(lead.count == 6)
    }

    /// **Each of them also names the path in its text.** A state that leads there and does not
    /// say so would have a button without a label; one that says so and does not lead there
    /// would be the old state.
    @Test("Whatever leads there also names the side path")
    func namesIt() {
        for state in PlaybackPhase.allCases where state.sidePathLeadsToDownloads {
            #expect(state.form.sidePath != nil, "\(state) leads there and does not say so")
        }
    }

    /// **Airplane mode is among them, and it is the most important of the six.** It is the
    /// only state in which downloads are not a stopgap but the only thing that works at all.
    @Test("Airplane mode leads into downloads")
    func airplaneMode() {
        #expect(PlaybackPhase.networkAirplaneMode.sidePathLeadsToDownloads)
    }

    /// **And the others do not lead there.** "Nothing found for …" names Live as the second
    /// place, not downloads; whoever routed all side paths to downloads would turn six right
    /// paths into nineteen wrong ones.
    @Test("States with another side path do not lead into downloads")
    func notAll() {
        #expect(!PlaybackPhase.emptySearch.sidePathLeadsToDownloads)
        #expect(!PlaybackPhase.emptyLibrary.sidePathLeadsToDownloads)
    }

    /// **No downloads, no button.** The shell sets the environment value only when a manager
    /// exists; without it the text stays, as before. That is not a regression but the same
    /// rule: a button into the void is worse than none.
    @Test("The environment value is empty without downloads")
    @MainActor
    func withoutDownloadsNoPath() {
        #expect(OpenDownloadsKey.defaultValue == nil)
    }
}
