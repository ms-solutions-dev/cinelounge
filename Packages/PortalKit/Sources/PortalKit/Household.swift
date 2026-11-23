import Core
import Foundation

/// Who lives in the household, and who is watching right now.
///
/// **That is the difference from the bridge, and it is the reason for the whole
/// changeover (2026-09-12).** The portals bridge was a service without users: every
/// device on the network saw everything, and the watch state hung on the device. The
/// CineLounge server knows people, roles and devices — and with that the state hangs on
/// the person. Start on the phone, continue watching on the TV.
///
/// **Two ways in, one result.** On the phone one chooses a profile and types a PIN; on
/// the TV nobody types a PIN, there one redeems a six-digit code that the console shows
/// in the browser. Both end with a ``DeviceTrait``, and from then on that is the
/// only thing the app keeps.
public struct Household: Sendable {

    private let binding: PortalBridge

    public init(binding: PortalBridge) {
        self.binding = binding
    }

    // ── Before sign-in ────────────────────────────────────────────────────────

    /// Who lives here — **the profile picker.**
    ///
    /// Needs no token: it is the question one asks before having one.
    ///
    /// **No PIN hint, no number of attempts.** The list is deliberately harmless: name,
    /// colour, role. Whoever intercepts it knows who lives here — and sees that anyway when
    /// standing in front of the TV.
    public func choice() async throws -> SignInChoice {
        try await binding.fetch("login/who")
    }

    /// Sign in with profile and PIN — **the path on the phone.**
    ///
    /// - Parameter geraet: What this device should be called in the device list. The
    ///   server otherwise inserts "Browser", and in a list of nothing but "Browser" no
    ///   device can be recognised any more.
    ///
    /// **A wrong PIN and an unknown person give the same refusal**
    /// (`auth.bad_credentials`). That is intended and must **not** be given away in the app
    /// by two different texts: "This person does not exist" tells a stranger which names to
    /// try next.
    public func signIn(person: String, pin: String, device: String) async throws -> SignIn {
        try await binding.notify(
            "login", mainContent: SignInCredentials(name: person, pin: pin, device: device))
    }

    /// Redeem a pairing code or invitation — **the path on the TV.**
    ///
    /// **The field is called `token` and not `code`.** The same path redeems both: a
    /// six-digit pairing code and an invitation of 22 lowercase characters. A field named
    /// `code` would mean something different from what is in it for half the calls.
    ///
    /// **Lowercase is allowed.** The server writes six-character codes in uppercase;
    /// whoever types it in lowercase from the remote means the same. The app does not have
    /// to convert anything.
    ///
    /// **Where the device comes from is told by the server itself** — there is no origin
    /// field in the body. The origin is the address of the request, and an app cannot give
    /// it without also being able to give it falsely. Only what afterwards appears in the
    /// device list is contributed: ``kind`` (see ``DeviceKind``) and a name.
    public func redeem(
        password: String, name: String, kind: DeviceKind
    ) async throws
        -> SignIn
    {
        try await binding.notify(
            "redeem", mainContent: Redemption(token: password, name: name, kind: kind.rawValue))
    }

    // ── Danach ───────────────────────────────────────────────────────────────

    /// Who am I, and what may I do.
    public func me() async throws -> HouseholdPerson {
        try await binding.fetch("household/me")
    }

    /// The token expires — **at the server, not only on the device.**
    ///
    /// Because a token does not expire by itself, this is the only place where it becomes
    /// invalid. Deleting only locally would leave a valid token in the world that nobody
    /// can take back any more because nobody knows it any more.
    public func signOut() async throws {
        struct Ignored: Decodable {}
        let _: Ignored = try await binding.notify("logout", mainContent: EmptyBody())
    }

    // ── Bodies that go out ────────────────────────────────────────────────────

    /// **English keys on purpose.** The writer translates German words into the server's;
    /// these here are already its own, and it leaves them alone. That is the shorter way
    /// than a vocabulary entry that is needed in one single place only.
    private struct SignInCredentials: Encodable, Sendable {
        let name: String
        let pin: String
        let device: String
    }

    private struct Redemption: Encodable, Sendable {
        let token: String
        let name: String
        let kind: String
    }

    private struct EmptyBody: Encodable, Sendable {}
}

/// What kind of device signs in.
///
/// **The app says so by itself.** The server lists the kind in the device list so that
/// one recognises a device one wants to sign out. Since the console rebuild
/// (2026-11-09) it knows `tv`, `phone`, `tablet` and `web`; before, phones and
/// tablets signed in as `web` and looked like a browser in that list.
public enum DeviceKind: String, Sendable, CaseIterable {
    /// A TV — is not assigned a profile and borrows one.
    case tv
    /// A phone that belongs to someone.
    case phone
    /// A tablet that belongs to someone.
    case tablet
    /// The console in a browser.
    case web
}

/// The profile picker as the server sends it.
public struct SignInChoice: Decodable, Sendable {
    /// **Fresh server, no person yet.** Then no path leads through the app; the console in
    /// the browser does that. The app says so and offers nothing that does not work.
    public let setupRequired: Bool
    public let people: [HouseholdPerson]

    enum CodingKeys: String, CodingKey {
        case setupRequired = "setup_required"
        case people = "people"
    }
}

/// What a sign-in yields.
public struct SignIn: Decodable, Sendable {
    public let trait: String
    /// **`nil` for a TV without a person.** A device that belongs to no person is paired
    /// and still not finished: it needs a borrowed profile with every request. A
    /// ``HouseholdPerson`` with nothing but empty fields instead of `nil` would have blurred
    /// that difference.
    public let person: HouseholdPerson?

    enum CodingKeys: String, CodingKey {
        case trait = "device_token"
        case person
    }
}

/// A person in the household.
///
/// **Called ``HouseholdPerson`` and not `Person`** (2026-09-12): ``Core`` already has a
/// ``Person`` — the cast of a film. `Features` sees both, and the compiler called the
/// name "ambiguous for type lookup" in three files, without any of these files having
/// anything to do with households.
public struct HouseholdPerson: Decodable, Sendable, Identifiable, Equatable, Hashable {
    public let id: String
    public let name: String
    /// A **label**, not a decision — see ``permissions``.
    public let role: String
    /// The colour of the profile circle, as `#RRGGBB`.
    public let color: String
    /// Missing in the profile picker: there the list is deliberately harmless.
    public let adult: Bool?
    /// What this person may do. Only ``Household/me()`` delivers it.
    public let permissions: AccessRights?
    /// The role the person holds (since the console rebuild, 2026-11-09: roles are data
    /// and can be created freely). ``role`` stays the derived old label —
    /// `admin`, `adult` or `child` — for older apps. Missing on older servers.
    public let roleID: String?
    /// Whether the person may open the console. Missing on older servers.
    public let console: Bool?

    enum CodingKeys: String, CodingKey {
        case id, name
        case role = "role"
        case color = "color"
        case adult = "adult"
        case permissions = "rights"
        case roleID = "role_id"
        case console = "console"
    }
}

/// What a person may do.
///
/// **Switch on rights, never on the role.** The role is a label, the rights are the
/// decision — roles can be added, rights remain. An `if role == "admin"` would be
/// wrong on the day a fourth role exists, and nobody would look for the error there.
///
/// **All optional with default `false`.** A right the server does not name is none —
/// and an older app must not fail on a new right.
public struct AccessRights: Decodable, Sendable, Equatable, Hashable {
    public let changeAccess: Bool
    public let changeSettings: Bool
    public let installPortals: Bool
    public let pairDevices: Bool
    public let togglePortals: Bool
    public let keepProgress: Bool
    public let adultViewing: Bool
    public let watch: Bool
    public let workshop: Bool
    /// May sign in further devices of their own (`own_devices`, since 2026-11-09).
    ///
    /// **`nil`, not `false`, when the server does not name it.** An older server knows
    /// no such right; there "missing" means "decide the old way", not "may not".
    /// See ``Household/TokenReconciliation``.
    public let ownDevices: Bool?
    /// May invite somebody into the household (`invite`, since 2026-11-09).
    public let invite: Bool

    enum CodingKeys: String, CodingKey {
        case changeAccess = "change_access"
        case changeSettings = "change_settings"
        case installPortals = "install_portals"
        case pairDevices = "pair_devices"
        case togglePortals = "switch_portals"
        case keepProgress = "track_progress"
        case adultViewing = "view_adult"
        case watch = "watch"
        case workshop = "workshop"
        case ownDevices = "own_devices"
        case invite = "invite"
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        func right(_ key: CodingKeys) -> Bool {
            ((try? values.decodeIfPresent(Bool.self, forKey: key)) ?? nil) ?? false
        }
        changeAccess = right(.changeAccess)
        changeSettings = right(.changeSettings)
        installPortals = right(.installPortals)
        pairDevices = right(.pairDevices)
        togglePortals = right(.togglePortals)
        keepProgress = right(.keepProgress)
        adultViewing = right(.adultViewing)
        watch = right(.watch)
        workshop = right(.workshop)
        ownDevices = (try? values.decodeIfPresent(Bool.self, forKey: .ownDevices)) ?? nil
        invite = right(.invite)
    }
}
