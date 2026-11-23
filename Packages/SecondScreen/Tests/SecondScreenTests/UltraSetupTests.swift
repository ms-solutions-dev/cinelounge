import Core
import Foundation
import Network
import SourceProbe
import Testing

@testable import SecondScreen

/// The findings of the ultra check "Setup/Second screen" (e5, 2026-09-27), round A —
/// **as guards.** Every test was red against the state of `2812ed64`.
@Suite("ultra e5 – pairing and handoff", .serialized)
@MainActor
struct UltraSetupTests {

    // MARK: - A.2 One pairing code, two phones

    /// **Two phones scan the same code** and both sign in before one of them sends its proof.
    /// The code was only checked at sign-in and consumed only after the proof — both got
    /// through and stayed paired permanently.
    @Test("A.2: A pairing code pairs exactly one phone, even with a simultaneous scan")
    func oneCodeOnePhone() async throws {
        let ledger = RemotePairingLedger(InMemoryStore())
        let receiver = RemoteReceiver(name: "Living Room", pairings: ledger, hint: "H")
        let paired = Collector<RemotePairingLedger.Phone>()
        receiver.paired = { paired.take($0) }
        // What is checked is the simultaneous scan, not throwing out slow candidates — under load
        // the greeting came after 30 s, and both were thrown out after five.
        receiver.deadline = 60
        let connection = try await receiver.startOnLoopback()
        defer { receiver.stopListening() }

        let key = HandoffKey.fresh(target: "Living Room")
        receiver.openPairing(key)

        let first = RawPhone(connection)
        let secondOne = RawPhone(connection)
        defer {
            first.connection.cancel()
            secondOne.connection.cancel()
        }
        // **Under load the handshake needs time** (2026-10-11, third red full run in one day, 1.9 s
        // alone): the test talks over a real network on the loopback, and next to a release build
        // a greeting sometimes takes ten seconds. The wait is for the event, not for the clock —
        // the deadlines are only the emergency brake.
        let greetingA = try #require(await first.frame.wait(to: 1, atMost: 20).first)
        let greetingB = try #require(await secondOne.frame.wait(to: 1, atMost: 20).first)

        var a = RemoteLogin(
            credential: .fresh(name: "Living Room"), pairing: key, phoneName: "A")
        var b = RemoteLogin(
            credential: .fresh(name: "Living Room"), pairing: key, phoneName: "B")
        let outboundA = try a.take(greetingA).compactMap(\.content)
        let outboundB = try b.take(greetingB).compactMap(\.content)
        #expect(outboundA.count == 2)
        #expect(outboundB.count == 2)

        // Both sign-ins first, then both proofs.
        await first.send(outboundA[0])
        await secondOne.send(outboundB[0])
        try? await Task.sleep(for: .milliseconds(300))
        await first.send(outboundA[1])
        await secondOne.send(outboundB[1])
        // **Wait for the first, then look at the wrong second** (2026-09-30): with only 1.5 s for
        // both, under load none was paired yet, and the test reported 0 instead of 1 — twice in
        // one day, both times next to a parallel build.
        _ = await paired.wait(to: 1, atMost: 40)
        _ = await paired.wait(to: 2, atMost: 1.5)

        #expect(paired.all.count == 1, "paired: \(paired.all.map(\.name))")
        #expect(ledger.phones.count == 1)
    }

    // MARK: - A.3 Forgetting and pairing at once

    /// **Forgetting and a fresh pairing ran without a shared lock** over the same list in the
    /// Keychain: read, filter, write. If the forgetting wrote last, the fresh pairing was gone.
    @Test("A.3: Forgetting during a pairing does not lose the fresh pairing")
    func forgettingLosesNoPairing() async throws {
        let store = SlowStore()
        let ledger = RemotePairingLedger(store)
        let receiver = RemoteReceiver(name: "Living Room", pairings: ledger, hint: "H")
        let legacy = RemotePairing.PairingRequest(
            phone: "alt", name: "Old iPhone", key: RemotePairing.random())
        let fresh = RemotePairing.PairingRequest(
            phone: "neu", name: "New iPhone", key: RemotePairing.random())
        ledger.accept(legacy)

        store.throttleOnNextRead()
        let forgotten = Task.detached { receiver.forget(phone: "alt") }
        await store.read.value()
        let pair = Task.detached { ledger.accept(fresh) }
        await forgotten.value
        _ = await pair.value

        #expect(ledger.phones.map(\.id) == ["neu"])
    }

    // MARK: - A.4 The handoff receiver has limits

    /// **Unlimited connections, no deadline:** as long as the QR code was up, any device on the
    /// network could open and hold connections. Now the limits of the remote receiver apply: at
    /// most ``RemoteReceiver/maxPerSource`` candidates per address, and whoever brings no
    /// packet within the deadline is thrown out.
    @Test("A.4: Handoff – rejected above the limit per source, silence is dropped after the deadline")
    func handoffHasLimits() async throws {
        let receiver = HandoffReceiver(key: .fresh(target: "Living Room")) { _ in nil }
        let connection = try await receiver.startOnLoopback()
        defer { receiver.stopListening() }

        var silent: [RawPhone] = []
        for _ in 0..<RemoteReceiver.maxPerSource {
            silent.append(RawPhone(connection))
        }
        defer { for s in silent { s.connection.cancel() } }
        try? await Task.sleep(for: .milliseconds(300))

        let tooMany = RawPhone(connection)
        defer { tooMany.connection.cancel() }
        #expect(await tooMany.end.wait(to: 1, atMost: 1.5).count == 1, "above the limit")
        #expect(silent[0].end.all.isEmpty, "the waiting ones are still there")

        let deadline = RemoteReceiver.candidateTimeout + 2
        #expect(
            await silent[0].end.wait(to: 1, atMost: deadline).count == 1,
            "a silent connection is dropped after the deadline")
    }

    // MARK: - A.6 A reader for the frame

    /// **The read loop existed twice** and only one of the two detected a broken header. Now
    /// both sides read through ``HandoffWire/Frame/extract(from:)``.
    @Test("A.6: The frame reader takes whole frames, waits for half ones and recognizes broken ones")
    func frameReader() {
        var buffer = HandoffWire.Frame.pack(Data("one".utf8))
        buffer.append(HandoffWire.Frame.pack(Data("two".utf8)))
        let half = HandoffWire.Frame.pack(Data("three".utf8))
        buffer.append(half.prefix(5))

        #expect(HandoffWire.Frame.extract(from: &buffer) == .frame(Data("one".utf8)))
        #expect(HandoffWire.Frame.extract(from: &buffer) == .frame(Data("two".utf8)))
        #expect(HandoffWire.Frame.extract(from: &buffer) == .incomplete)
        buffer.append(half.dropFirst(5))
        #expect(HandoffWire.Frame.extract(from: &buffer) == .frame(Data("three".utf8)))
        #expect(buffer.isEmpty)

        var broken = Data([0xFF, 0xFF, 0xFF, 0xFF, 0x00])
        #expect(HandoffWire.Frame.extract(from: &broken) == .broken)
        var short = Data([0x00, 0x00])
        #expect(HandoffWire.Frame.extract(from: &short) == .incomplete)
    }

    // MARK: - A.8 Diagnostics coverage

    /// **The TV knows why it declined** — to the outside it stays a refusal.
    @Test("A.8: A rejection carries its reason on the TV, not on the wire")
    func rejectionReason() throws {
        let ledger = RemotePairingLedger(InMemoryStore())
        let now = Date()
        let expired = HandoffKey.fresh(target: "Living Room", now: now.addingTimeInterval(-3600))
        var phone = RemoteLogin(
            credential: .fresh(name: "Living Room"), pairing: expired, phoneName: "A")
        var tv = RemoteSession()
        let outbound = try phone.take(tv.greeting(hint: "")).compactMap(\.content)
        var actions: [RemoteSession.Action] = []
        for frame in outbound {
            actions += tv.take(frame, ledger: ledger, pairing: expired, status: .idle, now: now)
        }
        #expect(tv.rejectionReason == .codeExpired)
        #expect(!actions.contains { if case .pairingCodeConsumed = $0 { true } else { false } })

        var foreign = RemoteSession()
        _ = foreign.take(Data("{}".utf8), ledger: ledger, pairing: nil, status: .idle)
        #expect(foreign.rejectionReason == .noLogin)
    }

    /// **Second screen had zero log points** (product decision 2026-09-27: the app is going
    /// commercial, reports must be explainable without follow-up questions). Every decision —
    /// pairing requested, accepted, rejected with reason, code consumed or expired, connection
    /// up and gone, handoff received, rejected, too new, limits hit — writes a line via
    /// `Diagnose`.
    @Test("A.8: Every decision point in SecondScreen writes to the log")
    func decisionPointsLogged() throws {
        let expected: [String: [String]] = [
            "RemoteReceiver.swift": [
                "pairing code shown", "pairing requested, code used up",
                "phone paired", "rejected – ", "candidate limit reached",
                "candidate without sign-in dropped after the deadline", "phone signed in",
                "connection to the phone lost", "phone forgotten",
            ],
            "HandoffWire.swift": [
                "connection accepted", "limit reached", "without a packet dropped after the deadline",
                "packet opened", "bundle too new", "after the code expired",
                "second transmission on a used code", "packet could not be opened",
                "failed attempt", "code abandoned",
            ],
            "OwnWire.swift": [
                "connected", "failed", "connection to the TV lost",
                "sign-in rejected", "proven rejection",
            ],
            "Takeover.swift": ["parental controls rejected", "Takeover: server"],
        ]
        for (file, wordings) in expected {
            let callCount = Self.diagnosticCalls(try SourceText.read(file, in: .secondScreen))
            for message in wordings {
                #expect(
                    callCount.contains { $0.contains(message) }, "\(file): \"\(message)\" missing in the log")
            }
        }
    }

    /// **No keys, codes or passwords in the log.** The redaction catches addresses and paths,
    /// but not a key in hex — so do not pass it in in the first place.
    @Test("A.8: No log sentence in SecondScreen lets a secret in")
    func noSecretInLog() throws {
        let forbidden = [
            "secret", "schluessel", "password", "passphrase", "accesstoken", "token",
            "request", "credential", "pin", "nonce", "challenge", "packet", "bundles)",
        ]
        var counted = 0
        for file in try SourceText.files(in: .secondScreen) {
            for call in Self.diagnosticCalls(file.content) {
                counted += 1
                // `report.key` is a count (``Takeover/Report/key``).
                for usage in Self.usages(call) where usage != "report.schluessel" {
                    let lowercased = usage.lowercased()
                    for word in forbidden where lowercased.contains(word) {
                        #expect(Bool(false), "\(file.name): \\(\(usage)) in the log")
                    }
                }
            }
        }
        #expect(counted >= 30, "only \(counted) log sites")
    }

    /// Every `Diagnose.…(…)` call as text, across lines up to the closing parenthesis.
    static func diagnosticCalls(_ text: String) -> [String] {
        let source = SourceText.strippingCommentLines(text)
        var callCount: [String] = []
        var rest = source[...]
        while let match = rest.range(of: "Diagnose.") {
            guard let to = rest[match.upperBound...].firstIndex(of: "(") else { break }
            var depth = 0
            var end = to
            for index in rest[to...].indices {
                let character = rest[index]
                if character == "(" { depth += 1 }
                if character == ")" {
                    depth -= 1
                    if depth == 0 {
                        end = index
                        break
                    }
                }
            }
            callCount.append(String(rest[match.lowerBound...end]))
            rest = rest[rest.index(after: end)...]
        }
        return callCount
    }

    /// What is interpolated in `\(…)`.
    static func usages(_ call: String) -> [String] {
        var found: [String] = []
        var rest = call[...]
        while let start = rest.range(of: "\\(") {
            var depth = 1
            var index = start.upperBound
            while index < rest.endIndex, depth > 0 {
                if rest[index] == "(" { depth += 1 }
                if rest[index] == ")" { depth -= 1 }
                if depth > 0 { index = rest.index(after: index) }
            }
            found.append(String(rest[start.upperBound..<min(index, rest.endIndex)]))
            rest = index < rest.endIndex ? rest[rest.index(after: index)...] : rest[rest.endIndex...]
        }
        return found
    }
}

// MARK: - Tools

extension RemoteLogin.Event {
    /// The content of a ``send(_:)``, otherwise `nil`.
    var content: Data? {
        if case .send(let value) = self { return value }
        return nil
    }
}

/// A phone without sign-in logic — **wire only**: connects, collects whole frames and
/// notes when the other side hangs up.
final class RawPhone: @unchecked Sendable {
    let connection: NWConnection
    let frame = Collector<Data>()
    let end = Collector<Bool>()
    private let lock = NSLock()
    private var buffer = Data()

    init(_ link: NWEndpoint.Port) {
        connection = NWConnection(host: "127.0.0.1", port: link, using: .tcp)
        connection.stateUpdateHandler = { [end] state in
            switch state {
            case .failed, .cancelled: end.take(true)
            default: break
            }
        }
        connection.start(queue: .global())
        read()
    }

    private func read() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) {
            [weak self] data, _, done, error in
            guard let self else { return }
            if let data {
                lock.lock()
                buffer.append(data)
                while let length = HandoffWire.Frame.length(from: buffer),
                    buffer.count >= length + 4
                {
                    frame.take(buffer.subdata(in: 4..<(4 + length)))
                    buffer.removeSubrange(0..<(4 + length))
                }
                lock.unlock()
            }
            if done || error != nil {
                end.take(true)
                return
            }
            read()
        }
    }

    func send(_ content: Data) async {
        let sent = OneShot<Void>()
        connection.send(
            content: HandoffWire.Frame.pack(content),
            completion: .contentProcessed { _ in sent.give(()) })
        await sent.value()
    }
}

/// A store that pauses **once** when the pairing list is read — the window in which, without
/// a lock, a second writer gets in between.
final class SlowStore: KeyValueStore, @unchecked Sendable {
    private let inside = InMemoryStore()
    private let lock = NSLock()
    private var armed = false
    let read = OneShot<Void>()

    func throttleOnNextRead() {
        lock.withLock { armed = true }
    }

    func set(_ value: String, for key: String) throws { try inside.set(value, for: key) }
    func remove(_ key: String) throws { try inside.remove(key) }

    func value(for key: String) throws -> String {
        let value = try inside.value(for: key)
        let throttles = lock.withLock {
            let now = armed && key == RemotePairingLedger.key
            if now { armed = false }
            return now
        }
        if throttles {
            read.give(())
            Thread.sleep(forTimeInterval: 0.3)
        }
        return value
    }
}
