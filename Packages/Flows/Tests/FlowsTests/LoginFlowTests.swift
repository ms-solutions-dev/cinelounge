import Core
import Foundation
@_spi(Check) import JellyfinKit
import Testing
import WordingKit

@_spi(Check) @testable import Flows

/// The sign-in at the media server — **the checks the TV never had** (AP58 R7,
/// finding E1). Until R7 the flow lived in the app target (`LoginModel`) without a single
/// check; the phone tested its own version in `SetupTests`. Both now run
/// through this, and the phone checks hit the same flow.
@Suite("Sign-in flow")
@MainActor
struct LoginFlowTests {

    nonisolated private static let home = ServerDiscovery.Found(
        id: "3c37", name: "testbox", address: URL(string: "http://192.0.2.10:8096")!)
    nonisolated private static let lab = ServerDiscovery.Found(
        id: "b", name: "Labor", address: URL(string: "http://jellyfin.example:8096")!)
    nonisolated private static let info = JellyfinConnection.ServerInfo(
        serverName: "testbox", version: "10.11.0", id: "3c37")
    nonisolated private static let credential = ServerCredentials(
        serverURL: URL(string: "http://192.0.2.10:8096")!, userID: "u", username: "alex",
        accessToken: "token")

    private func flow(
        _ services: LoginServices, searchMode: LoginFlow.SearchMode = .broadcastFirst,
        memory: (any KeyValueStore)? = nil,
        stored: @escaping @MainActor (ServerCredentials) -> Void = { _ in }
    ) -> LoginFlow {
        LoginFlow(
            services: services, searchMode: searchMode, deviceID: "probe",
            deviceName: "Apple TV", memory: memory, persist: stored)
    }

    // MARK: - Search

    /// Counts how often it was probed.
    private final class TallyCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var state = 0
        var value: Int { lock.withLock { state } }
        func tally() { lock.withLock { state += 1 } }
    }

    /// **The TV probes only if the broadcast stays empty** — one package against up to
    /// 254 requests.
    @Test("On the TV only an empty broadcast probes the network")
    func broadcastFirst() async {
        let counter = TallyCounter()
        var services = LoginServices.mock(broadcast: [Self.home])
        services.probe = { discoverySource in
            counter.tally()
            discoverySource(Self.lab)
        }
        let full = flow(services)
        await full.searchServers()
        #expect(full.discoveries.map(\.id) == ["3c37"])
        #expect(counter.value == 0, "the broadcast carried")

        services.broadcast = { [] }
        let empty = flow(services)
        await empty.searchServers()
        #expect(empty.discoveries.map(\.id) == ["b"])
        #expect(counter.value == 1)
    }

    /// **The phone does both**, and with the same identifier the address of the
    /// broadcast wins — it is the one the server itself considers correct.
    @Test("On the phone broadcast and probing both count, the broadcast wins")
    func bothAtOnce() async {
        let probedHouse = ServerDiscovery.Found(
            id: "3c37", name: "testbox", address: URL(string: "http://192.0.2.11:8096")!)
        let flow = flow(
            .mock(broadcast: [Self.home], probed: [probedHouse, Self.lab]),
            searchMode: .bothAtOnce)
        await flow.searchServers()
        #expect(flow.discoveries.map(\.id).sorted() == ["3c37", "b"])
        #expect(flow.discoveries.first { $0.id == "3c37" }?.address == Self.home.address)
    }

    /// **Ask first, then offer** (AP18): a find that this device cannot
    /// reach stays in the list — with a note.
    @Test("Unreachable discoveries stay and carry a note")
    func reachability() async {
        let flow = flow(
            .mock(broadcast: [Self.home, Self.lab], reached: { $0.host() != "jellyfin.example" }))
        await flow.searchServers()
        #expect(flow.verifiedDiscoveries.map(\.id) == ["3c37", "b"], "the order of the search")
        #expect(flow.verifiedDiscoveries.map(\.reachable) == [true, false])
        #expect(flow.unreachable == ["b"])
    }

    @Test("The same server appears only once in the list")
    func noServerTwice() {
        let flow = flow(.mock())
        flow.takeDiscovery(Self.home)
        flow.takeDiscovery(
            ServerDiscovery.Found(
                id: "3c37", name: "testbox", address: URL(string: "http://192.0.2.11:8096")!))
        #expect(flow.discoveries.count == 1)
    }

    // MARK: - Address

    @Test("An unreadable address stays on the server step and names the reason")
    func unreadableAddress() async {
        let flow = flow(.mock(server: Self.info))
        flow.address = "http://"
        await flow.checkAddress()
        #expect(flow.phase == .server)
        #expect(flow.error == "error.invalidAddress")
    }

    @Test("A server that does not answer leads back to the field")
    func noResponse() async {
        CertificatePrompt.shared.clear()
        let flow = flow(.mock(server: nil))
        flow.address = "vault"
        await flow.checkAddress()
        #expect(flow.phase == .server)
        #expect(flow.error == "error.unreachable")
    }

    /// **The resolved address is remembered** — on the TV typing is the most expensive
    /// operation, and after signing out it is back in the field.
    @Test("A responding server leads to the sign-in path and is remembered")
    func serverResponds() async {
        let memory = InMemoryStore()
        let flow = flow(
            .mock(server: Self.info, canUseCode: true), memory: memory)
        flow.address = "192.0.2.10:8096"
        await flow.checkAddress()

        #expect(flow.phase == .loginRoute)
        #expect(flow.serverReply?.serverName == "testbox")
        #expect(flow.canUseCode)
        #expect(flow.error == nil)
        let remembered = try? memory.value(for: LoginFlow.addressKey)
        #expect(remembered == "http://192.0.2.10:8096")
        #expect(self.flow(.mock(), memory: memory).address == remembered, "prefilled")
    }

    /// **The old location is cleared** (decision 2) — and an address already taken over is not
    /// overwritten.
    @Test("The address from UserDefaults moves once into the file store")
    func legacyAddress() throws {
        let name = "probe.\(UUID().uuidString)"
        let legacy = try #require(UserDefaults(suiteName: name))
        defer { legacy.removePersistentDomain(forName: name) }
        let fresh = InMemoryStore()
        legacy.set("http://media.example:8096", forKey: LoginFlow.addressKey)

        LoginFlow.adoptLegacyAddress(from: legacy, in: fresh)
        #expect(try fresh.value(for: LoginFlow.addressKey) == "http://media.example:8096")
        #expect(legacy.string(forKey: LoginFlow.addressKey) == nil)

        try fresh.set("http://neu.example", for: LoginFlow.addressKey)
        legacy.set("http://legacy.example", forKey: LoginFlow.addressKey)
        LoginFlow.adoptLegacyAddress(from: legacy, in: fresh)
        #expect(try fresh.value(for: LoginFlow.addressKey) == "http://neu.example")
    }

    // MARK: - Certificate

    @Test("An open certificate question is asked instead of reported as a network error")
    func certificatePrompt() {
        let flow = flow(.mock())
        let query = CertificatePrompt.Pending(
            host: "medienserver.beispiel",
            fingerprint: CertificateFingerprint(certificateData: Data("A".utf8)))
        CertificatePrompt.shared.location(query)
        defer { CertificatePrompt.shared.clear() }

        flow.takeCertificatePrompt(fallback: "error.unreachable")
        #expect(flow.certificatePrompt == query)
        #expect(flow.error == nil)

        flow.rejectCertificate()
        #expect(flow.certificatePrompt == nil)
        #expect(CertificatePrompt.shared.current == nil)
        #expect(flow.error == "cert.rejected")
    }

    /// **Confirming clears the question immediately** — the TV's confirmation prompt closes
    /// on the press and must find no open question afterwards, otherwise it would read the
    /// confirmation as a rejection.
    @Test("Confirming clears the question before checking again")
    func confirm() {
        let flow = flow(.mock())
        let query = CertificatePrompt.Pending(
            host: "probe.\(UUID().uuidString).beispiel",
            fingerprint: CertificateFingerprint(certificateData: Data("B".utf8)))
        CertificatePrompt.shared.location(query)
        defer { CertificatePrompt.shared.clear() }
        flow.takeCertificatePrompt(fallback: "error.unreachable")

        #expect(flow.confirmCertificate())
        #expect(flow.certificatePrompt == nil)
        #expect(!flow.confirmCertificate(), "nothing left open")
    }

    @Test("The sentence of a rejection is in the shared catalog")
    func rejectionInCatalog() {
        #expect(WordingKit.hasKey("cert.rejected"))
    }

    // MARK: - Sign in

    @Test("With password: the credential is stored, the password forgotten")
    func password() async {
        var stored: [ServerCredentials] = []
        let flow = flow(
            .mock(server: Self.info, credential: Self.credential), stored: { stored.append($0) })
        flow.address = "192.0.2.10:8096"
        await flow.checkAddress()
        flow.choosePassword()
        flow.user = "alex"
        flow.password = "secret"

        await flow.notify()

        #expect(flow.phase == .done(Self.credential))
        #expect(stored == [Self.credential])
        #expect(flow.password.isEmpty)
    }

    @Test("A wrong password stays on the password page and names the reason")
    func wrongPassword() async {
        var stored = 0
        let flow = flow(.mock(server: Self.info), stored: { _ in stored += 1 })
        flow.address = "vault"
        await flow.checkAddress()
        flow.choosePassword()
        flow.user = "alex"

        await flow.notify()

        #expect(flow.phase == .password)
        #expect(flow.error == "error.wrongCredentials")
        #expect(stored == 0)
    }

    /// **No button that learns only on pressing that it does not exist.**
    @Test("Without a code on the server it stays on the sign-in path")
    func codeOff() async {
        let flow = flow(.mock(server: Self.info, canUseCode: false))
        flow.address = "vault"
        await flow.checkAddress()
        #expect(!flow.canUseCode)

        await flow.startCode()
        #expect(flow.phase == .loginRoute)
        #expect(flow.error == "error.quickConnectDisabled")
    }

    @Test("An expired code leads back to the sign-in path")
    func codeExpired() async throws {
        var services = LoginServices.mock(server: Self.info, canUseCode: true)
        services.beginCode = { _, _, _ in QuickConnect.Session.forCheck }
        let flow = flow(services)
        flow.address = "vault"
        await flow.checkAddress()

        await flow.startCode()

        #expect(flow.phase == .loginRoute)
        #expect(flow.error == "error.quickConnectExpired")
    }

    // MARK: - Way back

    @Test("Going back moves one step, not to the beginning")
    func backPath() {
        let flow = flow(.mock())
        flow.setPhaseForTesting(.password)
        #expect(flow.back())
        #expect(flow.phase == .loginRoute)

        flow.setPhaseForTesting(.code(.forCheck))
        #expect(flow.back())
        #expect(flow.phase == .loginRoute)

        #expect(flow.back())
        #expect(flow.phase == .server)

        #expect(!flow.back(), "before the address step, going back belongs to the platform")
        #expect(flow.phase == .server)
    }

    /// **Back cancels a waiting code** — on the TV until R7 only
    /// "Cancel" did that; "Back" let it keep running, and it reported back minutes later
    /// with a finished access.
    @Test("Back cancels a running code")
    func backCancelsCode() async throws {
        var stored = 0
        var services = LoginServices.mock(server: Self.info, canUseCode: true)
        services.beginCode = { _, _, _ in QuickConnect.Session.forCheck }
        services.waitForCode = { _, _, _, _, _ in
            try await Task.sleep(for: .seconds(30))
            return Self.credential
        }
        let flow = flow(services, stored: { _ in stored += 1 })
        flow.address = "vault"
        await flow.checkAddress()

        let run = Task { await flow.startCode() }
        while flow.phase == .loginRoute { await Task.yield() }
        #expect(flow.phase == .code(.forCheck))

        flow.back()
        await run.value

        #expect(flow.phase == .loginRoute)
        #expect(stored == 0)
    }
}
