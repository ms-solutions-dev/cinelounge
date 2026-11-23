import Core
import Foundation

/// What there is to say about a channel row **besides the programme**.
///
/// **The most important case is the most frequent, and it looks the least like an error:**
/// Of 5.389 channels in the provider list, 610 carry a programme — the other 4.779 do not.
/// That is the normal case and not the exception. A row that stays empty then looks as if
/// the app were stuck; a row with a spinner looks as if something were still coming. It is
/// therefore written out in words.
public enum SpecialCase: Sendable, Equatable {

    /// The channel offers a look back — up to three days.
    ///
    /// **A niche on the TV, the actual purpose on the phone.** 51 of the 5.389 channels can do
    /// this; "yesterday's Tagesfunke on the train" is the sentence that stands next to it in
    /// the draft.
    case archive(days: Int)

    /// The one permitted connection is running elsewhere.
    ///
    /// **The row says so before you press** — instead of offering a "second try" button
    /// afterwards. With two devices in the household this is not an edge case but a permanent
    /// state.
    ///
    /// - Note: How the app **knows** this is delivered by AP28: Without the second screen
    ///   there is no information about what is playing on the TV. The provider does not
    ///   report it, and the media server knows nothing of a provider connection. Until then
    ///   this case is built and never set — explicitly, so the row does not have to be
    ///   rebuilt later.
    case taken

    /// No programme stored.
    case withoutGuide
}

extension SpecialCase {

    /// Which special cases this row carries.
    ///
    /// Several at once are possible and do occur: An archive channel without a programme is
    /// no contradiction — look back is a capability of the channel, the programme an
    /// information from the schedule.
    public static func forItem(
        _ channels: Channel, program: ProgramState, taken: Bool = false
    ) -> [SpecialCase] {
        var found: [SpecialCase] = []
        if taken { found.append(.taken) }
        if let days = channels.archiveDays, days > 0 { found.append(.archive(days: days)) }
        // **`.pending` does not count.** "Not asked yet" is not information about the channel but
        // about us — and that is none of the viewer's business.
        if program == .none { found.append(.withoutGuide) }
        return found
    }
}
