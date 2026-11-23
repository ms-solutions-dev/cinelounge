import Foundation

/// The name of a channel, split into name and quality mark.
///
/// **Since 2026-09-26 in `Core` and no longer on the phone** (decision 21): The name is what
/// the live-shelf selection stores on both devices, and two computations for it would sooner
/// or later diverge.
///
/// **Split and not deleted.** `ChannelName.display` explicitly folds the decoration instead of
/// throwing it away: `HD`, `UHD`, `4K` tell the viewer which of several feeds of the same
/// channel they choose — with a provider that lists the same channel four times, that is the
/// only distinction. The mark therefore only moves to its place: smaller, framed, behind the
/// name.
///
/// **Only at the end and only known words.** A pattern over the whole string would hit
/// `4K Entertainment` and `HD Austria`, and a channel name would turn into a mark without a
/// channel.
public struct ChannelDisplayName: Sendable, Equatable {
    public let name: String
    public let tag: String?

    /// The words that count as a mark — enumerated, not pattern-matched.
    static let marks: Set<String> = ["SD", "HD", "FHD", "UHD", "4K", "8K", "RAW", "HEVC"]

    public init(_ raw: String) {
        self.init(displayed: ChannelName.display(raw))
    }

    /// From an already folded name — ``Channel/favoriteName`` is exactly that.
    ///
    /// **So the catalog is not folded twice.** A channel folds its name when it is built; sending
    /// it through ``ChannelName/display(_:)`` once more for every shelf selection would cost, with
    /// 5389 channels, exactly the time that ``Channel`` saves.
    init(displayed: String) {
        var words = displayed.split(separator: " ").map(String.init)
        if let last = words.last, Self.marks.contains(last.uppercased()),
            words.count > 1
        {
            words.removeLast()
            self.name = words.joined(separator: " ")
            self.tag = last.uppercased()
        } else {
            self.name = displayed
            self.tag = nil
        }
    }
}

extension Channel {

    /// The name under which the live-shelf selection lists this channel — **the same on all
    /// devices** (decision 21, 2026-09-26).
    ///
    /// **The name and not the identifier**, because an Xtream identifier changes when the provider
    /// rebuilds its list, and two devices on two providers know two different ones. Until then the
    /// TV stored identifiers in ``ShelfOrder/liveChannel`` and the phone names — a selection that
    /// travelled via handoff or iCloud was meaningless on the other side.
    public var channelName: String { ChannelDisplayName(displayed: favoriteName).name }
}
