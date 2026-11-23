import Core
import Foundation
import PlaylistKit

/// **What is on right now — as a shelf on the Home screen** (AP29, 2026-09-11).
///
/// **The third of the three shelves, and the only one that the ``ShelfRule`` could not
/// dispose of.** A library has a *latest*; a channel list has a **programme**.
/// The shelf answers "is something on that interests me" — for that it needs
/// the programme guide and not `items(in:)`, and that is why it lives here and not in
/// the ``AggregateSource``.
///
/// **Perishable goods, and that is why it stands at the front.** A channel that shows something now
/// is a different one in two hours. Where it stands is still decided by
/// shelf management — whoever does not want it switches it off like any other.
///
/// **From the downloads and without a single fetch.** Channel list and programme lie on
/// disk; the Home screen must not go to the network for them. It is the first screen,
/// and what holds it up holds up the whole app — it has already choked on that twice
/// (2026-08-01 and 2026-08-08). If nothing is stored, the shelf stays absent.
nonisolated enum LiveShelf {

    /// The identifier of the shelf — fixed, so that ``ShelfPreferences`` keeps it.
    static let identifier = ShelfIdentifier.live

    /// This many channels go in — ``Core/LiveShelfChoice/atMost``, the same number as
    /// on the phone.
    static let atMost = LiveShelfChoice.atMost

    /// This many channels get a programme from the downloads — ``Core/LiveShelfChoice/programmeFor``.
    static let programmeFor = LiveShelfChoice.programmeFor

    /// The order in which channels move into the shelf — **the rule lives in
    /// ``Core/LiveShelfChoice/order(from:chosen:recent:)``** (AP58 R5, finding L3) and
    /// applies on the phone in the same way.
    ///
    /// **"Recently watched" is the whole list from ``Flows/ChannelHistory``**, names as
    /// on the phone (Live check, finding 5, decision 25, 2026-09-27). Until then the
    /// TV passed on only the one identifier from ``LiveMemory``: After three channels the
    /// phone had all three at the front, the TV only the last one.
    static func order(
        from channels: [Channel], recent: [String], chosen: [String] = []
    ) -> [Channel] {
        LiveShelfChoice.order(from: channels, chosen: chosen, recent: recent)
    }

    /// A channel with what is currently on it.
    ///
    /// **The channel is the title, the programme the subtitle** — and not the other way round.
    /// Whoever skims the Home screen looks for "is anything there"; what is recognized is the
    /// channel, because that one is familiar. The tile carries both: ``MediaItem/parentTitle`` is
    /// the line that ``EpisodeCard`` sets large.
    ///
    /// **The logo as a finished address.** A channel brings it along; nothing is computed
    /// on it — see ``AggregateSource/imageURL(itemID:kind:width:tag:)``.
    static func tile(_ channel: Channel, isRunning: Programme?) -> MediaItem {
        var frames = Artwork()
        frames.posterID = channel.logoURL?.absoluteString

        return MediaItem(
            id: channel.id,
            // ``MediaItem/Kind/channel`` and no case of its own: It has existed since the
            // favorites, and there a channel appears as a tile for the same reason.
            kind: .channel,
            // Without a programme the channel name stands in both lines — better than an
            // empty subtitle that looks as if something is missing.
            title: isRunning?.title ?? channel.cleanName,
            parentTitle: channel.cleanName,
            artwork: frames)
    }

    /// The shelf — **or none.**
    ///
    /// `nil` if no channel shows anything. **An empty shelf does not appear:** That
    /// a channel list is set up is not news.
    static func shelf(from tiles: [MediaItem]) -> HomeModel.Shelf? {
        guard !tiles.isEmpty else { return nil }
        return HomeModel.Shelf(
            id: identifier,
            titleKey: "home.liveNow",
            items: tiles,
            // **Wide format, and that is not a matter of taste:** A channel has no
            // poster, and on a 2 : 3 tile a logo would stand at the end and
            // **not a word** about what is on — so exactly not the information
            // this shelf exists for. The same finding as on the phone (contradiction W2,
            // 2026-09-06).
            usesWideCards: true,
            libraryKind: .liveTV)
    }

    /// The tiles from downloads and programme — the whole computation in one place.
    ///
    /// - Parameters:
    ///   - sender: What the downloads hold.
    ///   - sichtbar: The settings of the Live section. **The same as there** — otherwise
    ///     channels from groups hidden in the Live section would appear on the Home screen:
    ///     the same app with two opinions about what is visible.
    ///   - programm: The programme from the downloads, per channel identifier.
    /// - Parameter gewaehlt: The channels the viewer has chosen for this shelf.
    ///
    ///   **Two errors lurked here** (2026-09-12, reported on the device: a channel was
    ///   selected as a test and still did not appear on Home):
    ///
    ///   1. This function reordered **itself** and was not passed the choice.
    ///      The caller had long since read it — but only to use it to query the
    ///      programme guide. The selection of channels then fell back to
    ///      "recently watched, then favorites".
    ///   2. **A chosen channel without a running programme dropped out.** For the fallback
    ///      that is right — there the promise is expressly "the recently watched
    ///      ones that *currently show something*". For an explicit choice it is wrong: Whoever
    ///      names a channel wants to see it, and whether a programme is currently
    ///      on file is decided by the provider and not by them. ``tile(_:isRunning:)`` has always
    ///      handled that case (without a programme the channel name stands in both lines).
    static func tiles(
        channels: [Channel],
        isVisible: LivePreferences,
        recent: [String],
        program: [String: [Programme]],
        now: Date,
        chosen: [String] = []
    ) -> [MediaItem] {
        let ordered = order(
            from: isVisible.isVisible(channels), recent: recent, chosen: chosen)
        return LiveShelfChoice.selection(ordered, chosen: chosen) { channel in
            program[channel.id]?.first { $0.isRunning(at: now) }
        }
        .map { tile($0.channels, isRunning: $0.isRunning) }
    }
}
