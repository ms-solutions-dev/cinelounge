import Foundation

/// Everything the player needs — and nothing beyond that.
///
/// **The player knows no source.** It gets a finished URL, a
/// start point and the details for the display. That is the reason for this type:
/// a channel from an M3U list, a movie from Jellyfin and a trailer look the same to
/// the player, although they come from three different worlds.
///
/// Whoever passed a ``MediaItem`` into the player instead would have to distinguish there
/// again where it comes from — and would immediately tear down the separation that ``ContentSource``
/// and ``ChannelSource`` establish.
public struct PlaybackTarget: Sendable, Equatable, Identifiable {

    /// What progress is reported for. Empty for a trailer or a channel:
    /// there is nothing to remember there.
    public let itemID: String?

    public let title: String
    /// Second line — for an episode "Season 2 · Episode 4", for a channel the
    /// current program.
    public let subtitle: String?

    public let url: URL

    /// The URL under which this target is **registered**.
    ///
    /// **Not the same as ``url`` since the remuxer runs in the app.** It
    /// builds a playlist on `127.0.0.1` from the channel, and ``url``
    /// then points there — right for the engine and wrong for anyone who
    /// wants to know *which* channel this is. Exactly that was behind two failures
    /// of 2026-08-11: Up and Down no longer found a neighbour, and the
    /// overlay did not find the running channel again (no program, no
    /// cursor on the right row, always the first group).
    ///
    /// `nil` means: not redirected, ``url`` is both. It is queried via
    /// ``sourceURL`` so that there is no case distinction at the call sites.
    public let origin: URL?

    /// The URL by which this target is **recognised**.
    ///
    /// For everything that assigns the target to a source — channel switching, program,
    /// favorite mark. For the engine ``url`` still applies.
    public var sourceURL: URL { origin ?? url }

    /// The same target, but the engine gets a different URL.
    ///
    /// **For the remuxer.** It builds a playlist on
    /// `127.0.0.1` from the channel; the engine should go there, and everything that assigns the target to a source
    /// — channel switching, program, favorite mark — should keep seeing the channel.
    /// ``origin`` therefore remembers the original URL.
    ///
    /// **And it does not overwrite an existing `origin`.** Whoever redirects twice
    /// still means the same channel; the first origin is the real one. Exactly that was behind
    /// two failures of 2026-08-11: Up and Down no longer found a neighbour.
    public func redirected(to incoming: URL) -> PlaybackTarget {
        PlaybackTarget(
            itemID: itemID, title: title, subtitle: subtitle, url: incoming,
            decision: decision, startAt: startAt, duration: duration, seriesID: seriesID,
            media: media, chapters: chapters,
            preferredAudioLanguage: preferredAudioLanguage,
            preferredSubtitleLanguage: preferredSubtitleLanguage, kind: kind,
            origin: sourceURL, contentFrameRate: contentFrameRate)
    }

    public let decision: PlaybackDecision

    /// Where the **player** should jump to after it has loaded. Zero means: do not
    /// jump at all.
    ///
    /// For a resumed title this is zero today — there the server starts further
    /// ahead, see ``streamOffset``. The field stays because a seek within the
    /// running stream still occurs and is also the right way for short distances.
    public let startAt: TimeInterval

    /// What the server reports as the length, if known. The engine supplies it
    /// itself later — until then this already puts a bar there, instead of starting at
    /// zero and jumping.
    public let duration: TimeInterval?

    /// For the next episode. Without a series there is none.
    public let seriesID: String?

    /// What the server knows about the file — for track selection with chunked
    /// delivery.
    ///
    /// There the engine knows only the one track that the server packed in;
    /// the selection in the player is fed from this metadata, and a switch
    /// becomes a new request. For channels and trailers it stays empty — their
    /// tracks are in the stream, and the engine finds them itself.
    public let media: MediaSource?

    /// Chapter marks of the title — jump targets for the control bar.
    /// Empty if the server carries none; for channels and trailers always.
    public let chapters: [Chapter]

    /// Language preferences for engines that find their tracks in the stream themselves.
    ///
    /// With chunked delivery the choice is in the URL as a track number —
    /// there no preference is needed anymore. VLC and unchanged delivery,
    /// however, choose only once their tracks have appeared, and that happens
    /// after the start. The player then applies the preferences exactly once.
    public let preferredAudioLanguage: String?
    public let preferredSubtitleLanguage: String?

    /// The content's frame rate in hertz, if someone **measured** it.
    ///
    /// **Filled by the remuxer, needed by the TV.** The engine can otherwise only
    /// estimate the frame rate from its own drawing rate, and that is wrong during
    /// startup: on 2026-08-22 it announced the same channel within 18 seconds
    /// as 24, then 25, then 50 Hz — with matching enabled that is
    /// three mode switches of the TV for a single channel. Whoever knows the number
    /// beforehand announces once and correctly.
    ///
    /// `nil` means "nobody measured" — then the engine's estimate stays,
    /// because a guessed number would be worse here than none.
    public let contentFrameRate: Double?

    /// What is playing right now. Determines what the controls offer — not as
    /// free text, but as a case, so that nothing can be forgotten.
    public let kind: Kind

    public enum Kind: String, Sendable, Equatable {
        /// Movie, episode, home video — has a length, progress and an end.
        case recording
        /// Trailer. No progress, no next episode, no skipping.
        case trailer
        /// Channel. No seeking, no end, no progress report.
        case live
    }

    /// **Via ``sourceURL`` and not via ``url``.** Otherwise a channel changes
    /// its identity at the moment the remuxer stands — for SwiftUI
    /// that would be a different title, and the view would rebuild in the middle of startup.
    public var id: String { (itemID ?? sourceURL.absoluteString) + kind.rawValue }

    public init(
        itemID: String?,
        title: String,
        subtitle: String? = nil,
        url: URL,
        decision: PlaybackDecision,
        startAt: TimeInterval = 0,
        duration: TimeInterval? = nil,
        seriesID: String? = nil,
        media: MediaSource? = nil,
        chapters: [Chapter] = [],
        preferredAudioLanguage: String? = nil,
        preferredSubtitleLanguage: String? = nil,
        kind: Kind = .recording,
        origin: URL? = nil,
        contentFrameRate: Double? = nil
    ) {
        self.itemID = itemID
        self.title = title
        self.subtitle = subtitle
        self.url = url
        self.origin = origin
        self.decision = decision
        self.startAt = startAt
        self.duration = duration
        self.seriesID = seriesID
        self.media = media
        self.chapters = chapters
        self.preferredAudioLanguage = preferredAudioLanguage
        self.preferredSubtitleLanguage = preferredSubtitleLanguage
        self.kind = kind
        self.contentFrameRate = contentFrameRate
    }

    /// The same target, but from somewhere else — and possibly decided differently.
    ///
    /// **For the remuxer in the app.** It builds a playlist on `127.0.0.1`
    /// from the file on the server; for the engine only the
    /// URL changes, nothing else. And if it does not accept the file, the
    /// decision changes too — then the second engine takes over again.
    /// - Parameter startAt: A corrected start position — for example zero if the
    ///   desired one lies beyond the end of a truncated file.
    public func rerouted(
        to url: URL, decision: PlaybackDecision? = nil, frameRate: Double? = nil,
        startAt: TimeInterval? = nil, subtitle: String? = nil
    ) -> PlaybackTarget {
        PlaybackTarget(
            itemID: itemID, title: title, subtitle: subtitle ?? self.subtitle, url: url,
            decision: decision ?? self.decision, startAt: startAt ?? self.startAt,
            duration: duration, seriesID: seriesID, media: media, chapters: chapters,
            preferredAudioLanguage: preferredAudioLanguage,
            preferredSubtitleLanguage: preferredSubtitleLanguage, kind: kind,
            // **The first origin remains the origin.** If redirected twice
            // — the remuxer fails, VLC gets the raw stream —, a
            // plain `url` would point to the intermediate station instead of the channel.
            origin: sourceURL,
            // The remuxer measures it, so the remuxer hands it over here. Without a
            // value the existing one stays — a second redirect should not
            // lose a number that has already been measured.
            contentFrameRate: frameRate ?? contentFrameRate
        )
    }

    /// Whether progress should be reported for this target.
    ///
    /// Decided explicitly here and not when reporting: a trailer that ends up on
    /// Home as "40 % watched" is a mistake that you only
    /// notice once it is standing there.
    public var tracksProgress: Bool {
        kind == .recording && itemID != nil
    }

    /// Whether seeking is allowed. With a live channel there is nothing to seek.
    public var isSeekable: Bool {
        kind != .live
    }
}
