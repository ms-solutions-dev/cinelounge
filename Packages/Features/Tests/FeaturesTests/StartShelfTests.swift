import Core
import Foundation
import ParentalControls
import ProfileKit
import Testing

@testable import Features

/// **The shelf on the home screen per profile** (AP52, decision 13 of 2026-09-25).
///
/// Tested over the whole connection that links the app and the extension: profile book
/// and Keychain → ``ParentalControlsState`` → ``HomeShelf/context(credentials:state:profileStore:mode:)``
/// → the state as JSON as it lies in the shared entry → the filter that the extension
/// lays over every server response. The finding (K2) lay exactly in this chain: it knew
/// only the account.
@MainActor
@Suite("Top Shelf per profile")
struct StartShelfTests {

    /// One account for both profiles — the case from the finding.
    private static let account = ServerCredentials(
        serverURL: URL(string: "https://jellyfin.example")!, userID: "benutzer",
        username: "familie", accessToken: "marke")

    /// What the server delivers as the account's "Continue Watching", identifier and rating.
    private static let reply: [(identifier: String, approval: String?)] = [
        ("0a1b2c3d4e5f60718293a4b5c6d7e8f9", "FSK 16"),
        ("1b2c3d4e5f60718293a4b5c6d7e8f90a", "FSK 6"),
        ("2c3d4e5f60718293a4b5c6d7e8f90a1b", nil),
        ("animehub|serie|salt-compass", nil),
        ("liste#vod#4711", nil),
    ]

    private static let sixteen = "0a1b2c3d4e5f60718293a4b5c6d7e8f9"
    private static let portalTitle = "animehub|serie|salt-compass"

    /// Adult A and child B (limit 6) on a device with a PIN.
    @MainActor
    private struct Household {
        let sharedStore = InMemoryStore()
        let ledgerStore = InMemoryStore()
        let mode = ChildMode(store: UserDefaults(suiteName: UUID().uuidString)!)
        let adult = Profile(name: "Max", kind: .adult)
        let kind = Profile(name: "Selin", kind: .kind)

        init(withProfiles: Bool) {
            _ = Pin(store: sharedStore).set("1234")
            mode.set(false)
            AgeLimit.write(.from6, in: sharedStore, forItem: kind.identifier.rawValue)
            var ledger = ProfileBook()
            if withProfiles {
                ledger.create(adult)
                ledger.create(kind)
            }
            ledger.write(in: ledgerStore)
        }

        func switchTo(zu profile: Profile) {
            var ledger = ProfileBook.read(from: ledgerStore)
            ledger.switchTo(zu: profile.identifier)
            ledger.write(in: ledgerStore)
        }

        /// Freshly read — as after every switch in the app.
        func context(
            credentials: ServerCredentials?, startChoice: Profile.Identifier? = nil
        ) -> TopShelfContext? {
            let state = ParentalControlsState(
                store: sharedStore, childAccounts: ChildAccountList(store: InMemoryStore()),
                profileStore: ledgerStore, childMode: mode)
            return HomeShelf.context(
                credentials: credentials, state: state, profileStore: ledgerStore,
                mode: .resume, keychain: sharedStore, startChoice: startChoice)
        }
    }

    /// What the extension puts on the shelf from the response — via the state as it lies in the
    /// shared entry.
    private static func shelfIDs(from context: TopShelfContext?) throws -> [String] {
        let context = try #require(context)
        let stored = try JSONDecoder().decode(
            TopShelfContext.self, from: JSONEncoder().encode(context))
        return reply.filter { stored.filter.allows(identifier: $0.identifier, approval: $0.approval) }
            .map(\.identifier)
    }

    @Test("Child B sees neither the 16-rated title nor the portal title; A sees both after switching back")
    func childAndBack() throws {
        let household = Household(withProfiles: true)

        household.switchTo(zu: household.kind)
        let forB = try Self.shelfIDs(from: household.context(credentials: Self.account))
        #expect(!forB.contains(Self.sixteen))
        #expect(!forB.contains(Self.portalTitle))
        #expect(!forB.contains("liste#vod#4711"))
        #expect(
            forB == ["1b2c3d4e5f60718293a4b5c6d7e8f90a", "2c3d4e5f60718293a4b5c6d7e8f90a1b"])

        household.switchTo(zu: household.adult)
        let forA = try Self.shelfIDs(from: household.context(credentials: Self.account))
        #expect(forA.contains(Self.sixteen))
        #expect(forA.contains(Self.portalTitle))
        #expect(forA.count == Self.reply.count)
    }

    @Test("The snapshot names the active profile")
    func namesProfile() throws {
        let household = Household(withProfiles: true)
        household.switchTo(zu: household.kind)

        let context = try #require(household.context(credentials: Self.account))
        #expect(context.profile == household.kind.identifier.rawValue)
        #expect(context.filter.childMode)
        #expect(context.filter.limit == 6)
    }

    @Test("Without a profile the shelf is empty")
    func withoutProfile() {
        let household = Household(withProfiles: false)
        #expect(household.context(credentials: Self.account) == nil)
    }

    @Test("Without a media server the shelf is empty")
    func withoutMediaServer() {
        let household = Household(withProfiles: true)
        #expect(household.context(credentials: nil) == nil)
    }

    @Test("Unrecognized items for a child follow the profile's rule")
    func unrecognized() throws {
        let household = Household(withProfiles: true)
        household.switchTo(zu: household.kind)
        UnrecognizedLock.write(false, in: household.sharedStore, forItem: nil)
        UnrecognizedLock.write(true, in: household.sharedStore, forItem: household.kind.identifier.rawValue)

        let context = try #require(household.context(credentials: Self.account))
        #expect(!context.filter.allows(identifier: Self.sixteen, approval: "TV-MA"))

        UnrecognizedLock.write(false, in: household.sharedStore, forItem: household.kind.identifier.rawValue)
        let pending = try #require(household.context(credentials: Self.account))
        #expect(pending.filter.allows(identifier: Self.sixteen, approval: "TV-MA"))
    }

    // MARK: - Finding 5 (check 25.09.2026): profile PIN and start choice

    @Test("If the active profile has a profile PIN the shelf stays empty")
    func profilePinClears() {
        let household = Household(withProfiles: true)
        household.switchTo(zu: household.adult)
        #expect(household.context(credentials: Self.account) != nil)

        let lock = ProfilePIN(store: household.sharedStore, forItem: household.adult.identifier)
        _ = lock.set("4711", now: Date())
        #expect(lock.isSet)
        #expect(household.context(credentials: Self.account) == nil)
    }

    @Test("If the start choice points to another profile the shelf stays empty")
    func startChoiceClears() {
        let household = Household(withProfiles: true)
        household.switchTo(zu: household.adult)
        #expect(
            household.context(credentials: Self.account, startChoice: household.kind.identifier) == nil)
        #expect(
            household.context(credentials: Self.account, startChoice: household.adult.identifier)
                != nil)
    }

    /// F-045, 2026-09-29: After merges the start choice pointed to an identifier
    /// that no longer exists — the shelf stayed empty in every presentation.
    @Test("A start choice pointing to a vanished profile does not empty the shelf")
    func orphanedStartChoice() {
        let household = Household(withProfiles: true)
        household.switchTo(zu: household.adult)
        #expect(
            household.context(credentials: Self.account, startChoice: Profile.Identifier(rawValue: "weg"))
                != nil)
    }

    @Test("A snapshot without profile and filter cannot be read")
    func staleSnapshot() {
        let old = Data(
            #"{"serverURL":"https://jellyfin.example","userID":"u","accessToken":"t","mode":"resume"}"#
                .utf8)
        #expect((try? JSONDecoder().decode(TopShelfContext.self, from: old)) == nil)
    }
}
