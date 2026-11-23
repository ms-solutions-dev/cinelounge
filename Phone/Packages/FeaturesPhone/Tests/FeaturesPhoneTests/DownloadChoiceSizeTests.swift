import Core
import Downloads
import Foundation
import Testing

@testable import FeaturesPhone

/// What the download sheet shows as a size — **and when nothing is shown there.**
///
/// **The finding of 2026-09-09, from review:** nearly every portal item in the
/// download sheet showed 720 MB, which cannot be right.
/// On screen, for "Morrowfeld" S1E1: one episode 720 MB, whole season 5.76 GB (= 8 ×
/// 720), everything unwatched 10.08 GB (= 14 × 720). It was not an estimate but a fixed
/// number per episode.
///
/// **Re-measured at the bridge the same day:** `/p/serieshub/list` returns for this
/// episode `dauer_minuten: null`, `/p/serieshub/sources` two hosts without a size —
/// and a range request to the resolved URL answers `206` with
/// `content-range: bytes 0-1/561149891`. The truth is 561 MB.
///
/// **The tested standard case is therefore "no runtime known".** For portals it is
/// not the exception: All ten episodes of the season carry `null`.
@Suite("Download choice: sizes and what shows without a runtime")
@MainActor
struct DownloadChoiceSizeTests {

    private static func job(
        extent: Extent = .episode(season: 1, number: 1), source: SourceKind = .portal,
        runtime: TimeInterval? = nil
    ) -> DownloadJob {
        DownloadJob(
            id: .init("serieshub|morrowfeld-s1f1|https%3A%2F%2Fserieshub.example%2Fx"),
            title: "1 - Wendetag", beside: "Morrowfeld", source: source, extent: extent,
            runtime: runtime, host: "HOSTA", version: "(DE)")
    }

    // MARK: - Der Regelfall: keine Laufzeit

    /// **The repair in one line.** Without a runtime there is no size — neither for the
    /// episode nor for the season nor for everything unwatched.
    @Test("Without a runtime none of the three scopes names a size")
    func withoutRuntimeNoSize() {
        let choice = DownloadChoice(job: Self.job())
        #expect(choice.isSizeUnknown)
        for extent in choice.extents {
            #expect(choice.size(forItem: extent) == nil)
            #expect(choice.sizeText(forItem: extent) == nil)
        }
    }

    /// **The old number does not come back.** It was 720,000,000 bytes, and it appeared
    /// everywhere — this check fails as soon as someone enters a default again.
    @Test("A fixed size appears nowhere any more")
    func noConstantAnymore() {
        let choice = DownloadChoice(job: Self.job())
        #expect(choice.size(forItem: .episode(season: 1, number: 1)) != 720_000_000)
        #expect(choice.size(forItem: .season(number: 1, episodes: 8)) != 5_760_000_000)
    }

    /// **The loud button is silent then too.** Until 2026-09-09 it carried the bare amount and
    /// was thus the most conspicuous spot of the finding: "720 MB" in red across the whole
    /// sheet width.
    @Test("Without a size the button carries no number")
    func buttonWithoutNumber() {
        let choice = DownloadChoice(job: Self.job())
        #expect(choice.footerCaption.contains("MB") == false)
        #expect(choice.footerCaption.contains("GB") == false)
    }

    /// **And the queued request claims nothing either.** `0` means "unknown" there;
    /// it adds up harmlessly in the storage budget.
    @Test("Without a runtime the finished request carries zero")
    func finishedJobWithoutSize() {
        let choice = DownloadChoice(job: Self.job())
        #expect(choice.finalizedJob.estimatedSize == 0)
        #expect(choice.finalizedJob.sizeIsCertain == false)
    }

    // MARK: - Mit Laufzeit

    /// **Where a runtime arrives, it is calculated again** — with Jellyfin that is the
    /// normal case (`MediaItem.runtime`). Checked with the real length of "Morrowfeld" S1E1:
    /// 561,149,891 bytes at 2 Mbit/s correspond to about 37.4 minutes.
    @Test("With a runtime the computed size is shown")
    func calculatedWithRuntime() {
        let choice = DownloadChoice(job: Self.job(source: .jellyfin, runtime: 37 * 60))
        #expect(choice.isSizeUnknown == false)
        #expect(choice.size(forItem: .episode(season: 1, number: 1)) == 555_000_000)
        #expect(choice.sizeText(forItem: .episode(season: 1, number: 1)) != nil)
    }

    /// **The runtime comes with the request and not from a default.** Until 2026-09-09
    /// the path did not exist: ``DownloadChoice`` hard-coded 48 minutes, and no caller
    /// could say anything else.
    @Test("The runtime travels along in the download request")
    func runtimeTravelsAlong() {
        let request = DownloadRequest(
            identifier: "jf-8dec87ad", title: "Morrowfeld", extent: .film, source: .jellyfin,
            runtime: 37 * 60)
        let expected: TimeInterval = 37 * 60
        #expect(request.job.runtime == expected)
        #expect(DownloadChoice(job: request.job).size(forItem: .film) == 555_000_000)
    }

    /// **The season is the episode times its count** — an extrapolation from **one**
    /// runtime and therefore still an estimate. It must not read like a measurement;
    /// it stays recognizable by the "about" that row and button both carry.
    @Test("The season total is eight times as much and carries the same “about”")
    func seasonIsSum() {
        let choice = DownloadChoice(job: Self.job(source: .jellyfin, runtime: 37 * 60))
        let eightEpisodes: Int64 = 8 * 555_000_000
        #expect(choice.size(forItem: .season(number: 1, episodes: 8)) == eightEpisodes)

        // Without a language catalog `String(localized:)` returns the key; the check is
        // therefore that both take the same one and not how it is translated.
        choice.extent = .season(number: 1, episodes: 8)
        #expect(choice.sizeText(forItem: choice.extent)?.contains("sizeAbout") == true)
        #expect(choice.footerCaption.contains("putAbout"))
    }

    /// **A movie has no episode count and still has a length.** ``Extent/episodeCount``
    /// returns `0` there — anyone who multiplies by it gets zero bytes.
    @Test("A film computes with its own length")
    func movieCalculatesSimply() {
        let choice = DownloadChoice(
            job: Self.job(extent: .film, source: .jellyfin, runtime: 100 * 60))
        let hundredMinutes: TimeInterval = 100 * 60
        #expect(choice.duration(forItem: .film) == hundredMinutes)
        #expect(choice.size(forItem: .film) == 1_500_000_000)
    }

    /// **The tier changes the size and not the runtime.** Four tiers, four numbers —
    /// and without a runtime four blanks.
    @Test("The tier rows compute with the same runtime")
    func tiersCalculate() {
        let using = DownloadChoice(job: Self.job(source: .jellyfin, runtime: 37 * 60))
        #expect(using.size(forItem: .low) == 555_000_000)
        #expect(using.size(forItem: .minimal) == 138_750_000)

        let without = DownloadChoice(job: Self.job(source: .jellyfin))
        #expect(without.size(forItem: .low) == nil)
        #expect(without.size(forItem: .minimal) == nil)
    }
}
