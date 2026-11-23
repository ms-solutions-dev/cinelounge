import Core
import Foundation
import ParentalControls
import ProfileKit
import Testing

@testable import Features

/// **The profile list that has taken the place of the account list** — AP41, row 5.
///
/// The tests of the predecessor ``AccountsModel`` move along, because their reasons move along:
/// whoever removes the signed-in profile must not leave behind an access token for an
/// account that no longer exists (AP22, 2026-09-11) — and whoever removes an account
/// that a second profile still has must not take it away from that profile.
///
/// **Against a Keychain and a compartment of their own**, as everywhere here: one
/// service name per test, so that it does not reach into that of the running device. The
/// host names carry hyphens — `scripts/strings.py` would otherwise read `vault.example` as a
/// language key.
@MainActor
@Suite("The profiles on this TV")
struct ProfileModelTests {

    private static let server = URL(string: "https://haus-a.example/")!

    private static func setup() -> (ProfileModel, SecureStore, InMemoryStore) {
        let sharedStore = SecureStore(service: "probe.\(UUID().uuidString)")
        let bucket = InMemoryStore()
        return (ProfileModel(keychain: sharedStore, store: bucket), sharedStore, bucket)
    }

    private static func credential(_ user: String) -> ServerCredentials {
        ServerCredentials(
            serverURL: server, userID: user, username: user,
            accessToken: "marke-\(user)")
    }

    // MARK: - Creating

    /// **A profile without access is a valid profile**, and that is the point of the
    /// row: until now a person came into being only through a sign-in.
    @Test("A profile is created without any access")
    func profileWithoutAccess() throws {
        let (model, _, bucket) = Self.setup()

        let identifier = try #require(model.create(name: "Eli", color: .moss, kind: .kind, avatar: nil))

        #expect(model.profile.count == 1)
        #expect(model.active == identifier)
        let read = try #require(ProfileBook.read(from: bucket).activeProfile)
        #expect(read.name == "Eli")
        #expect(read.kind == .kind)
        #expect(read.credentials.isEmpty)
    }

    /// **A new child locks what is not understood, explicitly** (strand G, 2026-09-25).
    ///
    /// Since a profile without an entry stays silent, on a device set to "off" the
    /// device switch alone would otherwise decide — and a freshly created child would lose the protection that
    /// until then the default gave when reading. An adult gets nothing.
    @Test("A new child profile explicitly gets \"Block unrecognized\"")
    func newChildLocksUnrecognized() throws {
        let (model, sharedStore, _) = Self.setup()
        UnrecognizedLock.write(false, in: sharedStore, forItem: nil)

        let kind = try #require(model.create(name: "Eli", color: .moss, kind: .kind, avatar: nil))
        let parents = try #require(
            model.create(name: "Max", color: .moss, kind: .adult, avatar: nil))

        #expect(UnrecognizedLock.own(from: sharedStore, forItem: kind.rawValue) == true)
        #expect(UnrecognizedLock.applicable(from: sharedStore, forItem: kind.rawValue))
        #expect(UnrecognizedLock.own(from: sharedStore, forItem: parents.rawValue) == nil)
        #expect(UnrecognizedLock.applicable(from: sharedStore, forItem: parents.rawValue) == false)
    }

    /// **A name made of spaces is not a name.** It would produce a circle without a letter
    /// in a list without names.
    @Test("An empty name creates nothing")
    func emptyName() {
        let (model, _, _) = Self.setup()

        #expect(model.create(name: "   ", color: .moss, kind: .adult, avatar: nil) == nil)
        #expect(model.profile.isEmpty)
    }

    @Test("The name is stripped of whitespace")
    func nameIsTrimmed() throws {
        let (model, _, _) = Self.setup()

        model.create(name: "  Max  ", color: .coral, kind: .adult, avatar: nil)

        #expect(model.profile.first?.name == "Max")
    }

    /// **The suggested color is the first that nobody has yet.** Two people in
    /// the same color are two circles that cannot be told apart from three meters away.
    @Test("The color suggestion avoids the ones already taken")
    func colorSuggestion() {
        let (model, _, _) = Self.setup()
        let first = model.nextColor

        model.create(name: "Max", color: first, kind: .adult, avatar: nil)

        #expect(model.nextColor != first)
    }

    /// **And from the seventh on it continues in rotation**, instead of suggesting none any more.
    @Test("If all six are taken, the suggestion starts over")
    func colorSuggestionWrapsAround() {
        let (model, _, _) = Self.setup()
        for tag in Profile.ColorTag.allCases {
            model.create(name: tag.rawValue, color: tag, kind: .adult, avatar: nil)
        }

        #expect(Profile.ColorTag.allCases.contains(model.nextColor))
    }

    // MARK: - Changing

    @Test("Name and color can be changed, the kind cannot")
    func change() throws {
        let (model, _, _) = Self.setup()
        let identifier = try #require(model.create(name: "Eli", color: .moss, kind: .kind, avatar: nil))

        model.update(identifier, name: "Eli K.", color: .lilac, avatar: nil)

        let profile = try #require(model.profile.first)
        #expect(profile.name == "Eli K.")
        #expect(profile.color == .lilac)
        // **The kind stays** — whatever could be set to "child" could also be
        // set back, and then nobody would have to circumvent parental controls.
        #expect(profile.kind == .kind)
    }

    // MARK: - Removing

    /// **The last profile must not go.** An empty book means "not yet taken over" for the takeover:
    /// the next start would rebuild exactly the profile that
    /// someone just removed.
    @Test("The last profile cannot be removed")
    func lastRemains() throws {
        let (model, _, _) = Self.setup()
        let identifier = try #require(model.create(name: "Max", color: .coral, kind: .adult, avatar: nil))

        #expect(!model.mayRemove(identifier))
        model.remove(identifier)
        #expect(model.profile.count == 1)
    }

    /// **The finding from AP22, in its new place.** An access token for an account
    /// that no longer exists is not a sign-in but a riddle.
    @Test("With an account's last profile, the account and the session go")
    func accountComesAlong() throws {
        try ProfilePointer.als(nil) {
            let (model, sharedStore, bucket) = Self.setup()
            try sharedStore.memorize(Self.credential("u1"))
            try sharedStore.saveCredentials(Self.credential("u1"))

            var ledger = ProfileBook()
            var max = Profile(name: "Max")
            max.create(Access(Self.credential("u1")))
            ledger.create(max)
            ledger.create(Profile(name: "Bleibt"))
            ledger.write(in: bucket)
            model.load()

            model.remove(max.identifier)

            #expect(sharedStore.allAccounts().isEmpty)
            #expect((try? sharedStore.loadCredentials()) == nil)
        }
    }

    /// **An account that a second profile still has stays.** Taking it away would mean
    /// closing the library to a bystander.
    @Test("A shared account survives removing a profile")
    func sharedAccountStays() throws {
        try ProfilePointer.als(nil) {
            let (model, sharedStore, bucket) = Self.setup()
            try sharedStore.memorize(Self.credential("u1"))

            var ledger = ProfileBook()
            for name in ["Max", "Eltern"] {
                var person = Profile(name: name)
                person.create(Access(Self.credential("u1")))
                ledger.create(person)
            }
            ledger.write(in: bucket)
            model.load()

            let first = try #require(model.profile.first?.identifier)
            model.remove(first)

            #expect(model.profile.count == 1)
            #expect(sharedStore.allAccounts().count == 1)
        }
    }

    /// **Whoever leaves takes their playback preferences along** (decision 4, 2026-09-24).
    /// Otherwise their compartments would remain as corpses in the Keychain — and the device value and
    /// the compartments of the others stay as they are.
    @Test("The profile's playback preferences go with it")
    func preferencesComeAlong() throws {
        try ProfilePointer.als(nil) {
            let (model, sharedStore, bucket) = Self.setup()
            var ledger = ProfileBook()
            for name in ["Max", "Eltern"] { ledger.create(Profile(name: name)) }
            ledger.write(in: bucket)
            model.load()
            let departing = try #require(model.profile.first?.identifier.rawValue)
            let remaining = try #require(model.profile.last?.identifier.rawValue)

            AudioPreference.writeLanguage("deu", in: sharedStore)
            AudioPreference.writeLanguage("jpn", in: ProfileStore(sharedStore, forItem: departing))
            SubtitleStyle.writeSize(.large, in: ProfileStore(sharedStore, forItem: departing))
            AudioPreference.writeLanguage("eng", in: ProfileStore(sharedStore, forItem: remaining))

            model.remove(Profile.Identifier(rawValue: departing))

            #expect(ProfileStore(sharedStore, forItem: departing).own().isEmpty)
            #expect(ProfileStore(sharedStore, forItem: remaining).own().count == 1)
            #expect(AudioPreference.load(from: sharedStore).language == "deu")
        }
    }
}
