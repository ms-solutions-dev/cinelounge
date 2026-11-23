import Core
import Foundation

/// **What a press on a programme plays — the recording or the channel** (decision
/// 27, A2, 2026-09-26).
///
/// **Until then only the TV could do this**, in the programme grid; on the phone a
/// catch-up channel had only the symbol and "X days archive", and the daily programme always played
/// the channel. Now grid and daily programme ask the same rule:
///
/// - **In the archive** (``Core/Catchup/isInArchive(_:start:now:)``: the channel carries
///   archive days, the programme has begun and does not lie further back) — the
///   recording from its start. This also applies to the **running** programme: Whoever taps it in the
///   programme instead of the channel wants it from the beginning.
/// - **Otherwise the channel itself.** A future entry thus leads to the running
///   programme — more honest than a press that does nothing.
///
/// **A gap in the grid** is no programme and always plays the channel.
public nonisolated enum CatchUpSelection {

    /// The recording's address — `nil` means: play the channel.
    public static func recording(
        channels: Channel, start: Date, end: Date, isGap: Bool = false, now: Date
    ) -> URL? {
        guard !isGap, Catchup.isInArchive(channels, start: start, now: now) else {
            return nil
        }
        let minutes = Int((end.timeIntervalSince(start) / 60).rounded())
        return Catchup.address(fromLive: channels.streamURL, start: start, minutes: minutes)
    }

    /// The same over a channel's feeds — **the first that yields a recording.** With the
    /// provider, often only one of the versions carries an archive.
    public static func recording(
        feeds: [Channel], start: Date, end: Date, now: Date
    ) -> (channels: Channel, address: URL)? {
        for channels in feeds {
            if let address = recording(channels: channels, start: start, end: end, now: now) {
                return (channels, address)
            }
        }
        return nil
    }

    /// Whether a **past** programme is still in the archive — the rows that the
    /// daily programme shows before the running one.
    public static func catchUpAvailable(feeds: [Channel], broadcast: Programme, now: Date) -> Bool {
        broadcast.end <= now
            && recording(
                feeds: feeds, start: broadcast.start, end: broadcast.end, now: now)
                != nil
    }
}
