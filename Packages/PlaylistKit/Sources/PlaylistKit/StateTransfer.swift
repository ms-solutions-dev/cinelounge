import Core
import Foundation

/// Brings the state that belonged to the **device** before AP42 into the ``Core/StillLedger``.
///
/// **Three dictionaries that belonged to nobody** (2026-09-19): `vod.memory.v1` (started
/// movies), `live.lastChannel*` (last watched channel per list) and
/// `playlists.favorites.v1` (channel favorites). They lived in the Keychain, the profile switch
/// left them standing, and whoever watched after someone else continued in their place.
///
/// **Into the device's book and not into a person's.** Who sat in front of the TV at the time of
/// the update, nobody knows — there were no profiles yet. The device base is the
/// honest answer: It applies as long as no profile is chosen (see ``Core/ProfilePointer``),
/// and ``ProfileKit/ProfileStates`` passes it to the logged-in profile when the profiles are created.
///
/// **The takeover itself deletes nothing**; clearing is a separate step alongside
/// (``clearLegacyCatalog(listen:from:in:)``, AP48, 2026-09-25), and the caller calls it only
/// once the takeover into the profile is in place. Writing happens only where **nothing is
/// there yet** — a second run must not replace a state that has grown in the meantime with the
/// old one.
///
/// **Without outbox.** What arrives here is not an action of the viewer but a
/// move. Booked as events, hundreds of them would sit in the outbox and go out on the first
/// sync (AP43) as fresh messages — there they would overwrite newer state from another
/// device.
public enum StateTransfer {

    /// - Parameters:
    ///   - listen: The list identifiers. Needed because the last watched channel per list
    ///     lay under a key of its own and a Keychain store cannot be
    ///     browsed.
    ///   - alt: The Keychain with the three dictionaries.
    ///   - buch: Where the Standbuch files live.
    /// - Returns: Whether anything was taken over.
    @discardableResult
    public static func fromDevice(
        listen: [String], from old: any KeyValueStore, in ledger: any KeyValueStore
    ) -> Bool {
        guard StillLedger.read(from: ledger) == StillLedger() else { return false }

        var recording = StateRecording()

        for (identifier, entry) in legacyMovies(from: old) {
            recording.titlePositions[identifier] = entry.asTitleSlot
        }

        for list in [""] + listen {
            let key = list.isEmpty ? "live.lastChannel" : "live.lastChannel.\(list)"
            guard let channel = try? old.value(for: key), !channel.isEmpty else { continue }
            recording.lastChannel[list] = channel
        }

        recording.channelFavorites = legacyFavorites(from: old)

        guard recording != StateRecording() else { return false }
        StillLedger(state: recording).write(in: ledger)
        return true
    }

    /// Clears the three dictionaries — **each only if its content has arrived in the device
    /// base** (AP48, decision 2 of 2026-09-25: clean cut, no
    /// rollback).
    ///
    /// **The proof is a set comparison per key and not "the base is not
    /// empty"** (cross-check strand C, finding 7). ``fromDevice(listen:from:in:)`` writes only
    /// into an **empty** base; if something was already there — a channel favorite, a last
    /// watched channel —, the started movies were never taken over, and the old rule
    /// would have deleted `vod.memory.v1` anyway, because the base was not empty. Now
    /// it holds: every movie of the old dictionary is in the base, every old favorite is
    /// there, the last watched channel per list is the same. Otherwise the key
    /// stays — a "taken over" flag would be a second truth that would be wrong at the first
    /// failure.
    ///
    /// **Only what is readable.** A dictionary that cannot be decrypted was
    /// never taken over and stays: Nothing is deleted that was not taken over.
    ///
    /// The question *whether* clearing is allowed is answered by the caller — on the TV only
    /// once the takeover into the profile is in place.
    ///
    /// - Returns: the cleared keys.
    @discardableResult
    public static func clearLegacyCatalog(
        listen: [String], from old: any KeyValueStore, in ledger: any KeyValueStore
    ) -> [String] {
        let base = StillLedger.read(from: ledger).state
        var cleaned: [String] = []

        if (try? old.value(for: VODMemory.oldKey)) != nil,
            readable([String: LegacyFilm].self, VODMemory.oldKey, from: old),
            Set(legacyMovies(from: old).keys).isSubset(of: base.titlePositions.keys)
        {
            try? old.remove(VODMemory.oldKey)
            cleaned.append(VODMemory.oldKey)
        }
        if (try? old.value(for: PlaylistStore.favoritesKey)) != nil,
            readable([String].self, PlaylistStore.favoritesKey, from: old),
            Set(legacyFavorites(from: old)).isSubset(of: base.channelFavorites)
        {
            try? old.remove(PlaylistStore.favoritesKey)
            cleaned.append(PlaylistStore.favoritesKey)
        }
        for list in [""] + listen {
            let key = list.isEmpty ? "live.lastChannel" : "live.lastChannel.\(list)"
            guard let channel = try? old.value(for: key) else { continue }
            guard channel.isEmpty || base.lastChannel[list] == channel else { continue }
            try? old.remove(key)
            cleaned.append(key)
        }
        return cleaned
    }

    private static func readable<T: Decodable>(
        _ contentType: T.Type, _ key: String, from store: any KeyValueStore
    ) -> Bool {
        guard let json = try? store.value(for: key), let bytes = json.data(using: .utf8)
        else { return false }
        return (try? JSONDecoder().decode(contentType, from: bytes)) != nil
    }

    private static func legacyMovies(from store: any KeyValueStore) -> [String: LegacyFilm] {
        guard let json = try? store.value(for: VODMemory.oldKey),
            let bytes = json.data(using: .utf8),
            let read = try? JSONDecoder().decode([String: LegacyFilm].self, from: bytes)
        else { return [:] }
        return read
    }

    private static func legacyFavorites(from store: any KeyValueStore) -> [String] {
        guard let json = try? store.value(for: PlaylistStore.favoritesKey),
            let bytes = json.data(using: .utf8),
            let read = try? JSONDecoder().decode([String].self, from: bytes)
        else { return [] }
        return read.sorted()
    }

    /// The old format of `vod.memory.v1`.
    ///
    /// **Spelled out here and not taken from ``VODMemory``.** The type there is now
    /// ``Core/StateRecording/TitlePosition`` and carries German field names; this one has to read the
    /// English ones of the old data and must therefore never change again. A
    /// shared type would mean that the next rename in the new store silently makes the
    /// old data unreadable — and that is noticed only on the device that was not yet
    /// updated.
    private struct LegacyFilm: Codable {
        /// Stored keys keep their original (German) names — renaming them would
        /// make data written by earlier versions unreadable (AP85 B4).
        private enum CodingKeys: String, CodingKey {
            case position
            case duration
            case watched
            case favorite
            case title = "titel"
            case kind = "art"
            case image = "bild"
            case recent = "zuletzt"
        }

        var position: TimeInterval?
        var duration: TimeInterval?
        var watched = false
        var favorite = false
        var title: String?
        var kind: MediaItem.Kind?
        var image: String?
        var recent: Date?

        var asTitleSlot: StateRecording.TitlePosition {
            StateRecording.TitlePosition(
                location: position, duration: duration, seen: watched, favorite: favorite,
                title: title, kind: kind, image: image, recent: recent)
        }
    }
}
