import Foundation

/// A person sitting in front of the device — **across all three content paths.**
///
/// **The product decision of 2026-09-19** (report, section 4): a
/// profile is a person and not a sign-in. It carries name, color, kind and its
/// ``Access``e — a media server user, channel lists, the portals person. Until then there
/// were three places to switch and three owners for "where did I leave off": the
/// "account" was a Jellyfin user, the channel lists hung on the **device**, and the
/// portals person was a third sign-in via a device token.
///
/// **Profiles are independent of each other.** Jellyfin is set up for person X just as
/// for Y, whether or not X is still around. That is the difference from a
/// "sub-account": whoever removes a profile here takes nothing away from anyone else.
///
/// **A child profile is a kind and not a device flag.** Until now "child mode" was
/// a property of the TV: it applied to everyone in front of it, and whoever
/// switched it off switched it off for everyone. As a kind of the profile, the age limit hangs on
/// the **person** — and the device lock ("the TV in the child's room") remains
/// alongside it, as a named exception and not as a replacement.
///
/// **`Codable`, because it goes into the store and later into the cloud** (AP43). That is why
/// there are no view types here: no `Color`, no `Image`. A color that sits in the file as a
/// number triple is wrong at the next redesign;
/// ``ColorTag`` is a name that each UI resolves for itself.
public struct Profile: Sendable, Equatable, Identifiable, Codable {
    /// Stored keys keep their original (German) names — renaming them would
    /// make data written by earlier versions unreadable (AP85 B4).
    private enum CodingKeys: String, CodingKey {
        case identifier = "kennung"
        case name
        case color = "farbe"
        case kind = "art"
        case avatar
        case credentials = "zugaenge"
    }

    /// **An identifier of its own and not "server plus user".**
    ///
    /// The old ``Account/Identifier`` was exactly that — and thus bound to a Jellyfin user.
    /// A profile that has only channel lists would have no identifier in it; one that
    /// changes its media server would be a different profile afterward and lose
    /// its state. The identifier is assigned once and never changes again.
    public struct Identifier: Sendable, Equatable, Hashable, Codable, RawRepresentable {

        public let rawValue: String

        public init(rawValue: String) {
            self.rawValue = rawValue
        }

        /// A fresh identifier.
        public static func fresh() -> Identifier { Identifier(rawValue: UUID().uuidString) }
    }

    /// Whether this profile belongs to a child.
    ///
    /// **Two cases and no `Bool`.** "Is child" reads at the call site like a
    /// property of the person; what is meant is which rules apply. And if one day
    /// a third case is added — a guest profile —, here it is one line and not an inverted `if`
    /// in forty places.
    public enum Kind: String, Sendable, Equatable, Codable, CaseIterable {
        case adult = "erwachsen"
        case kind
    }

    /// The color of the profile circle — **a name and not a color value.**
    ///
    /// What `cinema` takes to be "blue" is decided by the design and not by the store;
    /// the same rule as with ``DesignSystem`` and the color sample (AP40). A number triple
    /// in the file would be wrong at the next palette redesign — and silently so.
    public enum ColorTag: String, Sendable, Equatable, Codable, CaseIterable {
        case amber = "bernstein"
        case turquoise = "tuerkis"
        case coral = "koralle"
        case lilac = "flieder"
        case moss = "moos"
        case slate = "schiefer"
    }

    public let identifier: Identifier
    public var name: String
    public var color: ColorTag
    public var kind: Kind

    /// The profile picture — **the name of one of the bundled motifs.**
    ///
    /// **Three states, and two of them show the same thing:** `nil` means "never decided",
    /// `""` means "No picture" (a choice with a timestamp in the cloud), a name means a motif.
    /// The display draws the letter for `nil` and `""`; the sync distinguishes
    /// them — see ``ProfileMapping/avatarType``.
    ///
    /// **A name and not an image**, for the same reason as ``color``: the sixteen motifs
    /// lie in each program's bundle, only which one is chosen (AP49). What the name
    /// shows, each UI resolves itself — via ``AvatarMotif/motif(forItem:)``.
    ///
    /// **An unknown name stays and is not set to `nil`.** It comes
    /// from a newer version with a larger set; whoever deleted it here would take the choice
    /// away from the other device at the next sync. The letter is then drawn —
    /// decided at the display, not in the store.
    ///
    /// **Optional in the file too:** profile books from before AP49 do not have the field, and
    /// the derived decoding reads a missing optional field as `nil`.
    /// `ProfilTests/oldBook` pins that down.
    public var avatar: String?

    /// The accesses of this profile — **in the order in which they were created.**
    ///
    /// A set would be the more precise form and the less usable one: the order is the
    /// information about which access someone started with, and the UI shows it that way.
    public private(set) var credentials: [Access]

    public var id: Identifier { identifier }

    public init(
        identifier: Identifier = .fresh(), name: String, color: ColorTag = .amber,
        kind: Kind = .adult, credentials: [Access] = [], avatar: String? = nil
    ) {
        self.identifier = identifier
        self.name = name
        self.color = color
        self.kind = kind
        self.credentials = credentials
        self.avatar = avatar
    }

    /// The same profile under another identifier — for the move, when the identifier
    /// changes and everything else stays (``ProfileSync/wins(_:about:)``,
    /// ``ProfileMove/episode(_:ledgerStore:keychain:startStore:)``).
    public func withIdentifier(_ fresh: Identifier) -> Profile {
        Profile(
            identifier: fresh, name: name, color: color, kind: kind, credentials: credentials, avatar: avatar)
    }

    // MARK: - Accesses

    /// Adds an access — **or replaces the one of the same kind.**
    ///
    /// **One media server user per profile, and that is a decision.** A person
    /// can have access to two servers; but as long as "Continue Watching" comes from *one*
    /// server, two Jellyfin accesses would be two truths about the same state.
    /// Several channel lists, on the other hand, are allowed: they have no state they
    /// could contradict.
    public mutating func create(_ credential: Access) {
        if credential.onlyOnce {
            credentials.removeAll { $0.kind == credential.kind }
        } else {
            credentials.removeAll { $0 == credential }
        }
        credentials.append(credential)
    }

    public mutating func remove(_ credential: Access) {
        credentials.removeAll { $0 == credential }
    }

    /// Rewrites the media server's address — **in place, user and name
    /// stay** (check setup, E3, 2026-09-27).
    ///
    /// - Returns: whether anything changed.
    @discardableResult
    public mutating func moveServer(from old: URL, after fresh: URL) -> Bool {
        guard
            let slot = credentials.firstIndex(where: {
                if case .jellyfin(let server, _, _) = $0 { return server == old }
                return false
            }),
            case .jellyfin(_, let user, let name) = credentials[slot]
        else { return false }
        credentials[slot] = .jellyfin(server: fresh, userID: user, username: name)
        return true
    }

    /// The media server access, if there is one.
    public var jellyfin: Access? {
        credentials.first { $0.kind == .jellyfin }
    }

    /// The channel lists of this profile.
    public var channelLists: [Access] {
        credentials.filter { $0.kind == .channelList }
    }

    /// Whether this profile wants the portals.
    public var wantsPortals: Bool {
        credentials.contains { $0.kind == .portals }
    }

    /// The household person at the CineLounge server — **the value for `X-CL-Profile`.**
    ///
    /// `nil` means: no portals, or a bare bridge without persons. Both are
    /// the same header, namely none — and that is exactly what ``PortalKit/PortalBridge`` expects.
    public var portalPerson: String? {
        for credential in credentials {
            if case .portals(let person) = credential { return person }
        }
        return nil
    }

    /// The letter in the profile circle.
    ///
    /// **A question mark for an empty name and not an empty circle.** A circle without a character
    /// looks like a load failure; a question mark says "a name is missing here".
    public var initial: String {
        name.first.map { String($0).uppercased() } ?? "?"
    }
}
