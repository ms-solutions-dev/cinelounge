import Foundation

/// When a paged level fetches its next page — **before** the last tile is in place.
///
/// **"Feels like no waiting"** (AP76, 2026-10-11). Until then TV and phone fetched
/// the next page only when the **last** tile appeared: whoever reached the bottom saw a
/// spinner for as long as the page took. Now the last ``leadTime`` tiles trigger it,
/// on the TV two rows of six, on the phone four rows of three — without knowing the grid width,
/// because counting is done from the end. The server already prefetches the next page for this
/// (`naechste_seite_vorholen`), so the request usually finds it ready. One
/// rule for both devices, so that they do not drift apart; the guard against
/// repeated fetches stays in the model as before.
public nonisolated enum LoadMore {

    /// How many tiles before the end trigger the reload.
    public static let leadTime = 12

    /// Whether the appearance of this tile triggers the reload — it belongs to the last
    /// ``leadTime``. With fewer tiles, every one triggers.
    public static func applies<T: Identifiable>(_ item: T, in items: [T]) -> Bool {
        items.suffix(leadTime).contains { $0.id == item.id }
    }
}
