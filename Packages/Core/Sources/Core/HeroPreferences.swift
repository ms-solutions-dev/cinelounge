import Foundation

/// Which libraries may appear large in the header area of the Home screen.
///
/// The automatic detection recognizes the **kind** of a library reliably — film, series,
/// home video — but not the **intent**. Anyone who sets up their family recordings as a
/// film library because they like the film view better would otherwise get them
/// filling the whole Home screen. No heuristic helps against that,
/// only a switch.
///
/// What is stored is what is **excluded**, not what is allowed. The
/// difference matters: If a library is added later, it is included without any action —
/// as one expects. With an allow list it would be
/// silently invisible, and one would look for the fault in the app.
public struct HeroPreferences: Sendable, Equatable {

    /// Identifiers of the libraries that stay out.
    public private(set) var excluded: Set<String>

    public init(excluded: Set<String> = []) {
        self.excluded = excluded
    }

    public func allows(_ libraryID: String) -> Bool {
        !excluded.contains(libraryID)
    }

    public mutating func setAllowed(_ allowed: Bool, for libraryID: String) {
        if allowed {
            excluded.remove(libraryID)
        } else {
            excluded.insert(libraryID)
        }
    }

    // MARK: - Ablage

    static let storageKey = "hero.excludedLibraries"

    /// As one line with a separator, not as JSON: These are identifiers without
    /// structure, and the server forms them from hexadecimal characters — a semicolon
    /// cannot occur in them.
    public static func load(from store: any KeyValueStore) -> HeroPreferences {
        guard let raw = try? store.value(for: storageKey), !raw.isEmpty else {
            return HeroPreferences()
        }
        return HeroPreferences(excluded: Set(raw.split(separator: ";").map(String.init)))
    }

    public func save(to store: any KeyValueStore) {
        if excluded.isEmpty {
            try? store.remove(Self.storageKey)
        } else {
            // Sorted, so that the same selection always yields the same line —
            // otherwise a comparison sees changes where there are none.
            try? store.set(excluded.sorted().joined(separator: ";"), for: Self.storageKey)
        }
    }
}
