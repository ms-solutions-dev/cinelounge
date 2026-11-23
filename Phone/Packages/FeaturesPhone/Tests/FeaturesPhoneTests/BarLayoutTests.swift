import NetworkStatus
import Testing

@testable import FeaturesPhone

/// When the tab bar drops — **two questions, and both are easily answered wrong.**
@Suite("Bar layout")
struct BarLayoutTests {

    /// **Before the first report, the bar stays.** ``NetworkStatus/NetworkWatch/route`` starts at
    /// `.none`, and `NWPathMonitor` reports a moment after launch —
    /// without this rule the first version of **every** launch would be the offline screen.
    @Test("As long as nothing has been reported, no bar is dropped")
    func unmeasured() {
        #expect(BarState.forItem(route: .none, measured: false, playerRunning: false) == .full)
    }

    @Test("With a network all tabs are shown")
    func withNetwork() {
        #expect(
            BarState.forItem(route: NetworkPath(kind: .wifi), measured: true, playerRunning: false) == .full)
    }

    @Test("Without a network only downloads remain")
    func offline() {
        #expect(BarState.forItem(route: .none, measured: true, playerRunning: false) == .downloadsOnly)
    }

    /// **Never on "slow".** M1 and M6 are 26 : 1 apart, and the difference is
    /// a change of location — a bar that rebuilds under the thumb while walking is
    /// more unusable than one that shows too much.
    @Test("An expensive or throttled connection changes nothing")
    func slowDoesNotCount() {
        let narrow = NetworkPath(kind: .cellular, expensive: true, frugal: true)
        #expect(BarState.forItem(route: narrow, measured: true, playerRunning: false) == .full)
    }

    /// **Never switch while the player runs.** A rebuild under the running picture
    /// would be invisible, and on leaving a different app would stand there than on entering.
    @Test("During playback the bar stays, even without a network")
    func playerBeatsEverything() {
        #expect(BarState.forItem(route: .none, measured: true, playerRunning: true) == .full)
    }
}
