import Core
import Foundation
import Network
import Testing

@testable import SecondScreen

/// The pairing of the remote wire (decision 6, 2026-09-25).
///
/// **Two levels.** The calculation — ``RemoteSession`` on the TV, ``RemoteLogin`` on the
/// phone — is played frame by frame against each other; the decision about who may speak
/// sits there. And once the **real wire** over the loopback: ``RemoteReceiver`` and
/// ``OwnWire`` with `Network.framework`, without Bonjour. Only there does it show
/// whether the receiver passes on what the calculation decides.
@Suite("The pairing of the remote", .serialized)
@MainActor
struct RemotePairingTests {

    let ledger = RemotePairingLedger(InMemoryStore())

    static func oneTimeKey(_ now: Date = Date()) -> HandoffKey {
        HandoffKey.fresh(target: "Living Room", now: now)
    }

    /// Plays phone and TV against each other until both have nothing more to say.
    struct Conversation {
        var tv = RemoteSession()
        var phone: RemoteLogin
        var commands: [Command] = []
        var progressStates: [StateMirror] = []
        var paired: [RemotePairingLedger.Phone] = []
        var closed = false
        var confirmed = false

        mutating func begin(
            ledger: RemotePairingLedger, pairing: HandoffKey?, state: StateMirror = .idle
        ) throws(RemotePairing.TestError) {
            var toPhone = [tv.greeting(hint: "Hinweis")]
            while !toPhone.isEmpty {
                var toTV: [Data] = []
                for frame in toPhone {
                    for event in try phone.take(frame) {
                        switch event {
                        case .send(let value): toTV.append(value)
                        case .confirmed: confirmed = true
                        case .state(let fresh): progressStates.append(fresh)
                        }
                    }
                }
                toPhone = []
                for frame in toTV {
                    toPhone += process(
                        tv.take(frame, ledger: ledger, pairing: pairing, status: state))
                }
            }
        }

        mutating func process(_ actions: [RemoteSession.Action]) -> [Data] {
            var outbound: [Data] = []
            for action in actions {
                switch action {
                case .send(let value): outbound.append(value)
                case .command(let command): commands.append(command)
                case .paired(let fresh): paired.append(fresh)
                case .pairingCodeConsumed: break
                case .signedIn: break
                case .close: closed = true
                }
            }
            return outbound
        }

        mutating func send(_ frame: Data, ledger: RemotePairingLedger) {
            _ = process(tv.take(frame, ledger: ledger, pairing: nil, status: .idle))
        }
    }

    // MARK: - The computation

    @Test("Pairing with the one-time key, afterwards sealed commands carry")
    func pairAndOperate() throws {
        let key = Self.oneTimeKey()
        let credential = RemoteCredential.fresh(name: "Living Room")
        var conversation = Conversation(
            phone: RemoteLogin(credential: credential, pairing: key, phoneName: "Alex's iPhone"))
        try conversation.begin(ledger: ledger, pairing: key, state: StateMirror(title: "Morrowfeld"))

        #expect(conversation.confirmed)
        #expect(conversation.paired.map(\.name) == ["Alex's iPhone"])
        #expect(ledger.phones.map(\.id) == [credential.phone])
        #expect(conversation.progressStates.map(\.title) == ["Morrowfeld"])

        let frame = try conversation.phone.wrap(.jumpBy(-10))
        conversation.send(frame, ledger: ledger)
        #expect(conversation.commands == [.jumpBy(-10)])
        #expect(!conversation.closed)
    }

    /// **Unpaired does not mean "quieter" but "nothing".** An older phone sends its command
    /// immediately in plain text.
    @Test("A command in plain text is discarded and the connection drops")
    func plaintextDiscarded() throws {
        var session = RemoteSession()
        let plaintext = try JSONEncoder().encode(Command.matches(false))
        let actions = session.take(plaintext, ledger: ledger, pairing: nil, status: .idle)
        #expect(!actions.contains { if case .command = $0 { true } else { false } })
        #expect(actions.contains { if case .close = $0 { true } else { false } })
    }

    /// The phone knows a different key than the TV — for instance because someone tries it
    /// with the same ID.
    ///
    /// **The refusal is unproven** — the TV can prove nothing that the caller cannot
    /// recompute —, and that is why on the phone it is called ``RemotePairing/TestError/dismissed``.
    @Test("Wrongly encrypted: no command, connection closed, phone learns of it")
    func wrongKey() throws {
        let real = RemoteCredential.fresh(name: "Living Room")
        ledger.accept(
            RemotePairing.PairingRequest(phone: real.phone, name: "real", key: real.key))
        let wrong = RemoteCredential(
            phone: real.phone, tv: "", name: "Living Room", key: RemotePairing.random())
        var conversation = Conversation(phone: RemoteLogin(credential: wrong, phoneName: "x"))
        #expect(throws: RemotePairing.TestError.dismissed) {
            try conversation.begin(ledger: ledger, pairing: nil)
        }
        #expect(!conversation.confirmed)
        #expect(conversation.closed)
        #expect(!conversation.tv.signedIn)

        // And a command that it sends afterwards anyway does not open on the TV.
        var tv = RemoteSession()
        var attacker = RemoteLogin(credential: wrong, phoneName: "x")
        var actions: [RemoteSession.Action] = []
        for event in try attacker.take(tv.greeting(hint: "")) {
            guard case .send(let frame) = event else { continue }
            actions += tv.take(frame, ledger: ledger, pairing: nil, status: .idle)
        }
        #expect(!actions.contains { if case .command = $0 { true } else { false } })
        #expect(actions.contains { if case .close = $0 { true } else { false } })
    }

    @Test("A repeated frame is not executed twice")
    func replay() throws {
        let key = Self.oneTimeKey()
        var conversation = Conversation(
            phone: RemoteLogin(
                credential: .fresh(name: "Living Room"), pairing: key, phoneName: "x"))
        try conversation.begin(ledger: ledger, pairing: key)
        let frame = try conversation.phone.wrap(.halt)
        conversation.send(frame, ledger: ledger)
        conversation.send(frame, ledger: ledger)
        #expect(conversation.commands == [.halt])
        #expect(conversation.closed)
    }

    @Test("Expired pairing code: rejection, nothing in the ledger")
    func expired() {
        let legacy = Self.oneTimeKey(Date().addingTimeInterval(-600))
        var conversation = Conversation(
            phone: RemoteLogin(credential: .fresh(name: "Living Room"), pairing: legacy, phoneName: "x"))
        #expect(throws: RemotePairing.TestError.pairingRejected) {
            try conversation.begin(ledger: ledger, pairing: legacy)
        }
        #expect(ledger.phones.isEmpty)
    }

    @Test("Without a code on the screen nobody pairs")
    func withoutOpenCode() {
        var conversation = Conversation(
            phone: RemoteLogin(
                credential: .fresh(name: "Living Room"), pairing: Self.oneTimeKey(),
                phoneName: "x"))
        #expect(throws: RemotePairing.TestError.pairingRejected) {
            try conversation.begin(ledger: ledger, pairing: nil)
        }
        #expect(ledger.phones.isEmpty)
    }

    @Test("A forgotten phone is unpaired")
    func forgotten() throws {
        let key = Self.oneTimeKey()
        let credential = RemoteCredential.fresh(name: "Living Room")
        var first = Conversation(
            phone: RemoteLogin(credential: credential, pairing: key, phoneName: "x"))
        try first.begin(ledger: ledger, pairing: key)
        ledger.forget(credential.phone)
        var secondOne = Conversation(phone: RemoteLogin(credential: credential, phoneName: "x"))
        #expect(throws: RemotePairing.TestError.unpaired) {
            try secondOne.begin(ledger: ledger, pairing: nil)
        }
    }

    // MARK: - Older devices

    /// **The understandable message for an older iPhone.** It reads the greeting as an
    /// ordinary state — and shows the sentence as a title.
    @Test("A phone without pairing reads the greeting as a state with the hint")
    func oldPhoneSeesHint() throws {
        let greeting = RemoteSession().greeting(hint: "Please pair")
        let state = try JSONDecoder().decode(StateMirror.self, from: greeting)
        #expect(state.title == "Please pair")
        #expect(state.identifier == nil)
    }

    @Test("A new phone without a credential learns \"unpaired\", on an old TV \"too old\"")
    func newPhoneWithoutCredential() throws {
        var without = RemoteLogin(credential: nil, phoneName: "x")
        #expect(throws: RemotePairing.TestError.unpaired) {
            try without.take(RemoteSession().greeting(hint: ""))
        }
        var onOld = RemoteLogin(credential: .fresh(name: "alt"), phoneName: "x")
        let oldState = try JSONEncoder().encode(StateMirror(title: "Morrowfeld"))
        #expect(throws: RemotePairing.TestError.tvTooOld) {
            try onOld.take(oldState)
        }
    }

    @Test("A state without tastaturGeheim (older TV) stays readable")
    func mirrorDownstream() throws {
        let legacy = Data(
            #"{"stelle":1,"laeuft":true,"tastaturOffen":false,"tastaturtext":""}"#.utf8)
        let state = try JSONDecoder().decode(StateMirror.self, from: legacy)
        #expect(state.keyboardSecret == false)
    }

    // MARK: - The password

    /// **The mirror never sends the password back — not even encrypted.** Checked on the board
    /// and on what comes from it into the mirror.
    @Test("Password field: typed text goes into the field, never into the mirror")
    func passwordStaysOverThere() throws {
        var inField = ""
        RemoteKeyboard.signIn(text: "alt", isSecret: true) { inField = $0 }
        defer { RemoteKeyboard.signOut() }
        RemoteKeyboard.give("s3cret-password")
        RemoteKeyboard.refresh("s3cret-password")

        #expect(inField == "s3cret-password")
        #expect(RemoteKeyboard.text.isEmpty, "the board does not retain a password")
        let mirror = StateMirror.idle.withRemoteKeyboard()
        #expect(mirror.keyboardOpen && mirror.keyboardSecret)
        #expect(mirror.keyboardText.isEmpty)
        let json = String(decoding: try JSONEncoder().encode(mirror), as: UTF8.self)
        #expect(!json.contains("s3cret"))
        #expect(!json.contains("alt\""))
    }

    @Test("An ordinary field keeps mirroring")
    func ordinaryField() {
        RemoteKeyboard.signIn(text: "Bay") { _ in }
        defer { RemoteKeyboard.signOut() }
        RemoteKeyboard.give("Bolto")
        #expect(StateMirror.idle.withRemoteKeyboard().keyboardText == "Bolto")
    }

    // MARK: - The real wire

    /// **Over the loopback, with `Network.framework` on both sides.** Pair, send a command,
    /// receive a state, type a password — and on the phone it never comes back.
    @Test("Over the real wire: pair, operate, password only across")
    func realWire() async throws {
        let store = InMemoryStore()
        let receiver = RemoteReceiver(name: "Living Room", pairings: ledger, hint: "Hinweis")
        let arrived = Collector<Command>()
        let paired = Collector<String>()
        receiver.perform = { command in
            arrived.take(command)
            if case .tap(let text) = command {
                Task { @MainActor in
                    RemoteKeyboard.give(text)
                    receiver.notify(StateMirror.idle.withRemoteKeyboard())
                }
            }
        }
        receiver.paired = { paired.take($0.name) }
        let connection = try await receiver.startOnLoopback()
        defer { receiver.stopListening() }
        let target = DeviceDiscovery.Device(
            name: "Living Room", endpoint: .hostPort(host: "127.0.0.1", port: connection))

        let key = Self.oneTimeKey()
        receiver.openPairing(key)
        let wire = OwnWire(credentials: RemoteCredentialStore(store), phoneName: "Alex's iPhone")
        try await wire.pair(
            using: key, target: target, credential: .fresh(name: "Living Room"))
        #expect(await wire.connected)
        #expect(paired.all == ["Alex's iPhone"])
        #expect(RemoteCredentialStore(store).credential(forItem: ledger.tvIdentifier)?.name == "Living Room")

        var progressStates = wire.states.makeAsyncIterator()
        #expect(await progressStates.next() == .idle, "the confirmation is the last state")

        try await wire.send(.jumpBy(30))
        #expect(await arrived.wait(to: 1) == [.jumpBy(30)])

        RemoteKeyboard.signIn(text: "", isSecret: true) { _ in }
        defer { RemoteKeyboard.signOut() }
        try await wire.send(.tap("s3cret-password"))
        let back = await progressStates.next()
        #expect(back?.keyboardSecret == true)
        #expect(back?.keyboardText == "")

        // Second time: the same wire signs in with the stored credential.
        await wire.disconnect()
        try await wire.connect(using: target)
        #expect(await wire.connected)
    }

    /// **A phone without pairing on the real wire:** it gets the greeting with the notice that
    /// its plain-text command is not executed.
    @Test("Over the real wire: an unpaired phone operates nothing")
    func realWireUnpaired() async throws {
        let receiver = RemoteReceiver(name: "Living Room", pairings: ledger, hint: "Please pair")
        let arrived = Collector<Command>()
        receiver.perform = { arrived.take($0) }
        let connection = try await receiver.startOnLoopback()
        defer { receiver.stopListening() }

        let raw = NWConnection(host: "127.0.0.1", port: connection, using: .tcp)
        defer { raw.cancel() }
        let greeting = OneShot<Data?>()
        raw.stateUpdateHandler = { if case .ready = $0 {} }
        raw.start(queue: .global())
        raw.receive(minimumIncompleteLength: 4, maximumLength: 64 * 1024) { data, _, _, _ in
            greeting.give(data)
        }
        let first = try #require(await greeting.value())
        let length = try #require(HandoffWire.Frame.length(from: first))
        let state = try JSONDecoder().decode(
            StateMirror.self, from: first.dropFirst(4).prefix(length))
        #expect(state.title == "Please pair")

        let plaintext = HandoffWire.Frame.pack(try JSONEncoder().encode(Command.halt))
        let sent = OneShot<Void>()
        raw.send(content: plaintext, completion: .contentProcessed { _ in sent.give(()) })
        await sent.value()
        try await Task.sleep(for: .milliseconds(300))
        #expect(arrived.all.isEmpty)
        #expect(!receiver.phonePresent)

        let withoutCredential = OwnWire(credentials: RemoteCredentialStore(InMemoryStore()))
        await #expect(throws: RemotePairing.TestError.unpaired) {
            try await withoutCredential.connect(
                using: DeviceDiscovery.Device(
                    name: "Living Room", endpoint: .hostPort(host: "127.0.0.1", port: connection)))
        }
    }
}

/// Collects what arrives on foreign threads, and lets callers wait for it.
final class Collector<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Value] = []

    func take(_ value: Value) {
        lock.lock()
        values.append(value)
        lock.unlock()
    }

    var all: [Value] {
        lock.lock()
        defer { lock.unlock() }
        return values
    }

    func wait(to count: Int, atMost seconds: Double = 3) async -> [Value] {
        let end = Date().addingTimeInterval(seconds)
        while all.count < count, Date() < end {
            try? await Task.sleep(for: .milliseconds(20))
        }
        return all
    }
}
