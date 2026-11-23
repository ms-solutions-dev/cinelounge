import Foundation

/// The device token — **the only thing the app keeps from a sign-in.**
///
/// **The difference from the bridge, in one sentence (2026-09-12):** The portal bridge knew
/// no people; every device on the network saw everything. The CineLounge server knows people,
/// roles and devices, and both ways in — profile plus PIN on the phone, pairing code
/// on the TV — end with the same result: a string that from then on is attached to every
/// request.
///
/// **In the Keychain and not in the default store.** That is not a habit
/// but the point itself: The token is **full access to a household** and
/// does not expire on its own. An address is a hostname and not a secret;
/// this one is a secret.
///
/// **No expiry, and therefore a sign-out path.** Because the server does not let the token
/// expire, `POST /logout` is the only place where it becomes invalid —
/// deleting it on the device alone leaves it standing on the server.
public enum DeviceTrait {

    /// The store key. The same spelling in both apps, so that both talk about
    /// the same thing under the same name — as with ``BridgeAddress``.
    public static let storageKey = "setup.deviceToken"

    /// The borrowed profile of a device that belongs to no person.
    ///
    /// **Only on the TV, and deliberately next to the token instead of inside it.** The token
    /// says which device is asking; the profile says who is sitting in front of it. Anyone who put both into one
    /// value would have to rewrite it at every profile switch — and a
    /// profile switch is the normal case on the TV, not the exception.
    public static let profileKey = "setup.deviceProfile"

    /// Whether this device **belongs to a person** — set when it came in through a share, a
    /// person token or a sign-in with a person (AP47).
    ///
    /// **Why a separate flag:** ``ProfileKit/ProfileSwitch`` writes the profile's server person
    /// as ``profileKey`` on a switch — that is correct on the shared living-room TV.
    /// On a device that belongs to a person, the same header turns the
    /// sign-in into a loan (``PortalKit/SignInState`` computes `isBorrowed = profile != nil`),
    /// and the share page and sign-out disappear. **The flag says "own" and not
    /// "shared", so that no migration is needed:** Every already paired TV does not
    /// have it and behaves as before; only what comes in through a person from now on
    /// sets it.
    public static let ownKey = "setup.deviceOwned"

    /// All three keys — for cleaning up a profile and for moving off the device.
    public static let allKeys = [storageKey, profileKey, ownKey]

    /// **The token belongs to the profile, not to the device** (product decision, 2026-09-28: each
    /// profile should have exactly its own signed-in-as and its own progress).
    ///
    /// **The finding:** A TV that was paired with a person answers at the
    /// server for every profile as that person — the server takes the person from the
    /// token and ignores the profile header (`web/access.py`, `current_person`). When the
    /// token lived in the device, every new profile showed "signed in as" the paired person, and everything
    /// watched landed in that person's state.
    ///
    /// Now it lives in the compartment of the active profile (``ProfileStore``): A fresh profile
    /// has none and has to pair or request one itself, and at the server every
    /// profile appears as its own device. It does not go to the cloud — a token is a key
    /// of this device, not a value of the person. Anyone who already passes a ``ProfileStore`` means
    /// a specific profile, and gets exactly that one.
    static func bucket(_ store: any KeyValueStore) -> ProfileStore {
        (store as? ProfileStore) ?? ProfileStore.active(store)
    }

    /// Reads **only** from the profile's compartment — without the fallback to the device that
    /// ``ProfileStore`` has for older profiles. For a setting it is right; for the
    /// token it would be the finding itself: Every older profile would appear as the device's
    /// person. What still lies in the device is moved into the right profile by `TraitMigration`.
    static func read(_ key: String, in playlistStore: any KeyValueStore) -> String? {
        let storeRef = bucket(playlistStore)
        guard let profile = storeRef.profile else { return try? storeRef.device.value(for: key) }
        return try? storeRef.device.value(for: ProfileStore.bucket(key, forItem: profile))
    }

    /// Whether this device belongs to a person — see ``ownKey``.
    public static func own(in store: any KeyValueStore) -> Bool {
        read(ownKey, in: store) == "1"
    }

    /// Records whether the device belongs to a person. `false` withdraws the flag.
    public static func saveOwn(_ own: Bool, to store: any KeyValueStore) {
        if own {
            try? bucket(store).set("1", for: ownKey)
        } else {
            try? bucket(store).remove(ownKey)
        }
    }

    /// The stored token, or `nil` for "not signed in".
    public static func load(from store: any KeyValueStore) -> String? {
        guard let value = read(storageKey, in: store), !value.isEmpty else { return nil }
        return value
    }

    /// The stored profile, or `nil` — also when the device belongs to a person.
    public static func profile(from store: any KeyValueStore) -> String? {
        guard let value = read(profileKey, in: store), !value.isEmpty else { return nil }
        return value
    }

    /// Stores a token. An empty value withdraws it.
    public static func save(_ trait: String, to store: any KeyValueStore) {
        let clean = trait.trimmingCharacters(in: .whitespacesAndNewlines)
        if clean.isEmpty {
            try? bucket(store).remove(storageKey)
        } else {
            try? bucket(store).set(clean, for: storageKey)
        }
    }

    /// Stores the chosen profile. An empty value withdraws it.
    public static func saveProfile(_ profile: String?, to store: any KeyValueStore) {
        let clean = (profile ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if clean.isEmpty {
            try? bucket(store).remove(profileKey)
        } else {
            try? bucket(store).set(clean, for: profileKey)
        }
    }

    /// Throws away token and profile.
    ///
    /// **This is the second half of a sign-out, never the whole of it.** First `POST
    /// /logout`, so that the token also expires at the server; only then delete here.
    /// The other way around, a valid token would remain in the world that nobody can
    /// revoke any more, because nobody knows it any more.
    public static func forget(in store: any KeyValueStore) {
        try? bucket(store).remove(storageKey)
        try? bucket(store).remove(profileKey)
        try? bucket(store).remove(ownKey)
    }

    /// Is this device signed in?
    public static func signedIn(in store: any KeyValueStore) -> Bool {
        load(from: store) != nil
    }
}
