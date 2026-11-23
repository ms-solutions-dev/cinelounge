import Foundation

/// The ID under which a recalled programme stands in the ``StillLedger``.
///
/// **Why catch-up needs an ID and a film does not.** A film has one: the
/// provider assigns it, and it is in ``PlaylistKit/XtreamVOD/Reference``. A
/// recalled programme has none — it is a channel and a point in time, and the
/// provider knows of it only when it is fetched. Without an ID of its own one
/// could not remember how far one got in it; with one, it is the same as a
/// film for the Standbuch.
///
/// **Built like a title ID** (`<list>#<kind>#…`), so that ``ListMigration``
/// takes it along too: the move rewrites everything that carries the old list
/// ID before the first hash. A form of its own would have left exactly this
/// catalog standing.
///
/// **`catchUp` is no kind from ``PlaylistKit/XtreamVOD/Reference/Role``**,
/// and that is intentional: whoever reads a catch-up ID in there gets `nil`
/// and so the right answer — it is no title of the provider.
public enum StateIdentifier {

    static let kind = "rueckschau"

    /// - Parameters:
    ///   - liste: The list key from ``ListKey``.
    ///   - sender: The channel ID.
    ///   - ab: The start of the programme. **To the exact minute and in GMT** —
    ///     the same format that ``Catchup/stamp(_:in:)`` sends to the
    ///     provider. Two fetches of the same programme thus yield the same ID,
    ///     even across devices in different time zones.
    public static func catchUp(list: String, channels: String, from start: Date) -> String {
        "\(list)#\(kind)#\(channels)#\(stamp(start))"
    }

    /// **Written out here and not taken from ``Catchup``.** The stamp there is
    /// the provider's address format; if it changed, every remembered ID here
    /// would change with it — and the state of all recalled programmes would be
    /// gone. The two look the same today and answer different questions.
    private static func stamp(_ timestamp: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        let split = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: timestamp)
        func two(_ value: Int?) -> String { String(format: "%02d", value ?? 0) }
        return "\(split.year ?? 0)\(two(split.month))\(two(split.day))"
            + "-\(two(split.hour))\(two(split.minute))"
    }
}
