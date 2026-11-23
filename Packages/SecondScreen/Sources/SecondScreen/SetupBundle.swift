import Foundation
import ParentalControls
import ProfileKit

/// What travels from one device to the other — **and what explicitly does not.**
///
/// **The table from E5 as a type.** The draft lists it as an enumeration ("travels along /
/// stays on the device / is already there"), and an enumeration in a document is an
/// intention. As a type it is a commitment: What has no field here cannot travel along,
/// and whoever adds one has to write it down.
///
/// **Three kinds, three reasons:**
///
/// * **Travels along** — everything that is a pain to set up and should be the same
///   on every device: accesses, keys, preferences, parental controls including the PIN.
/// * **Stays on the device** — the downloads (14.8 GB do not travel through the network),
///   "Wi-Fi only" (meaningless on the TV), picture-in-picture and rotation, the diagnostic
///   identifier.
/// * **Is already there** — progress, watched marks and favorites live in the
///   media server's user account. Once the access is transferred, they are there without
///   a byte of them having to go through the channel.
///
/// **Parental controls travel along, PIN included.** Without that, the new
/// device would stand open at exactly the moment a child first gets it in hand — and
/// that is the moment they exist for.
public struct SetupBundle: Sendable, Equatable, Codable {
    /// Stored keys keep their original (German) names — renaming them would
    /// make data written by earlier versions unreadable (AP85 B4).
    private enum CodingKeys: String, CodingKey {
        case version = "fassung"
        case jellyfin = "medienserver"
        case channelLists = "senderlisten"
        case bridge = "bruecke"
        case omdbKey = "omdbSchluessel"
        case tmdbKey = "tmdbSchluessel"
        case malKey = "malSchluessel"
        case language = "sprache"
        case colorPattern = "farbmuster"
        case shelfOrder = "regalreihenfolge"
        case sports = "sportarten"
        case groupOrder = "gruppenreihenfolge"
        case hiddenGroups = "versteckteGruppen"
        case parentalControls = "kindersicherung"
        case profile
    }

    /// The version of the bundle.
    ///
    /// **An older phone must not half-set-up a newer device.** Whoever adds a field
    /// raises the number; whoever receives a bundle whose number it does not know
    /// rejects it instead of guessing. Half set up is worse than not at all: The one
    /// state is noticed, the other is not.
    ///
    /// **Version 2 since 2026-09-21** (AP44): The bundle carries the ``ProfileKit``s along.
    /// Version 1 only carried the signed-in access — on the TV that turned into a
    /// device with one person on it, while the phone showed four.
    public static let version = 2

    public let version: Int

    // MARK: - Travels along

    public let jellyfin: ServerAccess?
    public let channelLists: [ListAccess]
    /// The address of the portals bridge.
    public let bridge: URL?
    public let omdbKey: String?
    public let tmdbKey: String?
    /// The MyAnimeList client ID (AP68) — an older device does not know the field and
    /// ignores it.
    public let malKey: String?
    public let language: String?
    public let colorPattern: String?
    public let shelfOrder: [String]
    /// The **switched-off** sports (``Core/SportFilterSettings/disabled``) — not the
    /// chosen ones.
    ///
    /// **Filled and read only since 2026-09-27** (ultra e5, round A.5), like the
    /// two group fields below: The fields existed, the phone never packed them, and
    /// the TV never read them. What is switched off is remembered for the same reason as
    /// on the device: A sport that only the TV knows stays on there instead of quietly
    /// disappearing. **No new version** — the fields were already in version 1.
    public let sports: [String]
    /// The channel groups in the chosen order (``Core/LivePreferences/groupOrder``).
    public let groupOrder: [String]
    /// The hidden channel groups (``Core/LivePreferences/hiddenGroups``), sorted.
    public let hiddenGroups: [String]
    public let parentalControls: ParentalControlsState?

    /// **The people of this device** — since version 2.
    ///
    /// **Without secrets, and that is not a gap.** A ``ProfileKit/Access`` says *whom*
    /// a server or a list belongs to, and not what you sign in there with; the
    /// passwords and tokens keep traveling in ``jellyfin`` and ``channelLists``. What
    /// this field adds is the assignment — it was missing entirely until here, and without
    /// it a set-up device arrives on the TV without a family.
    ///
    /// **And without saying who is currently watching.** Who sits in front of it is decided by the
    /// receiving device; a bundle that brought along the active person would switch the person
    /// on the TV — triggered by someone standing at the phone.
    public let profile: [Profile]

    public init(
        version: Int = SetupBundle.version,
        jellyfin: ServerAccess? = nil,
        channelLists: [ListAccess] = [],
        bridge: URL? = nil,
        omdbKey: String? = nil,
        tmdbKey: String? = nil,
        malKey: String? = nil,
        language: String? = nil,
        colorPattern: String? = nil,
        shelfOrder: [String] = [],
        sports: [String] = [],
        groupOrder: [String] = [],
        hiddenGroups: [String] = [],
        parentalControls: ParentalControlsState? = nil,
        profile: [Profile] = []
    ) {
        self.version = version
        self.jellyfin = jellyfin
        self.channelLists = channelLists
        self.bridge = bridge
        self.omdbKey = omdbKey
        self.tmdbKey = tmdbKey
        self.malKey = malKey
        self.language = language
        self.colorPattern = colorPattern
        self.shelfOrder = shelfOrder
        self.sports = sports
        self.groupOrder = groupOrder
        self.hiddenGroups = hiddenGroups
        self.parentalControls = parentalControls
        self.profile = profile
    }

    /// **A bundle from version 1 has no profile field** — and that is the normal case
    /// as long as not every phone is new. Without this reader the device would reject a
    /// bundle that, according to ``acceptable(version:)``, it is supposed to accept: A
    /// key would be missing, and the generated default reader then throws.
    public init(from decoder: any Decoder) throws {
        let bucket = try decoder.container(keyedBy: CodingKeys.self)
        version = try bucket.decode(Int.self, forKey: .version)
        jellyfin = try bucket.decodeIfPresent(ServerAccess.self, forKey: .jellyfin)
        channelLists = try bucket.decodeIfPresent([ListAccess].self, forKey: .channelLists) ?? []
        bridge = try bucket.decodeIfPresent(URL.self, forKey: .bridge)
        omdbKey = try bucket.decodeIfPresent(String.self, forKey: .omdbKey)
        tmdbKey = try bucket.decodeIfPresent(String.self, forKey: .tmdbKey)
        malKey = try bucket.decodeIfPresent(String.self, forKey: .malKey)
        language = try bucket.decodeIfPresent(String.self, forKey: .language)
        colorPattern = try bucket.decodeIfPresent(String.self, forKey: .colorPattern)
        shelfOrder = try bucket.decodeIfPresent([String].self, forKey: .shelfOrder) ?? []
        sports = try bucket.decodeIfPresent([String].self, forKey: .sports) ?? []
        groupOrder =
            try bucket.decodeIfPresent([String].self, forKey: .groupOrder) ?? []
        hiddenGroups =
            try bucket.decodeIfPresent([String].self, forKey: .hiddenGroups) ?? []
        parentalControls =
            try bucket.decodeIfPresent(ParentalControlsState.self, forKey: .parentalControls)
        profile = try bucket.decodeIfPresent([Profile].self, forKey: .profile) ?? []
    }

    /// Whether this bundle may be applied here.
    ///
    /// **A newer bundle is rejected, an older one accepted.** What an old device
    /// sends, a new one understands completely — it knows every field that can
    /// appear in it. The reverse does not hold.
    public static func acceptable(version: Int) -> Bool {
        version <= Self.version
    }

    /// An access to the media server — **including certificate trust.**
    ///
    /// Without the fingerprint the new device asks on first connecting, and the
    /// viewer faces a security question they cannot answer: They have
    /// nothing to compare it with.
    public struct ServerAccess: Sendable, Equatable, Codable {
        /// Stored keys keep their original (German) names — renaming them would
        /// make data written by earlier versions unreadable (AP85 B4).
        private enum CodingKeys: String, CodingKey {
            case address = "adresse"
            case userID = "benutzerkennung"
            case username = "benutzername"
            case accessToken = "zugangsmarke"
            case trusted = "vertraut"
        }

        public let address: URL
        public let userID: String
        public let username: String
        public let accessToken: String
        /// Fingerabdruck je Rechnername.
        public let trusted: [String: String]

        public init(
            address: URL, userID: String, username: String,
            accessToken: String, trusted: [String: String] = [:]
        ) {
            self.address = address
            self.userID = userID
            self.username = username
            self.accessToken = accessToken
            self.trusted = trusted
        }
    }

    /// A channel list including its password.
    public struct ListAccess: Sendable, Equatable, Codable {
        /// Stored keys keep their original (German) names — renaming them would
        /// make data written by earlier versions unreadable (AP85 B4).
        private enum CodingKeys: String, CodingKey {
            case identifier = "kennung"
            case name
            case address = "adresse"
            case user = "benutzer"
            case password = "kennwort"
            case epg
        }

        public let identifier: String
        public let name: String
        public let address: URL
        public let user: String?
        public let password: String?
        /// The program source of the list — **since 2026-09-27** (setup check, E2).
        ///
        /// **Optional and without a new version.** A TV of an older version ignores the
        /// field and sets up the list without a program, as before; a higher number would make
        /// it reject the whole bundle — for a line it can fill in later.
        public let epg: URL?

        public init(
            identifier: String, name: String, address: URL, user: String? = nil,
            password: String? = nil, epg: URL? = nil
        ) {
            self.identifier = identifier
            self.name = name
            self.address = address
            self.user = user
            self.password = password
            self.epg = epg
        }
    }

    /// Parental controls — **with the digest of the PIN and not its digits.**
    ///
    /// **Until 2026-09-10 this had `pin: String`, and nobody could have filled it.**
    /// While building the handoff channel it turned out that the four digits are stored nowhere:
    /// ``ParentalControls/Pin`` salts and hashes them when set and afterwards only
    /// compares. A device cannot state its own PIN.
    ///
    /// **An empty field would have been the worse outcome.** On the TV the
    /// parental controls would then arrive as "on, but without PIN" — the worst finding
    /// of the usability pass, a second time and on a second device.
    ///
    /// **The version stays 1 regardless.** A bundle has never gone over a wire —
    /// there was none until today —, and raising a version whose predecessor
    /// nobody ever saw is a commitment to no one.
    public struct ParentalControlsState: Sendable, Equatable, Codable {
        /// Stored keys keep their original (German) names — renaming them would
        /// make data written by earlier versions unreadable (AP85 B4).
        private enum CodingKeys: String, CodingKey {
            case active = "aktiv"
            case pin
            case ageLimit = "altersgrenze"
        }

        public let active: Bool
        /// The salted digest including the salt — see ``ParentalControls/Pin/Extract``.
        public let pin: Pin.Extract?
        public let ageLimit: Int?

        public init(active: Bool, pin: Pin.Extract?, ageLimit: Int?) {
            self.active = active
            self.pin = pin
            self.ageLimit = ageLimit
        }
    }
}
