import Foundation
import Security

/// What the top area of the Apple TV Home Screen should show.
public enum TopShelfMode: String, CaseIterable, Codable, Sendable, Identifiable {
    case resume
    case favorites
    case latest
    /// No content from us — tvOS falls back to the app's brand image.
    case off

    public var id: String { rawValue }

    /// The language key for the settings.
    public var titleKey: String { "topshelf." + rawValue }
}

/// The state the app stores for the Top Shelf extension.
///
/// The extension runs as its own process without a UI and without the app's sign-in —
/// whatever it needs, the app has to leave for it: the server address, the access token,
/// the chosen presentation, **who is sitting in front of the screen and which rule applies
/// for filtering** (AP52, decision 13 of 2026-09-25).
///
/// **Profile and filter are required fields, not extras.** A state written by an older
/// version without them cannot be read — and that is intended: the extension then shows
/// nothing until the app writes the active profile's state on its next start. An old state
/// treated as "open" would show a child the parents' titles until then.
public struct TopShelfContext: Codable, Sendable, Equatable {
    /// Stored keys keep their original (German) names — renaming them would
    /// make data written by earlier versions unreadable (AP85 B4).
    private enum CodingKeys: String, CodingKey {
        case serverURL
        case userID
        case accessToken
        case mode
        case profile = "profil"
        case filter = "sieb"
        case extras = "zusatz"
    }

    /// The media server — **`nil` without Jellyfin** (product decision, 2026-09-28: "like Netflix").
    /// Until then it was required, and a profile with only IPTV or CL-Server had an empty
    /// shelf.
    public let serverURL: URL?
    public let userID: String?
    public let accessToken: String?
    public let mode: TopShelfMode
    /// The identifier of the active profile — only for information and for comparing two
    /// states; filtering is done solely by ``filter``.
    public let profile: String
    /// What the shelf may show.
    public let filter: ShelfFilter
    /// What the app contributes from the profile's state: IPTV VOD and CL-Server.
    ///
    /// **A finished list and not a query**, unlike Jellyfin: only the app knows their
    /// credentials, and the extension does not query any provider itself. The state is
    /// that of the app's last visit — exactly right for "Continue Watching".
    public let extras: [TopShelfEntry]?

    public init(
        serverURL: URL?, userID: String?, accessToken: String?, mode: TopShelfMode,
        profile: String, filter: ShelfFilter, extras: [TopShelfEntry]? = nil
    ) {
        self.serverURL = serverURL
        self.userID = userID
        self.accessToken = accessToken
        self.mode = mode
        self.profile = profile
        self.filter = filter
        self.extras = extras
    }

    /// Derselbe Kontext in einer anderen Darstellung.
    public func using(mode fresh: TopShelfMode) -> TopShelfContext {
        TopShelfContext(
            serverURL: serverURL, userID: userID, accessToken: accessToken, mode: fresh,
            profile: profile, filter: filter, extras: extras)
    }

    /// The media server, if there is one.
    public var jellyfin: (server: URL, user: String, tag: String)? {
        guard let serverURL, let userID, let accessToken else { return nil }
        return (serverURL, userID, accessToken)
    }
}

/// An entry the app contributes to the shelf (``TopShelfContext/extras``).
public struct TopShelfEntry: Codable, Sendable, Equatable {
    /// Stored keys keep their original (German) names — renaming them would
    /// make data written by earlier versions unreadable (AP85 B4).
    private enum CodingKeys: String, CodingKey {
        case id
        case title = "titel"
        case image = "bild"
        case recent = "zuletzt"
    }

    /// This many titles fit in the row.
    public static let shelfSize = 8

    /// The identifier of the title — the same one under which `cinelounge://item/…` opens it.
    public let id: String
    public let title: String
    public let image: URL?
    /// When last watched — for the ordering alongside the Jellyfin titles.
    public let recent: Date?

    public init(id: String, title: String, image: URL?, recent: Date?) {
        self.id = id
        self.title = title
        self.image = image
        self.recent = recent
    }

    /// The entries of a profile state for a presentation — **newest first.**
    ///
    /// "Continue Watching" takes what was started but not finished; "Favorites" takes the
    /// favorites. The state knows no "Recently Added" — that stays with Jellyfin.
    public static func from(
        _ state: StateRecording, mode: TopShelfMode, atMost: Int = 8
    ) -> [TopShelfEntry] {
        let matching = state.titlePositions.filter { _, location in
            switch mode {
            case .resume: (location.location ?? 0) > 0 && !location.seen
            case .favorites: location.favorite
            case .latest, .off: false
            }
        }
        let entries = matching.compactMap { identifier, location -> TopShelfEntry? in
            guard let title = location.title, !title.isEmpty else { return nil }
            return TopShelfEntry(
                id: identifier, title: title, image: location.image.flatMap(URL.init(string:)),
                recent: location.recent)
        }
        let sortedEntries = entries.sorted {
            ($0.recent ?? .distantPast, $1.id) > ($1.recent ?? .distantPast, $0.id)
        }
        return Array(sortedEntries.prefix(atMost))
    }
}

/// What the shelf on the Home Screen may show — **the active profile's rule
/// as a value a foreign process can read** (AP52, 2026-09-25).
///
/// **Why the extension filters itself instead of the app leaving a finished list:**
/// the extension queries the media server fresh on every visit to the Home Screen,
/// and that should stay so — whoever starts an episode on the phone finds it on the
/// TV without having opened the app there. A list from the app would be the state of
/// its last start. That is why the **rule** travels, not its result.
///
/// **The fields are exactly the ingredients of `ParentalControls.ProtectionRule` that a
/// title asks about**, plus the scope of the origins. The interpretation itself lives there
/// and not here — `Core` knows no approvals; see `ShelfFilter.allows(identifier:approval:)`
/// in the `ParentalControls` package.
public struct ShelfFilter: Codable, Sendable, Equatable {
    /// Stored keys keep their original (German) names — renaming them would
    /// make data written by earlier versions unreadable (AP85 B4).
    private enum CodingKeys: String, CodingKey {
        case childMode = "kindermodus"
        case applies = "greift"
        case limit = "grenze"
        case blocksUnrecognized = "sperrtUnverstandene"
        case assignments = "zuordnungen"
    }

    /// Whether the areas without approvals are dropped — portals, providers, channels. For a
    /// child always, otherwise only when the lock applies.
    public let childMode: Bool

    /// Whether the title rule applies — without a PIN it does not, as in the app.
    public let applies: Bool

    /// The applicable limit as a minimum age; `nil` means no limit.
    public let limit: Int?

    /// Ob unverstandene Freigaben sperren.
    public let blocksUnrecognized: Bool

    /// What was assigned by hand, raw text to minimum age.
    public let assignments: [String: Int]

    public init(
        childMode: Bool, applies: Bool, limit: Int?, blocksUnrecognized: Bool,
        assignments: [String: Int]
    ) {
        self.childMode = childMode
        self.applies = applies
        self.limit = limit
        self.blocksUnrecognized = blocksUnrecognized
        self.assignments = assignments
    }

    /// Whether an identifier has the shape of a media server identifier.
    ///
    /// **Since AP58 R6 the rule comes from ``Origin/isMediaServerIdentifier(_:)``** — the same
    /// place where both programs read off their origin. Narrower rather than wider: anything that
    /// does not unambiguously look like a media server counts as foreign and is dropped in child mode.
    public static func isMediaServerIdentifier(_ identifier: String) -> Bool {
        Origin.isMediaServerIdentifier(identifier)
    }
}

/// The bridge between the app and the Top Shelf extension.
///
/// **Through a shared Keychain group, not through shared
/// settings.** That keeps the access token encrypted instead of lying in
/// plain text in a shared plist — the same rule as everywhere in
/// the app: credentials belong in the Keychain.
///
/// **Why no app group:** it requires an entry in the developer portal
/// that the wildcard team profiles cannot carry — the on-device build failed because of it
/// (2026-08-07). Keychain groups with a team prefix, on the other hand, are part of every
/// standard profile. Their full name begins with the team prefix, and the source code does
/// not know it — it reads it at runtime from its own
/// access group (``sharedAccessGroup``).
///
/// The app writes on every start, on sign-in and sign-out, on every change of the
/// setting and — since AP52 — on every profile switch, every rule change and
/// every remote move (`Features.HomeShelf`); the extension only reads.
public enum TopShelfBridge {

    /// The shared entry. Its own service name, so that it sits next to the app's private
    /// entries instead of between them.
    private static let contextKey = "topshelf.context"
    /// The chosen presentation, remembered on the app side — so it also survives
    /// a sign-out, in which the shared entry is cleared.
    static let modeKey = "topshelf.mode"

    /// The core of the shared group name — entered in the entitlements of both
    /// targets behind the team prefix (see `project.yml`).
    private static var sharedGroupSuffix: String { AppIdentifier.sharedKeychainGroup }

    /// The full shared access group, including the team prefix.
    ///
    /// The prefix appears nowhere in the source code — it belongs to the account, not to the
    /// project. A probe entry without an explicit group lands in the target's
    /// own group (`PREFIX.bundle-identifier`); the shared one is built from it
    /// by swapping the bundle identifier for the shared name.
    /// This works in the app AND the extension, because both know
    /// their own identifier.
    private static var sharedAccessGroup: String? {
        guard let bundleID = Bundle.main.bundleIdentifier,
            let own = ownAccessGroup()
        else { return nil }
        guard own.hasSuffix(bundleID) else {
            // Without a recognizable pattern, better not to share at all than to end up in a
            // wrong group that nobody finds again.
            return nil
        }
        return String(own.dropLast(bundleID.count)) + sharedGroupSuffix
    }

    /// The own access group, read off a probe entry.
    private static func ownAccessGroup() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "dev.ms-solutions.cinelounge.probe",
            kSecAttrAccount as String: "group",
            kSecValueData as String: Data("x".utf8),
            kSecReturnAttributes as String: true,
        ]

        var result: CFTypeRef?
        var status = SecItemAdd(query as CFDictionary, &result)
        if status == errSecDuplicateItem {
            var read = query
            read.removeValue(forKey: kSecValueData as String)
            read[kSecMatchLimit as String] = kSecMatchLimitOne
            status = SecItemCopyMatching(read as CFDictionary, &result)
        }
        guard status == errSecSuccess,
            let attributes = result as? [String: Any]
        else { return nil }
        return attributes[kSecAttrAccessGroup as String] as? String
    }

    private static var shared: SecureStore {
        SecureStore(
            service: "dev.ms-solutions.cinelounge.topshelf",
            accessGroup: sharedAccessGroup
        )
    }

    // MARK: - The chosen presentation

    /// The presentation **of the active profile** (product decision, 2026-09-28) — it travels in the
    /// context to the extension, which itself knows no profile.
    public static func mode(from store: any KeyValueStore = ProfileStore.playback) -> TopShelfMode {
        (try? store.value(for: modeKey)).flatMap(TopShelfMode.init(rawValue:)) ?? .resume
    }

    /// Remembers the presentation and rewrites the shared state, if one exists.
    public static func updateMode(
        _ mode: TopShelfMode, store: any KeyValueStore = ProfileStore.playback
    ) {
        try? store.set(mode.rawValue, for: modeKey)
        guard let context = load() else { return }
        save(context.using(mode: mode))
    }

    // MARK: - Der geteilte Stand

    /// The state for a profile — **or none.**
    ///
    /// **Without a media server or without an active profile there is nothing to show** (AP52).
    /// Without access the extension would have nobody to ask; without a profile it would
    /// not know whose rule applies, and the cautious answer to that is an empty
    /// shelf, not the account's.
    ///
    /// A pure computation, so that the checks can cover it without a shared Keychain.
    public static func context(
        credentials: ServerCredentials?, profile: String?, filter: ShelfFilter, mode: TopShelfMode,
        extras: [TopShelfEntry] = []
    ) -> TopShelfContext? {
        guard let profile, !profile.isEmpty, credentials != nil || !extras.isEmpty else { return nil }
        return TopShelfContext(
            serverURL: credentials?.serverURL,
            userID: credentials?.userID,
            accessToken: credentials?.accessToken,
            mode: mode,
            profile: profile,
            filter: filter,
            extras: extras.isEmpty ? nil : extras
        )
    }

    /// Writes the state for the extension — or clears it when there is none.
    ///
    /// **The only writer besides ``updateMode(_:store:)``.** Until AP52 it was called
    /// `sync(credentials:)` and knew only the account; two profiles on one account saw
    /// the same shelf as a result. The old name is gone on purpose, so that no caller writes past
    /// the profile.
    public static func write(_ context: TopShelfContext?) {
        guard let context else {
            clear()
            return
        }
        save(context)
    }

    // MARK: - What the extension saw

    // Assembled, so that the language check does not mistake it for wording.
    private static let extensionKey = "topshelf." + "erweiterung"

    /// The finding of the extension's last run — **written by it, put into the report by the app**
    /// (2026-09-29, F-036). The app wrote the shelf correctly and read it back, yet the Home
    /// Screen still showed only the brand image; what the extension found was recorded nowhere.
    /// If nothing lies here, it does not reach the shared Keychain or is not running at all.
    public static func reportExtension(_ finding: String, now: Date = Date()) {
        let timestamp = ISO8601DateFormatter().string(from: now)
        try? shared.set("\(timestamp) \(finding)", for: extensionKey)
    }

    public static func extensionFinding() -> String? {
        try? shared.value(for: extensionKey)
    }

    /// Whether the shared group could be determined at all — without it each side reads and
    /// writes in its own.
    public static var sharesKeychain: Bool { sharedAccessGroup != nil }

    public static func clear() {
        try? shared.remove(contextKey)
    }

    /// For the extension: the state the app has stored.
    public static func load() -> TopShelfContext? {
        guard let json = try? shared.value(for: contextKey),
            let data = json.data(using: .utf8)
        else { return nil }
        return try? JSONDecoder().decode(TopShelfContext.self, from: data)
    }

    private static func save(_ context: TopShelfContext) {
        guard let data = try? JSONEncoder().encode(context),
            let json = String(data: data, encoding: .utf8)
        else { return }
        try? shared.set(json, for: contextKey)
    }
}
