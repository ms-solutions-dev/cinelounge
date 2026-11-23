import Core
import Diagnose
import Foundation
import Network

/// The side of the **TV**: listens, executes, reports back.
///
/// **Separate from ``HandoffReceiver``, although both listen.** The other one accepts an
/// encrypted bundle, acknowledges it and hangs up — a process with a beginning
/// and an end. This one holds a connection for hours, speaks in both directions and
/// must never pause the film while doing so.
///
/// **Paired since 2026-09-25** (decision 6, ``RemotePairing``). Before, it opened
/// bare TCP and asked nobody who was speaking. Now it greets every connection with
/// a challenge, accepts only phones from the ``RemotePairingLedger`` and
/// discards every frame that cannot be opened with the session key. The
/// decision itself lives in ``RemoteSession``; this file is the network around it.
///
/// **One phone at a time — but only after the proof.** A new connection used to
/// replace the old one immediately. With pairing that would be a door for anyone on the home network to
/// throw out someone else's remote; now a new connection waits as a
/// candidate and replaces the old one only once it has **proven** the permanent key
/// (``RemoteSession``). Until 2026-09-25 the identifier from the sign-in was enough for that — it
/// is in plain text, and anyone on the Wi-Fi could use it to throw out the real phone
/// (counter-check strand D, finding 1.1). Whoever restarts their phone still gets
/// back in immediately.
///
/// **Candidates have a deadline** (``candidateTimeout``, finding 1.4): Whoever is not signed in
/// after five seconds is dropped. If all slots are taken, a new connection displaces
/// only an **expired** candidate, otherwise it is itself rejected — before, the
/// oldest always went, and five empty connections threw every phone out in the middle of
/// signing in.
///
/// **The signed-in line has no idle deadline, and that is deliberate.** A phone
/// holds the connection through a whole film and often stays silent for an hour; a
/// deadline would cut off exactly that or demand a keep-alive tap every minute. And it is no
/// longer needed: Only a phone that has proven the key can occupy the slot,
/// and any other that proves it replaces it. A phone that vanishes from the
/// Wi-Fi without a goodbye is caught by TCP keepalive (``keepAlive``) after a bit over a minute.
///
/// **It decides nothing about playback.** What a command does is known by the player.
public final class RemoteReceiver: @unchecked Sendable {

    /// What happens with an arrived, **verified** command.
    public var perform: (@Sendable (Command) -> Void)?

    /// A phone has just been paired — the pairing screen closes with it.
    public var paired: (@Sendable (RemotePairingLedger.Phone) -> Void)?

    /// At most this many connections wait for their sign-in at the same time.
    ///
    /// **Sixteen instead of four** (final check 2026-09-25, D2-1). Four held
    /// half-open connections were enough to lock a real phone out for five seconds —
    /// and whoever reopens them after the deadline locks it out permanently. A candidate
    /// costs an open socket and a few bytes of buffer; sixteen of them are nothing.
    static let maxCandidates = 16

    /// At most this many candidates **per source address** (D2-1).
    ///
    /// **The actual barrier against lockout:** Whoever wants to occupy all the slots from one
    /// address only occupies these eight, and the phone at its own address still gets in. Eight
    /// and not one, because after a network change or an app restart a phone can briefly have
    /// two or three connections open, all coming from the same address.
    static let maxPerSource = 8

    /// This long a connection may take from acceptance to proof.
    ///
    /// **Five seconds like ``OwnWire/deadline``:** The phone sends sign-in and proof
    /// without asking, directly after the greeting; whoever takes longer is not a
    /// phone that wants to sign in.
    static let candidateTimeout: TimeInterval = 5

    /// The ``candidateTimeout`` of this receiver — **only checks set it differently.**
    ///
    /// Next to a release build, even the greeting over the loopback took 30 s
    /// (2026-10-11, A.2 red three times): Both phones were dropped as candidates before they could
    /// sign in, and the test counted zero instead of one. Whoever tests concurrency
    /// gives themselves time here; whoever tests the dropping leaves the five seconds.
    var deadline: TimeInterval = candidateTimeout

    /// TCP keepalive: ask after 30 s of silence, repeat every 10 s, give up after 3 failures
    /// — a vanished phone drops out this way after a bit over a minute.
    static func keepAlive() -> NWParameters {
        let tcp = NWProtocolTCP.Options()
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 30
        tcp.keepaliveInterval = 10
        tcp.keepaliveCount = 3
        return NWParameters(tls: nil, tcp: tcp)
    }

    private let name: String
    private let ledger: RemotePairingLedger
    /// The identifier of this TV — read once, it does not change.
    private let identifier: String
    private let hint: String
    private var listener: NWListener?
    private let lock = NSLock()

    private final class Wire: @unchecked Sendable {
        let connection: NWConnection
        var session: RemoteSession
        var buffer = Data()
        /// When the connection was accepted — for the ``candidateTimeout``.
        let since: Date
        /// Where it comes from — for ``maxPerSource``.
        let source: String
        init(_ connection: NWConnection, tv: String, since: Date) {
            self.connection = connection
            self.session = RemoteSession(tv: tv)
            self.since = since
            self.source = RemoteReceiver.source(from: connection.endpoint)
        }
    }

    /// The source address of a connection — without the port, because that changes per connection.
    static func source(from endpoint: NWEndpoint) -> String {
        if case .hostPort(let calculator, _) = endpoint { return "\(calculator)" }
        return "\(endpoint)"
    }

    /// **Only for the checks:** runs in ``take(_:from:)`` right after unlocking —
    /// the spot where, before 2026-09-27, the confirmation had not yet gone out (E13).
    var afterUnlock: (@Sendable () -> Void)?

    private var active: Wire?
    private var candidates: [Wire] = []
    private var pairingKey: HandoffKey?
    private var lastState: StateMirror = .idle

    /// - Parameters:
    ///   - name: What the TV is called in the phone's list — and the target in the
    ///     pairing code.
    ///   - kopplungen: The paired phones. **Without** an explicit value an empty book
    ///     in memory: Then nobody is paired, and nobody operates.
    ///   - hinweis: The string that a phone without pairing sees as its title — translated
    ///     by the program.
    public init(
        name: String, pairings: RemotePairingLedger = RemotePairingLedger(InMemoryStore()),
        hint: String = RemotePairing.defaultHint
    ) {
        self.name = name
        self.ledger = pairings
        self.identifier = pairings.tvIdentifier
        self.hint = hint
    }

    public func start() throws {
        let parameters = Self.keepAlive()
        parameters.includePeerToPeer = true
        let new = try NWListener(using: parameters)
        new.service = NWListener.Service(name: name, type: DeviceDiscovery.service)
        new.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        // **State and service registration into the log** (finding 13): "listening" used to mean
        // only "started" — whether Bonjour accepted the service was nowhere to be seen.
        BonjourProtocol.observe(new, who: "Remote")
        new.start(queue: .global(qos: .userInitiated))
        listener = new
        Diagnose.step(.network, "Remote: receiver listening, \(ledger.phones.count) phones paired")
    }

    /// **For the checks:** without Bonjour, on the loopback only, on a free port.
    ///
    /// A real service on the home network per check run would be an entry in every Bonjour list
    /// of the house; over the loopback the same wire runs with the same pairing.
    func startOnLoopback() async throws -> NWEndpoint.Port {
        let parameters = Self.keepAlive()
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let new = try NWListener(using: parameters)
        new.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        let ready = OneShot<NWEndpoint.Port?>()
        new.stateUpdateHandler = { state in
            switch state {
            case .ready: ready.give(new.port)
            case .failed, .cancelled: ready.give(nil)
            default: break
            }
        }
        new.start(queue: .global(qos: .userInitiated))
        listener = new
        guard let link = await ready.value() else { throw RemotePairing.TestError.unreadable }
        return link
    }

    public func stopListening() {
        listener?.cancel()
        listener = nil
        lock.lock()
        let all = candidates + (active.map { [$0] } ?? [])
        active = nil
        candidates = []
        pairingKey = nil
        lock.unlock()
        for line in all { line.connection.cancel() }
    }

    /// Whether a **signed-in** phone is currently connected.
    public var phonePresent: Bool {
        lock.lock()
        defer { lock.unlock() }
        return active != nil
    }

    // MARK: - Pairing

    /// A pairing code is on the screen — **until it is used or expires.**
    ///
    /// The one-time key applies once: After the first pairing the receiver throws it
    /// away, and the screen puts up a new one when needed.
    public func openPairing(_ key: HandoffKey) {
        lock.lock()
        pairingKey = key
        lock.unlock()
        Diagnose.step(.login, "Remote: pairing code shown")
    }

    public func closePairing() {
        lock.lock()
        let existed = pairingKey != nil
        pairingKey = nil
        lock.unlock()
        if existed { Diagnose.step(.login, "Remote: pairing code withdrawn") }
    }

    /// Forget a phone — **and disconnect it immediately** if it is
    /// currently connected. A removal that waits until the next connection is none.
    ///
    /// The book itself changes under its own lock
    /// (``RemotePairingLedger/writeLock``, round A.3) — a concurrent pairing
    /// is not lost in the process.
    public func forget(phone: String) {
        ledger.forget(phone)
        lock.lock()
        let route = active?.session.phone == phone ? active : nil
        if route != nil { active = nil }
        lock.unlock()
        Diagnose.step(
            .login, "Remote: phone forgotten\(route != nil ? ", connection dropped" : "")")
        route?.connection.cancel()
    }

    // MARK: - Melden

    /// Sends the state to the phone — **only to a signed-in one, and sealed.**
    ///
    /// Silently, if there is none: A state nobody heard is outdated by the next time.
    /// The last one is remembered nonetheless — it is the confirmation
    /// a phone gets first after signing in.
    ///
    /// **Sent under the lock** (setup check, E13, 2026-09-27). The frame's counter
    /// is assigned under it; whoever sends only afterwards leaves a gap in
    /// which a second frame with a higher counter reaches the wire first — the phone
    /// then reads n=2 before n=1 and disconnects a sign-in that had just succeeded. `NWConnection.send`
    /// only enqueues and does not wait; the lock does not hold it up.
    public func notify(_ state: StateMirror) {
        lock.lock()
        defer { lock.unlock() }
        lastState = state
        guard let line = active, let content = line.session.wrap(state) else { return }
        send(content, to: line.connection)
    }

    // MARK: - Accepting and reading

    /// A new connection becomes a candidate — **if there is room.**
    ///
    /// Only one who has already exceeded their ``candidateTimeout`` is displaced; otherwise the
    /// new connection is rejected. This way nobody can displace a phone that is just in the
    /// middle of signing in by using empty connections.
    ///
    /// **Rejection is with a notice and not silent** (D2-1). Until then the
    /// TV simply hung up, and the phone read that as "the TV does not greet" —
    /// ``RemotePairing/TestError/tvTooOld``, with the advice to update the app on the
    /// Apple TV. The notice is the same unproven one as after a failed
    /// proof; the phone reports ``RemotePairing/TestError/dismissed`` and keeps its
    /// credential.
    private func accept(_ incoming: NWConnection) {
        let now = Date()
        let line = Wire(incoming, tv: identifier, since: now)
        lock.lock()
        var displaced: [Wire] = []
        if candidates.count >= Self.maxCandidates
            || candidates.filter({ $0.source == line.source }).count >= Self.maxPerSource
        {
            displaced = candidates.filter { now.timeIntervalSince($0.since) >= deadline }
            candidates.removeAll { legacy in displaced.contains { $0 === legacy } }
        }
        let accepted =
            candidates.count < Self.maxCandidates
            && candidates.filter({ $0.source == line.source }).count < Self.maxPerSource
        if accepted { candidates.append(line) }
        let greeting = line.session.greeting(hint: hint)
        let waiting = candidates.count
        lock.unlock()
        for legacy in displaced { legacy.connection.cancel() }
        if !displaced.isEmpty {
            Diagnose.hint(.network, "Remote: \(displaced.count) expired candidates displaced")
        }
        guard accepted else {
            Diagnose.hint(
                .network, "Remote: connection rejected, candidate limit reached (\(waiting) waiting)"
            )
            mode(incoming)
            return
        }
        Diagnose.step(.network, "Remote: connection accepted (\(waiting) waiting)")
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + deadline) {
            [weak self] in self?.expire(line)
        }

        incoming.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled: self?.forget(line)
            default: break
            }
        }
        incoming.start(queue: .global(qos: .userInitiated))
        send(greeting, to: incoming)
        read(line)
    }

    /// Rejects a connection for which there is no room — **with a notice**, so that the
    /// phone reports ``RemotePairing/TestError/dismissed`` and not "too old".
    ///
    /// It hangs up after sending and after one second at the latest: A peer
    /// that reads nothing must not hold the slot through the back door of the send buffer.
    private func mode(_ incoming: NWConnection) {
        incoming.stateUpdateHandler = { _ in }
        incoming.start(queue: .global(qos: .utility))
        incoming.send(
            content: HandoffWire.Frame.pack(RemotePairing.rejectionWithoutEvidence()), isComplete: true,
            completion: .contentProcessed { _ in incoming.cancel() })
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1) { incoming.cancel() }
    }

    /// A candidate's deadline is up — **if it is still one, it is dropped.**
    private func expire(_ line: Wire) {
        lock.lock()
        let stillPending = candidates.contains { $0 === line }
        if stillPending { candidates.removeAll { $0 === line } }
        lock.unlock()
        guard stillPending else { return }
        Diagnose.hint(.network, "Remote: candidate without sign-in dropped after the deadline")
        line.connection.cancel()
    }

    /// **Only its own.** An expired connection must not take down the new one
    /// accepted in the meantime.
    private func forget(_ line: Wire) {
        lock.lock()
        let existed = active === line
        if existed { active = nil }
        candidates.removeAll { $0 === line }
        lock.unlock()
        if existed { Diagnose.step(.network, "Remote: connection to the phone lost") }
    }

    private func read(_ line: Wire) {
        line.connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) {
            [weak self] data, _, done, error in
            guard let self else { return }
            if let data, !data.isEmpty { self.take(data, from: line) }
            if error != nil || done {
                self.forget(line)
                return
            }
            self.read(line)
        }
    }

    /// Unpack the frame, send it through the ``RemoteSession``, do what it says.
    ///
    /// **Executed outside the lock.** The player reaches into the main thread;
    /// calling it under a lock is the design that deadlocks come from.
    private func take(_ data: Data, from line: Wire) {
        var commands: [Command] = []
        var outbound: [Data] = []
        var newlyPaired: [RemotePairingLedger.Phone] = []
        var close = false
        var brokenHeader = false
        var superseded: Wire?
        var signedIn = false
        var codeConsumed = false

        lock.lock()
        line.buffer.append(data)
        frame: while !close {
            let content: Data
            switch HandoffWire.Frame.extract(from: &line.buffer) {
            case .frame(let total): content = total
            case .incomplete: break frame
            case .broken:
                brokenHeader = true
                close = true
                break frame
            }
            let actions = line.session.take(
                content, ledger: ledger, pairing: pairingKey, status: lastState)
            for action in actions {
                switch action {
                case .send(let value): outbound.append(value)
                case .command(let command): if active === line { commands.append(command) }
                case .pairingCodeConsumed:
                    // **In the same step as the check, under the same lock** — the
                    // next sign-in, even on another line, sees no code
                    // anymore (round A.2).
                    pairingKey = nil
                    codeConsumed = true
                case .paired(let phone):
                    newlyPaired.append(phone)
                case .signedIn:
                    candidates.removeAll { $0 === line }
                    if active !== line { superseded = active }
                    active = line
                    signedIn = true
                case .close:
                    close = true
                }
            }
        }
        if close {
            if active === line { active = nil }
            candidates.removeAll { $0 === line }
        }
        // **Sent under the lock** — see ``notify(_:)``: The confirmation carries the
        // counter it got here and must go out before any later state.
        for content in outbound { send(content, to: line.connection) }
        let action = perform
        let report = paired
        let override = afterUnlock
        let reason = line.session.rejectionReason
        lock.unlock()
        override?()

        if codeConsumed {
            Diagnose.step(.login, "Remote: pairing requested, code used up")
        }
        if !newlyPaired.isEmpty {
            Diagnose.step(.login, "Remote: phone paired, \(ledger.phones.count) paired")
        }
        if signedIn {
            Diagnose.step(
                .network,
                "Remote: phone signed in\(superseded != nil ? ", older connection superseded" : "")")
        }
        if brokenHeader {
            Diagnose.hint(.network, "Remote: unusable frame header, connection closed")
        } else if close {
            Diagnose.hint(
                .login, "Remote: rejected – \(reason?.rawValue ?? "no reason")")
        }
        for command in commands {
            // **The description blacks out what was typed** (``Command``, finding 1.7).
            Diagnose.step(.network, "Remote: command \(command)")
        }

        superseded?.connection.cancel()
        if close {
            line.connection.send(
                content: nil, isComplete: true,
                completion: .contentProcessed { _ in line.connection.cancel() })
        }
        for phone in newlyPaired { report?(phone) }
        for command in commands { action?(command) }
    }

    private func send(_ content: Data, to connection: NWConnection) {
        connection.send(
            content: HandoffWire.Frame.pack(content), completion: .contentProcessed { _ in })
    }
}
