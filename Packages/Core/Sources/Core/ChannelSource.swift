import Foundation

/// A TV channel from a channel list.
public struct Channel: Sendable, Equatable, Identifiable {

    public let id: String
    public let name: String
    /// Group from the channel list, such as country or genre.
    public var group: String?
    public var logoURL: URL?
    public var streamURL: URL
    /// Identifier for matching to the program guide.
    public var epgID: String?
    public var isFavorite: Bool

    /// How the provider classifies the channel.
    ///
    /// Deliberately kept as a statement **by the provider** and not as a judgement: in
    /// a checked catalog, 294 of 5389 channels carry the label, but whether
    /// it is complete and correct only the provider knows. What follows from it is decided by
    /// ``LivePreferences`` — here is only what is stated there.
    public var isAdult: Bool

    /// Whether this can be time-shifted content, and how many days back.
    ///
    /// `nil` if the channel offers no catch-up. In a checked catalog,
    /// 51 of 5389 channels have three days. Taken along because the value is in
    /// the same response anyway — adding it later would mean fetching everything again.
    public var archiveDays: Int?

    /// Which stored list the channel comes from — needed with several lists
    /// to tell duplicates apart and to assign favorites correctly.
    public let playlistID: String

    // MARK: - Computed once, not at every opportunity
    //
    // **The finding** (AP7 · L6, expert review 2026-08-24): ``cleanName``,
    // ``searchKey``, ``favoriteName`` and ``isSectionMarker`` were computed
    // properties — each folds the name anew, and the catalog has 5389
    // channels. That hit in four places at once: about 165 ms at startup,
    // about 350 ms on every press of "Favorite" (the catalog is folded
    // **twice** in the process), a hitch on every settings change, and
    // the cost per drawn channel row.
    //
    // Computation now happens at build time — once per channel, where it arises anyway
    // from the provider's response.

    /// The name as it should appear on screen.
    ///
    /// Two cleaning steps, both backed by real lists:
    ///
    /// 1. An **appended resolution in parentheses** is dropped — `(1080p)`, `(HD)`.
    ///    This is the quirk of simple M3U lists.
    /// 2. **Superscript decoration characters are folded**, `ᴴᴰ` becomes `HD`. This is the
    ///    quirk of commercial Xtream providers: 40 percent of 5389 checked
    ///    names carry them. The detailed reasoning is at ``ChannelName``.
    ///
    /// The order matters: fold first, then remove the parentheses. A provider
    /// who writes `(⁴ᴷ)` would otherwise not be caught — the search pattern knows `4K`,
    /// but not `⁴ᴷ`.
    public let cleanName: String

    /// The name for the favorite identifier — folded like ``cleanName``, but
    /// **with** the quality suffix.
    ///
    /// The split is the on-device finding of 2026-08-15: for **display**,
    /// "(1080p)" is ornament and may go; for **remembering**, the version is
    /// half the information. Whoever marks "KopruHaber HD" does not mean UHD, FHD and
    /// HEVC as well — via the display name they got them all.
    public let favoriteName: String

    /// What is searched and sorted by — never display it.
    ///
    /// Separate from the displayed name because the two need different things: the display
    /// must keep `RAW`, because it distinguishes two feeds of the same channel;
    /// the search must get rid of the provider's prefix, because otherwise
    /// 1313 channels begin with `DE`.
    public let searchKey: String

    /// Whether this entry is not a channel at all but a group heading.
    ///
    /// Providers put them in the middle of the list. They have an ID and address like
    /// any channel and deliver nothing. Reasoning and evidence at
    /// ``ChannelName/isSectionMarker(_:)``.
    public let isSectionMarker: Bool

    public init(
        id: String,
        name: String,
        streamURL: URL,
        playlistID: String,
        group: String? = nil,
        logoURL: URL? = nil,
        epgID: String? = nil,
        isFavorite: Bool = false,
        isAdult: Bool = false,
        archiveDays: Int? = nil
    ) {
        self.id = id
        self.name = name
        self.streamURL = streamURL
        self.playlistID = playlistID
        self.group = group
        self.logoURL = logoURL
        self.epgID = epgID
        self.isFavorite = isFavorite
        self.isAdult = isAdult
        self.archiveDays = archiveDays

        // Fold once instead of at every opportunity — see the fields above.
        let displayed = ChannelName.display(name)
        self.favoriteName = displayed
        self.cleanName = displayed.replacing(Self.resolutionAtEnd, with: "")
        self.searchKey = ChannelName.searchKey(name)
        self.isSectionMarker = ChannelName.isSectionMarker(name)
    }

    /// An appended resolution in parentheses — `(1080p)`, `(HD)`.
    ///
    /// Compiled once and then kept: Foundation keeps no
    /// cache for patterns, every occurrence compiles it anew.
    nonisolated(unsafe) static let resolutionAtEnd: Regex<AnyRegexOutput> = {
        // The expression is fixed; if it fails, that is a programming error
        // and not a runtime condition.
        // swift-format-ignore
        try! Regex(#"\s*\((?:\d{3,4}[pi]|HD|FHD|UHD|4K|SD)\)\s*$"#)
            .ignoresCase()
    }()

    /// Whether **this** channel runs at the given address.
    ///
    /// **Not `streamURL == url`, and that is the reason for two failures.** Since
    /// the silent fallback to the raw stream (``RawStreamMemory``), the
    /// address the player receives is no longer necessarily the one in the
    /// channel list: `…/1234.m3u8` becomes `…/1234.ts`. Whoever compares the two
    /// does not find the running channel again — and with that, both features in the player that need it
    /// failed: the program overlay did not know
    /// whose program to show (it sat on "loading", without ever
    /// asking), and Up/Down found no neighbor, because the starting point
    /// was unknown (viewer finding 2026-08-08).
    ///
    /// So the address is compared **without extension** — but only if both
    /// extensions belong to exactly this switch. A channel must not
    /// count as another one just because the same path happens to exist with a
    /// third extension.
    public func plays(_ url: URL) -> Bool {
        if streamURL == url { return true }

        let swappable: Set<String> = ["m3u8", "ts"]
        guard swappable.contains(streamURL.pathExtension.lowercased()),
            swappable.contains(url.pathExtension.lowercased())
        else { return false }

        return streamURL.deletingPathExtension() == url.deletingPathExtension()
    }
}

/// An entry of the program guide.
public struct Programme: Sendable, Equatable, Identifiable {
    public let id: String
    public let channelID: String
    public let title: String
    public var description: String?
    public let start: Date
    public let end: Date

    public init(
        id: String,
        channelID: String,
        title: String,
        start: Date,
        end: Date,
        description: String? = nil
    ) {
        self.id = id
        self.channelID = channelID
        self.title = title
        self.start = start
        self.end = end
        self.description = description
    }

    public func isRunning(at date: Date) -> Bool {
        date >= start && date < end
    }
}

/// A stored channel list.
public struct Playlist: Sendable, Equatable, Identifiable {

    public enum Kind: Sendable, Equatable {
        /// An M3U file, local or via an address.
        case m3u(URL)
        /// An account using the Xtream scheme. Unlike the
        /// M3U file, it also delivers genres and the program guide in structured form.
        case xtream(server: URL, username: String)
        /// The server's own channel management.
        case jellyfinLiveTV
    }

    public let id: String
    public var name: String
    public var kind: Kind
    public var isEnabled: Bool
    public var epgURL: URL?

    /// The key that this list's type yields — see ``ListKey``.
    ///
    /// **Alongside ``id`` and not instead of it**, because the two answer different questions:
    /// ``id`` says which entry in this store is meant, ``key`` says
    /// which list it *is*. For everything entered from AP42 on, the two are
    /// equal; for legacy data ``id`` is a random number until the re-keying
    /// has run, and during a provider move they diverge
    /// for the duration of the move. Exactly these two cases could not be seen with a single field.
    public var key: String { ListKey.forItem(kind) }

    /// - Parameter id: Without a value, the computed key. **A default and not a
    ///   requirement**, because two callers bring an identifier with them: the store when
    ///   reading in, and the takeover from the phone. Both enter something that already exists.
    public init(
        id: String? = nil,
        name: String,
        kind: Kind,
        isEnabled: Bool = true,
        epgURL: URL? = nil
    ) {
        self.id = id ?? ListKey.forItem(kind)
        self.name = name
        self.kind = kind
        self.isEnabled = isEnabled
        self.epgURL = epgURL
    }
}

/// Where channels come from.
///
/// Deliberately separate from ``ContentSource``: a media library knows titles and
/// progress, a channel list knows channels and broadcast times. A shared
/// contract for both would leave half-empty bodies everywhere.
public protocol ChannelSource: Sendable {
    var playlist: Playlist { get }
    func channels() async throws -> [Channel]
    func programmes(for channelID: String, around date: Date) async throws -> [Programme]
}
