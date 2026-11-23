import Testing

@testable import FeaturesPhone

/// What becomes of a season ID when resuming.
///
/// **The finding (E61), confirmed twice independently:** "Whole season" creates a job
/// under an **invented** ID — a season has none of its own at the server, it
/// is a selection from a series. After a restart ``DownloadsManager`` built from
/// exactly this ID a `PlaybackJob`, and that resolves at no source.
///
/// **What is checked is the rule and not the flow.** Whether the job then ends as
/// "not ready" or as "connection lost" is decided by a
/// string — and that can be recomputed without a network, without a folder and without a server.
@Suite("Season identifiers when resuming")
struct SeasonContinuationTests {

    @Test("A season identifier is recognizable as such")
    func seasonIsRecognizable() {
        let identifier = DownloadDescriber.seasonID(series: "morrowfeld", season: 2)

        #expect(DownloadDescriber.seriesID(from: identifier) == "morrowfeld")
    }

    /// **The case that went wrong silently.** An ordinary title ID must not be read as a
    /// season — otherwise nothing could be resumed any more after a restart.
    @Test("An ordinary identifier is not a season")
    func titleIsNoSeason() {
        #expect(DownloadDescriber.seriesID(from: "morrowfeld") == nil)
        #expect(DownloadDescriber.seriesID(from: "morrowfeld-f3") == nil)
        #expect(DownloadDescriber.seriesID(from: "serieshub:1-wendetag:") == nil)
        #expect(DownloadDescriber.seriesID(from: "") == nil)
    }

    /// **The tag stands in one place and is read at the same one.** Two places
    /// would be two formats as soon as one of them is touched — and then a
    /// season job would again end up as a play job.
    @Test("Built and read with the same marker")
    func oneMarkForBoth() {
        for season in 1...12 {
            let identifier = DownloadDescriber.seasonID(series: "drugladan", season: season)
            #expect(identifier.contains(DownloadDescriber.seasonMarker))
            #expect(DownloadDescriber.seriesID(from: identifier) == "drugladan")
        }
    }
}
