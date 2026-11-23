import Core
import CryptoKit
import Foundation
import Network
import Testing

@testable import SecondScreen

/// **The final check of 2026-09-25 on the remote pairing** (strand E).
///
/// D2-1 reversed: four held half-open connections locked a real phone out, and the phone
/// read from that "the TV is too old". Plus the attacks Z1–Z5 of the check
/// (`PruefFinalAngriffTests`), which already failed — here they stand as a guard.
@Suite("Final check: candidate and rejection", .serialized)
@MainActor
struct FinalCheckRemoteTests {

    /// A TV on the loopback with a paired, then disconnected phone.
    static func setup() async throws -> (RemoteReceiver, NWEndpoint.Port, OwnWire) {
        let ledger = RemotePairingLedger(InMemoryStore())
        let receiver = RemoteReceiver(name: "Living Room", pairings: ledger, hint: "H")
        let connection = try await receiver.startOnLoopback()
        let target = DeviceDiscovery.Device(
            name: "Living Room", endpoint: .hostPort(host: "127.0.0.1", port: connection))
        let key = HandoffKey.fresh(target: "Living Room")
        receiver.openPairing(key)
        let wire = OwnWire(credentials: RemoteCredentialStore(InMemoryStore()), phoneName: "real")
        try await wire.pair(using: key, target: target, credential: .fresh(name: "Living Room"))
        await wire.disconnect()
        try? await Task.sleep(for: .milliseconds(200))
        return (receiver, connection, wire)
    }

    /// Opens `count` connections that say nothing — the half-open connections of the finding.
    static func hold(_ count: Int, on connection: NWEndpoint.Port) async -> [NWConnection] {
        var pending: [NWConnection] = []
        for _ in 0..<count {
            let c = NWConnection(host: "127.0.0.1", port: connection, using: .tcp)
            c.stateUpdateHandler = { _ in }
            c.start(queue: .global())
            pending.append(c)
        }
        try? await Task.sleep(for: .milliseconds(300))
        return pending
    }

    @Test("D2-1: Four held half-open connections do not lock out a real phone")
    func halfOpenConnectionsDoNotBlock() async throws {
        let (receiver, connection, wire) = try await Self.setup()
        defer { receiver.stopListening() }
        let pending = await Self.hold(4, on: connection)
        defer { for c in pending { c.cancel() } }

        let target = DeviceDiscovery.Device(
            name: "Living Room", endpoint: .hostPort(host: "127.0.0.1", port: connection))
        try await wire.connect(using: target)
        #expect(await wire.connected)
        #expect(receiver.phonePresent)
    }

    @Test("D2-1: Whoever gets no place hears a rejection and not \"too old\"")
    func rejectedInsteadOfTooOld() async throws {
        let (receiver, connection, wire) = try await Self.setup()
        defer { receiver.stopListening() }
        let pending = await Self.hold(16, on: connection)
        defer { for c in pending { c.cancel() } }

        let target = DeviceDiscovery.Device(
            name: "Living Room", endpoint: .hostPort(host: "127.0.0.1", port: connection))
        await #expect(throws: RemotePairing.TestError.dismissed) { try await wire.connect(using: target) }
    }

    @Test("D2-1: A rejection before the greeting is read by the phone as rejected")
    func rejectionBeforeGreeting() throws {
        let (_, credential) = try RemotePairingAttackTests.paired()
        var phone = RemoteLogin(credential: credential, phoneName: "real")
        let rejection = try JSONEncoder().encode(
            RemotePairing.Rejection(rejection: RemotePairing.Rejection.word, evidence: RemotePairing.random())
        )
        #expect(throws: RemotePairing.TestError.dismissed) { try phone.take(rejection) }

        var pairing = RemoteLogin(
            credential: .fresh(name: "Living Room"), pairing: .fresh(target: "Living Room"), phoneName: "neu")
        #expect(throws: RemotePairing.TestError.dismissed) { try pairing.take(rejection) }

        // An ordinary greeting stays one.
        var normal = RemoteLogin(credential: credential, phoneName: "real")
        #expect(try normal.take(RemoteSession().greeting(hint: "H")).count == 2)
    }

    // MARK: - Z1–Z5: counter and keys (already closed, here as a guard)

    /// Pairs, then a fresh session with the permanent key — returns both sides after the proof
    /// and the captured proof frames.
    static func session() throws -> (
        tv: RemoteSession, phone: RemoteLogin, ledger: RemotePairingLedger, proof: Data
    ) {
        let (ledger, credential) = try RemotePairingAttackTests.paired()
        var tv = RemoteSession(tv: ledger.tvIdentifier)
        var phone = RemoteLogin(credential: credential, phoneName: "real")
        let greeting = tv.greeting(hint: "h")
        var frame: [Data] = []
        for e in try phone.take(greeting) { if case .send(let d) = e { frame.append(d) } }
        #expect(frame.count == 2)
        _ = tv.take(frame[0], ledger: ledger, pairing: nil, status: .idle)
        let actions = tv.take(frame[1], ledger: ledger, pairing: nil, status: .idle)
        #expect(RemotePairingAttackTests.signedIn(actions))
        for h in actions {
            if case .send(let d) = h { _ = try phone.take(d) }
        }
        return (tv, phone, ledger, frame[1])
    }

    static func closes(_ h: [RemoteSession.Action]) -> Bool {
        h.contains { if case .close = $0 { true } else { false } }
    }

    @Test("Z1: A command with the proof's counter (n=1) is discarded")
    func commandWithProofCounter() throws {
        var (tv, phone, ledger, _) = try Self.session()
        guard case .signedIn(let channel) = phone.state else {
            Issue.record("not signed in")
            return
        }
        let legacy = try RemotePairing.seal(Command.matches(false), n: 1, using: channel.toTV)
        #expect(Self.closes(tv.take(legacy, ledger: ledger, pairing: nil, status: .idle)))
    }

    @Test("Z2: A gap in the counter is allowed, a step back is not")
    func gap() throws {
        var (tv, phone, ledger, _) = try Self.session()
        guard case .signedIn(let channel) = phone.state else {
            Issue.record("not signed in")
            return
        }
        let lastFiveSeconds = try RemotePairing.seal(Command.halt, n: 5, using: channel.toTV)
        let h1 = tv.take(lastFiveSeconds, ledger: ledger, pairing: nil, status: .idle)
        #expect(h1.contains { if case .command(.halt) = $0 { true } else { false } })
        let three = try RemotePairing.seal(Command.halt, n: 3, using: channel.toTV)
        #expect(Self.closes(tv.take(three, ledger: ledger, pairing: nil, status: .idle)))
    }

    @Test("Z3: The captured proof again, after sign-in — closes")
    func proofAsCommand() throws {
        var (tv, _, ledger, proof) = try Self.session()
        let h = tv.take(proof, ledger: ledger, pairing: nil, status: .idle)
        #expect(Self.closes(h))
        #expect(!h.contains { if case .command = $0 { true } else { false } })
    }

    @Test("Z4: HKDF — salt challenge‖nonce, TV identifier in info")
    func hkdf() {
        let duration = RemotePairing.random()
        let her = RemotePairing.random()
        let nonce = RemotePairing.random()
        let channel = RemotePairing.Lane(
            permanentKey: duration, challenge: her, nonce: nonce, tv: "TV-1")
        let expected = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: duration), salt: her + nonce,
            info: Data("cinelounge-fern-2 telefon>fernseher TV-1".utf8), outputByteCount: 32)
        #expect(channel.toTV == expected)
        let other = RemotePairing.Lane(
            permanentKey: duration, challenge: her, nonce: nonce, tv: "TV-2")
        #expect(other.toTV != channel.toTV)
        #expect(channel.toTV != channel.toPhone)
    }

    @Test("Z5: The proof of an older session does not hold in a new one")
    func oldProof() throws {
        let (_, _, ledger, oldProof) = try Self.session()
        var tv = RemoteSession(tv: ledger.tvIdentifier)
        _ = tv.greeting(hint: "h")
        let phone = try #require(ledger.phones.first).id
        let login = try JSONEncoder().encode(
            RemotePairing.SignIn(phone: phone, nonce: RemotePairing.random()))
        _ = tv.take(login, ledger: ledger, pairing: nil, status: .idle)
        let h = tv.take(oldProof, ledger: ledger, pairing: nil, status: .idle)
        #expect(!RemotePairingAttackTests.signedIn(h))
        #expect(Self.closes(h))
    }
}
