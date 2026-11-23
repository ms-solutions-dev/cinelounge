import Diagnose
import Foundation
import Network

/// The wire over which a phone sets up a TV.
///
/// **Both ends are in one file because they are an agreement.** A frame that
/// only one side knows is not a frame; whoever changes the length field here and
/// forgets it there gets no compile error but a connection that hangs.
/// Split across two packages, that would be exactly the normal case.
///
/// **What the path looks like:**
///
/// 1. The TV creates a one-time key (``HandoffKey``), opens a
///    service on the home network and shows both as a QR code.
/// 2. The phone reads the code — it contains the name of the service and the secret.
/// 3. The phone asks for Face ID (``AccessGrant``), packs the bundle
///    (``HandoffPackage``) and sends it to the service with that name.
/// 4. The TV opens it with **its** key and answers with one byte.
///
/// **Without TLS, and that is not negligence.** What goes through this wire is encrypted
/// with AES-GCM under the one-time key, and only whoever has seen the screen knows that.
/// TLS on top would mean: a second secret, a certificate nobody
/// issues, and a warning the viewer would have to tap away. The protection lives in the
/// content and not in the envelope — the same decision as for ``HandoffPackage``.
public enum HandoffWire {

    /// The service type on the home network.
    ///
    /// **A dedicated one and not `_http._tcp`.** Whoever hangs under a foreign type
    /// appears in every network browser as a web server — and has to prevail when resolving
    /// against every printer that claims the same. The name belongs in the
    /// Info file of both programs, otherwise iOS does not even allow it.
    public static let service = "_cinelounge-uebg._tcp"

    /// How long to wait for the other side.
    ///
    /// **Fifteen seconds**: The handoff is a process between two devices in one
    /// room, and what does not start there within fifteen seconds will not start. Longer
    /// would mean leaving the viewer in front of a spinner while the TV
    /// is long back on the home screen.
    public static let deadline: TimeInterval = 15

    /// What the receiver reports back — **a byte and not a sentence.**
    ///
    /// The text belongs in the language catalog of the respective program; over the wire goes
    /// the cause and not its translation. Otherwise the TV would speak in its
    /// language into a phone that has set another.
    public enum Receipt: UInt8, Sendable, Equatable {
        case accepted = 0
        /// The packet could not be opened — wrong key or tampered with.
        case unreadable = 1
        /// A bundle from a newer version that this device does not know.
        case wrongVersion = 2
        /// The key has expired. **A case of its own**, because it is the only one with
        /// advice that helps: start over.
        case expired = 3
    }

    /// **What comes after the receipt** — since 2026-09-20 (AP39).
    ///
    /// **The finding:** Before sending, the phone showed a sheet with a **fixed**
    /// list of what travels along, while ``SetupBundle`` packs depending on the
    /// catalog — and a byte with four cases came back. "Parental controls rejected"
    /// (``Takeover/Report/parentalControlsRejected``) could **never** arrive
    /// at the sender this way, although the TV knows it and shows it.
    ///
    /// **Appended and not built in.** The first byte stays what it was; the report
    /// follows behind it as framed JSON. A phone of an older version reads its byte
    /// and hangs up — it gets exactly what it always got. A new one reads on
    /// and gets more. A version number in the protocol would be the second solution for
    /// the same thing and would have to be maintained from today on.
    public typealias ReceiveReport = Takeover.Report

    public enum TestError: Error, Equatable {
        case noService
        case wasCancelled
        case timedOut
        case rejected(Receipt)
    }

    // MARK: - The frame

    /// What a packet looks like on the wire: **four bytes of length, then the content.**
    ///
    /// **TCP knows no messages, only a stream.** Whoever writes without a length field
    /// relies on everything arriving in one piece — and on the home network it almost always does,
    /// which is why the error only shows with the first large bundle.
    /// A bundle with three channel lists and their passwords is large enough for that.
    public enum Frame {

        /// Nobody accepts more than this.
        ///
        /// **One million bytes**, and that is already a hundred times a real
        /// bundle. The number is not against an attacker — who does not know the key —
        /// but against a slipped length field: Without a limit, a
        /// misread header would allocate four gigabytes of memory.
        public static let maxLength = 1_000_000

        public static func pack(_ content: Data) -> Data {
            var length = UInt32(content.count).bigEndian
            var data = Data(bytes: &length, count: 4)
            data.append(content)
            return data
        }

        /// Reads the header — `nil` as long as the four bytes are not all there.
        public static func length(from header: Data) -> Int? {
            guard header.count >= 4 else { return nil }
            let value = header.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
            guard value > 0, value <= UInt32(maxLength) else { return nil }
            return Int(value)
        }

        /// What ``extract(from:)`` found in the buffer.
        public enum Extraction: Equatable, Sendable {
            /// A whole frame — its content without the header, and it is out of the buffer.
            case frame(Data)
            /// Not enough there yet; keep reading.
            case incomplete
            /// **Four bytes of header and still no usable length.** That is not a frame
            /// of ours, and reading on would mean waiting for something that does not come.
            case broken
        }

        /// Takes **one** whole frame from the front of the buffer — the one reader for both
        /// sides of the remote (ultra e5, round A.6, 2026-09-27).
        ///
        /// Until then the same loop stood there twice, in ``OwnWire`` and in the
        /// ``RemoteReceiver``, and only one of the two recognized a broken header: The
        /// phone then quietly kept waiting. That is exactly how two halves of an agreement
        /// drift apart.
        public static func extract(from buffer: inout Data) -> Extraction {
            guard let length = length(from: buffer) else {
                return buffer.count >= 4 ? .broken : .incomplete
            }
            guard buffer.count >= length + 4 else { return .incomplete }
            let start = buffer.startIndex
            let content = buffer.subdata(in: (start + 4)..<(start + 4 + length))
            buffer.removeSubrange(start..<(start + 4 + length))
            return .frame(content)
        }
    }
}

// MARK: - The phone sends

/// Sends a bundle to the TV whose code was just read.
///
/// **The service is found by its name and not by an address.** The QR contains
/// no host name and no IP — both would be wrong as soon as the TV changes its
/// address, and the TV would first have to know either of itself.
/// Bonjour resolves the name at the moment of connecting.
public actor HandoffSender {

    public init() {}

    /// Sends and waits for the receipt.
    ///
    /// **First check whether the key still applies.** An expired code would otherwise lead to
    /// a connection that the TV closes again immediately — and the phone would say
    /// "not reachable" although in truth only the three minutes are up.
    /// - Returns: What arrived over there — `nil` for a TV that does not yet send the
    ///   report (versions before 2026-09-20).
    @discardableResult
    public func send(
        _ bundles: SetupBundle, using key: HandoffKey
    ) async throws -> HandoffWire.ReceiveReport? {
        try await send(
            bundles, using: key,
            on: .service(
                name: key.target, type: HandoffWire.service, domain: "local.",
                interface: nil))
    }

    /// **For the checks:** to a fixed endpoint instead of the Bonjour name — the
    /// path over the loopback to ``HandoffReceiver/startOnLoopback()``.
    @discardableResult
    func send(
        _ bundles: SetupBundle, using key: HandoffKey, on target: NWEndpoint
    ) async throws -> HandoffWire.ReceiveReport? {
        guard key.applies() else { throw HandoffWire.TestError.rejected(.expired) }
        let packet = try HandoffPackage.seal(bundles, using: key)

        let connection = NWConnection(to: target, using: .tcp)
        defer { connection.cancel() }

        return try await withTimeout(connection) {
            try await Self.waitUntilReady(connection)
            try await Self.write(HandoffWire.Frame.pack(packet), to: connection)
            let receipt = try await Self.readReceipt(connection)
            guard receipt == .accepted else {
                throw HandoffWire.TestError.rejected(receipt)
            }
            return await Self.readReport(connection)
        }
    }

    /// **The deadline belongs around the whole process and not at every step.** Three
    /// deadlines of fifteen seconds each would be forty-five — and the viewer is not
    /// waiting for a step but for a result.
    ///
    /// **The abort quiets the connection, and only that ends the work**
    /// (setup check, E1, 2026-09-27). The group waits for **every** child before leaving;
    /// but the work sits in continuations of the network that do not listen to a
    /// cancellation of the task. Until then the deadline threw after fifteen seconds,
    /// and nobody caught it: A Bonjour name that no longer resolved (the code on the
    /// TV expired, the device off) left `.preparing` standing forever, and the
    /// phone showed "sending" until the app was quit. `cancel()` brings every open
    /// continuation to an end — `.cancelled` in the state, an error on reading and sending.
    private func withTimeout<Outcome: Sendable>(
        _ connection: NWConnection,
        _ work: @escaping @Sendable () async throws -> Outcome
    ) async throws -> Outcome {
        try await withThrowingTaskGroup(of: Outcome.self) { group in
            group.addTask {
                try await withTaskCancellationHandler {
                    try Task.checkCancellation()
                    return try await work()
                } onCancel: {
                    connection.cancel()
                }
            }
            group.addTask {
                try await Task.sleep(for: .seconds(HandoffWire.deadline))
                throw HandoffWire.TestError.timedOut
            }
            defer { group.cancelAll() }
            // **`next()` returns whichever finishes first** — the work or the deadline.
            // The deadline throws, so only the work's result arrives here; an
            // empty result cannot occur because the group has two tasks.
            guard let result = try await group.next() else {
                throw HandoffWire.TestError.wasCancelled
            }
            return result
        }
    }

    private static func waitUntilReady(_ connection: NWConnection) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let once = OneShotReply(continuation)
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready: once.succeeded()
                case .failed, .cancelled: once.failed(HandoffWire.TestError.noService)
                default: break
                }
            }
            connection.start(queue: .global(qos: .userInitiated))
        }
    }

    private static func write(_ data: Data, to connection: NWConnection) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(
                content: data,
                completion: .contentProcessed { error in
                    if error != nil {
                        continuation.resume(throwing: HandoffWire.TestError.wasCancelled)
                    } else {
                        continuation.resume()
                    }
                })
        }
    }

    private static func readReceipt(
        _ connection: NWConnection
    ) async throws
        -> HandoffWire.Receipt
    {
        try await withCheckedThrowingContinuation { continuation in
            let once = OneShotReply(continuation)
            connection.receive(minimumIncompleteLength: 1, maximumLength: 1) { data, _, _, _ in
                guard let value = data?.first,
                    let receipt = HandoffWire.Receipt(rawValue: value)
                else {
                    once.failed(HandoffWire.TestError.wasCancelled)
                    return
                }
                once.succeeded(receipt)
            }
        }
    }

    /// Reads the report after the receipt — **`nil` is a valid answer.**
    ///
    /// **A TV of an older version does not send it**, hangs up after the byte, and
    /// exactly then `receive` reports "complete" without data. That must not make the handoff
    /// fail: It **has** succeeded, the receipt was already there. Everything that
    /// goes wrong here costs the viewer a listing — not their setup.
    private static func readReport(
        _ connection: NWConnection
    ) async -> HandoffWire.ReceiveReport? {
        guard let header = await read(4, from: connection),
            let length = HandoffWire.Frame.length(from: header),
            let bodyContent = await read(length, from: connection), bodyContent.count == length
        else { return nil }

        return try? JSONDecoder().decode(HandoffWire.ReceiveReport.self, from: bodyContent)
    }

    /// **Does not throw** — the same ``OneShotReply`` as everywhere here, except that a
    /// failure becomes `nil`. The caller treats missing data as "the
    /// TV sends no report" anyway, and a second path for the same outcome would be
    /// a distinction without consequence.
    private static func read(_ count: Int, from connection: NWConnection) async -> Data? {
        let data: Data? = try? await withCheckedThrowingContinuation { continuation in
            let once = OneShotReply(continuation)
            connection.receive(minimumIncompleteLength: count, maximumLength: count) {
                received, _, _, _ in
                once.succeeded(received)
            }
        }
        return data
    }
}

// MARK: - The TV accepts

/// Accepts a bundle — the TV.
///
/// **One receiver per code.** The key applies for three minutes and **once**; after that
/// the receiver closes, and the screen creates a new one. A service that stays open beyond
/// an expired code would be the note on the door that
/// ``HandoffKey`` explicitly wants to avoid.
public final class HandoffReceiver: @unchecked Sendable {

    private let key: HandoffKey
    /// **`listeners`, `pending`, `accepted` and `failedAttempts` only under the ``lock``.**
    /// They are written from two threads — ``start()``/``stopListening()`` from the main thread,
    /// ``take(_:)`` from the network's queue (setup check, side finding).
    private var listeners: NWListener?
    private var pending: [NWConnection] = []
    private let lock = NSLock()
    private var accepted = false
    private var failedAttempts = 0

    /// A connection whose packet is not yet fully there.
    private struct Candidate {
        let connection: NWConnection
        let since: Date
        /// Where it comes from — for ``RemoteReceiver/maxPerSource``.
        let source: String
    }

    /// **Only under the ``lock``.** Whoever is in here counts against the limits; with the
    /// complete packet a connection is no longer a candidate.
    private var candidates: [Candidate] = []

    /// This long a connection may take from acceptance to the complete packet.
    ///
    /// **The remote receiver's limits, adopted** (ultra e5, round A.4, 2026-09-27).
    /// Until then this receiver accepted unlimited connections and held each one, even
    /// a silent one, to the end: As long as the QR code was up, any device on the network
    /// could flood it with open connections. The phone sends its packet right after
    /// connecting — Face ID comes before —, and a bundle is a few kilobytes;
    /// five seconds are plenty for that. **An expired or rejected connection
    /// does not count as a failed attempt** (``maxFailedAttempts``): Otherwise three
    /// silent connections would use up the code, and the limit would itself be the door to disabling it.
    static let candidateTimeout = RemoteReceiver.candidateTimeout

    /// This many connections may fail per code before the TV gives up.
    ///
    /// **Three and not one** (E12, 2026-09-27): Until then the **first**
    /// connection used up the code, whatever it sent — a port scanner, a Bonjour browser,
    /// an aborted first attempt by the phone. The TV reported "failed"
    /// and closed, and the real transmission behind it found no service anymore. **And not
    /// unlimited:** Whoever does not know the code should not be able to guess it in peace —
    /// even though 256 bits rule that out anyway, a service that takes every failed attempt
    /// in silently would be an open door for the next misunderstanding.
    static let maxFailedAttempts = 3

    /// What arrived — called on a thread of its own, not on the main thread.
    /// **The callback answers instead of merely being informed** (AP39, 2026-09-20).
    ///
    /// It returns what actually became of the bundle — and exactly that goes as
    /// ``HandoffWire/ReceiveReport`` to the sender. Before, this file acknowledged
    /// "accepted" **before** anything was applied; "parental controls rejected"
    /// only arose afterwards and could never reach the sender.
    ///
    /// **`async`, because applying belongs on the main thread.** It writes to
    /// the Keychain and the store; the receiver runs on a network queue. The
    /// receipt therefore waits for the applying — milliseconds, and in return it tells the
    /// truth instead of a declaration of intent.
    private let arrived:
        @Sendable (Result<SetupBundle, HandoffWire.TestError>) async ->
            HandoffWire.ReceiveReport?

    /// - Parameter angekommen: Applies the bundle and reports back **what became
    ///   of it** — the report goes as an attachment of the receipt to the sender. `nil` means
    ///   "nothing to report"; then it stays at the one byte as before 2026-09-20.
    public init(
        key: HandoffKey,
        arrived:
            @escaping @Sendable (Result<SetupBundle, HandoffWire.TestError>) async ->
            HandoffWire.ReceiveReport?
    ) {
        self.key = key
        self.arrived = arrived
    }

    /// Opens the service.
    ///
    /// **The service's name is the target from the key** — exactly the text that is in the
    /// QR. A second name alongside would be a second truth.
    public func start() throws {
        let listeners = try NWListener(using: .tcp)
        listeners.service = NWListener.Service(name: key.target, type: HandoffWire.service)
        listeners.newConnectionHandler = { [weak self] connection in
            self?.take(connection)
        }
        // The same lines as on the remote's receiver (finding 13).
        BonjourProtocol.observe(listeners, who: "Handoff")
        lock.lock()
        self.listeners = listeners
        lock.unlock()
        listeners.start(queue: .global(qos: .userInitiated))
        Diagnose.step(.login, "Handoff: receiver open")
    }

    /// **For the checks:** without Bonjour, on the loopback only — the same seam as
    /// ``RemoteReceiver/startOnLoopback()``.
    func startOnLoopback() async throws -> NWEndpoint.Port {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let listeners = try NWListener(using: parameters)
        listeners.newConnectionHandler = { [weak self] connection in
            self?.take(connection)
        }
        let ready = OneShot<NWEndpoint.Port?>()
        listeners.stateUpdateHandler = { state in
            switch state {
            case .ready: ready.give(listeners.port)
            case .failed, .cancelled: ready.give(nil)
            default: break
            }
        }
        set(listeners)
        listeners.start(queue: .global(qos: .userInitiated))
        guard let link = await ready.value() else { throw HandoffWire.TestError.noService }
        return link
    }

    private func set(_ new: NWListener) {
        lock.withLock { listeners = new }
    }

    public func stopListening() {
        lock.lock()
        let previous = listeners
        let all = pending
        listeners = nil
        pending = []
        candidates = []
        lock.unlock()
        if previous != nil { Diagnose.step(.login, "Handoff: receiver closed") }
        previous?.cancel()
        for connection in all { connection.cancel() }
    }

    /// **Only an opened packet counts** (E12). A second sender on the same code
    /// would be someone of whom the first would learn nothing — and the key applies once.
    /// It is consumed only when a packet opened with it
    /// (``open(_:to:)``); until then every connection may try.
    ///
    /// **But not arbitrarily many at once** (round A.4): at most
    /// ``RemoteReceiver/maxCandidates`` candidates, of which ``RemoteReceiver/maxPerSource``
    /// per address, and each only for the ``candidateTimeout``. As with the remote receiver,
    /// a new connection displaces only an **expired** candidate — the timer
    /// may lag behind —, otherwise it is itself rejected.
    private func take(_ connection: NWConnection) {
        let now = Date()
        let source = RemoteReceiver.source(from: connection.endpoint)
        lock.lock()
        let zu = accepted || listeners == nil
        var displaced: [NWConnection] = []
        var slot = false
        if !zu {
            let expired = candidates.filter { now.timeIntervalSince($0.since) >= Self.candidateTimeout }
            displaced = expired.map(\.connection)
            candidates.removeAll { a in displaced.contains { $0 === a.connection } }
            pending.removeAll { o in displaced.contains { $0 === o } }
            slot =
                candidates.count < RemoteReceiver.maxCandidates
                && candidates.filter({ $0.source == source }).count < RemoteReceiver.maxPerSource
            if slot {
                pending.append(connection)
                candidates.append(Candidate(connection: connection, since: now, source: source))
            }
        }
        let waiting = candidates.count
        lock.unlock()
        for legacy in displaced { legacy.cancel() }
        if !displaced.isEmpty {
            Diagnose.hint(.login, "Handoff: \(displaced.count) expired connections displaced")
        }
        guard !zu else {
            Diagnose.hint(.login, "Handoff: connection rejected after acceptance or close")
            connection.cancel()
            return
        }
        guard slot else {
            Diagnose.hint(
                .login, "Handoff: connection rejected, limit reached (\(waiting) waiting)")
            connection.cancel()
            return
        }
        Diagnose.step(.login, "Handoff: connection accepted (\(waiting) waiting)")
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + Self.candidateTimeout) {
            [weak self] in self?.expire(connection)
        }
        connection.start(queue: .global(qos: .userInitiated))
        read(connection, previous: Data())
    }

    /// The deadline is up — **if the connection is still waiting for its packet, it is dropped.** It
    /// also leaves ``pending``, so that its abort does not count as a failed attempt.
    private func expire(_ connection: NWConnection) {
        lock.lock()
        let stillPending = candidates.contains { $0.connection === connection }
        if stillPending {
            candidates.removeAll { $0.connection === connection }
            pending.removeAll { $0 === connection }
        }
        lock.unlock()
        guard stillPending else { return }
        Diagnose.hint(.login, "Handoff: connection without a packet dropped after the deadline")
        connection.cancel()
    }

    /// The packet is fully there — **no longer a candidate from now on**, the deadline no longer applies.
    private func complete(_ connection: NWConnection) {
        lock.withLock { candidates.removeAll { $0.connection === connection } }
    }

    /// A connection has failed — **the code stays until too many fail.**
    ///
    /// Only on the ``maxFailedAttempts``-th time does the screen learn of it; before that
    /// only this one connection closes, and the real transmission can still come.
    private func fails(_ connection: NWConnection, _ error: HandoffWire.TestError) {
        lock.lock()
        let wasPending = pending.contains { $0 === connection }
        pending.removeAll { $0 === connection }
        candidates.removeAll { $0.connection === connection }
        let counts = wasPending && !accepted
        if counts { failedAttempts += 1 }
        let state = failedAttempts
        let giveUp = counts && failedAttempts >= Self.maxFailedAttempts
        lock.unlock()
        if counts {
            Diagnose.hint(
                .login,
                "Handoff: failed attempt \(state) of \(Self.maxFailedAttempts) (\(error))")
        }
        guard giveUp else { return }
        Diagnose.error(.login, "Handoff: too many failed attempts, code abandoned")
        Task { [arrived] in _ = await arrived(.failure(error)) }
    }

    /// Finishes — **only the first successful transmission.** `false` means: Another
    /// connection was faster, this one is rejected.
    private func accept() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !accepted else { return false }
        accepted = true
        return true
    }

    /// Reads until the frame is full.
    ///
    /// **Piece by piece and not all at once.** What was sent off in one piece on the wire
    /// does not arrive in one piece; see ``HandoffWire/Frame``.
    private func read(_ connection: NWConnection, previous: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) {
            [weak self] part, _, done, error in
            guard let self else { return }
            var data = previous
            if let part { data.append(part) }

            if let length = HandoffWire.Frame.length(from: data) {
                if data.count >= length + 4 {
                    self.complete(connection)
                    self.open(data.dropFirst(4).prefix(length), to: connection)
                    return
                }
            } else if data.count >= 4 {
                // Four bytes there and still no usable length: That is not a packet
                // of ours. Reading on would mean waiting for something that does not come.
                Diagnose.hint(.login, "Handoff: unusable frame header")
                Self.acknowledge(.unreadable, to: connection)
                self.fails(connection, .wasCancelled)
                return
            }

            guard error == nil, !done else {
                connection.cancel()
                self.fails(connection, .wasCancelled)
                return
            }
            self.read(connection, previous: data)
        }
    }

    private func open(_ packet: Data, to connection: NWConnection) {
        // **First the clock, then the key.** An expired code has its own
        // advice — start over —, and that is lost if it is acknowledged as "unreadable".
        guard key.applies() else {
            Diagnose.hint(.login, "Handoff: packet arrived after the code expired")
            Self.acknowledge(.expired, to: connection)
            Task { [arrived] in _ = await arrived(.failure(.rejected(.expired))) }
            return
        }
        do {
            let bundles = try HandoffPackage.open(Data(packet), using: key)
            guard accept() else {
                Diagnose.hint(.login, "Handoff: second transmission on a used code rejected")
                Self.acknowledge(.unreadable, to: connection)
                return
            }
            Diagnose.step(
                .login, "Handoff: packet opened (version \(bundles.version)), code used up")
            // **First apply, then acknowledge** — see ``arrived``.
            Task { [arrived] in
                let report = await arrived(.success(bundles))
                Self.acknowledge(.accepted, report: report, to: connection)
            }
        } catch HandoffPackage.TestError.wrongVersion {
            // **Sealed with the right key** — that is the phone, and its
            // bundle is too new. The screen learns that immediately; it is not a stranger.
            guard accept() else { return }
            Diagnose.hint(
                .login,
                "Handoff: bundle too new, version \(SetupBundle.version) applies here")
            Self.acknowledge(.wrongVersion, to: connection)
            Task { [arrived] in _ = await arrived(.failure(.rejected(.wrongVersion))) }
        } catch {
            // bewusst still: A wrong key and a tampered packet look the same here,
            // and that is the intention — see ``HandoffPackage/open(_:using:)``.
            Diagnose.hint(.login, "Handoff: packet could not be opened")
            Self.acknowledge(.unreadable, to: connection)
            fails(connection, .rejected(.unreadable))
        }
    }

    /// **The receipt goes out before closing.** Whoever closes the connection immediately
    /// lets the phone run into "not reachable" — for a bundle that
    /// arrived long ago.
    ///
    /// **The report follows behind it if there is one** (AP39, 2026-09-20): a byte
    /// as always, then framed JSON. A phone of an older version reads its byte and
    /// hangs up — for that end nothing changes.
    /// **Static, because the receiver may already be gone when acknowledging.** Applying
    /// ends with ``HandoffReceiveModel/stopListening()``, and that releases it;
    /// if the receipt hung on `self`, it would never go out in exactly the case it
    /// was built for — and the sender would run into its deadline.
    private static func acknowledge(
        _ receipt: HandoffWire.Receipt, report: HandoffWire.ReceiveReport? = nil,
        to connection: NWConnection
    ) {
        var outbound = Data([receipt.rawValue])
        if let report, let json = try? JSONEncoder().encode(report) {
            outbound.append(HandoffWire.Frame.pack(json))
        }
        connection.send(
            content: outbound,
            completion: .contentProcessed { _ in connection.cancel() })
    }
}

/// A continuation that answers exactly once.
///
/// **The network's callbacks come multiple times.** A `stateUpdateHandler` reports
/// `.ready` and afterwards `.cancelled`; whoever passes on both resumes the same continuation
/// twice — and that is not an error you see but a crash.
private final class OneShotReply<Value: Sendable>: @unchecked Sendable {
    private var continuation: CheckedContinuation<Value, Error>?
    private let lock = NSLock()

    init(_ continuation: CheckedContinuation<Value, Error>) {
        self.continuation = continuation
    }

    func succeeded(_ value: Value) {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(returning: value)
    }

    func failed(_ error: Error) {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(throwing: error)
    }
}

extension OneShotReply where Value == Void {
    func succeeded() { succeeded(()) }
}
