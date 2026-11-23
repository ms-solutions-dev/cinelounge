import Core
import Foundation

/// What state the sign-in is in — **the one question every screen asks first.**
///
/// **Why this is here and not in the two apps (2026-09-12):** the answer arises from
/// three requests and five refusals, and it is the same in both programs. Built twice
/// it would drift apart — and the case that gets lost first is the most inconspicuous
/// one: a token the server no longer knows. It looks like "not signed in" and is, only
/// the store still holds a string claiming everything is fine.
///
/// **No case means "something is wrong".** Every case carries what the screen should
/// show in response — that is the difference between a state and an error.
public enum SignInState: Sendable, Equatable {

    /// The old bridge. **No sign-in, and none is needed** — it knows no people. The apps
    /// show nothing here about profiles, PIN or pairing.
    case bridge

    /// A fresh server without a single person.
    ///
    /// **No path leads through the app here**, and that is intentional: creating the first
    /// person means setting the first PIN, and that belongs at a keyboard. The app says so
    /// and offers nothing that does not work.
    case setupRequired

    /// Nobody is signed in — the profile picker. Carries the list along, so that the screen
    /// does not have to ask a second time.
    case notSignedIn([HouseholdPerson])

    /// A paired device **that belongs to no person** — the living-room TV.
    ///
    /// Whoever sits in front of it chooses, **without a PIN**: on the living-room TV the
    /// age rating is an agreement within the household, not a lock. Whoever wants it
    /// differently gives the device a person; then this case goes away.
    ///
    /// The list comes from ``Household/choice()`` and **not** from `/household/people` — that
    /// path itself already requires a profile and answers `401` here.
    case profileRequired([HouseholdPerson])

    /// Signed in. `isBorrowed` means: the device belongs to no person, this profile is only
    /// chosen for now — and may watch, not manage.
    case signedIn(HouseholdPerson, isBorrowed: Bool)

    /// Nothing answers at this address.
    ///
    /// **Kept apart from "not set up"**, because the two demand different sentences: an
    /// empty address is information, a silent address a problem.
    case unreachable

    /// The app is too old for this server.
    ///
    /// **No fallback to the bridge.** An unknown service is the old bridge and is served; a
    /// CineLounge server with a contract version from the future is something else, and
    /// that is a sentence the viewer has to read.
    case appZuAlt(version: String)

    /// May this profile manage?
    ///
    /// **Switch on rights, never on the role** — and a borrowed profile never may, even if
    /// it is admin. The server rejects it with `403 auth.borrowed_profile`; the app should
    /// not offer the buttons beforehand.
    public func isAllowed(_ right: (AccessRights) -> Bool) -> Bool {
        guard case .signedIn(let person, let isBorrowed) = self, !isBorrowed,
            let permissions = person.permissions
        else { return false }
        return right(permissions)
    }

    /// Who is watching right now, when someone is watching.
    public var person: HouseholdPerson? {
        if case .signedIn(let person, _) = self { return person }
        return nil
    }

    /// Can browsing and playback happen at all in this state?
    public var carries: Bool {
        switch self {
        case .bridge: true
        case .signedIn: true
        case .setupRequired, .notSignedIn, .profileRequired, .unreachable, .appZuAlt: false
        }
    }
}

extension Household {

    /// Determine the state — **one request more than would be needed, and it pays off.**
    ///
    /// The flow is the order of the cases: first who answers, then whether the server
    /// knows people at all, then whether this device has one, then who it is.
    ///
    /// **A token the server no longer knows leads to the profile picker here and not to an
    /// error.** That is the case that falls through without this spot: something is in the
    /// store, so the app considers itself signed in, and every screen stays empty with
    /// `auth.required` in the diagnostics. Whoever was signed out should see the profile
    /// picker — that is the only useful answer to it.
    public static func state(
        basis: URL, trait: String?, profile: String? = nil, session: URLSession = .shared
    ) async -> SignInState {
        guard let (dialect, version) = try? await ServerVersion.probe(basis, session: session)
        else { return .unreachable }
        guard dialect == .cinelounge, let version else { return .bridge }
        guard version.recognized else { return .appZuAlt(version: version.version) }
        if version.setupRequired { return .setupRequired }

        func binding(_ trait: String?, _ profile: String?) -> PortalBridge {
            PortalBridge(
                basis: basis, dialect: .cinelounge, trait: trait, profile: profile,
                session: session)
        }
        func choice() async -> [HouseholdPerson] {
            (try? await Household(binding: binding(nil, nil)).choice().people) ?? []
        }

        guard let trait else { return .notSignedIn(await choice()) }

        do {
            let person = try await Household(binding: binding(trait, profile)).me()
            return .signedIn(person, isBorrowed: profile != nil)
        } catch let failure as PortalBridge.TestError {
            Diagnostics.verbose("Sign-in state: \(Diagnostics.explain(failure))")
            switch failure.code {
            case "auth.profile_required":
                // The device is paired and belongs to no person. Whoever sits in front of it
                // chooses — without a PIN.
                return .profileRequired(await choice())
            case "auth.required":
                // **The token is no longer valid**, or the remembered profile no longer exists. The
                // two cannot be told apart from the store, and both end in the same answer: choose
                // again.
                return .notSignedIn(await choice())
            default:
                return .unreachable
            }
        } catch {
            Diagnostics.defect(
                "Sign-in state unknown, portal service unreachable: \(Diagnostics.explain(error))",
                since: nil,
                area: "Anmeldung")
            return .unreachable
        }
    }
}
