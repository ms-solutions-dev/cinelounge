import CloudSync
import Core
import Foundation
import Testing

@testable import ProfileKit

/// The one-time code and the public mailbox — AP44, direction 2.
@Suite("Pairing via the public mailbox")
struct PairingTests {

    let now = Date(timeIntervalSince1970: 1_758_400_000)
    let link = URL(string: "https://www.icloud.com/share/0abc123")!

    /// **The code is the key, not the hint to it.** It lives in the
    /// public database; whoever knows it gets the sharing link and thus the zone.
    /// Six characters would be a billion — too little for a mailbox without a throttle.
    /// **Length costs nothing here**, because nobody types it in.
    @Test("A code is long enough that guessing is not worth it")
    func length() {
        let code = Pairing.code()
        #expect(code.count == 16)
        // Over 10^23 possibilities — versus a billion with six characters.
        let optionCount = pow(Double(Pairing.alphabet.count), Double(code.count))
        #expect(optionCount > 1e23)
    }

    /// **No `0`, `O`, `1`, `I`, `l`.** The code is shown as text under the QR — in case a camera
    /// refuses. An alphabet in which one can mistype turns a way out into a second
    /// dead end.
    @Test("The alphabet has no easily confused characters")
    func alphabet() {
        for character in "0O1Il" {
            #expect(!Pairing.alphabet.contains(character), "\(character)")
        }
        // And two codes in a row are not the same.
        #expect(Pairing.code() != Pairing.code())
    }

    @Test("Upper and lower case is the same code")
    func spelling() {
        #expect(Pairing.name(forItem: "abcd") == Pairing.name(forItem: "ABCD"))
        #expect(Pairing.store(code: "abcd", link: link, device: "x").name == "ABCD")
    }

    /// **The deadline is in the record so that the picker-up checks it.** CloudKit clears
    /// nothing by itself; an entry nobody picked up stays there. Whoever
    /// relied on putting it in to clean up would accept a link that has been
    /// lying in the mailbox for hours.
    @Test("After five minutes the entry no longer applies")
    func deadline() {
        let message = Pairing.store(code: "A", link: link, device: "Maxs iPhone", now: now)
        #expect(Pairing.broadcast(from: message, now: now.addingTimeInterval(299)) != nil)
        #expect(Pairing.broadcast(from: message, now: now.addingTimeInterval(301)) == nil)
    }

    /// The device name travels along — without it the TV would say "a profile has
    /// arrived", and nobody would know whether it was the expected one.
    @Test("The device name comes along")
    func deviceName() {
        let message = Pairing.store(code: "A", link: link, device: "Maxs iPhone", now: now)
        let broadcast = Pairing.broadcast(from: message, now: now)
        #expect(broadcast?.device == "Maxs iPhone")
        #expect(broadcast?.link == link)
    }

    // MARK: - What the QR carries

    /// **Without the role a device puts in where it should pick up.** Both directions
    /// use the same mailbox and the same code; the role alone says who
    /// puts in and who takes out.
    @Test("Round trip through the QR text")
    func roundTrip() {
        for role in Pairing.Role.allCases {
            let code = Pairing.code()
            let read = Pairing.read(Pairing.link(code: code, role: role).absoluteString)
            #expect(read?.code == code)
            #expect(read?.role == role)
        }
        // "I have the profile" means: The scanner picks up.
        #expect(Pairing.Role.give.scannerFetches)
        #expect(!Pairing.Role.search.scannerFetches)
    }

    /// **A camera sees packaging and Wi-Fi codes.** What does not fit is not an
    /// error but simply nothing for us.
    @Test("Foreign codes are skipped")
    func foreign() {
        for text in [
            "https://example.com", "WIFI:S=Heim;T=WPA;P=geheim;;", "",
            "cinelounge://etwasanderes?code=ABC", "1234567890",
        ] {
            #expect(Pairing.read(text) == nil, "\(text)")
        }
    }

    /// **A truncated code would be a mailbox that never answers** — and that
    /// would look to the viewer like "the other device is too slow". That is why
    /// the length is checked and not only that something is there.
    @Test("A half-captured code is not accepted")
    func truncated() {
        let code = Pairing.code()
        let full = Pairing.link(code: code, role: .give).absoluteString
        #expect(Pairing.read(full) != nil)

        let short = full.replacingOccurrences(of: code, with: String(code.dropLast(3)))
        #expect(Pairing.read(short) == nil)

        // And a code with characters that do not exist in the alphabet does not count either.
        let wrong = full.replacingOccurrences(of: code, with: String(repeating: "0", count: 16))
        #expect(Pairing.read(wrong) == nil)
    }

    /// Without a role no pairing — better nothing at all than the wrong path.
    @Test("A code without a role is not accepted")
    func withoutRole() {
        let code = Pairing.code()
        #expect(Pairing.read("cinelounge://koppeln?code=\(code)") == nil)
        #expect(Pairing.read("cinelounge://koppeln?code=\(code)&rolle=irgendwas") == nil)
    }

    /// Device finding 2026-09-30: The iPhone camera only opens registered schemes.
    @Test("New codes carry the camera scheme, old ones are still read")
    func cameraScheme() {
        let code = Pairing.code()
        let fresh = Pairing.link(code: code, role: .search)
        #expect(fresh.scheme == Pairing.cameraScheme)
        #expect(Pairing.read(fresh.absoluteString)?.role == .search)
        #expect(Pairing.read("cinelounge://koppeln?code=\(code)&rolle=gebe")?.code == code)
        #expect(Pairing.read("cinelounge-fremd://koppeln?code=\(code)&rolle=gebe") == nil)
    }

    @Test("An entry without a link yields no broadcast")
    func withoutLink() {
        let without = CloudRecord(
            contentType: Pairing.contentType, name: "A", fields: ["bis": .date(now.addingTimeInterval(60))])
        #expect(Pairing.broadcast(from: without, now: now) == nil)

        let withoutDeadline = CloudRecord(
            contentType: Pairing.contentType, name: "A", fields: ["link": .text(link.absoluteString)])
        #expect(Pairing.broadcast(from: withoutDeadline, now: now) == nil)
    }
}

/// The path across two devices — against the fake.
@Suite("Pairing between two accounts")
@MainActor
struct PairingPathTests {

    let server = MockCloud()
    let identifier = Profile.Identifier(rawValue: UUID().uuidString)

    func device(_ user: String) -> (ProfileCloud, InMemoryStore) {
        let store = InMemoryStore()
        let hub = CloudHub(
            service: server.credential(user), file: nil,
            device: DeviceDescription(identifier: user, name: user, model: "Test rig"))
        return (ProfileCloud(hub: hub, store: store, moveBundle: nil, automatic: false), store)
    }

    /// **The whole path:** The phone has the profile, the TV shows a code, the
    /// phone puts the sharing link under it, the TV picks it up and accepts.
    @Test("A profile moves from the phone to the TV")
    func fullPath() async throws {
        let (phone, ablagePhone) = device("max")
        var person = Profile(identifier: identifier, name: "Max", color: .turquoise)
        person.create(.channelList(identifier: "xtream|panel|max"))
        var ledger = ProfileBook.read(from: ablagePhone)
        ledger.create(person)
        ledger.write(in: ablagePhone)
        var state = StillLedger.read(from: ablagePhone, forItem: identifier.rawValue)
        state.record(.titlePosition(title: "film1", location: 4350, duration: 7200))
        state.write(in: ablagePhone, forItem: identifier.rawValue)

        // The TV generates a random code and shows it.
        let code = Pairing.code()

        // The phone scans and puts it in.
        try await phone.store(
            identifier, code: code, title: "Max", device: "Maxs iPhone")

        // The TV picks up — a **different** account.
        let (tv, ablageTV) = device("sina")
        let broadcast = try #require(try await tv.fetchPairing(code: code))
        #expect(broadcast.device == "Maxs iPhone")

        let arrived = try await tv.accept(broadcast.link)
        #expect(arrived?.name == "Max")
        #expect(ProfileBook.read(from: ablageTV).profile.map(\.name) == ["Max"])
        #expect(
            StillLedger.read(from: ablageTV, forItem: identifier.rawValue).state
                .titlePositions["film1"]?.location == 4350)
    }

    /// **Picked up means gone**, and before the acceptance is attempted: If that fails,
    /// the link is used up anyway. The other way round a valid key would stay in the
    /// public mailbox because a later step failed.
    @Test("A code is valid exactly once")
    func onlyOnce() async throws {
        let (phone, store) = device("max")
        var ledger = ProfileBook.read(from: store)
        ledger.create(Profile(identifier: identifier, name: "Max"))
        ledger.write(in: store)

        let code = Pairing.code()
        try await phone.store(identifier, code: code, title: "Max", device: "iPhone")

        let (tv, _) = device("sina")
        #expect(try await tv.fetchPairing(code: code) != nil)
        #expect(try await tv.fetchPairing(code: code) == nil)
    }

    /// As long as nobody has answered, the mailbox is empty — that is the normal case
    /// when polling and not an error.
    @Test("A code with nothing under it is not an error")
    func empty() async throws {
        let (tv, _) = device("sina")
        #expect(try await tv.fetchPairing(code: Pairing.code()) == nil)
    }

    /// An expired entry is discarded on pick-up — **and deleted anyway.**
    /// A key that is no use to anyone anymore has no business in the public mailbox.
    @Test("An expired entry yields nothing and does not stay around")
    func expired() async throws {
        let (phone, store) = device("max")
        var ledger = ProfileBook.read(from: store)
        ledger.create(Profile(identifier: identifier, name: "Max"))
        ledger.write(in: store)

        let code = Pairing.code()
        try await phone.store(identifier, code: code, title: "Max", device: "iPhone")

        let (tv, _) = device("sina")
        let later = Date().addingTimeInterval(Pairing.deadline + 60)
        #expect(try await tv.fetchPairing(code: code, now: later) == nil)
        // And it is gone, too.
        #expect(try await tv.fetchPairing(code: code) == nil)
    }
}
