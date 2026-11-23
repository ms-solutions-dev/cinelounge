import Core
import CryptoKit
import Foundation
import Network
import PlaylistKit
import Testing

@testable import SecondScreen

/// The red reproductions from the "setup" check of 2026-09-27 — as guards.
///
/// **Every test stands for one finding** (E1, E2, E6, E7, E8, E9, E12, E13 and the
/// re-pairing). All were red before the finding was fixed; the numbers are in the check
/// report `check/setup.md`.
@Suite("Check setup")
struct SetupCheckTests {

    /// E1: The 15 s deadline did not take effect when the Bonjour service could not be
    /// resolved.
    @Test("Handoff to a non-existent TV ends after the deadline")
    func timeoutAppliesWithoutService() async throws {
        let key = HandoffKey.fresh(target: "gibt-es-nicht-\(UUID().uuidString.prefix(8))")
        let end = OneShot<String>()
        let work = Task.detached {
            do {
                try await HandoffSender().send(SetupBundle(), using: key)
                end.give("succeeded")
            } catch {
                end.give("error: \(error)")
            }
        }
        // Guard: 25 s — well above the 15 s deadline.
        Task.detached {
            try? await Task.sleep(for: .seconds(25))
            end.give("HANGS")
        }
        let result = await end.value()
        work.cancel()
        #expect(result.contains("timedOut"), "Result: \(result)")
    }

    /// E1, second half: **Whoever cancels the handoff does not wait out the deadline.**
    @Test("A canceled send returns immediately")
    func cancellationTakesEffectImmediately() async throws {
        let key = HandoffKey.fresh(target: "gibt-es-nicht-\(UUID().uuidString.prefix(8))")
        let end = OneShot<String>()
        let work = Task.detached {
            do {
                try await HandoffSender().send(SetupBundle(), using: key)
                end.give("succeeded")
            } catch {
                end.give("error: \(error)")
            }
        }
        try? await Task.sleep(for: .milliseconds(500))
        work.cancel()
        Task.detached {
            try? await Task.sleep(for: .seconds(5))
            end.give("HANGS")
        }
        let result = await end.value()
        #expect(result.hasPrefix("error"), "Result: \(result)")
    }

    /// E12: The first arbitrary connection consumed the code.
    ///
    /// A device that sends nonsense (a port scanner, a Bonjour browser) must not reject the
    /// real transmission behind it — and the TV reports no failure for it.
    @Test("A foreign connection does not use up the code")
    func foreignConnectionConsumesNothing() async throws {
        let key = HandoffKey.fresh(target: "Living Room")
        let results = Collector<String>()
        let receiver = HandoffReceiver(key: key) { result in
            switch result {
            case .success: results.take("arrived")
            case .failure(let error): results.take("error: \(error)")
            }
            return nil
        }
        let connection = try await receiver.startOnLoopback()
        defer { receiver.stopListening() }

        let foreign = NWConnection(host: "127.0.0.1", port: connection, using: .tcp)
        defer { foreign.cancel() }
        foreign.stateUpdateHandler = { _ in }
        foreign.start(queue: .global())
        let sent = OneShot<Void>()
        foreign.send(
            content: Data("GET / HTTP/1.1\r\n\r\n".utf8),
            completion: .contentProcessed { _ in sent.give(()) })
        await sent.value()
        try? await Task.sleep(for: .milliseconds(300))

        let target = NWEndpoint.hostPort(host: "127.0.0.1", port: connection)
        try await HandoffSender().send(
            SetupBundle(language: "de"), using: key, on: target)
        #expect(await results.wait(to: 1) == ["arrived"])
    }

    /// Side finding: `pending`/`listeners` were written without a lock by the main thread and the
    /// network thread. **Many connections and a stop at the same time** — a finding with the
    /// Thread Sanitizer, a crash without it if it goes wrong.
    @Test("Stopping while connections arrive stays calm")
    func stoppingDuringArrival() async throws {
        let key = HandoffKey.fresh(target: "Living Room")
        let receiver = HandoffReceiver(key: key) { _ in nil }
        let connection = try await receiver.startOnLoopback()
        var connections: [NWConnection] = []
        for _ in 0..<8 {
            let raw = NWConnection(host: "127.0.0.1", port: connection, using: .tcp)
            raw.stateUpdateHandler = { _ in }
            raw.start(queue: .global())
            connections.append(raw)
        }
        try? await Task.sleep(for: .milliseconds(100))
        receiver.stopListening()
        for raw in connections { raw.cancel() }
    }
}

@Suite("Check setup – takeover")
@MainActor
struct TakeoverCheckTests {

    private func takeover(
        listen: PlaylistStore,
        trust: CertificateTrustStore = CertificateTrustStore(store: InMemoryStore()),
        secureStore: SecureStore? = nil
    ) -> Takeover {
        let name = "probe.\(UUID().uuidString)"
        return Takeover(
            keychain: secureStore ?? SecureStore(service: name), listen: listen, trust: trust,
            store: UserDefaults(suiteName: name) ?? .standard, shelfStore: InMemoryStore(),
            ledgerStore: InMemoryStore())
    }

    private func listen() -> PlaylistStore {
        PlaylistStore(store: InMemoryStore(), secrets: InMemoryStore(), ledger: InMemoryStore())
    }

    /// E2: An existing list lost its EPG address and switch.
    @Test("An existing list keeps EPG address and switch")
    func existingListStays() throws {
        let listen = listen()
        let server = URL(string: "http://anbieter.example:8080")!
        let epg = URL(string: "http://epg.example/guide.xml")!
        let available = Playlist(
            name: "My list", kind: .xtream(server: server, username: "u"), isEnabled: false,
            epgURL: epg)
        listen.add(available, password: "secret")

        takeover(listen: listen).matches(
            code: SetupBundle(channelLists: [
                .init(
                    identifier: available.id, name: "Liste vom Telefon", address: server, user: "u",
                    password: "secret")
            ]))

        let following = try #require(listen.playlist(withID: available.id))
        #expect(following.epgURL == epg, "EPG address lost: \(String(describing: following.epgURL))")
        #expect(following.isEnabled == false, "switched-off list was switched on")
        #expect(following.name == "My list", "the name on the TV stays")
        #expect(listen.playlists.count == 1)
    }

    /// E2, second half: **The EPG address travels along** — for a list that is new here.
    @Test("A new list brings its EPG address along")
    func newListBringsEPG() throws {
        let listen = listen()
        let server = URL(string: "http://anbieter.example:8080")!
        let epg = URL(string: "http://epg.example/guide.xml")!
        let identifier = ListKey.forItem(.xtream(server: server, username: "u"))

        takeover(listen: listen).matches(
            code: SetupBundle(channelLists: [
                .init(
                    identifier: identifier, name: "Vom Telefon", address: server, user: "u",
                    password: "secret", epg: epg)
            ]))

        let following = try #require(listen.playlist(withID: identifier))
        #expect(following.epgURL == epg)
        #expect(listen.password(for: identifier) == "secret")
    }

    /// E2: A bundle of an older version without an EPG field stays readable.
    @Test("A list credential without an EPG field can be read")
    func oldBundleWithoutEPG() throws {
        let legacy = Data(#"{"kennung":"k","name":"n","adresse":"http://a.example"}"#.utf8)
        let credential = try JSONDecoder().decode(SetupBundle.ListAccess.self, from: legacy)
        #expect(credential.epg == nil)
    }

    /// E6: A confirmed fingerprint was silently replaced.
    @Test("A confirmed fingerprint is not silently replaced")
    func fingerprintStays() {
        let trust = CertificateTrustStore(store: InMemoryStore())
        try? trust.trust(CertificateFingerprint(value: "AA:AA"), for: "jellyfin.example")
        takeover(listen: listen(), trust: trust).matches(
            code: SetupBundle(
                jellyfin: .init(
                    address: URL(string: "https://jellyfin.example")!, userID: "u1",
                    username: "Alex", accessToken: "token",
                    trusted: ["jellyfin.example": "BB:BB", "neu.example": "CC:CC"])))
        #expect(trust.fingerprint(for: "jellyfin.example") == CertificateFingerprint(value: "AA:AA"))
        #expect(
            trust.fingerprint(for: "neu.example") == CertificateFingerprint(value: "CC:CC"),
            "a not yet known machine is taken over")
    }
}

@Suite("Check setup – remote", .serialized)
@MainActor
struct RemoteCheckTests {

    /// E7: The state stream did not end when the TV disconnected.
    @Test("The state stream ends when the TV drops the connection")
    func streamEnds() async throws {
        let ledger = RemotePairingLedger(InMemoryStore())
        let receiver = RemoteReceiver(name: "Living Room", pairings: ledger, hint: "H")
        let connection = try await receiver.startOnLoopback()
        defer { receiver.stopListening() }
        let target = DeviceDiscovery.Device(
            name: "Living Room", endpoint: .hostPort(host: "127.0.0.1", port: connection))
        let key = HandoffKey.fresh(target: "Living Room")
        receiver.openPairing(key)
        let wire = OwnWire(credentials: RemoteCredentialStore(InMemoryStore()), phoneName: "real")
        try await wire.pair(using: key, target: target, credential: .fresh(name: "Living Room"))

        let stream = wire.states
        let end = OneShot<String>()
        Task.detached {
            for await _ in stream {}
            end.give("ended")
        }
        try? await Task.sleep(for: .milliseconds(300))
        let phone = try #require(ledger.phones.first)
        receiver.forget(phone: phone.id)

        Task.detached {
            try? await Task.sleep(for: .seconds(5))
            end.give("HANGS")
        }
        let result = await end.value()
        let connected = await wire.connected
        #expect(!connected, "wire still reports connected")
        #expect(result == "ended", "Stream: \(result)")
    }

    /// E7, reverse direction: **After reconnecting, a new stream flows.** A stream that ends
    /// on disconnect must not silence the wire forever.
    @Test("After reconnecting, states arrive again")
    func newStreamAfterReconnect() async throws {
        let ledger = RemotePairingLedger(InMemoryStore())
        let receiver = RemoteReceiver(name: "Living Room", pairings: ledger, hint: "H")
        let connection = try await receiver.startOnLoopback()
        defer { receiver.stopListening() }
        let target = DeviceDiscovery.Device(
            name: "Living Room", endpoint: .hostPort(host: "127.0.0.1", port: connection))
        let key = HandoffKey.fresh(target: "Living Room")
        receiver.openPairing(key)
        let wire = OwnWire(credentials: RemoteCredentialStore(InMemoryStore()), phoneName: "real")
        try await wire.pair(using: key, target: target, credential: .fresh(name: "Living Room"))
        await wire.disconnect()

        try await wire.connect(using: target)
        var progressStates = wire.states.makeAsyncIterator()
        #expect(await progressStates.next() == .idle, "the confirmation arrives in the new stream")
    }

    /// Side finding re-pairing: every re-pairing created a new phone ID, and on the TV
    /// "iPhone", "iPhone", … then stood up to the maximum number.
    @Test("Re-pairing with the same TV replaces the entry")
    func repairingReplaces() async throws {
        let ledger = RemotePairingLedger(InMemoryStore())
        let receiver = RemoteReceiver(name: "Living Room", pairings: ledger, hint: "H")
        let connection = try await receiver.startOnLoopback()
        defer { receiver.stopListening() }
        let target = DeviceDiscovery.Device(
            name: "Living Room", endpoint: .hostPort(host: "127.0.0.1", port: connection))
        let store = RemoteCredentialStore(InMemoryStore())
        let wire = OwnWire(credentials: store, phoneName: "iPhone")

        for _ in 0..<2 {
            let key = HandoffKey.fresh(target: "Living Room")
            receiver.openPairing(key)
            try await wire.pair(using: key, target: target, credential: .fresh(name: "Living Room"))
            await wire.disconnect()
        }

        #expect(ledger.phones.count == 1, "Entries: \(ledger.phones.map(\.name))")
        #expect(store.all.count == 1)
        try await wire.connect(using: target)
        #expect(await wire.connected, "the new key holds")
    }

    /// E13: The confirmation frame and `notify()` could overtake each other — the phone then
    /// read n=2 before n=1 and disconnected a sign-in that had just succeeded.
    ///
    /// **The gap is not left to chance but set up:** the hook
    /// ``RemoteReceiver/afterUnlock`` runs exactly where, before the fix, the confirmation
    /// had not yet gone out, and reports a state at that moment.
    @Test("A state between sign-in and confirmation does not disconnect the phone")
    func messagesDuringLogin() async throws {
        let ledger = RemotePairingLedger(InMemoryStore())
        let receiver = RemoteReceiver(name: "Living Room", pairings: ledger, hint: "H")
        let connection = try await receiver.startOnLoopback()
        defer { receiver.stopListening() }
        let target = DeviceDiscovery.Device(
            name: "Living Room", endpoint: .hostPort(host: "127.0.0.1", port: connection))
        let key = HandoffKey.fresh(target: "Living Room")
        receiver.openPairing(key)
        let wire = OwnWire(credentials: RemoteCredentialStore(InMemoryStore()), phoneName: "real")
        try await wire.pair(using: key, target: target, credential: .fresh(name: "Living Room"))
        await wire.disconnect()

        let reported = Collector<Bool>()
        receiver.afterUnlock = { [weak receiver] in
            guard let receiver, receiver.phonePresent, reported.all.isEmpty else { return }
            reported.take(true)
            receiver.notify(StateMirror(title: "Film", location: 1, isRunning: true))
        }
        try await wire.connect(using: target)
        try? await Task.sleep(for: .milliseconds(300))
        #expect(reported.all == [true], "the hook did not report")
        #expect(await wire.connected, "the sign-in broke")
        await #expect(throws: Never.self, "the sign-in broke") {
            try await wire.send(.jumpBy(10))
        }
    }
}

@Suite("Check setup – takeover on a set-up device")
@MainActor
struct TakeoverSessionCheckTests {

    /// E8: The running session was switched to the phone's account.
    @Test("An existing session stays, whoever is currently watching stays untouched")
    func sessionStays() throws {
        let name = "probe.\(UUID().uuidString)"
        let secureStore = SecureStore(service: name)
        let kind = ServerCredentials(
            serverURL: URL(string: "http://media.example:8096")!, userID: "kind", username: "Child",
            accessToken: "token-kind")
        try secureStore.memorize(kind)
        try secureStore.saveCredentials(kind)

        let takeover = Takeover(
            keychain: secureStore,
            listen: PlaylistStore(store: InMemoryStore(), secrets: InMemoryStore(), ledger: InMemoryStore()),
            trust: CertificateTrustStore(store: InMemoryStore()),
            store: UserDefaults(suiteName: name) ?? .standard, shelfStore: InMemoryStore(),
            ledgerStore: InMemoryStore())
        takeover.matches(
            code: SetupBundle(
                jellyfin: .init(
                    address: URL(string: "http://media.example:8096")!, userID: "parent",
                    username: "Parent", accessToken: "token-parent")))

        #expect((try? secureStore.loadCredentials())?.userID == "kind")
        #expect(
            secureStore.allAccounts().contains { $0.userID == "parent" },
            "the fetched account is in the list — switching happens via the profile latch")
    }

    /// E8, reverse direction: **On first setup the bundle is the session.**
    @Test("Without a session the bundle becomes the sign-in")
    func initialSetupSignsIn() throws {
        let name = "probe.\(UUID().uuidString)"
        let secureStore = SecureStore(service: name)
        Takeover(
            keychain: secureStore,
            listen: PlaylistStore(store: InMemoryStore(), secrets: InMemoryStore(), ledger: InMemoryStore()),
            trust: CertificateTrustStore(store: InMemoryStore()),
            store: UserDefaults(suiteName: name) ?? .standard, shelfStore: InMemoryStore(),
            ledgerStore: InMemoryStore()
        ).matches(
            code: SetupBundle(
                jellyfin: .init(
                    address: URL(string: "http://media.example:8096")!, userID: "parent",
                    username: "Parent", accessToken: "token-parent")))
        #expect((try? secureStore.loadCredentials())?.userID == "parent")
    }
}

/// E9: Ohne laufenden Spieler wurde Getipptes verworfen.
extension RemotePairingTests {

    @Test("The remote keyboard arrives even without a player")
    func tapWithoutPlayer() {
        var inField = ""
        RemoteKeyboard.signIn(text: "") { inField = $0 }
        defer { RemoteKeyboard.signOut() }

        #expect(RemoteSwitch.derive(.tap("Bolto"), playerPresent: false) == .done)
        #expect(inField == "Bolto")
        #expect(RemoteSwitch.derive(.jumpBy(30), playerPresent: false) == .discarded)
        #expect(RemoteSwitch.derive(.jumpBy(30), playerPresent: true) == .player)
        #expect(
            RemoteSwitch.derive(.spieleTitel(identifier: "k", origin: "h", from: 3), playerPresent: false)
                == .title(identifier: "k", origin: "h", from: 3))
    }
}
