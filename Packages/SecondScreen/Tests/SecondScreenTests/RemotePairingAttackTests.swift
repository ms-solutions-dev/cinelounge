import Core
import CryptoKit
import Foundation
import Network
import Testing

@testable import SecondScreen

/// **The attacks of the counter-check of strand D, reversed** (2026-09-25).
///
/// The check reproduced them on a copy; there, "green" meant the attack succeeds. Here
/// green means it fails. Every test was red at the state of `a8a4326`.
@Suite("Attacks on the pairing", .serialized)
@MainActor
struct RemotePairingAttackTests {

    /// Pairs a phone and returns the book and the credential.
    static func paired() throws -> (RemotePairingLedger, RemoteCredential) {
        let ledger = RemotePairingLedger(InMemoryStore())
        let key = HandoffKey.fresh(target: "Living Room")
        let credential = RemoteCredential.fresh(name: "Living Room")
        var g = RemotePairingTests.Conversation(
            phone: RemoteLogin(credential: credential, pairing: key, phoneName: "real"))
        try g.begin(ledger: ledger, pairing: key)
        #expect(g.confirmed)
        return (ledger, credential)
    }

    static func signedIn(_ actions: [RemoteSession.Action]) -> Bool {
        actions.contains { if case .signedIn = $0 { true } else { false } }
    }

    // MARK: - 1.1 Takeover without a key

    @Test("1.1: A sign-in with an eavesdropped identifier does not sign in without proof")
    func takeoverWithoutKey() throws {
        let (ledger, credential) = try Self.paired()
        var tv = RemoteSession()
        _ = tv.greeting(hint: "")
        let login = try JSONEncoder().encode(
            RemotePairing.SignIn(phone: credential.phone, nonce: RemotePairing.random()))
        let actions = tv.take(login, ledger: ledger, pairing: nil, status: .idle)
        #expect(!Self.signedIn(actions))
        #expect(!tv.signedIn)
        #expect(tv.phone == nil)

        // And what the attacker sends afterwards as "proof" does not hold.
        let following = tv.take(RemotePairing.random(64), ledger: ledger, pairing: nil, status: .idle)
        #expect(!Self.signedIn(following))
        #expect(following.contains { if case .close = $0 { true } else { false } })
    }

    @Test("1.1: Over the wire a plain-text sign-in does not kick out the real phone")
    func takeoverOverWire() async throws {
        let ledger = RemotePairingLedger(InMemoryStore())
        let receiver = RemoteReceiver(name: "Living Room", pairings: ledger, hint: "Hinweis")
        let arrived = Collector<Command>()
        receiver.perform = { arrived.take($0) }
        let connection = try await receiver.startOnLoopback()
        defer { receiver.stopListening() }
        let target = DeviceDiscovery.Device(
            name: "Living Room", endpoint: .hostPort(host: "127.0.0.1", port: connection))

        let key = HandoffKey.fresh(target: "Living Room")
        receiver.openPairing(key)
        let wire = OwnWire(credentials: RemoteCredentialStore(InMemoryStore()), phoneName: "real")
        let credential = RemoteCredential.fresh(name: "Living Room")
        try await wire.pair(using: key, target: target, credential: credential)
        #expect(await wire.connected)
        var progressStates = wire.states.makeAsyncIterator()
        _ = await progressStates.next()

        let raw = NWConnection(host: "127.0.0.1", port: connection, using: .tcp)
        defer { raw.cancel() }
        raw.stateUpdateHandler = { _ in }
        raw.start(queue: .global())
        let login = try JSONEncoder().encode(
            RemotePairing.SignIn(phone: credential.phone, nonce: RemotePairing.random()))
        let sent = OneShot<Void>()
        raw.send(
            content: HandoffWire.Frame.pack(login),
            completion: .contentProcessed { _ in sent.give(()) })
        await sent.value()
        try? await Task.sleep(for: .milliseconds(400))

        try await wire.send(.jumpBy(10))
        #expect(await arrived.wait(to: 1) == [.jumpBy(10)], "the real phone keeps operating")
        #expect(await wire.connected)
        #expect(receiver.phonePresent)
    }

    // MARK: - 1.2 Rejection

    @Test("1.2: An injected plain-text rejection is only a hint")
    func plaintextRejection() throws {
        let (_, credential) = try Self.paired()
        var phone = RemoteLogin(credential: credential, phoneName: "real")
        _ = try phone.take(RemoteSession().greeting(hint: ""))
        let rejection = try JSONEncoder().encode(
            RemotePairing.Rejection(rejection: RemotePairing.Rejection.word, evidence: RemotePairing.random())
        )
        #expect(throws: RemotePairing.TestError.dismissed) { try phone.take(rejection) }
    }

    /// **Proves only whoever knew the key:** if the TV has forgotten the phone, the wire
    /// deletes the credential; if a stranger cancels, it stays.
    @Test("1.2: Only a proven rejection deletes the credential on the phone")
    func provenRejectionDeletes() async throws {
        let ledger = RemotePairingLedger(InMemoryStore())
        let receiver = RemoteReceiver(name: "Living Room", pairings: ledger, hint: "H")
        let connection = try await receiver.startOnLoopback()
        defer { receiver.stopListening() }
        let target = DeviceDiscovery.Device(
            name: "Living Room", endpoint: .hostPort(host: "127.0.0.1", port: connection))

        // A credential that this TV has never seen: unproven, stays.
        let store = RemoteCredentialStore(InMemoryStore())
        store.create(RemoteCredential.fresh(name: "Living Room").bound(on: ledger.tvIdentifier))
        let foreign = OwnWire(credentials: store)
        await #expect(throws: RemotePairing.TestError.dismissed) { try await foreign.connect(using: target) }
        #expect(store.all.count == 1)

        // A phone that was paired, then forgotten: proven, deleted.
        let key = HandoffKey.fresh(target: "Living Room")
        receiver.openPairing(key)
        let own = RemoteCredentialStore(InMemoryStore())
        let wire = OwnWire(credentials: own)
        try await wire.pair(using: key, target: target, credential: .fresh(name: "Living Room"))
        let paired = try #require(own.all.first)
        await wire.disconnect()
        receiver.forget(phone: paired.phone)
        await #expect(throws: RemotePairing.TestError.unpaired) { try await wire.connect(using: target) }
        #expect(own.all.isEmpty)
    }

    // MARK: - 1.3 Replay against the phone

    @Test("1.3: With a repeated challenge the phone accepts no old state")
    func tvReplay() throws {
        let (ledger, credential) = try Self.paired()
        var g1 = RemotePairingTests.Conversation(
            phone: RemoteLogin(credential: credential, phoneName: "real"))
        try g1.begin(ledger: ledger, pairing: nil, state: StateMirror(title: "Alt"))
        let challenge = g1.tv.challenge
        let oldStateRaw = g1.tv.wrap(StateMirror(title: "Alt-2"))
        let oldState = try #require(oldStateRaw)

        var phone = RemoteLogin(credential: credential, phoneName: "real")
        let greeting = try JSONEncoder().encode(
            RemotePairing.Greeting(
                title: "",
                pairing: RemotePairing.Offer(
                    version: RemotePairing.version, challenge: challenge, tv: "")))
        _ = try phone.take(greeting)
        #expect(throws: RemotePairing.TestError.unreadable) { try phone.take(oldState) }
    }

    @Test("1.3: A captured sign-in with proof does not hold against a new challenge")
    func phoneReplay() throws {
        let (ledger, credential) = try Self.paired()
        var g1 = RemotePairingTests.Conversation(
            phone: RemoteLogin(credential: credential, phoneName: "real"))
        var recording: [Data] = []
        for event in try g1.phone.take(g1.tv.greeting(hint: "")) {
            if case .send(let frame) = event { recording.append(frame) }
        }
        #expect(recording.count == 2)
        var fresh = RemoteSession()
        var actions: [RemoteSession.Action] = []
        for frame in recording {
            actions += fresh.take(frame, ledger: ledger, pairing: nil, status: .idle)
        }
        #expect(!Self.signedIn(actions))
        #expect(!fresh.signedIn)
    }

    // MARK: - Reflection

    @Test("A TV frame sent back to the TV closes")
    func reflection() throws {
        let (ledger, credential) = try Self.paired()
        var g = RemotePairingTests.Conversation(phone: RemoteLogin(credential: credential, phoneName: "real"))
        try g.begin(ledger: ledger, pairing: nil)
        let fromTVRaw = g.tv.wrap(.idle)
        let fromTV = try #require(fromTVRaw)
        g.send(fromTV, ledger: ledger)
        #expect(g.closed)
        #expect(g.commands.isEmpty)
    }

    // MARK: - 1.5 No oracle

    @Test("1.5: The rejection does not reveal whether an identifier is paired")
    func noOracle() throws {
        let (ledger, credential) = try Self.paired()
        /// Sign-in and a wrong proof — and what the TV says after **every** frame.
        func answers(_ identifier: String, pairing: Data?) throws -> [[String]] {
            var s = RemoteSession()
            var a = RemotePairing.SignIn(phone: identifier, nonce: RemotePairing.random())
            a.pairing = pairing
            return try [JSONEncoder().encode(a), RemotePairing.random(60)].map { frame in
                s.take(frame, ledger: ledger, pairing: nil, status: .idle).compactMap {
                    guard case .send(let d) = $0,
                        let rejection = try? JSONDecoder().decode(RemotePairing.Rejection.self, from: d)
                    else { return nil }
                    return "\(rejection.rejection)/\(rejection.evidence.count)"
                }
            }
        }
        let expected = [[], ["refused/32"]]
        #expect(try answers("fremd", pairing: nil) == expected)
        #expect(try answers(credential.phone, pairing: nil) == expected)
        #expect(try answers(credential.phone, pairing: Data([1, 2, 3])) == expected)
        #expect(try answers("fremd", pairing: Data([1, 2, 3])) == expected)
    }

    // MARK: - 1.4 Half-open connections

    @Test("1.4: Half-open connections do not displace a waiting candidate")
    func halfOpen() async throws {
        let receiver = RemoteReceiver(
            name: "Living Room", pairings: RemotePairingLedger(InMemoryStore()), hint: "H")
        let connection = try await receiver.startOnLoopback()
        defer { receiver.stopListening() }
        var pending: [NWConnection] = []
        let first = NWConnection(host: "127.0.0.1", port: connection, using: .tcp)
        let end = OneShot<Bool>()
        first.stateUpdateHandler = { z in
            if case .cancelled = z { end.give(true) }
            if case .failed = z { end.give(true) }
        }
        first.start(queue: .global())
        // **Keep reading after the greeting** — a single `receive` would never see the hang-up.
        func read() {
            first.receive(minimumIncompleteLength: 1, maximumLength: 65536) { _, _, done, error in
                if done || error != nil { end.give(true) } else { read() }
            }
        }
        read()
        pending.append(first)
        try? await Task.sleep(for: .milliseconds(200))
        for _ in 0..<RemoteReceiver.maxCandidates {
            let c = NWConnection(host: "127.0.0.1", port: connection, using: .tcp)
            c.stateUpdateHandler = { _ in }
            c.start(queue: .global())
            pending.append(c)
        }
        defer { for c in pending { c.cancel() } }
        let clock = Task {
            try? await Task.sleep(for: .seconds(2))
            end.give(false)
        }
        defer { clock.cancel() }
        #expect(await end.value() == false, "the first connection must not be displaced")
    }

    @Test("1.4: A candidate without sign-in is dropped after its deadline")
    func candidateTimeout() async throws {
        let receiver = RemoteReceiver(
            name: "Living Room", pairings: RemotePairingLedger(InMemoryStore()), hint: "H")
        let connection = try await receiver.startOnLoopback()
        defer { receiver.stopListening() }
        let muted = NWConnection(host: "127.0.0.1", port: connection, using: .tcp)
        defer { muted.cancel() }
        let end = OneShot<Bool>()
        muted.stateUpdateHandler = { _ in }
        muted.start(queue: .global())
        func read() {
            muted.receive(minimumIncompleteLength: 1, maximumLength: 65536) { _, _, done, error in
                if done || error != nil { end.give(true) } else { read() }
            }
        }
        read()
        let clock = Task {
            try? await Task.sleep(for: .seconds(RemoteReceiver.candidateTimeout + 2))
            end.give(false)
        }
        defer { clock.cancel() }
        #expect(await end.value(), "the TV hangs up after the deadline")
    }

    // MARK: - 1.6 und 1.7

    @Test("1.6: Two TVs with the same name do not overwrite each other")
    func sameName() {
        let store = RemoteCredentialStore(InMemoryStore())
        let a = RemoteCredential.fresh(name: "Living Room").bound(on: "A")
        let b = RemoteCredential.fresh(name: "Living Room").bound(on: "B")
        store.create(a)
        store.create(b)
        #expect(store.credential(forItem: "A") == a)
        #expect(store.credential(forItem: "B") == b)
    }

    @Test("1.7: A typed password appears in no description")
    func typeMasked() {
        let command = Command.tap("s3cret-password")
        var dumped = ""
        dump(command, to: &dumped)
        for text in [
            String(describing: command), String(reflecting: command), "\(command)", dumped,
            String(describing: [command]),
        ] {
            #expect(!text.contains("s3cret"), "\(text)")
        }
        #expect(String(describing: Command.jumpBy(10)).contains("10"))
    }
}
