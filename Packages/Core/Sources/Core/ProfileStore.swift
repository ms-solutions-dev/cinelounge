import Foundation

/// A store that **belongs to one person** and falls back to the device's.
///
/// **Product decision 4 of 2026-09-24:** audio preference and subtitles move with the
/// profile; engine, picture output and diagnostics stay with the device. Until here
/// ``AudioPreference`` and ``SubtitleStyle`` lay under one key per device in the
/// Keychain — whoever set original audio on the living-room TV set it for
/// everyone who signed in afterwards.
///
/// **The pattern is that of the age limit** (`ParentalControls/ProfileSlot`): the same
/// key with the profile identifier at the end, in the **same** store. That is closer to the
/// catalog than the route of the shelf order (`ProfileKit/ProfileShelves`), for two
/// reasons: the values are already key-value pairs in the Keychain, a separate file
/// per profile would be a move instead of an extension; and the shelf order is
/// **copied** on first start, which would be wrong here — a copy of the device value into every profile
/// would look like a deliberate choice of every person and would go into the cloud as such.
///
/// **Hence a fallback instead of a takeover.** As long as a profile has no value of its own,
/// the device's applies — nobody loses their setting on update, and only
/// what a person has set themselves goes into the cloud (``own()``).
///
/// **A key that is in the profile compartment applies — even if empty.** An empty audio preference
/// means "as the file prescribes" and is a choice; if it fell back to the device,
/// nobody could choose "Automatic" as long as the device says "German".
///
/// **A value and not a pointer.** The identifier is fixed at construction; whoever needs the store
/// of the currently active profile asks ``active(_:)`` or ``playback`` at the
/// moment of reading. The switch updates ``ProfilePointer``, and the next question
/// hits the new person.
public struct ProfileStore: KeyValueStore {

    /// The device's store — in the program, the Keychain.
    public let device: any KeyValueStore

    /// Whose compartment. `nil` is the device itself: before the first setup, in the
    /// preview, and everywhere nobody has chosen yet.
    public let profile: String?

    /// **No default for `forItem:`.** Whoever means "no profile" here should write it down —
    /// an omitted argument that silently means the device is exactly the mistake
    /// this store is meant to fix.
    public init(_ device: any KeyValueStore, forItem profile: String?) {
        self.device = device
        self.profile = (profile?.isEmpty ?? true) ? nil : profile
    }

    /// The store of the person currently watching.
    public static func active(_ device: any KeyValueStore) -> ProfileStore {
        ProfileStore(device, forItem: ProfilePointer.active)
    }

    /// The playback preferences of the person currently watching — **the one route for every
    /// read and write site in the program.**
    ///
    /// A named access instead of `active(SecureStore())` at every site, so that a
    /// check can find the readers: whoever in the player queries `SecureStore()` directly
    /// again reads the device instead of the person, and in the source that looks like
    /// any other line. `FeaturesTests/Wiedergabevorzug` looks for exactly that.
    public static var playback: ProfileStore { active(SecureStore()) }

    /// The key in this profile's compartment — dot as separator, identifier at the end, as with
    /// the age limit. A profile identifier is a `UUID` text and carries no dot.
    public static func bucket(_ basis: String, forItem profile: String?) -> String {
        guard let profile, !profile.isEmpty else { return basis }
        return basis + "." + profile
    }

    // MARK: - KeyValueStore

    /// First the person's compartment, then the device.
    public func value(for key: String) throws -> String {
        if let profile, let own = try? device.value(for: Self.bucket(key, forItem: profile)) {
            return own
        }
        // **A fresh profile inherits nothing from the device** (product decision, 2026-09-28: a new
        // profile is new, it has to be set up anew). The fallback is for the profiles that
        // existed before a setting was moved — they keep what the device had.
        if let profile, Self.isFresh(profile, in: device) { throw Empty() }
        return try device.value(for: key)
    }

    /// No value of its own, and the profile inherits none.
    public struct Empty: Error {}

    /// The mark "created after the move".
    static let freshKey = "profil.frisch"

    /// Marks a just-created profile: it starts with basic settings instead of with
    /// the device's. If it then takes over values (from the phone, from iCloud), they sit in
    /// its compartment and count like any choice of its own.
    public static func markFresh(_ profile: String, in device: any KeyValueStore) {
        try? device.set("1", for: bucket(freshKey, forItem: profile))
    }

    public static func isFresh(_ profile: String, in device: any KeyValueStore) -> Bool {
        (try? device.value(for: bucket(freshKey, forItem: profile))) == "1"
    }

    /// Writing goes **only** into the person's compartment. Touching the device value would mean changing the
    /// setting of everyone else along with it — exactly what should stop here.
    public func set(_ value: String, for key: String) throws {
        try device.set(value, for: Self.bucket(key, forItem: profile))
    }

    /// Removes the person's value — **afterwards the device's applies again.**
    ///
    /// That is not "off": whoever wants to switch a switch off has to write that as a value
    /// (see ``SubtitleStyle/setPrefersPlainSubtitles(_:in:)``), otherwise the switched-on
    /// device value would show through again.
    public func remove(_ key: String) throws {
        try device.remove(Self.bucket(key, forItem: profile))
    }

    // MARK: - Was mitwandert

    /// The keys that move with the profile — **audio preference, subtitles and language.**
    ///
    /// The list lives here and not with ``ProfileKit``, because the keys hang `internal` on
    /// their types; a reconciliation that spelled them out itself would, on the
    /// next rename, write to a place nobody reads anymore.
    ///
    /// **The engine is deliberately not included** (`playback.enginePreference`), nor is
    /// the quality level: both depend on line and device. The ASS choice
    /// (`plainSubtitles`) is included although it influences the engine choice — it is a
    /// question of how someone wants to read subtitles, and in the UI it sits with them.
    /// That this list is complete is checked by `ProfileStoreTests`: every key that
    /// the two types write when saving must appear here.
    ///
    /// **Since 2026-09-25 the app language is included** (``AppLanguageSetting/key``,
    /// decision 4). The name of the list stays because the phone reads it; what is meant is
    /// "what moves with the person". Unlike the playback preferences, the language
    /// does not fall back to the device's Keychain but to `UserDefaults` — that is
    /// handled by ``AppLanguageSetting/read(profile:keychain:device:)``; here it is only about what
    /// the person chose themselves, and that lies in their compartment.
    public static let playbackKeys: [String] = [
        AudioPreference.languageKey,
        AudioPreference.animeKey,
        SubtitleMode.key,
        SubtitleStyle.sizeKey,
        SubtitleStyle.colorKey,
        SubtitleStyle.assKey,
        AppLanguageSetting.key,
        // **Since 2026-09-28: what makes up a profile** (product decision: everything that makes up a profile
        // belongs in the profile) — design/geraet-oder-profil-2026-09-28.md.
        LivePreferences.browseKey,
        LivePreferences.previewKey,
        LivePreferences.adultKey,
        LivePreferences.groupsKey,
        LivePreferences.orderKey,
        TrailerPreferences.autostartKey,
        TrailerPreferences.dwellKey,
        HeroPreferences.storageKey,
        SportFilterSettings.key,
        TopShelfBridge.modeKey,
        // **Since 2026-11-09: the binge package** (AP85) — per person, like the audio preference.
        BingePreferences.introKey,
        BingePreferences.spoilerKey,
        BingePreferences.stillWatchingKey,
    ]

    /// What the person has set **themselves** — without the fallback to the device.
    ///
    /// That is what belongs in the cloud. Sending the device value along would mean that the
    /// first device that syncs forces its setting on every person on every other device
    /// — with the timestamp *now*, against which nothing wins.
    public func own() -> [String: String] {
        guard let profile else { return [:] }
        var values: [String: String] = [:]
        for key in Self.playbackKeys {
            if let value = try? device.value(for: Self.bucket(key, forItem: profile)) {
                values[key] = value
            }
        }
        return values
    }

    /// Clears the person's compartment — **when the person no longer exists on this device.**
    ///
    /// Without this step up to six entries per removed profile would stay in the
    /// Keychain that nobody reads anymore. This is not a "back to the device"
    /// for a person who still exists; that choice is a design question and stands
    /// as an open line in the roadmap.
    public func forget() {
        guard let profile else { return }
        for key in Self.playbackKeys + [Self.freshKey] + DeviceTrait.allKeys {
            try? device.remove(Self.bucket(key, forItem: profile))
        }
    }

    /// Puts arrived values into the person's compartment.
    ///
    /// **Known keys only.** What a newer version sends along does not end up as a
    /// foreign entry in the Keychain, where nobody reads it and nobody cleans it up.
    ///
    /// - Returns: whether anything changed.
    @discardableResult
    public func adopt(_ values: [String: String]) -> Bool {
        guard let profile else { return false }
        var changed = false
        for key in Self.playbackKeys {
            guard let value = values[key] else { continue }
            let bucket = Self.bucket(key, forItem: profile)
            if (try? device.value(for: bucket)) == value { continue }
            try? device.set(value, for: bucket)
            changed = true
        }
        return changed
    }
}
