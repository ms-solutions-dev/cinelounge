import CloudSync
import Core
import Foundation
import Testing

@testable import ProfileKit

/// The flow behind the pairing screens — against the fake, with two accounts.
@Suite("The model behind the pairing screens")
@MainActor
struct PairingModelTests {

    let server = MockCloud()
    let identifier = Profile.Identifier(rawValue: UUID().uuidString)
    let now = Date(timeIntervalSince1970: 1_758_400_000)

    func device(_ user: String) -> (ProfileCloud, InMemoryStore) {
        let store = InMemoryStore()
        let hub = CloudHub(
            service: server.credential(user), file: nil,
            device: DeviceDescription(identifier: user, name: user, model: "Test rig"))
        return (ProfileCloud(hub: hub, store: store, moveBundle: nil, automatic: false), store)
    }

    /// A phone with a profile in it.
    func withProfile(_ user: String, name: String = "Max") -> ProfileCloud {
        let (cloud, store) = device(user)
        var ledger = ProfileBook.read(from: store)
        ledger.create(Profile(identifier: identifier, name: name, color: .turquoise))
        ledger.write(in: store)
        return cloud
    }

    // MARK: - Direction 1: this device gives

    /// **The whole path of the first direction**, as in StoryShelf (on-device test 2026-09-28):
    /// The TV shows the share link in the QR, the phone scans and accepts directly.
    @Test("Giving: the QR carries the link, the phone accepts directly")
    func giveAway() async throws {
        let tv = PairingModel(cloud: withProfile("sina"), device: "Wohnzimmer")
        await tv.give(identifier, title: "Max", now: now)

        #expect(tv.role == .give)
        let qr = try #require(tv.qr)
        #expect(ProfileLink(qr.absoluteString) != nil, "the QR is a profile link")
        #expect(tv.code == "", "no code to type in")

        // As long as the deadline runs, the QR stays.
        await tv.step(now: now)
        #expect(tv.state.waiting)

        // The phone scans the QR — a **different** account.
        let (phone, store) = device("max")
        let model = PairingModel(cloud: phone, device: "Maxs iPhone")
        #expect(await model.scanned(qr.absoluteString, offering: nil, now: now))
        #expect(model.state == .arrived(profile: "Max", device: "Wohnzimmer"))
        #expect(ProfileBook.read(from: store).profile.map(\.name) == ["Max"])

        // **The camera keeps reporting the same code** (CKError 20, 2026-09-28): After
        // arrival another scan changes nothing.
        #expect(await model.scanned(qr.absoluteString, offering: nil, now: now))
        #expect(model.state == .arrived(profile: "Max", device: "Wohnzimmer"))
    }

    // MARK: - Direction 2: this device searches

    /// **The whole path of the second direction.** The TV shows an empty
    /// mailbox, the phone puts something in, the TV accepts.
    @Test("Search, drop in, accept")
    func search() async throws {
        let (tv, ablageTV) = device("sina")
        let seeker = PairingModel(cloud: tv, device: "Wohnzimmer")
        seeker.search(now: now)
        #expect(seeker.role == .search)

        // Nothing there — that is the normal case and not an error.
        await seeker.step(now: now)
        #expect(seeker.state.waiting)

        let phone = PairingModel(cloud: withProfile("max"), device: "Maxs iPhone")
        #expect(
            await phone.scanned(
                seeker.qr!.absoluteString, offering: (identifier, "Max"), now: now))
        #expect(phone.state == .pickedUp)

        await seeker.step(now: now)
        #expect(seeker.state == .arrived(profile: "Max", device: "Maxs iPhone"))
        #expect(ProfileBook.read(from: ablageTV).profile.map(\.name) == ["Max"])
    }

    /// **A phone without a profile cannot hand one out** — and says so instead of standing still.
    @Test("Whoever has nothing to give gets a message")
    func nothingToGiveAway() async throws {
        let (tv, _) = device("sina")
        let seeker = PairingModel(cloud: tv, device: "Wohnzimmer")
        seeker.search(now: now)

        let (phone, _) = device("max")
        let model = PairingModel(cloud: phone, device: "iPhone")
        #expect(await model.scanned(seeker.qr!.absoluteString, offering: nil, now: now))
        #expect(model.state == .error(PairingModel.noProfile))
    }

    // MARK: - Die Frist

    /// **First look, then at the clock.** A profile that arrived in the last second
    /// would otherwise lose against the clock — and the viewer would see "expired"
    /// although everything was deposited.
    @Test("What arrives in the last second still counts")
    func tight() async throws {
        let (tv, _) = device("sina")
        let seeker = PairingModel(cloud: tv, device: "Wohnzimmer")
        seeker.search(now: now)

        let phone = PairingModel(cloud: withProfile("max"), device: "iPhone")
        await phone.scanned(seeker.qr!.absoluteString, offering: (identifier, "Max"), now: now)

        // Exactly on the deadline — and arrived anyway.
        await seeker.step(now: now.addingTimeInterval(Pairing.deadline))
        #expect(seeker.state == .arrived(profile: "Max", device: "iPhone"))
    }

    @Test("After five minutes without an answer the code has expired")
    func expired() async throws {
        let (tv, _) = device("sina")
        let seeker = PairingModel(cloud: tv, device: "Wohnzimmer")
        seeker.search(now: now)
        await seeker.step(now: now.addingTimeInterval(Pairing.deadline + 1))
        #expect(seeker.state == .expired)
    }

    /// **On-device test 2026-09-28:** "has arrived", but no profile in the list. Even a
    /// zone that yields nothing yet produces a profile — name from the QR.
    @Test("Accepting creates a profile even if the zone is still empty")
    func acceptedWithoutState() async throws {
        let (tv, fernsehablage) = device("sina")
        var ledger = ProfileBook.read(from: fernsehablage)
        let empty = Profile(name: "admin")
        ledger.create(empty)
        ledger.write(in: fernsehablage)
        let link = try await tv.split(empty.identifier, title: "admin")

        let (phone, store) = device("max")
        let profile = try await phone.accept(link, fallbackName: "admin")
        #expect(profile?.identifier == empty.identifier)
        #expect(ProfileBook.read(from: store).profile.map(\.identifier).contains(empty.identifier))
    }

    /// **Handing out puts nothing into the public database** (2026-09-28): The link is in the
    /// QR. After the deadline the screen has expired, and there is nothing to clean up.
    @Test("Giving puts nothing in the mailbox, and the deadline applies")
    func giveAwayWithoutMailbox() async throws {
        let cloud = withProfile("max")
        let giver = PairingModel(cloud: cloud, device: "iPhone")
        await giver.give(identifier, title: "Max", now: now)
        #expect(giver.profileLink != nil)

        await giver.step(now: now.addingTimeInterval(Pairing.deadline + 1))
        #expect(giver.state == .expired)
    }

    /// **Whoever closes the screen has changed their mind** — and the key
    /// should not lie open on the network for another five minutes.
    @Test("Closing empties the mailbox")
    func close() async throws {
        let cloud = withProfile("max")
        let giver = PairingModel(cloud: cloud, device: "iPhone")
        await giver.give(identifier, title: "Max", now: now)
        let code = try #require(giver.code)

        await giver.close()
        #expect(try await cloud.pairingExists(code: code) == false)
    }

    /// **Also when searching — and that is the case one overlooks.** Whoever searches has
    /// put nothing there themselves; but under **their** code something may long since lie that
    /// they never picked up. Between the deposit over there and the next look here
    /// there are up to three seconds; whoever closes then would leave someone else's sharing link
    /// lying open on the network.
    @Test("Closing empties the mailbox while searching too")
    func closeWhileSeeking() async throws {
        let (tv, ablageTV) = device("sina")
        let seeker = PairingModel(cloud: tv, device: "Wohnzimmer")
        seeker.search(now: now)
        let code = try #require(seeker.code)

        // The phone puts it in — and the TV closes before it has looked.
        let phone = PairingModel(cloud: withProfile("max"), device: "iPhone")
        await phone.scanned(seeker.qr!.absoluteString, offering: (identifier, "Max"), now: now)
        await seeker.close()

        #expect(try await tv.pairingExists(code: code) == false)
        // And it has accepted nothing — closed is closed.
        #expect(ProfileBook.read(from: ablageTV).profile.isEmpty)
    }

    // MARK: - Was die Kamera sonst noch sieht

    /// **A camera sees packaging and Wi-Fi codes.** What does not fit lets the
    /// scanner keep running and does not touch the state.
    @Test("Foreign codes let the scanner keep running")
    func foreign() async throws {
        let model = PairingModel(cloud: withProfile("max"), device: "iPhone")
        for text in ["https://example.com", "WIFI:S=Heim;T=WPA;P=geheim;;", ""] {
            #expect(await model.scanned(text, offering: nil) == false, "\(text)")
            #expect(model.state == .isRunning)
            #expect(model.role == nil)
        }
    }

    /// **A code whose deadline has passed looks to the scanner like an empty
    /// mailbox** — and that is exactly what it is. "Expired" is the honest
    /// answer; "still loading" would be a screen that never finishes.
    @Test("An empty mailbox when scanning means: expired")
    func scannedEmpty() async throws {
        let model = PairingModel(cloud: withProfile("max"), device: "iPhone")
        let link = Pairing.link(code: Pairing.code(), role: .give)
        #expect(await model.scanned(link.absoluteString, offering: nil))
        #expect(model.state == .expired)
    }

    // MARK: - Ohne Konto

    /// **Without an iCloud account the screen says what the cause is.** A pairing screen
    /// that simply waits without an account is the screen where someone
    /// stands for five minutes and then considers the app broken.
    @Test("Without an account the reason is shown")
    func withoutAccount() async throws {
        let store = InMemoryStore()
        let hub = CloudHub(
            service: nil, file: nil,
            device: DeviceDescription(identifier: "x", name: "x", model: "Test rig"))
        let cloud = ProfileCloud(hub: hub, store: store, moveBundle: nil, automatic: false)
        let model = PairingModel(cloud: cloud, device: "iPhone")

        await model.give(identifier, title: "Max", now: now)
        #expect(model.state == .error("pairing.noAccount"))
    }
}
