import Foundation

/// A video for a title at TMDb — trailer, teaser, clip, featurette — as far as the
/// trailer choice needs it (AP78, 2026-10-11).
///
/// Only YouTube videos arrive here: TMDb also lists Vimeo, but the app resolves only
/// YouTube (``TrailerRule``), and an entry nobody can play would be a
/// button leading nowhere.
public struct TrailerVideo: Sendable, Equatable, Codable {
    /// Stored keys keep their original (German) names — renaming them would
    /// make data written by earlier versions unreadable (AP85 B4).
    private enum CodingKeys: String, CodingKey {
        case youtubeID
        case language = "sprache"
        case kind = "art"
        case official = "offiziell"
        case name
        case published = "veroeffentlicht"
    }

    public enum Kind: String, Sendable, Equatable, Codable {
        case trailer
        case teaser
        /// Clip, featurette, making-of, opening credits — everything that is not a trailer. Never
        /// chosen as a trailer, but stays in the set so that the count is right.
        case other = "sonstiges"

        /// From TMDb's `type` field ("Trailer", "Teaser", "Clip", …).
        public init(tmdb contentType: String?) {
            switch contentType?.lowercased() {
            case "trailer": self = .trailer
            case "teaser": self = .teaser
            default: self = .other
            }
        }
    }

    /// The YouTube key (`key` at TMDb), eleven characters.
    public let youtubeID: String
    /// Language per ISO 639-1 (`de`, `en`, `tr`); `nil` if TMDb knows none.
    public let language: String?
    public let kind: Kind
    public let official: Bool
    public let name: String
    public let published: Date?

    public init(
        youtubeID: String, language: String?, kind: Kind, official: Bool, name: String,
        published: Date? = nil
    ) {
        self.youtubeID = youtubeID
        self.language = language
        self.kind = kind
        self.official = official
        self.name = name
        self.published = published
    }
}

/// A title's own trailer file (Jellyfin "LocalTrailers") — only what the
/// rule needs to know.
public struct TrailerFile: Sendable, Equatable {
    /// Audio language of the first audio track, as the server reports it (`ger`, `deu`, `narrow`, …);
    /// `nil` if the file carries none — the case for the sample trailers in the catalog.
    public let language: String?

    public init(language: String?) {
        self.language = language
    }
}

/// What plays as a title's trailer.
public enum TrailerChoice: Sendable, Equatable {
    /// The own file from the catalog; the view fetches it as before via the source.
    case file(language: String?)
    /// A YouTube video that the app resolves itself (`Trailer/TrailerResolution`).
    case youtube(id: String, language: String?)

    public var language: String? {
        switch self {
        case .file(let language), .youtube(_, let language): language
        }
    }

    public var youtubeID: String? {
        if case .youtube(let id, _) = self { return id }
        return nil
    }

    /// The badge on the button: "DE", "EN", "TR" — `nil` if the language is unknown.
    public var badge: String? {
        LanguageCode.short(language)?.uppercased()
    }
}

/// The language rule for trailers — a pure function, so it can be checked without a network.
///
/// **Order (product decision, 2026-10-11): app language, then original language, then English.**
/// For a Turkish movie that means TR before EN, for an English one nothing changes.
/// The own file in the catalog wins only if it is in the app language: behind today's
/// button, many titles have sample trailers without a language tag, and those should not
/// stand in the way of a German TMDb trailer. As soon as the real German trailers are
/// stored, they win by themselves.
///
/// 1. File in app language
/// 2. TMDb in app language
/// 3. File in another or unknown language
/// 4. TMDb in original language
/// 5. TMDb in English
public enum TrailerRule {

    public static func choice(
        file: TrailerFile?,
        videos: [TrailerVideo],
        appLanguage: String,
        original: String?
    ) -> TrailerChoice? {
        if let file, LanguageCode.matches(file.language, appLanguage) {
            return .file(language: file.language)
        }
        if let video = best(videos, language: appLanguage) {
            return .youtube(id: video.youtubeID, language: video.language)
        }
        if let file { return .file(language: file.language) }
        for language in fallbackOrder(appLanguage: appLanguage, original: original) {
            if let video = best(videos, language: language) {
                return .youtube(id: video.youtubeID, language: video.language)
            }
        }
        return nil
    }

    /// The languages after the app language, without duplicates: original, then English.
    static func fallbackOrder(appLanguage: String, original: String?) -> [String] {
        var row: [String] = []
        for kandidat in [original, "en"].compactMap({ $0 })
        where !LanguageCode.matches(kandidat, appLanguage) && !row.contains(kandidat) {
            row.append(kandidat)
        }
        return row
    }

    /// The best video of a language: trailer before teaser, official ones first, then the newest.
    /// Clips and featurettes do not count — they are not a trailer.
    public static func best(_ videos: [TrailerVideo], language: String) -> TrailerVideo? {
        videos
            .filter { $0.kind != .other && LanguageCode.matches($0.language, language) }
            .min { a, b in
                if a.kind != b.kind { return a.kind == .trailer }
                if a.official != b.official { return a.official }
                return (a.published ?? .distantPast) > (b.published ?? .distantPast)
            }
    }

    /// Which language still has to be requested before the rule decides.
    ///
    /// TMDb returns videos only in the requested languages; the title lookup requests
    /// app language and English. If the original is something third (Turkish, Japanese) and
    /// no trailer in the app language has been found yet, the original language has to be
    /// fetched separately — otherwise English would win before the original, against the rule.
    public static func missingOriginal(
        file: TrailerFile?, videos: [TrailerVideo], appLanguage: String, original: String?
    ) -> String? {
        guard let original, !LanguageCode.matches(original, appLanguage),
            !LanguageCode.matches(original, "en")
        else { return nil }
        // An own file wins before the original (step 3) — no matter which
        // language it carries. Then the extra request is not worth it.
        if file != nil { return nil }
        if best(videos, language: appLanguage) != nil { return nil }
        if videos.contains(where: { LanguageCode.matches($0.language, original) }) { return nil }
        return original
    }
}
