import Core
import Foundation

/// Where the channels come from — and where the guide does **not**.
///
/// **The difference from the TV is in the second line of this contract.** There
/// `LiveModel` fetches the guide per channel as soon as focus has rested on it for
/// half a second (`LiveModel.dwell`). That works because focus is **one**: at any
/// moment there is exactly one channel being asked about.
///
/// On the phone there is no focus. A list shows twelve rows at once and scrolls
/// past hundreds under the thumb; the same rule would mean hundreds of fetches in
/// seconds. The provider account allows **one** connection, and a connection storm
/// leads to an IP throttle that also blocks the interface and lasts minutes —
/// measured on 2026-08-15. A scrolled-through live directory would thus lock the app
/// out for minutes, and for everything, not just for Live.
///
/// Therefore: **The guide comes from the cache, in one pass for the whole group.**
/// It is fetched fresh only on explicit request — for that there is on the phone
/// `ProgramAge` with its one button.
///
/// **Since 2026-09-26 in `PlaylistKit`** (AP58 R0, report A K3). The contract lived in
/// `FeaturesPhone`; there neither parental controls (`KidsChannelSource`, next after
/// `ParentalControls`) nor a shared Live flow could reach it. It knows only
/// `Core` types, and its implementations talk to the providers of this package.
public protocol ChannelListingSource: Sendable {

    /// All channels the account carries — unfiltered.
    ///
    /// What of that is **visible** is decided by `LivePreferences`; the separation belongs
    /// in the model and not here, so that a changed setting takes effect without a new
    /// fetch.
    func channels() async -> ChannelCatalog

    /// The guide of several channels at once — **from the cache, without network.**
    func program(forItem channels: [Channel]) async -> [String: [Programme]]

    /// Fetch the guide anew. Returns how many programs are in the cache.
    ///
    /// The only path that really goes to the network — and it is pressed, not
    /// triggered.
    func freshProgramme() async -> Int

    /// When the last sync happened and how much came out of it.
    func downloadsState() async -> ProgrammeState

    /// The live sports broadcasts of a time window — **computed, not filtered.**
    ///
    /// Comes from the same source as the channels and therefore sits in the same contract:
    /// it is the same cache from which both are read. Without a fetched guide an
    /// empty list comes back — the area then says the guide has to be fetched
    /// first, and does not claim there is no sport today.
    func sport(from: Date, until: Date) async -> [SportEvent]

    /// Remember a channel as a favorite or undo the remembering.
    ///
    /// **The favorite hangs off the name and not the identifier** — that is the rule of the
    /// shared store (`PlaylistStore.favoriteKey(for:)`), and it has a reason:
    /// an Xtream identifier changes when the provider rebuilds its list, and then all
    /// favorites would be gone. The key **includes** the quality mark: whoever
    /// remembers "KopruHaber HD" does not mean UHD, FHD and HEVC as well.
    func setEnabled(favorite channels: Channel) async -> Bool

    /// Under which address this channel really plays.
    ///
    /// **Not `Channel.streamURL`, and that is the finding of 2026-09-06** The Live area
    /// showed "The one connection is busy" on every channel — with **zero** active
    /// connections. Nothing was busy: `XtreamPayload` builds every channel address as
    /// `.m3u8` with the reasoning *"Every Xtream provider delivers the same channel under
    /// both extensions"*, and the reference provider allows **only `ts`**. To every
    /// `.m3u8` address it answers with **407**.
    ///
    /// **The account is asked, not tried out.** On the TV two memos
    /// (`RawStreamMemory`, `RawStreamRule`) learn the same from failures — eight
    /// seconds of black each and a connection against an account that allows **one**. The
    /// panel says it by itself (`allowed_output_formats`), and a question about it costs
    /// no connection: `player_api.php` is not a stream.
    func address(forItem channels: Channel) async -> URL

    /// The guide of **one** channel over a whole day.
    ///
    /// **A second fetch path, and it is justifiable only for this reason.** ``program(forItem:)``
    /// fetches the guide of the whole list in one pass — right for a list in which
    /// twelve rows stand at once. A day guide, on the other hand, needs **more** than the
    /// current program, and only for the one channel someone has opened.
    /// That is the difference that justifies a path of its own: one per opened
    /// channel instead of one for 7.746.
    func dailyProgramme(forItem channels: Channel) async -> [Programme]

    /// The guide of many channels **in a time window** — per **guide identifier**, as
    /// ``Core/ProgramGrid/rows(channels:programs:from:until:now:)`` expects. For the
    /// program grid on the iPad (decision 27, B10, 2026-09-26).
    func gridProgramme(forItem channels: [Channel], from: Date, until: Date) async -> [String: [Programme]]
}

extension ChannelListingSource {

    /// **Default: the address that sits on the row.** A source without account information
    /// has nothing to correct.
    public func address(forItem channels: Channel) async -> URL { channels.streamURL }

    /// **Default for sources without a favorites store** — the state stays as it was.
    public func setEnabled(favorite channels: Channel) async -> Bool { channels.isFavorite }

    /// **Default: what the list already knows anyway.** A source without its own
    /// day path returns what ``program(forItem:)`` yields for this one channel —
    /// usually the next few hours. Less than a day is better than nothing.
    public func dailyProgramme(forItem channels: Channel) async -> [Programme] {
        await program(forItem: [channels])[channels.id] ?? []
    }

    /// **Default: the guide around now**, rekeyed to the guide identifier. A
    /// source with a cache answers more precisely (``LiveLibrary/storedProgrammes(for:from:to:)``);
    /// a filtered one passes on what its filter lets pass.
    public func gridProgramme(
        forItem channels: [Channel], from: Date, until: Date
    ) async -> [String: [Programme]] {
        let perChannel = await program(forItem: channels)
        var perIdentifier: [String: [Programme]] = [:]
        for channel in channels {
            guard let epg = channel.epgID, !epg.isEmpty, perIdentifier[epg] == nil,
                let list = perChannel[channel.id]
            else { continue }
            perIdentifier[epg] = list.filter { $0.end > from && $0.start < until }
        }
        return perIdentifier
    }
}

/// What a load yields.
///
/// **Lists that did not answer come along instead of being thrown.** With two
/// accounts of which one stalls, you want to see the channels of the other **and** know
/// that one is missing.
public struct ChannelCatalog: Sendable, Equatable {
    public let channels: [Channel]
    public let silent: [String]

    public init(channels: [Channel], silent: [String] = []) {
        self.channels = channels
        self.silent = silent
    }

    public static let empty = ChannelCatalog(channels: [])
}

/// How old the guide is.
public struct ProgrammeState: Sendable, Equatable {
    public let broadcasts: Int
    public let recent: Date?

    public init(broadcasts: Int, recent: Date?) {
        self.broadcasts = broadcasts
        self.recent = recent
    }

    public static let empty = ProgrammeState(broadcasts: 0, recent: nil)
}
