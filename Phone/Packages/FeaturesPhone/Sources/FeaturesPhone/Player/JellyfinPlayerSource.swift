import Core
import DesignSystemPhone
import Diagnose
import Foundation
import JellyfinKit
import ParentalControls
import Playback
import PortalKit

/// Playback from the Jellyfin server — **and via the provider catalog.**
///
/// **Despite its name, not tied to Jellyfin.** It works through `Core.ContentSource`, and
/// what it needs — address, progress, next episode — is in that contract. The same
/// experience as with the detail page: the mapping belongs in a switch above, not in the
/// source.
public struct JellyfinPlayerSource: PlayerSource {

    private let source: any ContentSource
    private let width: Int
    private let origin: Catalog.Origin

    public init(source: any ContentSource, width: Int, origin: Catalog.Origin) {
        self.source = source
        self.width = width
        self.origin = origin
    }

    public func target(zu job: PlaybackJob) async throws -> PlaybackRequest {
        let title = try await source.item(id: job.identifier)
        return try await self.job(
            forItem: title, from: job.startAt, at: job.source,
            withoutRepackager: job.withoutRepackager)
    }

    /// The address for downloading — **with the Jellyfin server the file and not the stream.**
    ///
    /// See ``PlayerSource/loadTarget(zu:)`` for the measurement that decided this. `directPlay`
    /// is forced **without** a bitrate limit: Together they give the address
    /// `…/stream?static=true`, and only that one answers range requests with 206.
    ///
    /// **A portal falls back to the default**, because there the resolved host address is a
    /// file anyway — the same one that also plays.
    public func loadTarget(zu job: PlaybackJob) async throws -> PlaybackRequest {
        if let portal = source as? PortalSource {
            return try await portalLoadTarget(portal, job)
        }

        // **The description is optional here too** (2026-09-09, backfilled). For the portal path the
        // reasoning is at ``portalLoadTarget(_:_:)``; it applies word for word to the provider
        // catalog as well, and there it was fatal instead of merely expensive:
        // `XtreamVODSource.item(id:)` **throws for every episode** as a matter of principle
        // (`Failure.malformed`) — an episode could therefore never be downloaded, even though its
        // address `…/series/<user>/<password>/<identifier>.mkv` is fixed. For a film it was
        // "only" one `get_vod_info` **before every block**, i.e. one request per eight megabytes
        // on an account with one allowed connection.
        //
        // **What the download path needs is the address.** The name is an accessory — it is
        // already in the ``DownloadJob``, set by the page on which someone pressed the button. So
        // it is asked for, and if the source knows nothing, the download happens anyway. That is
        // the same rule as for playback: **what plays, downloads.**
        let title = try? await source.item(id: job.identifier)
        let direct = PlaybackDecision(
            engine: .native, delivery: .directPlay, reason: .nativeContainer)
        let address = try await source.streamURL(
            for: title?.id ?? job.identifier, decision: direct)
        Diagnose.step(.network, "Downloads: download address used directly, no conversion")
        return PlaybackRequest(
            identifier: job.identifier,
            title: title.map(TileArtwork.label) ?? "",
            address: address,
            decision: direct)
    }

    /// The download address of a portal title — **without the detour via its description.**
    ///
    /// **The finding of 2026-09-09, reproduced on the simulator and verified at the bridge.** A
    /// portal download failed with "Connection lost" at **zero** bytes, and the bridge log
    /// showed exactly one line:
    ///
    ///     GET /stand?schluessel=1-mebik  →  404 Not Found
    ///
    /// No `/sources`, no `/play` — it failed **before** anything was fetched.
    ///
    /// **The cause is a detour.** Until now downloading went through ``target(zu:)``, and that
    /// begins with `item(id:)` — that is, with the **description** of the title. A portal does
    /// not know that by itself, though: `PortalSource.item(id:)` asks its notepad, then the
    /// bridge's state, then the portal search. The notepad is empty after a program start, the
    /// state contains only what has played once, and the search looks for the key —
    /// "1 mebik" finds nobody on Serieshub, the series is called "Bloufeit". Three
    /// stages, three failures, and the download was dead.
    ///
    /// **Yet the app carried the address with it the whole time.** A portal identifier is
    /// `portal|key|address`, and `stream(forItem:source:)` needs exactly this address and
    /// nothing else. Measured again at the bridge: `/sources` delivers the hosts, `/play` the
    /// file, a range request on it **206** with `content-range: bytes 0-1/561149891`. The
    /// chain held up — it was just never asked.
    ///
    /// **That is why the description is optional here and the address is not.** The name is
    /// already in the ``DownloadJob``: It comes from the detail page, which knew it when the
    /// viewer pressed the button. Obtaining it a second time here would mean letting a
    /// download fail on information it does not need.
    ///
    /// **For playback the old path stays.** There the description is no accessory: The player
    /// shows title, subtitle, duration and image, and a screen without them would be half the
    /// view. A download has no screen.
    private func portalLoadTarget(
        _ portal: PortalSource, _ job: PlaybackJob
    ) async throws -> PlaybackRequest {
        let stream = try await portal.stream(forItem: job.identifier, source: job.source)
        Diagnose.step(
            .network, "Downloads: portal address taken from the identifier, no description")
        return PlaybackRequest(
            identifier: job.identifier,
            title: (try? await source.item(id: job.identifier))
                .map(TileArtwork.label) ?? "",
            address: stream.address,
            headers: stream.headers,
            origin: .portals,
            validUntil: stream.validUntil)
    }

    /// The hosts of a title — **only a portal has any.**
    ///
    /// The same case distinction as with the deadline below, and with the same reasoning:
    /// `ContentSource` knows no hosts, because a Jellyfin server has none. Whoever attached an
    /// empty default to all forty contract methods would turn a peculiarity of the portals
    /// into a property of all sources.
    public func host(zu job: PlaybackJob) async throws -> [PortalHost] {
        guard let portal = (source as? PortalSource) ?? ((source as? FilteredSource)?.source as? PortalSource)
        else { return [] }
        return try await portal.host(forItem: job.identifier).map(PortalHost.init)
    }

    /// The source itself — **it is already filtered** (``SourceAssembly/playbackSource(_:width:origin:rule:)``
    /// puts the rule over it before it arrives here).
    public func contents(zu job: PlaybackJob) -> (any ContentSource)? { source }

    /// **Yes, because the filter stands in front of it** — the source delivers only what the
    /// rule lets through. The question about the origin is answered by
    /// ``CompositePlayerSource``, which sits above it.
    public func mayPlay(_ title: MediaItem, zu job: PlaybackJob) -> Bool { true }

    public func notify(
        location: TimeInterval, duration: TimeInterval, zu job: PlaybackJob, isPaused: Bool
    ) async throws {
        // **With the watched mark as on the TV** (AP58 R4): from 90 %.
        try await source.report(
            progress: PlaybackProgress(
                position: location, duration: duration,
                isWatched: PlaybackReporter.isWatched(position: location, duration: duration)),
            for: job.identifier, isPaused: isPaused)
    }

    public func segments(zu job: PlaybackJob) async throws -> [MediaSegment] {
        try await source.segments(for: job.identifier)
    }

    public func nextEpisode(after job: PlaybackJob) async throws -> PlaybackRequest? {
        guard let episode = try await source.nextEpisode(after: job.identifier) else {
            return nil
        }
        // **The next episode begins where the server says** — and not where the previous one
        // stopped. `nil` is exactly that: "ask the server".
        // **Without the host choice of the previous episode.** It belongs to that episode: Which
        // hosts an episode carries is decided by the portal per episode, and an identifier from
        // yesterday would simply be unknown for the next one.
        // **And without the repackager flag of the previous episode**, for the same reason: That
        // one file could not be read says nothing about the next.
        return try await self.job(forItem: episode, from: nil, at: nil, withoutRepackager: false)
    }

    public func begin(_ job: PlaybackJob) async throws {
        try await source.beginSession(for: job.identifier)
    }

    public func finish(_ job: PlaybackJob, at location: TimeInterval) async throws {
        try await source.endSession(for: job.identifier, at: location)
    }

    /// Builds everything the player needs from a title.
    ///
    /// **The engine choice is made by `PlaybackEngineSelector` and not by this file.** It
    /// weighs subtitles, container, codecs, color range and bandwidth against each other —
    /// every imitation of that would be a second rule that diverges at the first special
    /// case.
    ///
    /// **And what this device can do is asked, not assumed.** `DeviceCodecs` asks
    /// VideoToolbox at runtime: An iPhone 15 does not decode AV1, a newer one does. Whoever
    /// assumes that in the source code either ships something that stays black or wastes the
    /// hardware.
    /// - Parameter ab: Where to begin. `nil` means **not zero**, but "the server says" — the
    ///   progress is kept on the user account and may come from the TV. A position that
    ///   traveled along takes precedence: "From the beginning" sends a zero, and a chapter
    ///   jump sends the chapter mark. Until 2026-09-06 this path did not exist — `playFrom`
    ///   received the position from the detail page and threw it away.
    /// - Parameter bei: The identifier of a chosen host, otherwise `nil` for "the first usable
    ///   one". It comes only from the source choice in the player.
    /// - Parameter ohneUmpacker: Whether the app's own repackager should be avoided — see
    ///   ``isServable(_:withoutRepackager:)``. Always false on the first startup.
    private func job(
        forItem title: MediaItem, from: TimeInterval?, at chosen: String?, withoutRepackager: Bool
    ) async throws
        -> PlaybackRequest
    {
        guard let media = title.source else { throw Missing.source }
        async let approval = historyClearance(title)

        // **Calculated once and used twice.** ``isAnime`` decides the track choice and at the
        // same time travels along in the request.
        let anime = StartingTracks.isAnime(
            genres: title.genres, anilistID: title.ratings.anilistID)

        // **The same planning as on the TV** (AP58 R4, ``Core/PlaybackPlan``). Until then the
        // engine choice here received neither audio track nor subtitles, neither quality level
        // nor measured line, neither the ASS choice nor the screen — and it assumed a Jellyfin
        // server even for providers and portals. The start position follows
        // ``Core/PlaybackProgress/startPoint(fixed:state:length:)`` (since R0).
        let device = await PlaybackPlan.Device.thisDevice
        let plan = PlaybackPlan.build(
            title: title, media: media, source: PlaybackPlan.Source(source),
            preference: PlaybackPlan.Preference.effective(interfaceLanguage: LanguageChoice.running()),
            device: device, reason: .start(fixed: from, fromStart: false))
        let decision = plan.decision

        // **The decision itself stays in place**, only the delivery path can be replaced: What
        // the evaluator found out about subtitles, codecs and bandwidth still applies, and the
        // diagnostics show both.
        let isServable = Self.isServable(decision, withoutRepackager: withoutRepackager)
        // **Only a portal names a deadline, and only it is asked.**
        //
        // The contract of `ContentSource` returns a `URL` and knows no validity — rightly so: A
        // Jellyfin server has none, and neither does a provider catalog. The deadline is a
        // peculiarity of the portals, and attaching it to all sources would mean touching
        // forty-three call sites for one. That is why the only case distinction of this file
        // stands here, with its reason next to it — and `PortalSource.stream(forItem:)` lies **next
        // to** `streamURL` and not in its place, so the TV app notices nothing of it.
        let address: URL
        var validUntil: Date?
        // **And the headers with it** (2026-09-09): The host demands them, the bridge knows them, and
        // until then they ended in `PortalSource`. For playback this went unnoticed — there the
        // stream runs through the bridge, which sets them itself —, for downloading it is a 403
        // before the first byte.
        var headers: [String: String] = [:]
        var carries: String?
        if let portal = source as? PortalSource {
            let stream = try await portal.stream(forItem: title.id, source: chosen)
            address = stream.address
            validUntil = stream.validUntil
            headers = stream.headers
            // **Which source carries is decided by the server** — and since 2026-09-16 it may be a
            // different one than the one requested. Into the ledger, because that is the explanation
            // when the source choice suddenly marks a different row.
            carries = await portal.lastSource
            if await portal.lastSourceSwitched {
                Diagnose.step(
                    .playback,
                    "Source switched by the server: \(chosen ?? "first") does not carry, "
                        + "\(carries ?? "?") plays")
            }
        } else {
            address = await Self.playable(try await source.streamURL(for: title.id, decision: isServable))
        }
        Diagnose.step(
            .playback,
            "Engine choice: \(isServable.engine.rawValue) via \(isServable.delivery.rawValue) "
                + "— \(decision.reason.rawValue)"
                + (isServable.delivery == decision.delivery
                    ? "" : " (statt \(decision.delivery.rawValue))"))

        return PlaybackRequest(
            identifier: title.id,
            title: TileArtwork.label(title),
            beside: TileArtwork.secondaryLine(title),
            address: address,
            headers: headers,
            startAt: decision.startAt,
            duration: title.runtime,
            audioTracks: PlaybackTrack.fromServer(media.audioTracks),
            subtitles: PlaybackTrack.fromServer(media.subtitleTracks),
            chapters: title.chapters ?? [],
            image: PosterAddress.url(for: title, from: source, width: width),
            backdrop: TileArtwork.backdrop(title, source: source, width: width),
            description: title.overview?.trimmingCharacters(in: .whitespacesAndNewlines),
            origin: origin,
            validUntil: validUntil,
            decision: Self.passedThrough(isServable, origin: origin),
            // **Here and not in the player.** The shared
            // ``Core/StartingTracks/isAnime(genres:anilistID:)`` needs genres and the AniList
            // identifier; the player no longer has either, this place does.
            isAnime: anime,
            // **The format note travels along into the history** (2026-09-08). This source also serves
            // the portals — the collective source sends every origin here —, and the bridge fills
            // `Artwork.isWide`. Without this line, a landscape poster in "Continue Watching" would
            // again sit in the portrait frame, although it is long since correct in the portal.
            wide: title.artwork.isWide,
            // **The full track picker, at the only place that can feed it** (E45). It needs the
            // `MediaSource` — `media` stands three lines higher —, and it chooses audio and
            // subtitles **together**: "Anime in the original audio" means Japanese audio *and*
            // subtitles in the interface language. Whoever switched only the audio track delivered
            // Japanese audio without text.
            //
            // **The subtitle level thereby finally takes effect.** Since E45 it lay in the shared
            // ``Core/AudioPreference``, traveled along via the handoff — and was saved without ever
            // being applied.
            startAudio: Self.trackNumber(plan.audio),
            startSubtitle: Self.trackNumber(plan.subtitles),
            audioLanguage: plan.audioLanguage,
            subtitleLanguage: plan.subtitleLanguage,
            source: carries,
            approval: await approval)
    }

    /// The rating for the history — **for an episode, the one of its series** (AP58, K4).
    ///
    /// `item(id:)` does not look up the series; without this step every episode would carry
    /// an open series rating and drop out of Continue Watching in child mode. The question
    /// runs alongside the address building and therefore costs no waiting time. If it fails,
    /// the rating stays open, and the entry counts as blocked in child mode. Portals carry no
    /// series ratings and are not asked.
    private func historyClearance(_ title: MediaItem) async -> HistoryClearance {
        guard title.belongsToSeries, title.seriesClearanceChecked != true,
            !(source is PortalSource)
        else { return HistoryClearance(title) }
        let completed = await SeriesClearances().complete(
            [title], fetch: SeriesClearanceBackfill.fetch(about: source))
        return HistoryClearance(completed.first ?? title)
    }

    /// The number under which the engine knows a track.
    ///
    /// **Two identifier spaces, one translation.** `MediaTrack.id` is a **text** — the
    /// description from the server —, `PlaybackTrack.id` a **number**: the track's position in
    /// the file. Together they connect via `Int(track.id)`, and that is exactly what
    /// ``Core/PlaybackTrack/fromServer(_:)`` does when building the list. Here stands the same
    /// translation for the one track that was chosen.
    ///
    /// **`nil` for everything that is not a number**, and that is not an edge case: For an
    /// external subtitle track the server carries an identifier that is not a track number —
    /// turning an invented number out of it would mean choosing some arbitrary track at
    /// start.
    static func trackNumber(_ track: MediaTrack?) -> PlaybackTrack.ID? {
        track.flatMap { Int($0.id) }
    }

    /// Whether the obtained decision travels along in the request — **or whether it is
    /// estimated.**
    ///
    /// **It is passed on where the address was built for it.** That is the Jellyfin server:
    /// `JellyfinSource.streamURL` reads the delivery path and builds the raw file for
    /// `remuxInApp`, the playlist for `hls`. Tearing exactly this pair apart was the bug of
    /// 2026-09-07 — see ``PlaybackRequest/decision``.
    ///
    /// **For the other origins it stays with the estimate** (``PlaybackRequest``), and that is
    /// not inertia but the smaller bet:
    ///
    /// * **Portals** deliver a host address as a finished MP4. It does not depend on the
    ///   delivery path, because `PortalSource.stream(forItem:source:)` never gets to see it — a
    ///   decision "repackage" over an address that knows nothing of it would be an assertion.
    /// * **The provider catalog** hands out its films as they lie. If a Matroska lay there,
    ///   the passed-on decision would send the repackager via `MatroskaClusterWalk` with
    ///   thirty-two simultaneous range requests onto an account that allows **one** connection
    ///   and throttles on request bursts. That deserves a measurement of its own and is no side
    ///   effect of this repair.
    ///
    /// **Unless it does not go through the repackager** (AP75, 2026-10-11). An MP4 from the
    /// IPTV catalog gets "native, direct" from the evaluator — and until then this turned it
    /// into the guessed `hls`. That was no cosmetic flaw: A film resumed at a position counts
    /// with `hls` as a recording via the server's segmentation
    /// (``Flows/RemuxStart/needsStartMark(_:)``), and ``Core/HLSStartRelay`` downloaded
    /// the whole MP4 as a "playlist" before it noticed it is none. The real decision now
    /// travels along as long as it demands no repackager; the Matroska question above stays
    /// open and stays with the estimate.
    static func passedThrough(
        _ decision: PlaybackDecision, origin: Catalog.Origin
    )
        -> PlaybackDecision?
    {
        switch origin {
        case .jellyfin, .downloads: return decision
        case .provider: return decision.runsOverRepacker ? nil : decision
        case .channelList, .portals: return nil
        }
    }

    /// Sets a delivery path that **this** engine alone can serve.
    ///
    /// **The normal case is: change nothing.** The app's own repackager is connected —
    /// ``RepackagerRun`` accepts `renderInApp` and `remuxInApp`, for the channel as for the
    /// file. What the evaluator decided applies.
    ///
    /// **The stopgap is the second startup, and it is a transition.** If
    /// ``RepackagerRun/start(_:)`` throws, the app cannot read the file itself: a Matroska
    /// without a seek table, a container without a reader, a server that answers no range
    /// requests — or an `https` certificate only the app trusts, because `HTTPByteRangeSource`
    /// uses its own `URLSession` without the certificate sheet. Then the path is set to
    /// **HLS**: The Jellyfin server segments, Apple's engine plays it without further effort.
    ///
    /// **What that costs:** Compute time on the server instead of on the phone. Measured on
    /// the TV, that is 8.1 seconds to the picture against 303 milliseconds via the own
    /// repackager — and for a title the server has to transcode, its ffmpeg runs for the whole
    /// playback.
    ///
    /// **When it goes away:** As soon as the cause of the throw is fixed. It is not a permanent
    /// path but the reason why a failure of the repackager yields a picture instead of an error
    /// screen.
    ///
    /// **The decision otherwise stays untouched** — engine, reasoning, limits and start
    /// position travel on unchanged. Only the delivery path is replaced, and the diagnostics
    /// write both paths side by side.
    static func isServable(
        _ decision: PlaybackDecision, withoutRepackager: Bool
    )
        -> PlaybackDecision
    {
        guard withoutRepackager, decision.runsOverRepacker else { return decision }
        return PlaybackDecision(
            engine: .native,
            delivery: .hls,
            reason: decision.reason,
            maxBitrate: decision.maxBitrate,
            maxWidth: decision.maxWidth,
            isBandwidthLimited: decision.isBandwidthLimited,
            audioStreamIndex: decision.audioStreamIndex,
            subtitleStreamIndex: decision.subtitleStreamIndex,
            displaySupportsHDR: decision.displaySupportsHDR,
            startAt: decision.startAt)
    }

    /// **A dedicated error and no silent null case.** "The server names no version" is
    /// something different from "the network does not respond", and the screen says the two
    /// differently.
    enum Missing: Error { case source }
}

// MARK: - Der Systemplayer und das Zertifikat

extension JellyfinPlayerSource {

    /// Remembers per host whether the local address answers without TLS — **asked once.**
    private actor HomeAddresses {
        static let shared = HomeAddresses()
        private var answers: [String: Bool] = [:]

        func responds(_ calculator: String, probe: () async -> Bool) async -> Bool {
            if let known = answers[calculator] { return known }
            let result = await probe()
            answers[calculator] = result
            return result
        }
    }

    /// A stream address the system player can open.
    ///
    /// **The finding of 2026-09-07 from TestFlight:** Library there, film does not play. The
    /// connection was set to `https`, and the app trusted the certificate via its certificate
    /// sheet — the system player has its own network stack and rejects it. The TV has always
    /// bypassed this by using the local address without TLS (port 8096); the same happens
    /// here, but **only** if the app itself had to trust the certificate, and only if the
    /// local address answers. For a certificate the system trusts, everything stays as it is.
    /// If the local address does not answer, the address stays as well — and
    /// ``PlaybackPhase/certificateSystemPlayer`` then says what the cause is.
    static func playable(_ address: URL) async -> URL {
        guard PlayerModel.trustedByAppOnly(address), let calculator = address.host(),
            var split = URLComponents(url: address, resolvingAgainstBaseURL: false)
        else { return address }
        split.scheme = "http"
        split.port = 8096
        guard let withoutTLS = split.url,
            var root = URLComponents(url: withoutTLS, resolvingAgainstBaseURL: false)
        else { return address }
        root.path = ""
        root.query = nil
        guard let basis = root.url else { return address }
        let responds = await HomeAddresses.shared.responds(calculator) {
            (try? await JellyfinConnection(timeout: 4).probe(basis)) != nil
        }
        if responds {
            Diagnose.step(
                .playback,
                "Stream over the local address without TLS — the system player does not trust the certificate, the app does"
            )
            return withoutTLS
        }
        Diagnose.step(
            .playback,
            "Local address \(basis.absoluteString) not responding — the system player gets the https address"
        )
        return address
    }
}
