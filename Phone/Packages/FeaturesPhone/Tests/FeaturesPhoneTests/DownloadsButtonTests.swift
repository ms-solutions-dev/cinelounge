import Downloads
import Testing

@testable import FeaturesPhone

/// The button that is also the display.
///
/// **The finding of 2026-09-08 was: "visually there is still no apparent place where and how
/// content can be downloaded."** It was right — "Add to downloads"
/// lived exclusively in the ⋯ menu. What is checked here is the flip side of one
/// button carrying three states: that each state is recognized correctly and that the tap
/// on it does the right thing.
@Suite("Downloads button")
struct DownloadsButtonTests {

    private static func job(_ name: String) -> DownloadJob {
        DownloadJob(id: .init(name), title: name, source: .jellyfin, extent: .film)
    }

    // MARK: - Which state applies

    @Test("An unknown title is not queued")
    func unknown() {
        #expect(DownloadState.forItem(.init("A"), in: Downloads()) == .notQueued)
    }

    @Test("An item without a transfer is stored here")
    func isHere() {
        let v = Downloads(items: [Self.job("A")])
        #expect(DownloadState.forItem(.init("A"), in: v) == .isHere)
    }

    /// **The fraction travels along in the state.** A ring without a fraction spins instead of
    /// standing at zero — with a portal the size is known only after the first block,
    /// and by then something has long since happened.
    @Test("Whatever is loading carries its fraction")
    func loadsWithFraction() {
        let v = Downloads(
            items: [Self.job("A")],
            isRunning: [Transfer(id: .init("A"), state: .isLoading, loaded: 50, total: 100)])
        #expect(DownloadState.forItem(.init("A"), in: v) == .isLoading(0.5))
    }

    @Test("Without a known size there is no fraction")
    func loadsWithoutFraction() {
        let v = Downloads(items: [], isRunning: [Transfer(id: .init("A"), state: .isLoading)])
        #expect(DownloadState.forItem(.init("A"), in: v) == .isLoading(nil))
    }

    /// **Paused and waiting look the same, and that is right:** Both are
    /// interruptions, and the tap on them means "continue" for both. Why they rest
    /// is stated in the row in the downloads and not on a 44-point button.
    @Test("Resting and waiting are the same button state")
    func restingAndWaiting() {
        for state in [Transfer.Situation.idle(.cellular), .waitingForConnection] {
            let v = Downloads(items: [], isRunning: [Transfer(id: .init("A"), state: state)])
            #expect(DownloadState.forItem(.init("A"), in: v) == .idle(nil))
        }
    }

    /// **A failure is not a button state of its own.** The tap there means the same
    /// as for resting — try again —, and a fourth outline would be a
    /// distinction without consequence.
    @Test("A failure looks like an interruption")
    func failed() {
        let v = Downloads(
            items: [],
            isRunning: [Transfer(id: .init("A"), state: .failed(.network("Probe")))])
        #expect(DownloadState.forItem(.init("A"), in: v) == .idle(nil))
    }

    /// **A finished transfer is an item.** It then stands there as "is here" and
    /// not as "finished downloading" — the viewer is interested in the state, not
    /// in the process.
    @Test("Done means stored here")
    func doneIsStoredHere() {
        let v = Downloads(items: [], isRunning: [Transfer(id: .init("A"), state: .done)])
        #expect(DownloadState.forItem(.init("A"), in: v) == .isHere)
    }

    /// **The running transfer beats the item.** Whoever removes a title and queues it again
    /// would otherwise for a moment have a filled button above an empty folder.
    @Test("Whatever is running wins over whatever is stored")
    func runningWins() {
        let v = Downloads(
            items: [Self.job("A")],
            isRunning: [Transfer(id: .init("A"), state: .isLoading, loaded: 1, total: 4)])
        #expect(DownloadState.forItem(.init("A"), in: v) == .isLoading(0.25))
    }
}
