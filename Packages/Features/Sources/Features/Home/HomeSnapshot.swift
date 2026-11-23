import Core
import Foundation

/// **The Home screen as it last stood — for the next cold start** (AP70, 2026-10-11).
///
/// On the TV the Home screen needed 67 s (diagnosis F-017): `.loading` until every
/// shelf was there, and the portal folders ran one after the other into the 20 s timeout. The model is
/// StoryShelf: At start, what was built last time appears immediately, and the real
/// build replaces it as soon as it is through. The images come from the image cache anyway.
///
/// **One file per profile, and in the cache** — not in the structure store and
/// not in `UserDefaults`: It is an image, not a state. If the system clears the folder,
/// the next start gives the spinner, nothing more. And what is shown goes
/// through the profile's child filter once more (``HomeModel``) before it is on screen —
/// the rule may have changed since the last build.
struct HomeSnapshot: Codable, Equatable {
    /// Stored keys keep their original (German) names — renaming them would
    /// make data written by earlier versions unreadable (AP85 B4).
    private enum CodingKeys: String, CodingKey {
        case heroes
        case shelves
        case state = "stand"
    }

    var heroes: [MediaItem]
    var shelves: [HomeModel.Shelf]
    var state: Date

    static let key = "startseite"

    static func key(forItem profile: String?) -> String {
        guard let profile, !profile.isEmpty else { return key }
        return key + "." + profile
    }

    static func read(from store: any KeyValueStore, forItem profile: String?) -> HomeSnapshot? {
        RecordSheet.read(under: key(forItem: profile), from: store)
    }

    func write(in store: any KeyValueStore, forItem profile: String?) {
        RecordSheet.write(self, under: Self.key(forItem: profile), in: store)
    }

    static func cleanUp(in store: any KeyValueStore, forItem profile: String?) {
        RecordSheet.cleanUp(key(forItem: profile), in: store)
    }

    /// The place in the cache — without backup to `UserDefaults`, because an image
    /// of a few hundred kilobytes has no business there (AP66 cap).
    static func defaultStore() -> any KeyValueStore {
        let caches =
            FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return FileStore(folder: caches.appending(path: "startseite"), backup: nil)
    }
}
