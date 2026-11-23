import Core
import Foundation

/// A German voice actor for a role.
public struct VoiceCredit: Sendable, Equatable, Codable {
    public let name: String
    public let imageURL: URL?

    public init(name: String, imageURL: URL?) {
        self.name = name
        self.imageURL = imageURL
    }
}

/// The German voices for a title, searchable by role.
///
/// **Why this works at all — and why only here** (user request 2026-08-12):
/// The cast is wanted in two rows, the actors above, below them the
/// German voice for the same role. The Jellyfin server keeps no
/// voice actors, and the movie database does not either: Its cast is the
/// **original** cast, the same in every language. AniList, in contrast, keeps them
/// per role and language — and only for anime.
///
/// That is why there is no general promise of a "German cast" here,
/// but exactly what exists: a second row where a source
/// provides it, and no empty row where not. An empty field is no information at this
/// spot — it looks like an error.
public struct GermanVoices: Sendable, Equatable, Codable {

    /// Stored by **role name**, not by voice actor: The Jellyfin server
    /// gives the role for every entry of its cast, and via it leads the
    /// only reliable path between the two sources. The names of the
    /// Japanese voice actors are not — AniList writes them in
    /// transliteration, Jellyfin often in a different one.
    private let byCharacter: [String: VoiceCredit]

    public init(byCharacter: [String: VoiceCredit]) {
        self.byCharacter = byCharacter
    }

    public var isEmpty: Bool { byCharacter.isEmpty }

    /// The voice for a role, as the Jellyfin server writes it.
    public func voice(forCharacter character: String?) -> VoiceCredit? {
        guard let character else { return nil }
        for part in Self.characterKeys(character) {
            if let match = byCharacter[part] { return match }
        }
        return nil
    }

    /// The lookup forms of a role name.
    ///
    /// **Both sources write roles differently**, and that is the whole
    /// reason for this function:
    ///
    /// - Jellyfin appends "(voice)" for anime — "Baujouhas Klaungi (voice)".
    /// - One person often voices several roles — "Zosgok Wibein / Zosgok Flakriorn / Zosgok
    ///   Flohautzind (voice)". Then each counts individually, because AniList lists them individually.
    /// - Capitalisation and surrounding whitespace are unreliable in both
    ///   sources.
    ///
    /// The parts come back in the order in which they stand: The first
    /// role found wins, and that is the entry's main role.
    public static func characterKeys(_ character: String) -> [String] {
        character
            .replacingOccurrences(of: "(voice)", with: "")
            .split(separator: "/")
            .map { normalized(String($0)) }
            .filter { !$0.isEmpty }
    }

    /// A role name in its lookup form.
    public static func normalized(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}
