import Core
import Foundation
import ParentalControls
import SourceProbe
import Testing

@testable import FeaturesPhone

/// **Every profile switch on the phone goes through the same latch** — the finding of the
/// check evening of 2026-09-25.
///
/// In Settings → Accounts, ``AccountsView`` switched the session via
/// ``AccountsModel/switchTo(zu:)``, bypassing ``ShellModel/switchAccount(_:)``: without the door
/// of parental controls, without the profile PIN latch and
/// without the profile following the account. And "Add account" signed the new account in
/// immediately (``SecureStore/saveCredentials(_:)``), likewise bypassing the latch.
///
/// What is checked is **where** the session and the profile pointer may be switched — a
/// list of the permitted places with count —, and that the account list and the intake take the
/// path through the wrapper.
@MainActor
@Suite("Profile switches only through the latch")
struct ProfileSwitchPathsTests {

    /// All source lines without pure comment lines, per file (file name).
    ///
    /// **The name suffices as key**, because under the app target and `FeaturesPhone` no
    /// file name occurs twice.
    private static func rows() throws -> [(file: String, row: String)] {
        var result: [(String, String)] = []
        for location in [CodeLocation.phoneApp, .featuresPhone] {
            for file in try SourceText.files(in: location) {
                for row in file.content.split(separator: "\n")
                where !row.trimmingCharacters(in: .whitespaces).hasPrefix("//") {
                    result.append((file.name, String(row)))
                }
            }
        }
        return result
    }

    private static func code(_ name: String) throws -> String {
        try SourceText.read(name, in: .featuresPhone)
            .split(separator: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
    }

    /// **The permitted places, with count.** A new finding turns this check red;
    /// whoever adds one must justify why it does not bypass the latch.
    ///
    /// * `AccountsModel.swift` — the switch itself (``AccountsModel/switchTo(zu:)``) and the
    ///   intake of the **first** account, which has no predecessor yet.
    /// * `SetupState.swift` — setup stores the active profile's access.
    /// * The pointer at startup has been in the shared `Flows.ProfileStartup` since AP58 R2.
    /// * `ShellModel.swift` — ``ShellModel/adoptAccount(_:pin:)``: the shared
    ///   ``ProfileKit/ProfileSwitch`` (latch, ledger, session, header, pointer) and only without a profile
    ///   for the account the session alone. **Ledger and pointer are no longer switched on the phone by any
    ///   file of its own since AP58 R2** — the rebuild `Profilfolge` is gone.
    /// * `ShellModel.swift` — **"Who's watching?" since G3** via the shared
    ///   ``Flows/ProfileManagement/switchTo(zu:pin:)``: once without PIN (``ShellModel/switchProfile(_:)``
    ///   behind the door `accountSwitch`), once with PIN at the latch (``ShellModel/openLatch(_:)``).
    ///   No view switches by itself — not even the profile administration.
    static let isAllowed: [String: [String: Int]] = [
        "saveCredentials(": [
            "AccountsModel.swift": 1,
            "SetupState.swift": 1,
        ],
        "keychain.switchTo(": [
            "AccountsModel.swift": 1
        ],
        "ProfilePointer.show(": [:],
        ".switchTo(zu: account)": [
            "ShellModel.swift": 1
        ],
        "ProfileSwitch.episode(": [
            "ShellModel.swift": 1
        ],
        "ProfileSwitch.switchTo(": [:],
        "profile.switchTo(": [
            "ShellModel.swift": 2
        ],
        "administration.switchTo(": [:],
        "ledger.switchTo(zu:": [:],
    ]

    @Test("Session and profile pointer are switched only at the permitted places")
    func onlyAllowedPlaces() throws {
        let all = try Self.rows()
        for (pattern, locations) in Self.isAllowed {
            var found: [String: Int] = [:]
            for (file, row) in all where row.contains(pattern) {
                found[file, default: 0] += 1
            }
            #expect(found == locations, "\(pattern): \(found)")
        }
    }

    @Test("The account list switches through the shell and not by itself")
    func accountListViaShell() throws {
        let list = try Self.code("AccountsView.swift")
        #expect(!list.contains("model.switchTo("), "bypassing the latch")
        #expect(list.contains("select(account)"))
        let placeholder = try Self.code("TabPlaceholder.swift")
        let call = placeholder.ranges(of: "AccountsView(").map { placeholder[$0.lowerBound...].prefix(600) }
        #expect(call.count == 1)
        #expect(call.allSatisfy { $0.contains("select: { account in model.switchAccount(account) }") })
    }

    @Test("A new account is signed in through the shell")
    func intakeViaShell() throws {
        let placeholder = try Self.code("TabPlaceholder.swift")
        #expect(!placeholder.contains("model.accounts.accept("), "bypassing the latch")
        #expect(placeholder.contains("model.addAccount("))
        let model = try Self.code("ShellModel.swift")
        let recording = ChildProfilePhoneTests.bodyContent("public func addAccount(", in: model)
        #expect(recording.contains("accounts.accept("))
        #expect(recording.contains("switchAccount("))
    }

    private static func credential(_ user: String) throws -> ServerCredentials {
        ServerCredentials(
            serverURL: try #require(URL(string: AccountsTests.address)), userID: user,
            username: user.capitalized, accessToken: "marke-\(user)")
    }

    @Test("Adding a second account does not switch the session")
    func intakeDoesNotSwitch() throws {
        let load = SecureStore(service: "probe.\(UUID().uuidString)")
        let model = AccountsModel(
            keychain: load, childAccounts: ChildAccountList(store: InMemoryStore()))
        model.accept(try Self.credential("max"), asChild: false)
        let first = try #require(model.signedIn)
        #expect(first.user == "max", "the first account has no predecessor")

        model.accept(try Self.credential("selin"), asChild: true)
        #expect(model.accounts.count == 2)
        #expect(model.signedIn == first, "the session stays until the latch decides")
        #expect((try? load.loadCredentials())?.userID == "max")
        try? load.remove("server.accounts")
        try? load.clearCredentials()
    }
}
