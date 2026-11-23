import Foundation

/// The three questions of the settings — **the same on all devices, with the same names**
/// (owner decision 1, 2026-09-25; three instead of four since AP59 N7, 2026-09-30).
///
/// *Sources* — where something comes from; *Playback* (case `watching`) — how it is shown;
/// *Device* — what is here, who may, and who we are. "About" was a fourth group with
/// a single area, and the names differed per device ("Watching" and "Watching and
/// Appearance", "About" and "Account and App").
nonisolated public enum SettingsGroup: String, Sendable, CaseIterable, Identifiable {
    case sources = "quellen", watching = "sehen", device = "geraet"

    public var id: String { rawValue }

    /// The name in the app's language catalog.
    public var titleKey: String { "settings.group.\(rawValue)" }
}

/// The settings areas — **which area sits under which question is stated here
/// and only here.**
///
/// **The finding:** The structure was meant to be the same on both devices, but the assignment differed
/// — on the phone Live sat under *Sources* and the account under *About*, on the TV Live
/// under *Watching* and the media server under *Sources*. The EB drawing (decision 1)
/// decides: as on the TV.
///
/// **Not every device has every area.** The phone handles profiles, language and
/// subtitles within other areas; each platform model says which of its
/// areas is which of these, and thereby takes over the group.
nonisolated public enum SettingsArea: String, Sendable, CaseIterable {
    case jellyfin = "medienserver", channelLists = "senderlisten", portals = "portale", ratings =
        "bewertungen"
    case appearance = "darstellung", playback = "wiedergabe", live, subtitles = "untertitel"
    case profile, language = "sprache", parentalControls = "kindersicherung"
    /// **Other devices** (AP59 N7): share profile via iCloud, handoff, remote.
    case devices = "geraete"
    case storage = "speicher", diagnose
    case about = "ueber"

    public var group: SettingsGroup {
        switch self {
        case .jellyfin, .channelLists, .portals, .ratings: .sources
        case .appearance, .playback, .live, .subtitles, .language: .watching
        case .profile, .parentalControls, .devices, .storage, .diagnose, .about: .device
        }
    }
}

/// The search across the settings — **over the text and not over the key.**
///
/// Until R7 it existed only on the phone (`SettingsCatalog`); the rule is device-free and
/// therefore lives here, while the catalog itself stays with the device because it points to its
/// screens.
///
/// **Three ranks and no similarity computation:** A title that **starts** with the term
/// is almost always what is sought; one that contains it, often; a secondary text
/// (keywords, terms, area name) that contains it, sometimes. **Below two characters
/// empty and not "everything"** — the root then shows its cards.
nonisolated public enum SettingsSearch {

    public static func match<ContentEntryRecord>(
        zu word: String, in entries: [ContentEntryRecord],
        title: (ContentEntryRecord) -> String, secondaryText: (ContentEntryRecord) -> String
    ) -> [ContentEntryRecord] {
        let needle = fold(word)
        guard needle.count >= 2 else { return [] }
        var found: [(entry: ContentEntryRecord, title: String, rank: Int)] = []
        for entry in entries {
            let readable = title(entry)
            let folded = fold(readable)
            if folded.hasPrefix(needle) {
                found.append((entry, readable, 0))
            } else if folded.contains(needle) {
                found.append((entry, readable, 1))
            } else if fold(secondaryText(entry)).contains(needle) {
                found.append((entry, readable, 2))
            }
        }
        return found.sorted { $0.rank == $1.rank ? $0.title < $1.title : $0.rank < $1.rank }
            .map(\.entry)
    }

    /// Small, no symbol above it, no border — **with the current locale**: The
    /// Turkish "I" becomes "ı" and not "i".
    public static func fold(_ text: String) -> String {
        text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
