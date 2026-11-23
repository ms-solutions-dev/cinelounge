import Core
import Downloads
import Foundation
import Testing

@testable import FeaturesPhone

/// The path from the download sheet to the first byte — **the four places where it
/// broke on 2026-09-09**
///
/// **The finding was one sentence:** *"when I go to portal content and look at something there, I
/// still cannot download."* Measured at the bridge, the chain holds:
/// `/p/ahorn/sources` delivers ten finished `.mp4` from 1080p to 360p, `/play` gives a
/// file address for them, and a `Range: bytes=0-1` on it answers with `206` and
/// `accept-ranges: bytes`. The wiring was missing, not the capability.
///
/// **Checked without a bridge**, for the same reason as in the downloads package: What is
/// hard here are decisions — which host, which ID, what applies on the next
/// attempt.
@Suite("Downloads: the load path")
struct DownloadsLoadPathTests {

    // MARK: - Doubles

    /// A portal source with four hosts, one of them blocked.
    ///
    /// **The numbers are the measured ones.** Animehub delivers twelve rows for **one** episode
    /// — four hosts times three language versions —, and some of them the server marks as
    /// not usable.
    private final class PortalProbe: PlayerSource, @unchecked Sendable {

        /// What was last resolved with — the question that (a) is about.
        private(set) var asked: [String?] = []

        func target(zu job: PlaybackJob) async throws -> PlaybackRequest {
            asked.append(job.source)
            return PlaybackRequest(
                identifier: job.identifier, title: "Folge",
                address: URL(string: "http://portals.example:8099/stream?q=\(job.source ?? "-")")!,
                origin: .portals, validUntil: Date(timeIntervalSinceNow: 300))
        }

        func notify(
            location: TimeInterval, duration: TimeInterval, zu job: PlaybackJob, isPaused: Bool
        ) async throws {}

        func host(zu job: PlaybackJob) async throws -> [PortalHost] {
            [
                PortalHost(id: "hosta", name: "HOSTA", language: "(DE)"),
                PortalHost(
                    id: "hostd", name: "Hostd", language: "(DE)", locked: true,
                    reason: "Gesperrt"),
                PortalHost(id: "hosth", name: "Hosth", language: "(DE)"),
                PortalHost(id: "hoste", name: "Hoste", language: "(DE)"),
            ]
        }
    }

    /// A source without hosts — the media server.
    private struct ServerProbe: PlayerSource {
        func target(zu job: PlaybackJob) async throws -> PlaybackRequest {
            PlaybackRequest(
                identifier: job.identifier, title: "Film",
                address: URL(string: "https://server.invalid/stream?static=true")!)
        }
        func notify(
            location: TimeInterval, duration: TimeInterval, zu job: PlaybackJob, isPaused: Bool
        ) async throws {}
    }

    private static func portalJob(host: String?) -> DownloadJob {
        DownloadJob(
            id: .init("animehub|elvaran-1|https%3A%2F%2Fanimehub.example%2Fx"), title: "1 - Der Anfang",
            source: .portal, extent: .episode(season: 1, number: 1), host: host,
            version: "(DE)")
    }

    // MARK: - (a) The chosen option travels along

    /// **The smallest effective change — and the one without which everything else is useless.**
    ///
    /// The download sheet asks for host and language version and stores them in the ``DownloadJob``.
    /// The path to the resolver went until 2026-09-09 via `PlaybackJob(identifier:)`, and its
    /// ``PlaybackJob/source`` stayed `nil` — the bridge then took "the first usable".
    /// With four hosts times three language versions that is, with high probability, the
    /// wrong audio track.
    @Test("The chosen host appears in the playback job")
    func hostTravelsAlong() {
        let using = DownloadsManager.withHost(
            PlaybackJob(identifier: "animehub|elvaran-1|x", origin: .portals),
            Self.portalJob(host: "hosth"))
        #expect(using.source == "hosth")
    }

    /// **A choice made in the player wins.** It comes from the one place where
    /// someone saw what is on offer — overwriting it would mean replacing a decision
    /// with an older one.
    @Test("An already made choice stays")
    func choiceStays() {
        let using = DownloadsManager.withHost(
            PlaybackJob(identifier: "x", origin: .portals, source: "hoste"),
            Self.portalJob(host: "hosth"))
        #expect(using.source == "hoste")
    }

    /// **Without a host the job stays as it was** — the media server and the provider
    /// have none, and an empty field would be a choice nobody made.
    @Test("Nothing is invented without a host")
    func withoutHostNothing() {
        let without = PlaybackJob(identifier: "jf-42", origin: .jellyfin)
        #expect(DownloadsManager.withHost(without, Self.portalJob(host: nil)) == without)
        #expect(DownloadsManager.withHost(without, Self.portalJob(host: "")) == without)
    }

    // MARK: - (c) The next host

    /// **The promise from ``DownloadChoice`` — now fulfilled.** It says there verbatim: *"If the
    /// chosen host does not work, the job takes the next one — without asking."*
    ///
    /// **Blocked ones are skipped.** `/play` would give no address for them; trying
    /// would cost a request for an answer that is already known.
    @Test("Fallback goes to the next unlocked host")
    func fallsBack() async {
        let source = PortalProbe()
        let giver = PlaybackSourceAddress(
            source: source,
            job: PlaybackJob(identifier: "animehub|x|y", origin: .portals, source: "hosta"))

        _ = try? await giver.address()
        #expect(await giver.fallBack())
        _ = try? await giver.address()
        // "hostd" is blocked and is skipped.
        #expect(source.asked == ["hosta", "hosth"])
    }

    /// **Every host gets its turn exactly once, and then it is over.** A loop that
    /// tried the same one twice would use up bandwidth for an answer that is already
    /// known — and would never end.
    @Test("After the last host it ends")
    func finiteList() async {
        let giver = PlaybackSourceAddress(
            source: PortalProbe(),
            job: PlaybackJob(identifier: "animehub|x|y", origin: .portals, source: "hosta"))

        #expect(await giver.fallBack())  // hosth
        #expect(await giver.fallBack())  // hoste
        #expect(await giver.fallBack() == false)
    }

    /// **Whoever started without a choice got a host anyway** — the bridge
    /// takes "the first usable". Trying it again as a fallback would be a
    /// request with a guaranteed identical result.
    @Test("The first usable one counts as already tried")
    func firstCountsAsTried() async {
        let source = PortalProbe()
        let giver = PlaybackSourceAddress(
            source: source, job: PlaybackJob(identifier: "animehub|x|y", origin: .portals))

        _ = try? await giver.address()
        #expect(await giver.fallBack())
        _ = try? await giver.address()
        #expect(source.asked == [nil, "hosth"])
    }

    /// **Media server and provider do not fall back.** There is one file per title;
    /// "take another host" would have no target — and fetching the host list would be a
    /// request against an account that allows **one** connection.
    @Test("Without a portal there is no fallback")
    func noFallbackWithoutPortal() async {
        let giver = PlaybackSourceAddress(
            source: ServerProbe(),
            job: PlaybackJob(identifier: "jf-42", origin: .jellyfin))
        #expect(await giver.fallBack() == false)
    }

    // MARK: - (d) The portal identifier

    /// **Until 2026-09-09. `portal:` carried the string "portale"** — the origin and not
    /// the portal ID, the same for all four portals. Nobody noticed, because the
    /// field was read nowhere; since then it stands in every diagnostic line of a block.
    @Test("The portal comes from the title identifier")
    func portalFromIdentifier() {
        #expect(PortalJob.portal(from: "ahorn|doku-1|https%3A%2F%2Fard.de%2Fx") == "ahorn")
        #expect(PortalJob.portal(from: "animehub|elvaran-1|adr") == "animehub")
        // An address may itself contain hyphens — only the first two count.
        #expect(PortalJob.portal(from: "ahorn|x|a|b|c") == "ahorn")
    }

    /// **What is not a portal does not get one made up.** Reading a Jellyfin ID as a
    /// portal ID would yield a diagnostic line that claims an origin.
    @Test("Foreign identifiers yield no portal")
    func foreignIdentifierWithoutPortal() {
        #expect(PortalJob.portal(from: "8dec87ad4f") == nil)
        #expect(PortalJob.portal(from: "a|b") == nil)
        #expect(PortalJob.portal(from: "|b|c") == nil)
    }

    /// **The short form names what is missing when searching:** which host is not working right now.
    /// With the media server the fields stay empty, and then the line must not consist of
    /// separators.
    @Test("The diagnostic line names portal, episode and host")
    func shortForm() {
        let portal = PortalJob(
            portal: "animehub", key: "elvaran/s1/f12", host: "hosta", version: "(DE)")
        #expect(portal.shortForm == "animehub · elvaran/s1/f12 · hosta (DE)")

        let server = PortalJob(portal: "", key: "jf-42", host: "", version: "")
        #expect(server.shortForm == "jf-42")
    }

    // MARK: - (e) Resuming is not a fresh start

    /// **The finding of 2026-09-09, noticed during the own trailing-read check.** On the
    /// device, provider catalog, 2,5 GB: 92 MB loaded, then the provider reports "occupied",
    /// five seconds of trailing read — and the next line reads "fetch block 0–8388607".
    ///
    /// **The cause was an empty field.** ``Downloads/BackgroundSession`` discards a
    /// partial state about which nothing is known; the length would have been known, and it
    /// was never in the ``Downloads/PortalJob``. A file of this size never gets
    /// finished this way — every dropout costs everything.
    @Test("A measured length travels into the portal job")
    func measuredLengthTravelsAlong() {
        var job = DownloadJob(
            id: .init("A#movie#344604#mp4"), title: "Blind Harbinger", source: .provider,
            extent: .film)
        job.estimatedSize = 2_511_729_429
        job.sizeIsCertain = true
        #expect(DownloadsManager.measuredLength(job) == 2_511_729_429)
    }

    /// **An estimate must not travel along.**
    ///
    /// It would never hit the real number — measured on 2026-09-09: 720 MB estimated against 561 MB
    /// measured —, and ``Downloads/Resumability/sameFile(length:tag:changed:likeLength:likeTag:likeModified:)``
    /// answered "no" at the first block. The result would not be "starts over",
    /// but ``Downloads/LoadError/differentFile``: an abort with a red warning triangle for
    /// a file that is perfectly fine.
    @Test("An estimated size stays out")
    func estimatedSizeStaysOut() {
        var job = DownloadJob(
            id: .init("A#movie#344604#mp4"), title: "Blind Harbinger", source: .provider,
            extent: .film)
        job.estimatedSize = 720_000_000
        job.sizeIsCertain = false
        #expect(DownloadsManager.measuredLength(job) == nil)

        // **And a zero is not a length**, but "unknown" — see
        // ``Downloads/DownloadJob/estimatedSize``.
        job.estimatedSize = 0
        job.sizeIsCertain = true
        #expect(DownloadsManager.measuredLength(job) == nil)
    }
}
