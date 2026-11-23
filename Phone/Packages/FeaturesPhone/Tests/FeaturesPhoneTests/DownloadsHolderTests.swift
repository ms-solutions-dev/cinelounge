import Core
import Downloads
import Foundation
import Testing

@testable import FeaturesPhone

/// **One manager and not a second** — the check for the most expensive finding of 2026-09-09.
///
/// **What went wrong:** The downloads were built in
/// ``ShellModel/init(catalogs:accounts:parentalControls:synchronization:)``, and
/// this `init` runs several times: `ShellView` creates its model as
/// `State(initialValue: ShellModel(…))`, and SwiftUI **evaluates** this expression on
/// every build of the view, while it **keeps** only the first instance. Every
/// discarded instance had already built its own ``DownloadsManager`` — with its
/// own job list, but the same `jobs.json`. Whoever queued a title through the visible
/// manager lost it as soon as the invisible one noticed anything.
/// On disk there was `[]` next to four half-downloaded files.
///
/// **Why this check and not one on the view.** How often SwiftUI builds a view
/// is written nowhere in the code and changes with every system version. What can be checked is
/// the promise that holds independently of that: Whoever asks twice gets the same manager.
@Suite("Downloads holder")
@MainActor
struct DownloadsHolderTests {

    private struct ProbeSource: PlayerSource {
        func target(zu job: PlaybackJob) async throws -> PlaybackRequest {
            PlaybackRequest(
                identifier: job.identifier, title: "Stub",
                address: URL(string: "https://example.invalid/stream")!,
                decision: PlaybackDecision(
                    engine: .native, delivery: .directPlay, reason: .nativeContainer))
        }
        func notify(
            location: TimeInterval, duration: TimeInterval, zu job: PlaybackJob, isPaused: Bool
        ) async throws {}
        func nextEpisode(after job: PlaybackJob) async throws -> PlaybackRequest? { nil }
        func begin(_ job: PlaybackJob) async throws {}
        func finish(_ job: PlaybackJob, at location: TimeInterval) async throws {}
        func host(zu job: PlaybackJob) async throws -> [PortalHost] { [] }
    }

    @Test("Asked twice, it is the same manager")
    func onlyOne() {
        DownloadsHolder.forget()
        defer { DownloadsHolder.forget() }

        let first = DownloadsHolder.ready(
            source: ProbeSource(), start: nil, detail: nil, external: nil, networkMonitor: nil)
        let second = DownloadsHolder.ready(
            source: ProbeSource(), start: nil, detail: nil, external: nil, networkMonitor: nil)

        #expect(first === second)
    }

    /// **The second question brings new sources and does not throw the state away.**
    ///
    /// That is the difference from the previous build: It replaced the whole manager on every
    /// setup change — and with it the list of what is currently
    /// loading. Whoever created a channel list in the settings while a movie was running
    /// lost it from the display.
    ///
    /// **What is checked is ``DownloadsManager/rule`` and not a queued job**
    /// — and that is a lesson from the first attempt at this check: `create(_:resolve:)`
    /// writes into the **real** downloads folder under `Application Support`. The first
    /// version left an item "probe-1" there, on the developer's machine,
    /// outside the project. A check that leaves traces in the file system is the next
    /// one to fire wrongly on the run after next.
    @Test("New sources leave the state alone")
    func stateSurvivesSourceSwitch() {
        DownloadsHolder.forget()
        defer { DownloadsHolder.forget() }

        let administration = DownloadsHolder.ready(
            source: ProbeSource(), start: nil, detail: nil, external: nil, networkMonitor: nil)
        administration.rule = NetworkRule(wifiOnly: false)

        let following = DownloadsHolder.ready(
            source: ProbeSource(), start: nil, detail: nil, external: nil, networkMonitor: nil)

        #expect(following === administration)
        #expect(following.rule.wifiOnly == false)
    }
}
