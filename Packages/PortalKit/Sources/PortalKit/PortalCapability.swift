import Foundation

/// What a portal can do — **and which control depends on it.**
///
/// **The point at which the app stops knowing portal names.** A seventh portal should cost no
/// line of Swift; everything the UI has to know about a portal is in its capabilities. No
/// `if portal == "ard"`, anywhere.
///
/// **Two words per capability, and that is no blemish (2026-09-12).** The bridge writes them
/// in German (`seasons`, `resolver`), the server in English (`seasons`, `resolver`). A
/// capability is a **value** and not a key — the ``PortalDialect`` translates keys and would
/// not fit here. So the translation sits here, at the one place where both words mean the
/// same.
public enum PortalCapability: Sendable, CaseIterable, Hashable {

    /// Suchfeld im Bereich.
    case search
    /// Season pills on the detail page.
    case seasons
    /// Sprachmarke am Plakat, Sprachwahl.
    case languages
    /// Host button, "resolved in 1.8 s".
    case resolver
    /// Konto-Zeile in den Einstellungen.
    case login
    /// No TMDB matching needed — the portal brings its own images.
    case ownImages
    /// Untertitelwahl im Spieler.
    case subtitles
    /// „12 von 12 in Ordnung".
    case finding
    /// Continuation marker instead of one page at a time.
    case paging

    /// What the bridge calls this capability.
    public var bridgeWord: String {
        switch self {
        case .search: "suche"
        case .seasons: "staffeln"
        case .languages: "sprachen"
        case .resolver: "aufloeser"
        case .login: "anmeldung"
        case .ownImages: "eigene_bilder"
        case .subtitles: "untertitel"
        case .finding: "befinden"
        case .paging: "blaettern"
        }
    }

    /// What the server calls it.
    public var serverWord: String {
        switch self {
        case .search: "search"
        case .seasons: "seasons"
        case .languages: "languages"
        case .resolver: "resolver"
        case .login: "login"
        case .ownImages: "own_images"
        case .subtitles: "subtitles"
        case .finding: "health"
        case .paging: "paging"
        }
    }

    /// Is this capability in the list — regardless of which service wrote it?
    ///
    /// **Both words are searched and not that of the configured dialect.** A list that comes from
    /// a cache of the previous day can be in the other language; treating it as empty for that
    /// reason would make controls disappear without anything being broken.
    public func settled(in capabilities: some Collection<String>) -> Bool {
        capabilities.contains(bridgeWord) || capabilities.contains(serverWord)
    }

    /// The capability for a word — regardless of which language it is written in.
    ///
    /// `nil` for a word on which nothing in this app depends. **That is not an error:** the server
    /// may know capabilities that the app does not serve, and an app that failed on that would be
    /// due for a fix with every server extension.
    public init?(word: String) {
        guard let found = Self.allCases.first(where: { $0.bridgeWord == word || $0.serverWord == word })
        else { return nil }
        self = found
    }
}
