import Foundation
import Testing

@testable import PortalKit

/// Who lives in the household — **read from real responses.**
///
/// Recorded on 2026-09-12 against the home server.
@Suite("The household")
struct HouseholdTests {

    private func reader() -> JSONDecoder {
        let reader = JSONDecoder()
        reader.keyDecodingStrategy = .custom { path in
            DialectKey(PortalDialect.cinelounge.key(path: path))
        }
        return reader
    }

    private func recording(_ name: String) throws -> Data {
        let folder = try #require(Bundle.module.url(forResource: "Mitschnitte", withExtension: nil))
        return try Data(contentsOf: folder.appendingPathComponent("\(name).json"))
    }

    @Test("The profile picker")
    func choice() throws {
        let read = try reader().decode(SignInChoice.self, from: recording("login-who"))
        #expect(read.setupRequired == false)
        let person = try #require(read.people.first)
        #expect(person.id == "max")
        #expect(person.name == "Max")
        #expect(person.role == "admin")
        #expect(person.color == "#E2564A")
        // **The list is deliberately harmless**: no age, no rights, no PIN hint. Whoever intercepts it knows only
        // who lives here.
        #expect(person.adult == nil)
        #expect(person.permissions == nil)
    }

    @Test("Who am I, and what may I do")
    func me() throws {
        let person = try reader().decode(HouseholdPerson.self, from: recording("household-me"))
        #expect(person.adult == true)
        let permissions = try #require(person.permissions)
        #expect(permissions.watch)
        #expect(permissions.pairDevices)
        #expect(permissions.adultViewing)
        #expect(permissions.workshop)
    }

    /// **An older app must not fail on a new right**, and a right that the server does not name is none.
    @Test("Missing rights are not an error, but a no")
    func permissionsOptional() throws {
        let raw = Data(#"{"watch":true,"zeitreise":true}"#.utf8)
        let permissions = try reader().decode(AccessRights.self, from: raw)
        #expect(permissions.watch)
        #expect(permissions.pairDevices == false)
        #expect(permissions.workshop == false)
    }

    /// A paired TV belongs to no person — and that is not the same as a person with empty fields.
    @Test("A TV without a household person")
    func tvWithoutPerson() throws {
        let raw = Data(#"{"device_token":"abc","person":null}"#.utf8)
        let read = try reader().decode(SignIn.self, from: raw)
        #expect(read.trait == "abc")
        #expect(read.person == nil)
    }

    /// **The four words the server accepts** (`DEVICE_KINDS`, console rebuild 2026-11-09);
    /// anything else is refused with `household.bad_device_kind`.
    @Test("Four device kinds, exactly the server's words")
    func deviceKinds() {
        #expect(DeviceKind.allCases.map(\.rawValue) == ["tv", "phone", "tablet", "web"])
    }

    /// The answer of `/household/me` after the console rebuild — Sina in the adult role
    /// with the 18+ lock: derived label `child`, but her own devices allowed.
    @Test("Roles as data: the rights decide, the label stays for older apps")
    func meAfterTheRebuild() throws {
        let raw = Data(
            #"""
            {"id":"sina","name":"Sina","role":"child","color":"#9871C4","adult":false,
             "rights":{"change_access":false,"change_settings":false,"install_portals":false,
                       "invite":true,"own_devices":true,"pair_devices":false,
                       "switch_portals":false,"track_progress":true,"view_adult":false,
                       "watch":true,"workshop":false},
             "role_id":"adult","console":false}
            """#.utf8)
        let person = try reader().decode(HouseholdPerson.self, from: raw)
        #expect(person.role == "child")
        #expect(person.roleID == "adult")
        #expect(person.console == false)
        let rights = try #require(person.permissions)
        #expect(rights.ownDevices == true)
        #expect(rights.invite)
        #expect(rights.adultViewing == false)
    }

    /// **The contract, recorded against the real server** (`rolecheck/record.py`, 2026-11-09):
    /// if the server changes this answer, this test turns red instead of the app deciding
    /// silently on a missing right.
    @Test("Recorded: Sina in the locked adult role")
    func recordedLockedAdult() throws {
        let person = try reader().decode(HouseholdPerson.self, from: recording("household-me-roles"))
        #expect(person.role == "child")
        #expect(person.roleID == "adult")
        #expect(person.console == false)
        #expect(person.permissions?.ownDevices == true)
        #expect(person.permissions?.adultViewing == false)
    }

    /// **`own_devices` unknown is not `false`**: an older server does not name it, and the
    /// app then decides the old way (``Household/TokenReconciliation/holdsOwnMark(_:)``).
    @Test("A right the older server does not know stays open")
    func ownDevicesUnknown() throws {
        let raw = Data(#"{"watch":true}"#.utf8)
        let rights = try reader().decode(AccessRights.self, from: raw)
        #expect(rights.ownDevices == nil)
        #expect(rights.invite == false)
    }
}

/// The login against the **running** server.
///
/// **Off by default**, like the rest of the live series. Switch on with address and PIN:
///
///     CL_SERVER=http://<home-server>:8100 CL_PERSON=<person> CL_PIN=… swift test
///
/// **The PIN is not in this file, and that is no oversight.** Writing it here as an example would mean
/// putting an access token of the household into a repo — and an example that happens to work gets
/// copied.
///
/// It checks what a test double cannot — and among it two things that are not questions of form but
/// promises: that a wrong PIN and an unknown person give **the same** refusal, and that a borrowed
/// profile may not manage.
@Suite(
    "Sign-in against the running server",
    .enabled(if: ProcessInfo.processInfo.environment["CL_SERVER"] != nil)
)
struct HouseholdLiveTests {

    private var environment: [String: String] { ProcessInfo.processInfo.environment }
    private var server: URL { URL(string: environment["CL_SERVER"]!)! }
    private func household(trait: String? = nil, profile: String? = nil) -> Household {
        Household(
            binding: PortalBridge(
                basis: server, dialect: .cinelounge, trait: trait, profile: profile))
    }

    /// Logs in, runs the check and **logs out again in every case** — an attribute does not expire by itself,
    /// and a check that leaves one behind fills the household's device list.
    private func signedIn<T>(_ verify: (SignIn) async throws -> T) async throws -> T {
        let login = try await household().signIn(
            person: environment["CL_PERSON"] ?? "max",
            pin: environment["CL_PIN"] ?? "",
            device: "CineLounge check run")
        do {
            let result = try await verify(login)
            try? await household(trait: login.trait).signOut()
            return result
        } catch {
            try? await household(trait: login.trait).signOut()
            throw error
        }
    }

    @Test("The profile picker needs no credential")
    func choiceWithoutMarker() async throws {
        let choice = try await household().choice()
        #expect(!choice.people.isEmpty)
        for person in choice.people { print("   \(person.name) · \(person.role)") }
    }

    @Test("Sign in, get introduced, sign out")
    func signInAndOut() async throws {
        let trait = try await signedIn { login -> String in
            #expect(!login.trait.isEmpty)
            let me = try await household(trait: login.trait).me()
            #expect(me.permissions?.watch == true)
            print("   \(me.name) · \(me.role) · may watch")
            return login.trait
        }
        // After logging out the attribute is worthless — otherwise a valid access would remain in the world that
        // nobody can take back any more.
        await #expect(throws: PortalBridge.TestError.self) {
            _ = try await household(trait: trait).me()
        }
    }

    /// **The promise that must not be given away.** "Person does not exist" and "wrong PIN" must sound the
    /// same, otherwise the app tells a stranger which names to try next.
    @Test("Wrong PIN and unknown household person give the same rejection")
    func sameRejection() async throws {
        func rejection(person: String, pin: String) async -> String? {
            do {
                _ = try await household().signIn(person: person, pin: pin, device: "check run")
                return nil
            } catch let error as PortalBridge.TestError {
                return error.code
            } catch {
                return nil
            }
        }
        let wrongPIN = await rejection(person: environment["CL_PERSON"] ?? "max", pin: "000000")
        let noPerson = await rejection(person: "gibtesganzsichernicht", pin: "000000")
        #expect(wrongPIN == "auth.bad_credentials")
        #expect(wrongPIN == noPerson)
    }
}

/// **Roles as data, against a running server** (AP85, 2026-11-09).
///
/// Off by default. A driver sets up a fresh household — the adult role with the 18+
/// lock, one person in it, one child — and hands over an invitation and, for the child,
/// a pairing code assigned to it (children get no invitation link):
///
///     CL_SERVER=http://127.0.0.1:<port> CL_INVITE=… CL_INVITE_CHILD=… swift test --filter RolesLiveTests
///
/// It checks the promise the console rebuild made to the apps: a person in the locked
/// adult role is still labelled `child` for older apps, yet signs in a phone of her own
/// and gets a mark of her own — and a child does not.
@Suite(
    "Roles as data against the running server",
    .enabled(if: ProcessInfo.processInfo.environment["CL_INVITE"] != nil)
)
struct RolesLiveTests {

    private var environment: [String: String] { ProcessInfo.processInfo.environment }

    private func bridge(_ trait: String?) -> PortalBridge {
        PortalBridge(
            basis: URL(string: environment["CL_SERVER"]!)!, dialect: .cinelounge, trait: trait,
            profile: nil)
    }

    @Test("Locked adult role: labelled child, own phone, own mark, no 18+")
    func lockedAdultSignsInHerPhone() async throws {
        let login = try await Household(binding: bridge(nil)).redeem(
            password: environment["CL_INVITE"]!, name: "Live check phone", kind: .phone)
        let me = try await Household(binding: bridge(login.trait)).me()
        #expect(me.role == "child")
        #expect(me.roleID == "adult")
        #expect(me.adult == false)
        let rights = try #require(me.permissions)
        #expect(rights.ownDevices == true)
        #expect(rights.adultViewing == false)
        let own = try await Join(binding: bridge(login.trait)).ownToken(person: me.id)
        #expect(!own.isEmpty)
    }

    /// **The approval of AP85 #73:** a role from the server's list, the console apart — the
    /// new administrator keeps 18+. With the old word `admin` they would land in the
    /// locked adult role.
    @Test("Approve by role id with the console: an administrator with 18+")
    func approveByRoleWithConsole() async throws {
        guard let admin = environment["CL_ADMIN_TRAIT"], let pin = environment["CL_ADMIN_PIN"] else {
            return
        }
        let join = Join(binding: bridge(admin))
        let (requests, roles) = try await join.openRequestsWithRoles()
        let request = try #require(requests.first)
        let adultRole = try #require(roles?.first { $0.adult })
        let intake = try await join.approve(
            request.identifier, als: .chosen(id: adultRole.id, consolePin: "4711"), pin: pin,
            newName: nil)
        #expect(intake.person.roleID == adultRole.id)
        #expect(intake.person.console == true)
        #expect(intake.person.adult == true)
    }

    @Test("Child role: no own devices, and the server refuses the mark")
    func childGetsNoMark() async throws {
        let login = try await Household(binding: bridge(nil)).redeem(
            password: environment["CL_INVITE_CHILD"]!, name: "Live check child", kind: .tablet)
        let me = try await Household(binding: bridge(login.trait)).me()
        #expect(me.permissions?.ownDevices == false)
        do {
            _ = try await Join(binding: bridge(login.trait)).ownToken(person: me.id)
            Issue.record("the server issued a child a mark of its own")
        } catch let error as PortalBridge.TestError {
            #expect(error.code == "mark.not_for_children")
        }
    }
}
