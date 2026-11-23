import Foundation

/// What `/play` answers — **all of it.**
///
/// **As a type of its own and not as a four-element tuple** (2026-09-12): a tuple with four
/// fields can no longer be read at the call site, and the fourth had just been added.
public struct PortalStream: Sendable, Equatable {

    /// The reachable address — **always via the service's pass-through.**
    ///
    /// **Never a redirect.** A 302 carries no headers and cannot give a reason for a refusal; the
    /// app needs both. Whoever passed on the raw address of a portal's local pass-through would hand the
    /// Apple TV `127.0.0.1` — and that is itself.
    public let address: URL

    /// Until when this address is valid. After that **resolve anew**, do not repeat the old one.
    public let validUntil: Date?

    /// What the player has to send along — empty if the service passes through.
    public let headers: [String: String]

    /// The subtitle tracks — **mostly empty, and that is a statement.**
    ///
    /// Empty means "this portal supplies none", not "not loaded yet": it comes from the same response
    /// as the video address. A spinner at this point would spin forever.
    public let subtitles: [PortalSubtitle]

    /// The source that actually holds up — `nil` for the old bridge, which does not say.
    public let source: String?

    /// Did the server take a **different** source than the requested one? Then ``source`` holds the
    /// one that is running, and the choice in the player should follow it.
    public let switched: Bool

    public init(
        address: URL, validUntil: Date?, headers: [String: String],
        subtitles: [PortalSubtitle], source: String? = nil, switched: Bool = false
    ) {
        self.address = address
        self.validUntil = validUntil
        self.headers = headers
        self.subtitles = subtitles
        self.source = source
        self.switched = switched
    }
}

/// A subtitle track from a portal.
///
/// **Only WebVTT arrives here**, and the server decides that: AVPlayer does not open EBU-TT-D,
/// and a subtitle that does not open is worse than none. That is why ``PortalSubtitle/init(_:)``
/// is selecting and not merely transcribing — what cannot be played does not get into the list.
public struct PortalSubtitle: Sendable, Equatable, Identifiable {

    /// The language code, **as the portal finds it** — often three letters (`deu`), not always.
    ///
    /// **Not normalised to two letters.** What stands here is the portal's statement; the display
    /// makes a language name from it, and it can handle both.
    public let language: String
    public let address: URL

    public var id: String { language + "|" + address.absoluteString }

    /// From a response of the service — `nil` if the track is no good.
    init?(_ track: BridgeReply.SubtitleTrack) {
        // **The scheme is required, not just a readable address.** `URL(string:)` by now accepts almost
        // any string — "no URL" yields a valid `URL` with an encoded space and without a scheme. It
        // cannot be fetched, and a track that cannot be fetched does not belong in the list.
        guard track.format.lowercased() == "vtt", let address = URL(string: track.address),
            let schema = address.scheme?.lowercased(), schema == "http" || schema == "https"
        else { return nil }
        self.language = track.language
        self.address = address
    }

    public init(language: String, address: URL) {
        self.language = language
        self.address = address
    }
}
