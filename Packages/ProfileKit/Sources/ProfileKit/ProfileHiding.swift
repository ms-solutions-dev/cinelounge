import Core
import Foundation

/// A note **only for this device**: "do not show this profile here" (product requirement
/// from the on-device test of build 1332, 2026-09-27).
///
/// **The difference from ``ProfileTombstone``:** a tombstone tells all devices of the same
/// Apple ID that the profile has disappeared on purpose, and therefore also lies in the
/// household zone. "Remove from this device" means the opposite: the profile lives on in
/// iCloud and on the other devices, **only here** it should no longer appear.
/// Without this note ``ProfileCloud/find(now:)`` would read the zone at the next start as
/// "a profile from another device" and silently put it back into the book.
///
/// **On the device and never in the cloud** — if it traveled along, the profile would disappear on the
/// TV too, which nobody asked. It is lifted only explicitly, via "add existing
/// profiles" (``ProfileCloud/restore(_:now:)``) or a sharing link.
public enum ProfileHiding {

    /// Where the notes lie — in the book store next to the profile book.
    public static let key = "profiles.hiddenHere"

    /// The hidden identifiers, normalized like ``ProfileTombstone/norm(_:)``.
    public static func all(from store: any KeyValueStore) -> Set<String> {
        guard let text = try? store.value(for: key),
            let raw = text.data(using: .utf8),
            let identifiers = try? JSONDecoder().decode([String].self, from: raw)
        else { return [] }
        return Set(identifiers)
    }

    /// Whether this profile is hidden here.
    public static func contains(_ identifier: Profile.Identifier, in store: any KeyValueStore) -> Bool {
        all(from: store).contains(ProfileTombstone.norm(identifier))
    }

    /// Hides a profile on this device.
    public static func create(_ identifier: Profile.Identifier, in store: any KeyValueStore) {
        var identifiers = all(from: store)
        guard identifiers.insert(ProfileTombstone.norm(identifier)).inserted else { return }
        write(identifiers, in: store)
    }

    /// Takes the note back — the profile may appear here again.
    public static func lift(_ identifier: Profile.Identifier, in store: any KeyValueStore) {
        var identifiers = all(from: store)
        guard identifiers.remove(ProfileTombstone.norm(identifier)) != nil else { return }
        write(identifiers, in: store)
    }

    private static func write(_ identifiers: Set<String>, in store: any KeyValueStore) {
        guard !identifiers.isEmpty else {
            try? store.remove(key)
            return
        }
        guard let raw = try? JSONEncoder().encode(identifiers.sorted()),
            let text = String(data: raw, encoding: .utf8)
        else { return }
        try? store.set(text, for: key)
    }
}
