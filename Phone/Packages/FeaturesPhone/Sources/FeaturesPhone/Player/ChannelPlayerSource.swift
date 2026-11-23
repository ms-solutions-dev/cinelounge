import Core
import Diagnose
import Flows
import Foundation
import Playback
import PlaylistKit

/// The playback of a **channel**.
///
/// **The Live tab had no playback path until 2026-09-06** `LiveView` passed a channel
/// identifier to the player, ``CompositePlayerSource`` did not know it, and the title ended
/// up at the Jellyfin server — which does not carry it. The screen said "No response from
/// the Jellyfin server" over a broadcast that was never at the Jellyfin server.
///
/// **A channel is not a film, and this file is so short because that explains almost
/// everything.** There is no track list from the server (the tracks are in the stream, and
/// the engine finds them itself), no chapters, no length, no progress and no next
/// episode. What there is is an address — and it is already in ``Core/Channel/streamURL``.
///
/// **Nothing to report is a statement here and no omission.**
/// ``notify(location:duration:zu:isPaused:)`` is deliberately empty: A provider account allows
/// **one** connection, and progress reports for something that has no progress would be
/// requests without purpose against exactly that account.
public struct ChannelPlayerSource: PlayerSource {

    private let source: any ChannelListingSource

    public init(source: any ChannelListingSource) {
        self.source = source
    }

    public func target(zu job: PlaybackJob) async throws -> PlaybackRequest {
        let catalog = await source.channels()
        guard let channel = catalog.channels.first(where: { $0.id == job.identifier }) else {
            throw Missing.channels
        }
        if let catchUp = job.catchUp {
            return try recording(from: channel, catchUp)
        }
        Diagnose.step(.playback, "Channel: \(ChannelDisplayName(channel.name).name)")
        // **The address comes from the source and not from the row.** Which extension this access
        // yields only it knows — see ``ChannelListingSource/address(forItem:)``.
        return PlaybackRequest(
            identifier: channel.id,
            title: ChannelDisplayName(channel.name).name,
            beside: channel.group,
            address: await source.address(forItem: channel),
            origin: .channelList,
            // **`.live` and not the default `.recording`.** `isSeekable` and `tracksProgress` in the
            // shared type depend on it: A channel cannot be seeked, and progress over something
            // without an end is a number without meaning.
            kind: .live,
            approval: HistoryClearance())
    }

    /// A past broadcast as a recording (A2) — **by the TV's rule**
    /// (``Flows/CatchUpSelection``): If it is no longer in the archive, there is none.
    ///
    /// **`.recording` and not `.live`:** Its playlist has an end, so it can be seeked like a
    /// film — the same registration as on the TV. It still does not enter the history
    /// (``PlaybackRequest/belongsInHistory``): The tile led via the channel identifier to the
    /// running channel and not to this broadcast.
    private func recording(
        from channel: Channel, _ catchUp: PlaybackJob.CatchUpRequest
    ) throws -> PlaybackRequest {
        guard
            let address = CatchUpSelection.recording(
                channels: channel, start: catchUp.start, end: catchUp.end, now: Date())
        else { throw Missing.recording }
        Diagnose.step(.playback, "Catch-up: \(ChannelDisplayName(channel.name).name)")
        return PlaybackRequest(
            identifier: channel.id,
            title: catchUp.title,
            beside: ChannelDisplayName(channel.name).name,
            address: address,
            origin: .channelList,
            kind: .recording,
            approval: HistoryClearance())
    }

    /// **Empty, and on purpose.** See above.
    public func notify(
        location: TimeInterval, duration: TimeInterval, zu job: PlaybackJob, isPaused: Bool
    ) async throws {}

    /// **A dedicated error.** "This access does not carry this channel" is something different
    /// from "the provider does not respond" — the channel list may be a different one since
    /// the last load.
    enum Missing: Error { case channels, recording }
}

/// **The error knows which state belongs to it** (``DisruptionInterpretation``): This access no
/// longer carries this channel — the list may be a different one since loading.
extension ChannelPlayerSource.Missing: CarriesState {
    nonisolated var state: PlaybackPhase { .xtreamDeliversNothing }
}
