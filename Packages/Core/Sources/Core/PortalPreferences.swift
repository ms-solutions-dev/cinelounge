import Foundation

/// Which portals count in the **shared** shelves — and which stay on their own.
///
/// **Since decision 27 (C12) in `Core` and on both devices** — until 2026-09-26 the
/// type lived in the phone package, and the TV did not know the switch. Both read the same
/// row in the Keychain (`portals.ownArea`).
///
/// **The finding of 2026-09-07, from the client:** a portal was set inactive
/// again, but watched content still appears under Continue Watching — followed by the
/// question whether portals can be kept out of "Continue Watching" and the favorites at all.
///
/// **Two different things, and both deserve an answer:**
///
/// * **A switched-off portal drops out**, without anybody setting anything. That is
///   not a preference but the same rule that ``History/validOnes(at:portals:now:)``
///   applies to every source: a tile that leads to an error message is
///   worse than no tile. Until then it checked the origin ``Catalog/Origin``
///   as a whole — as long as **any** portal answered, every portal entry counted.
/// * **Keeping a running portal to itself** is a preference, and this type exists
///   for that. Whoever has a portal that should not sit on Home next to the children's
///   movies takes it out here; in the Portals tab it stays fully usable
///   and keeps its **own** history and its own favorites there.
///
/// **What is stored is what deviates** — empty means "all count". The same rule as
/// with ``StartPreferences`` and `LivePreferences.hiddenGroups`, and for the same reason:
/// if a portal is added on the bridge, it is included without any action. With an allow list
/// it would be silently invisible, and you would look for the error in the app.
public nonisolated struct PortalPreferences: Sendable, Equatable {

    /// Portals that do **not** appear in Home and favorites. Empty means: all.
    ///
    /// The portal name as the bridge carries it (`PortalInfo.id`) — and at the same time the
    /// first field of every portal identifier, see ``portal(zu:)``.
    public private(set) var ownSection: Set<String>

    public static let preset = PortalPreferences()

    public init(ownSection: Set<String> = []) {
        self.ownSection = ownSection
    }

    // MARK: - Fragen

    /// Whether this portal counts in the shared shelves.
    public func countsTogether(_ portal: String) -> Bool {
        !ownSection.contains(portal)
    }

    /// Which portal a title identifier belongs to — `nil` if it is not a portal identifier.
    ///
    /// **The portal name is in every identifier, and at the front.** A portal identifier is
    /// `portal|key|address` (`PortalItemID`); so no second store is needed
    /// to remember where a history entry came from. It is read via ``Origin``, which knows
    /// the shape of the identifier anyway — `Core` does not see `PortalKit`.
    public static func portal(zu identifier: String) -> String? {
        Origin.portal(fromIdentifier: identifier)
    }

    /// Whether a title may appear in Home and favorites — **an identifier without a
    /// readable portal stays**, the same rule as in the phone's history.
    public func accepts(identifier: String) -> Bool {
        Self.portal(zu: identifier).map(countsTogether) ?? true
    }

    // MARK: - Ändern

    public mutating func countTogether(_ portal: String, _ on: Bool) {
        if on { ownSection.remove(portal) } else { ownSection.insert(portal) }
    }

    // MARK: - Ablage

    private static let key = "portals.ownArea"

    /// **A separator that occurs in no portal name** — the same choice and
    /// the same reasoning as in ``StartPreferences``.
    private static let separator = "\n"

    public static func load(from store: any KeyValueStore) -> PortalPreferences {
        guard let raw = try? store.value(for: key), !raw.isEmpty else {
            return PortalPreferences()
        }
        return PortalPreferences(
            ownSection: Set(raw.components(separatedBy: separator).filter { !$0.isEmpty }))
    }

    public func save(to store: any KeyValueStore) {
        // **Empty means "nothing remembered" and is deleted.** Reading an empty string
        // back would yield a set with one empty entry.
        if ownSection.isEmpty {
            try? store.remove(Self.key)
        } else {
            try? store.set(
                ownSection.sorted().joined(separator: Self.separator), for: Self.key)
        }
    }
}

/// **Portals on or off — on the TV** (decision 27, C12).
///
/// The phone has had the same switch in its setup since AP21
/// (`SetupState.portalsWanted`, per profile via `ProfileKit.wantsPortals`). The
/// TV did not know it: portals were on as soon as a bridge was entered. Here
/// it is a single row in the device's Keychain — **only "off" is stored**, a
/// missing row means "on", as before.
public nonisolated enum PortalSwitch {

    static let key = "portals.offOnDevice"

    /// The key of the active profile.
    ///
    /// **Per profile and not per device** (product decision, 2026-09-28: visibilities are
    /// profile-dependent): until then one profile switched the CL-Server off for everyone watching on
    /// this TV. Without an active profile the old device key applies.
    static func key(forItem profile: String?) -> String {
        profile.map { key + "." + $0 } ?? key
    }

    /// Whether the CL-Server is on for the active profile. If the profile has never chosen,
    /// the device's earlier choice applies — so nobody loses their setting on update.
    public static func on(in store: any KeyValueStore, profile: String? = ProfilePointer.active) -> Bool {
        if let own = try? store.value(for: key(forItem: profile)) { return own != "aus" }
        return (try? store.value(for: key)) != "aus"
    }

    public static func set(
        _ enabled: Bool, in store: any KeyValueStore, profile: String? = ProfilePointer.active
    ) {
        try? store.set(enabled ? "an" : "aus", for: key(forItem: profile))
    }
}
