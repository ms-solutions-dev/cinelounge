import Foundation

/// What takes up how much — **one view, two doors.**
///
/// **Two designers had independently each built a storage screen**, with the same
/// six entries and different numbers: 1.4 GB against 17.9 GB for the same phone. One
/// did not know the downloads, the other did not know the settings. Whoever found the first
/// read "CineLounge uses 1.4 GB", cleaned up elsewhere — and next to it lay 14.8 GB of films.
///
/// **There is therefore exactly one budget**, and the question "where did I come from?" is
/// answered by the way back and not by a second calculation.
public struct StorageBudget: Sendable, Hashable {

    public var items: [LineItem]
    /// What is free on the device — **not what the app would still be allowed to use.**
    public var unrestricted: Int64

    public init(items: [LineItem], unrestricted: Int64) {
        self.items = items
        self.unrestricted = unrestricted
    }

    public var taken: Int64 { items.reduce(0) { $0 + $1.bytes } }

    public var downloads: Int64 { items.first { $0.kind == .downloads }?.bytes ?? 0 }

    /// What a "clean up" would free.
    public var reclaimable: Int64 { items.filter { !$0.remains }.reduce(0) { $0 + $1.bytes } }

    /// Whether a download job of this size still fits.
    ///
    /// **With a reserve, and it is not arbitrary.** iOS gets unpleasant from a few hundred
    /// megabytes of free space — it then cleans up by itself, and what it takes first is
    /// everything that looks like cache. A download store that fills the device down to the
    /// last remainder endangers itself.
    public static let reserve: Int64 = 2 * 1024 * 1024 * 1024

    public func matches(_ bytes: Int64) -> Bool {
        bytes + Self.reserve <= unrestricted
    }
}
