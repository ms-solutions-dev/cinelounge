import Core
import Foundation
import JellyfinKit
import Testing

@testable import Flows

/// The server move — **one flow for both devices** (AP58 R7, finding E2). The rule itself
/// is checked by `ServerMigrationTests` in Core; this file covers what the flow makes of it.
@Suite("Server move flow")
@MainActor
struct ServerMigrationFlowTests {

    nonisolated private static let legacy = URL(string: "http://192.0.2.10:8096")!

    private func flow(
        identifier: String?, responds: JellyfinConnection.ServerInfo?, previous: URL? = legacy
    ) -> ServerMigrationFlow {
        ServerMigrationFlow(
            from: previous, serverID: identifier,
            keychain: SecureStore(service: "probe.\(UUID().uuidString)"),
            verify: { address in
                guard let responds else { throw JellyfinConnection.Failure.unreachable }
                return (address, responds)
            })
    }

    private static func info(_ id: String) -> JellyfinConnection.ServerInfo {
        .init(serverName: "vault", version: "10.11", id: id)
    }

    @Test("An address without scheme is read as at sign-in")
    func addressWithoutScheme() throws {
        let target = try #require(ServerMigrationFlow.target(from: " jellyfin.example:8096 "))
        #expect(target.scheme == "http")
        #expect(target.host() == "jellyfin.example")
        #expect(ServerMigrationFlow.target(from: "   ") == nil)
    }

    @Test("The same server may move at once")
    func sameOne() async {
        let flow = flow(identifier: "abc", responds: Self.info("abc"))
        flow.address = "media.example:8096"
        await flow.verify()
        #expect(flow.finding == .sameOne(name: "vault"))
        #expect(flow.isAdoptable)
        #expect(!flow.asksForConsent)
    }

    /// **Ask, don't guess** — and only the consent makes the move possible.
    @Test("Without identifier only after explicit consent")
    func withoutIdentifier() async {
        let flow = flow(identifier: nil, responds: Self.info("abc"))
        flow.address = "media.example"
        await flow.verify()
        #expect(flow.finding == .withoutIdentifier(name: "vault"))
        #expect(flow.asksForConsent)
        #expect(!flow.isAdoptable)

        flow.confirmWithoutID()
        #expect(flow.isAdoptable)
    }

    @Test("A different server does not move even with consent")
    func differentServer() async {
        let flow = flow(identifier: "abc", responds: Self.info("xyz"))
        flow.address = "media.example"
        await flow.verify()
        flow.confirmWithoutID()
        #expect(flow.finding == .other(name: "vault"))
        #expect(!flow.isAdoptable)
    }

    @Test("No answer, no address, no account — one reason each")
    func error() async {
        let still = flow(identifier: "abc", responds: nil)
        still.address = "media.example"
        await still.verify()
        #expect(still.finding == .error("error.unreachable"))

        let unreadable = flow(identifier: "abc", responds: Self.info("abc"))
        unreadable.address = "http://"
        await unreadable.verify()
        #expect(unreadable.finding == .error("error.invalidAddress"))

        let withoutAccount = flow(identifier: nil, responds: Self.info("abc"), previous: nil)
        withoutAccount.address = "media.example"
        await withoutAccount.verify()
        #expect(withoutAccount.finding == .error("accounts.move.noAccount"))
    }

    @Test("Back to the input keeps the address and withdraws the consent")
    func back() async {
        let flow = flow(identifier: nil, responds: Self.info("abc"))
        flow.address = "media.example"
        await flow.verify()
        flow.confirmWithoutID()

        flow.backToInput()
        #expect(flow.finding == .pending)
        #expect(flow.address == "media.example")
        #expect(!flow.isAdoptable)
    }
}
