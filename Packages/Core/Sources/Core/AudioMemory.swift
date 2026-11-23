import Foundation

/// Which audio language someone chose **for this title** — the same on both devices
/// (AP58 G1, A10).
///
/// **Why this exists.** The startup rule (``StartingTracks``) knows one language for everything
/// plus the anime exception. Anyone who switched a series from German to the original audio
/// once got German again on the next episode — always on the TV, and on the phone the choice
/// lived in the source sheet of the detail page without ever reaching the player.
///
/// **Per title means: per movie or per series.** An episode is remembered under its series;
/// otherwise the choice would apply to exactly the one episode in which it was made, and the
/// next one would start again in the language of the rule.
///
/// **The language is remembered, not the track number.** Numbers are per file; on the next
/// episode the same number points to a completely different track. A track without a
/// language tag is therefore not remembered — there would be nothing to find it by again.
///
/// **In the person's compartment** (``ProfileStore``), like the other playback preferences: the
/// choice belongs to whoever is watching, not to the device.
public struct AudioMemory: Sendable, Equatable, Codable {
    /// Stored keys keep their original (German) names — renaming them would
    /// make data written by earlier versions unreadable (AP85 B4).
    private enum CodingKeys: String, CodingKey {
        case entries = "eintraege"
    }

    public static let key = "playback.titleAudio"

    /// The maximum number of titles remembered — the oldest drop out.
    ///
    /// Two hundred series and movies are more than anyone watches in rotation; unbounded,
    /// an entry in the Keychain would grow with every title that ever played.
    public static let atMost = 200

    public struct ContentEntryRecord: Sendable, Equatable, Codable {
        /// Stored keys keep their original (German) names — renaming them would
        /// make data written by earlier versions unreadable (AP85 B4).
        private enum CodingKeys: String, CodingKey {
            case title = "titel"
            case language = "sprache"
        }

        public let title: String
        public let language: String
    }

    /// Oldest first.
    public private(set) var entries: [ContentEntryRecord]

    public init(entries: [ContentEntryRecord] = []) {
        self.entries = entries
    }

    /// The name under which a title is remembered — **the series before the episode.**
    public static func title(identifier: String, series: String?) -> String {
        if let series, !series.isEmpty { return series }
        return identifier
    }

    public func language(forItem title: String) -> String? {
        entries.last { $0.title == title }?.language
    }

    /// Remembers a choice — `nil` or empty forgets it.
    public mutating func memorize(_ language: String?, forItem title: String) {
        entries.removeAll { $0.title == title }
        if let language, !language.isEmpty {
            entries.append(ContentEntryRecord(title: title, language: language))
        }
        if entries.count > Self.atMost {
            entries.removeFirst(entries.count - Self.atMost)
        }
    }

    public static func load(from store: any KeyValueStore) -> AudioMemory {
        guard let text = try? store.value(for: key), let data = text.data(using: .utf8),
            let read = try? JSONDecoder().decode(AudioMemory.self, from: data)
        else { return AudioMemory() }
        return read
    }

    public func save(in store: any KeyValueStore) {
        guard let data = try? JSONEncoder().encode(self),
            let text = String(data: data, encoding: .utf8)
        else { return }
        try? store.set(text, for: Self.key)
    }

    /// Read, remember, write back — **the one way a choice gets in.**
    public static func memorize(
        _ language: String?, identifier: String, series: String?, in store: any KeyValueStore
    ) {
        var memory = load(from: store)
        memory.memorize(language, forItem: title(identifier: identifier, series: series))
        memory.save(in: store)
    }

    /// The preference for this title — the general one, **with the remembered language on top.**
    ///
    /// **The anime rule yields to a remembered language**, unless the remembered one is itself the
    /// original audio: someone who deliberately chose German for an anime does not want to get
    /// Japanese with subtitles again on the next episode.
    public func preferred(
        _ general: AudioPreference, identifier: String, series: String?
    ) -> AudioPreference {
        guard let remembered = language(forItem: Self.title(identifier: identifier, series: series)) else {
            return general
        }
        var preferred = general
        preferred.language = remembered
        if !LanguageCode.matches(remembered, "ja") { preferred.animeOriginal = false }
        return preferred
    }
}
