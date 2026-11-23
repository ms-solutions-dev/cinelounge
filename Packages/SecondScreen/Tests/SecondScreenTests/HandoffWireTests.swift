import Foundation
import Testing

@testable import SecondScreen

/// The wire between phone and TV.
///
/// **What a check can prove here and what it cannot.** Playing both ends in the same
/// program run does not check the **agreement** — that is what the schedule says, and it is
/// true: whoever reads frame and receipt on both sides from the same file checks
/// themselves. What it does prove is the place where a failure would stay **silent**: a
/// header that is not yet complete at exactly four bytes; a packet that arrives in two
/// pieces; an expired key that is acknowledged as "unreadable" and thereby loses the one
/// piece of advice that helps.
@Suite("The handoff wire")
struct HandoffWireTests {

    // MARK: - The frame

    @Test("Four bytes of length, then the content")
    func frameCarriesItsLength() {
        let content = Data([9, 8, 7])
        let packet = HandoffWire.Frame.pack(content)

        #expect(packet.count == 7)
        #expect(Array(packet.prefix(4)) == [0, 0, 0, 3], "big-endian")
        #expect(HandoffWire.Frame.length(from: packet) == 3)
    }

    @Test("A half header yields no length yet")
    func halfHeaderIsNotALength() {
        // **The case that would hang silently.** Whoever returns a number here reads three bytes
        // as the length and then waits for a packet that never has that size.
        #expect(HandoffWire.Frame.length(from: Data([0, 0, 0])) == nil)
        #expect(HandoffWire.Frame.length(from: Data()) == nil)
    }

    @Test("An impossible length is not believed")
    func impossibleLengthIsRejected() {
        // Without a limit, a wrongly read header would allocate four gigabytes of memory — and
        // that is not an attack, but a slipped byte.
        #expect(HandoffWire.Frame.length(from: Data([255, 255, 255, 255])) == nil)
        #expect(HandoffWire.Frame.length(from: Data([0, 0, 0, 0])) == nil, "empty is not a packet")
        let justBarely = HandoffWire.Frame.pack(
            Data(repeating: 0, count: HandoffWire.Frame.maxLength))
        #expect(HandoffWire.Frame.length(from: justBarely) != nil)
    }

    @Test("A real bundle survives frame and encryption")
    func bundleSurvivesTheJourney() throws {
        let key = HandoffKey.fresh(target: "CineLounge-A7F3")
        let bundles = SetupBundle(
            jellyfin: .init(
                address: URL(string: "https://jellyfin.example")!, userID: "u1",
                username: "Alex", accessToken: "secret",
                trusted: ["jellyfin.example": "ab:cd"]),
            channelLists: [
                .init(
                    identifier: "xtream1", name: "iptvhost",
                    address: URL(string: "http://anbieter.example")!, user: "b",
                    password: "k")
            ],
            language: "de")

        let packet = try HandoffPackage.seal(bundles, using: key)
        let onTheWire = HandoffWire.Frame.pack(packet)

        let length = try #require(HandoffWire.Frame.length(from: onTheWire))
        let outgoing = onTheWire.dropFirst(4).prefix(length)
        let back = try HandoffPackage.open(Data(outgoing), using: key)

        #expect(back == bundles)
    }

    @Test("A bundle grows beyond a single read chunk")
    func bundleIsLargerThanOneChunk() throws {
        // **The reasoning behind the frame, recalculated.** Three channel lists with passwords and
        // a media server with fingerprints are not a short-message format; whoever reads without a
        // length field gets half a bundle on the first full one.
        let listen = (1...3).map {
            SetupBundle.ListAccess(
                identifier: "liste\($0)", name: String(repeating: "Anbieter \($0) ", count: 20),
                address: URL(string: "http://anbieter\($0).example/get.php")!,
                user: String(repeating: "b", count: 64),
                password: String(repeating: "k", count: 64))
        }
        let bundles = SetupBundle(channelLists: listen)
        let packet = try HandoffPackage.seal(
            bundles, using: .fresh(target: "CineLounge-Test"))

        #expect(packet.count > 512, "\(packet.count) bytes — more than one pull with a small buffer")
    }

    // MARK: - The receipt

    @Test("Every receipt has exactly one byte and keeps it")
    func receiptsStayFixed() {
        // **The numbers are the contract.** Whoever reorders them silently turns "accepted" into
        // "unreadable" — on a device that still has the old version.
        #expect(HandoffWire.Receipt.accepted.rawValue == 0)
        #expect(HandoffWire.Receipt.unreadable.rawValue == 1)
        #expect(HandoffWire.Receipt.wrongVersion.rawValue == 2)
        #expect(HandoffWire.Receipt.expired.rawValue == 3)
        #expect(HandoffWire.Receipt(rawValue: 9) == nil, "what we do not know does not count")
    }

    @Test("An expired key is not sent in the first place")
    func expiredKeyDoesNotGoOut() async {
        // The TV would reject it anyway; sending it regardless would mean waiting fifteen seconds
        // for an answer that is already certain.
        let legacy = HandoffKey(
            secret: Data(repeating: 7, count: 32), target: "CineLounge-Alt",
            issuedAt: Date(timeIntervalSinceNow: -HandoffKey.validity - 10))
        #expect(!legacy.applies())

        await #expect(throws: HandoffWire.TestError.rejected(.expired)) {
            try await HandoffSender().send(SetupBundle(), using: legacy)
        }
    }
}
