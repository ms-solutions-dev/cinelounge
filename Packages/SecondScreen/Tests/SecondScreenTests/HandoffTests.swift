import Foundation
import Testing

@testable import SecondScreen

/// The handoff: what travels along, what does not, and what nobody can read afterwards.
@Suite("Handoff")
struct HandoffTests {

    /// An address from a **value** and not from a string literal.
    ///
    /// `#require(URL(string: "http://…"))` reports "redundant" in the release build: the
    /// compiler evaluates the literal and knows it is never `nil`. Through a parameter it
    /// cannot do that — and the check stays a check.
    /// An invented host name. **As a value and not as a literal in twelve places:** that way
    /// it does not look like a language key — and the checker that reports exactly that found
    /// a real bug on 2026-09-06 because a name from the real network stood in a check.
    static let target = "probe" + ".local"

    private static func address(_ text: String) throws -> URL {
        try #require(URL(string: text))
    }

    private static func bundles() throws -> SetupBundle {
        SetupBundle(
            jellyfin: .init(
                address: try Self.address("http://medienserver.beispiel:8096"),
                userID: "abc", username: "Probe", accessToken: "token",
                trusted: ["medienserver.beispiel": "AA:BB"]),
            channelLists: [
                .init(
                    identifier: "l1", name: "Anbieter",
                    address: try Self.address("http://anbieter.beispiel"),
                    user: "u", password: "p")
            ],
            bridge: try Self.address("http://bruecke.beispiel:8099"),
            omdbKey: "omdb", tmdbKey: "tmdb", malKey: "mal",
            language: "de", colorPattern: "kino",
            shelfOrder: ["resume", "live"],
            sports: ["football"], groupOrder: ["DE"], hiddenGroups: ["XX"],
            parentalControls: .init(
                active: true,
                pin: .init(digest: "a1b2", salt: "salt", changed: nil), ageLimit: 12))
    }

    // MARK: - The table as a check

    /// **The table from E5, as a commitment instead of an intention.**
    ///
    /// What is to travel along must have a field — and only a check verifies that it has one. A
    /// document that says "parental controls including PIN" while the bundle does not carry
    /// them goes unnoticed: the TV is then set up, just without a lock, and one notices on the
    /// day when it is too late.
    @Test("Everything that travels along per E5 has a field — and arrives")
    func allMigratorsArrive() throws {
        let outcome = try Self.bundles()
        let key = HandoffKey.fresh(target: Self.target)
        let packet = try HandoffPackage.seal(outcome, using: key)
        let arrived = try HandoffPackage.open(packet, using: key)

        #expect(arrived == outcome, "the bundle arrived unchanged")

        // Named individually so that a dropped field shows up here and does not just vanish in an
        // equals sign.
        #expect(arrived.jellyfin?.accessToken == "token")
        #expect(arrived.jellyfin?.trusted.isEmpty == false, "certificate trust")
        #expect(arrived.channelLists.first?.password == "p")
        #expect(arrived.bridge != nil)
        #expect(arrived.omdbKey == "omdb")
        #expect(arrived.tmdbKey == "tmdb")
        #expect(arrived.malKey == "mal")
        #expect(arrived.language == "de")
        #expect(arrived.colorPattern == "kino")
        #expect(arrived.shelfOrder == ["resume", "live"])
        #expect(arrived.sports == ["football"])
        #expect(arrived.groupOrder == ["DE"])
        #expect(arrived.hiddenGroups == ["XX"])
    }

    /// **The parental controls travel along, PIN included.** Without them the new device would
    /// be open at exactly the moment a child first gets it into their hands — and that is the
    /// moment they exist for.
    @Test("Parental controls travel along with PIN and age limit")
    func parentalControlsMigrate() throws {
        let key = HandoffKey.fresh(target: Self.target)
        let arrived = try HandoffPackage.open(
            try HandoffPackage.seal(try Self.bundles(), using: key),
            using: key)

        let backup = try #require(arrived.parentalControls)
        #expect(backup.active)
        #expect(backup.pin?.digest == "a1b2")
        #expect(
            backup.pin?.salt == "salt",
            "without the same salt the other device checked against a different value")
        #expect(backup.ageLimit == 12)
    }

    /// **What stays on the device has no field — and therefore cannot travel along.**
    ///
    /// Checked against the blueprint itself: the keys of the stored version are exactly those
    /// that are meant to travel. A new field for the downloads or the diagnostics ID would be
    /// noticed here before it ever transfers anything.
    @Test("Downloads, Wi-Fi rule and diagnostics identifier have no field")
    func nonMigratorsHaveNoField() throws {
        let data = try JSONEncoder().encode(try Self.bundles())
        let fields = try #require(
            try JSONSerialization.jsonObject(with: data) as? [String: Any])

        for forbidden in [
            "vorrat", "nurImWLAN", "wlan", "bildImBild", "drehung", "topShelf",
            "diagnosekennung", "fortschritt", "gesehen", "favoriten",
        ] {
            #expect(
                fields[forbidden] == nil,
                "\(forbidden) belongs to what stays on the device or is already there")
        }
    }

    /// **Progress and favorites do not travel at all — they are already there.** They sit on
    /// the media server's user account; once the access is transferred, they are too.
    @Test("The bundle carries no progress")
    func progressDoesNotMigrate() throws {
        let text =
            String(
                data: try JSONEncoder().encode(try Self.bundles()), encoding: .utf8) ?? ""
        #expect(!text.contains("progress"))
        #expect(!text.contains("position"))
    }

    // MARK: - Version

    /// **An older phone must not set up a newer device halfway.** Half set up is worse than
    /// not at all: the one state is noticed, the other is not.
    @Test("A bundle from the future is rejected")
    func futureIsRejected() throws {
        #expect(SetupBundle.acceptable(version: SetupBundle.version))
        #expect(!SetupBundle.acceptable(version: SetupBundle.version + 1))
        #expect(SetupBundle.acceptable(version: 0), "older bundles are understood fully")
    }

    @Test("A packet with an unknown version is rejected on opening")
    func unknownVersionIsRejected() throws {
        let key = HandoffKey.fresh(target: Self.target)
        let future = SetupBundle(version: SetupBundle.version + 1)
        let packet = try HandoffPackage.seal(future, using: key)

        #expect(throws: HandoffPackage.TestError.self) {
            try HandoffPackage.open(packet, using: key)
        }
    }

    // MARK: - The key

    /// Three minutes: long enough to fetch the phone, and short enough that a forgotten screen
    /// releases nothing any more.
    @Test("A code is valid for three minutes and not afterwards")
    func validity() {
        let now = Date()
        let key = HandoffKey.fresh(target: Self.target, now: now)

        #expect(key.applies(um: now))
        #expect(key.applies(um: now.addingTimeInterval(179)))
        #expect(!key.applies(um: now.addingTimeInterval(181)))
        #expect(key.remainingTime(um: now.addingTimeInterval(60)) == 120)
        #expect(key.remainingTime(um: now.addingTimeInterval(300)) == 0)
    }

    /// **A custom scheme and not an address.** `https://…` would be opened in a browser by
    /// every camera window, and there would be nothing there.
    @Test("The QR text can be read back in")
    func textThereAndBack() throws {
        let key = HandoffKey.fresh(target: Self.target)
        let read = try #require(HandoffKey.fromText(key.asText))

        #expect(read.secret == key.secret)
        #expect(read.target == Self.target)
    }

    /// A camera sees packaging, posters and Wi-Fi codes. Whoever accepts any of that reports a
    /// failure where nothing was even attempted.
    @Test("Foreign codes are not accepted in the first place")
    func foreignCodes() {
        #expect(HandoffKey.fromText("https://beispiel.invalid") == nil)
        #expect(HandoffKey.fromText("WIFI:S:Netz;T:WPA;P:geheim;;") == nil)
        #expect(HandoffKey.fromText("") == nil)
        #expect(
            HandoffKey.fromText("cinelounge-uebergabe://ziel?k=zukurz") == nil,
            "a key that is not 32 bytes long is not one")
    }

    // MARK: - Encryption

    /// A home network is not a safe place: a second device in it listens in.
    @Test("A foreign key does not open the packet")
    func foreignKeyDoesNotOpen() throws {
        let genuine = HandoffKey.fresh(target: Self.target)
        let foreign = HandoffKey.fresh(target: Self.target)
        let packet = try HandoffPackage.seal(try Self.bundles(), using: genuine)

        #expect(throws: HandoffPackage.TestError.unreadable) {
            try HandoffPackage.open(packet, using: foreign)
        }
    }

    /// What goes out here are access tokens and passwords.
    @Test("The encrypted packet contains no password in plain text")
    func noPlaintextInPackage() throws {
        let packet = try HandoffPackage.seal(
            try Self.bundles(), using: HandoffKey.fresh(target: Self.target))
        let raw = String(decoding: packet, as: UTF8.self)

        #expect(!raw.contains("token"))
        #expect(!raw.contains("1234"))
        #expect(!raw.contains("medienserver.beispiel"))
    }
}
