import Foundation

/// The one device ID by which the server recognizes this TV.
///
/// **One source, and it persists.** Before, there were two places that each wanted to create the same
/// ID: sign-in read it from the defaults and
/// created it if needed; app launch read it too, but created **nothing** —
/// it rolled a fresh one on every run. On first launch that meant
/// two IDs side by side: the server listed the TV twice, and the
/// playback session hung on a device that sign-in never saw.
///
/// Hence a single path for both: read, otherwise create **and store**.
/// Whoever asks first creates it; whoever asks afterwards gets the same one.
public enum DeviceIdentity {

    static let storageKey = "device.id"

    /// Returns the stored ID — or creates one and stores it.
    public static func id(in defaults: UserDefaults = .standard) -> String {
        if let existing = defaults.string(forKey: storageKey) { return existing }
        let fresh = UUID().uuidString
        defaults.set(fresh, forKey: storageKey)
        return fresh
    }

    /// Adopts an ID that was stored under a **different** name.
    ///
    /// **What for** (AP40, 2026-09-20): The phone kept the same ID under
    /// `app.deviceID`. Simply switching over to this building block there finds nothing,
    /// rolls a fresh one — and **the media server sees a new device**. It keeps
    /// sessions per device; the old sign-in remains as a device that never
    /// appears again, and the running playback hangs on an ID that nobody
    /// knows. This is exactly what the header of this file warns against — only for the case "two
    /// places in one app", not for "two names over time".
    ///
    /// **The name belongs to the caller.** This building block serves three programs; which
    /// old key lay where is known only to the program that had it. What lives here is
    /// the rule: **adopt as long as nothing is stored under the new name** — and
    /// never overwrite, because an ID that has already been issued is known to the server
    /// already.
    ///
    /// - Returns: `true` if something was actually adopted — for the test and
    ///   for a line in the diagnostics.
    @discardableResult
    public static func adopt(
        from oldKey: String, in defaults: UserDefaults = .standard
    ) -> Bool {
        guard defaults.string(forKey: storageKey) == nil,
            let old = defaults.string(forKey: oldKey), !old.isEmpty
        else { return false }

        defaults.set(old, forKey: storageKey)
        return true
    }
}
