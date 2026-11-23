import Foundation

/// Which color scheme is chosen — **one store for both devices** (AP58 R7, finding E5).
///
/// **The finding:** the TV stored the choice in the Keychain (`Theme.save(to:
/// SecureStore())`), the phone in `UserDefaults` — the same key, two places. The
/// handoff wrote to the Keychain, the phone unpacked from `UserDefaults`. By the
/// README rule ("Where a setting belongs"), a preference is **structure** and belongs
/// in the file store; it is not a secret.
///
/// **The choice belongs to the device, not the person** — as before on both sides.
public enum ColorPattern {

    /// The key — the same on both devices and the same as in `Grundstock.Theme`.
    public static let key = "appearance.theme"

    /// The phone's key until 2026-09-20, now read only for migration.
    public static let oldKey = "app.theme"

    /// The phone's identifiers until 2026-09-20 — stored content and not text.
    private static let oldIdentifiers = [
        "kino": "cinema", "mitternacht": "midnight", "kontrast": "contrast",
    ]

    /// Today's identifier for one from before 2026-09-20. An unknown one comes back
    /// unchanged: it can come from a newer version.
    public static func newIdentifier(forItem old: String) -> String {
        oldIdentifiers[old] ?? old
    }

    /// The chosen identifier — `nil` as long as nobody has chosen.
    public static func chosen(in store: any KeyValueStore = FileStore()) -> String? {
        try? store.value(for: key)
    }

    /// Stores the choice.
    public static func select(_ identifier: String, in store: any KeyValueStore = FileStore()) {
        try? store.set(identifier, for: key)
    }

    /// Brings a choice from **before R7** into the file store — **once**, and clears the old
    /// locations (decision 2: clean cut).
    ///
    /// Reading happens in order of age: the TV's Keychain, the phone's
    /// `UserDefaults` under today's key and under the key from before
    /// 2026-09-20. **A choice already stored wins** — it is the newer one; clearing
    /// happens anyway.
    ///
    /// - Returns: whether anything was migrated.
    @discardableResult
    public static func adoptLegacyCatalog(
        device: UserDefaults, keychain: any KeyValueStore,
        in store: any KeyValueStore = FileStore()
    ) -> Bool {
        let old =
            (try? keychain.value(for: key))
            ?? device.string(forKey: key)
            ?? device.string(forKey: oldKey).map(newIdentifier(forItem:))
        try? keychain.remove(key)
        device.removeObject(forKey: key)
        device.removeObject(forKey: oldKey)
        guard let old, chosen(in: store) == nil else { return false }
        select(old, in: store)
        return true
    }
}
