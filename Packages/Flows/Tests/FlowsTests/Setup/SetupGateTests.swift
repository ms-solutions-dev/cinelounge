import Foundation
import ProfileKit
import Testing

@testable import Flows

/// When the first setup comes — **a calculation over book and device** (AP88 §1.5).
///
/// Counter-checks: with `profile.jellyfin != nil` in `SetupGate.canPlay` ``iCloudJellyfinIsNotUsable()``
/// turns red (G7); with "book empty" instead of "nothing plays" ``existingDeviceSeesNoSetup()`` (G10).
@Suite("Setup — the gate")
struct SetupGateTests {

    static let server = URL(string: "https://media.example:8096")!
    static let access = Access.jellyfin(server: server, userID: "lea-id", username: "lea")

    static func profile(_ name: String, _ credentials: [Access] = []) -> Profile {
        Profile(name: name, credentials: credentials)
    }

    @Test("A fresh device: setup from A1")
    func fresh() {
        #expect(SetupGate.entry(book: ProfileBook(), usable: .init()) == .fresh)
    }

    @Test("W9 An active profile and nothing usable: back into A4")
    func resume() {
        let anna = Self.profile("Anna")
        let book = ProfileBook(profile: [anna], active: anna.identifier)
        #expect(SetupGate.entry(book: book, usable: .init()) == .resume(anna.identifier))
    }

    @Test("W10 G7 A Jellyfin access from iCloud without a token does not count, a list does")
    func iCloudJellyfinIsNotUsable() {
        let lea = Self.profile("Lea", [Self.access, .channelList(identifier: "iptv")])
        let book = ProfileBook(profile: [lea], active: lea.identifier)
        #expect(SetupGate.entry(book: book, usable: .init()) == .resume(lea.identifier))
        #expect(SetupGate.entry(book: book, usable: .init(channelLists: ["iptv"])) == nil)
        #expect(
            SetupGate.entry(
                book: book, usable: .init(jellyfinAccounts: ["\(Self.server.absoluteString)|lea-id"])) == nil)
    }

    @Test("G10 An existing device with a list and nobody active lands in \"Who is watching?\", not in A2")
    func existingDeviceSeesNoSetup() {
        var book = ProfileBook(profile: [
            Self.profile("Lea", [.channelList(identifier: "iptv")]), Self.profile("Tom"),
        ])
        book.clearActive()
        #expect(SetupGate.entry(book: book, usable: .init(channelLists: ["iptv"])) == nil)
    }

    @Test("A child without sources of its own does not send the household back into the setup")
    func activeChildWithoutSources() {
        let lea = Self.profile("Lea", [.channelList(identifier: "iptv")])
        let mia = Profile(name: "Mia", kind: .kind)
        let book = ProfileBook(profile: [lea, mia], active: mia.identifier)
        #expect(SetupGate.entry(book: book, usable: .init(channelLists: ["iptv"])) == nil)
    }

    @Test("A CL-Server person counts only with a device trait here; a bare bridge counts as before")
    func clServerPerson() {
        let lea = Self.profile("Lea", [.portals(person: "lea")])
        let book = ProfileBook(profile: [lea], active: lea.identifier)
        #expect(SetupGate.entry(book: book, usable: .init()) == .resume(lea.identifier))
        #expect(SetupGate.entry(book: book, usable: .init(clServerProfiles: [lea.identifier])) == nil)

        let bridge = Self.profile("Zuhause", [.portals(person: nil)])
        #expect(SetupGate.entry(book: ProfileBook(profile: [bridge]), usable: .init()) == nil)
    }
}
