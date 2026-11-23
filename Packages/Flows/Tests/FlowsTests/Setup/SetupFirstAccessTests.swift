import Core
import Foundation
import ParentalControls
import ProfileKit
import Testing

@_spi(Check) @testable import Flows

/// **AP88, finding 1: on a fresh device the first access went nowhere** — G1.
///
/// `SessionStore.signIn`, `PlaylistAccounts.accept` and `PortalAccess.enable` store their
/// access with ``ProfileKit/ProfileAccesses/create(_:in:)``, and that writes only into the
/// **active** profile. A fresh device had none: the book that
/// ``ProfileKit/ProfileSync/adopt(cloud:in:)`` wrote from iCloud deliberately has no active
/// profile, and a profile created next to it does not become active either
/// (``ProfileKit/ProfileBook/create(_:)`` activates only the first). The next cold start did
/// not repair it: the takeover from the Keychain steps aside as soon as a book exists.
///
/// **The setup core makes a profile active before the first source** (``SetupEffect/activate(_:)``).
/// These checks run the journey against the real book, the real switch and the real
/// `ProfileAccesses` — no stand-in, because the finding is the connection between them.
///
/// Counter-check: without `.activate` in `SetupMachine.activate(_:effects:)` both turn red.
@MainActor
@Suite("Setup — the first access lands in a profile")
struct SetupFirstAccessTests {

    nonisolated static let server = URL(string: "https://media.example:8096")!

    struct Device {
        let store = InMemoryStore()
        let keychain = SecureStore(service: "probe.\(UUID().uuidString)")
        let management: ProfileManagement

        @MainActor
        init() {
            management = ProfileManagement(
                keychain: keychain, store: store, cloud: { nil },
                startStore: UserDefaults(suiteName: "probe.\(UUID().uuidString)")!)
        }

        /// The shell's services where they touch the book — the rest stays empty.
        @MainActor
        func services(cloud: CloudAnswer) -> SetupServices {
            var services = SetupServices.mock(cloud: cloud)
            services.adoptCloudProfile = { [store] in ProfileSync.adopt(cloud: [$0], in: store) }
            services.activate = { [management] in management.switchTo(zu: $0).result != nil }
            services.storeJellyfin = { [store] credential in
                ProfileAccesses.create(
                    .jellyfin(
                        server: credential.serverURL, userID: credential.userID, username: credential.username
                    ),
                    in: store)
            }
            return services
        }

        @MainActor
        func journey(cloud: CloudAnswer) -> SetupJourney {
            SetupJourney(
                SetupMachine(steps: .tv, start: .fresh(known: []), isPinSet: false, noticeSeen: true),
                services: services(cloud: cloud))
        }

        var book: ProfileBook { ProfileBook.read(from: store) }
    }

    static func credential(_ user: String) -> ServerCredentials {
        ServerCredentials(serverURL: server, userID: "\(user)-id", username: user, accessToken: "token")
    }

    @Test("A profile chosen from iCloud: the first Jellyfin sign-in lands in it")
    func chosenFromCloud() async {
        await ProfilePointer.als(nil) { await chosenFromCloudRun() }
    }

    private func chosenFromCloudRun() async {
        let device = Device()
        let lea = Profile(name: "Lea")
        let tom = Profile(name: "Tom", color: .coral)
        let journey = device.journey(cloud: .profiles([SetupProfile(lea), SetupProfile(tom)]))
        journey.start()
        await journey.settle()
        ProfileSync.adopt(cloud: [lea, tom], in: device.store)
        #expect(device.book.active == nil, "precondition: iCloud sets nobody active")

        journey.send(.chose(lea.identifier))
        journey.send(.openSource(.jellyfin))
        journey.signedIn(Self.credential("lea"))

        #expect(device.book.profile.first { $0.identifier == lea.identifier }?.jellyfin?.displayName == "lea")
        #expect(ChildAccountList(store: device.store).all().isEmpty, "G4: the kind never hangs on the access")
        journey.stop()
    }

    @Test("A new profile next to an iCloud book: the first Jellyfin sign-in lands in it")
    func createdNextToCloudBook() async throws {
        try await ProfilePointer.als(nil) { try await createdNextToCloudBookRun() }
    }

    private func createdNextToCloudBookRun() async throws {
        let device = Device()
        let journey = device.journey(cloud: .noAnswer)
        journey.start()
        await journey.settle()
        ProfileSync.adopt(cloud: [Profile(name: "Lea"), Profile(name: "Tom")], in: device.store)
        device.management.load()

        journey.send(.choseNew)
        let draft = ProfileDraft(name: "Anna", color: .moss, kind: .adult, limit: nil, avatar: nil)
        let anna = try #require(device.management.save(draft, existing: nil))
        #expect(device.book.active == nil, "precondition: creating next to others activates nobody")
        let profile = try #require(device.book.profile.first { $0.identifier == anna })
        journey.send(.draftSaved(SetupProfile(profile)))
        journey.send(.openSource(.jellyfin))
        journey.signedIn(Self.credential("anna"))

        #expect(device.book.profile.first { $0.identifier == anna }?.jellyfin?.displayName == "anna")
        #expect(ChildAccountList(store: device.store).all().isEmpty, "G4: the kind never hangs on the access")
        journey.stop()
    }
}
