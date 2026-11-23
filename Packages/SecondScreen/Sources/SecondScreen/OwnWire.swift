import Diagnose
import Foundation
import Network

/// A control channel of its own over Bonjour on the home network — **the phone's side.**
///
/// **The expensive way, and the only one that controls all three sources.** Jellyfin's
/// session commands would have been cheaper and control **one**: For a channel from the
/// provider list and for a portal title, the media server knows nothing about what plays on
/// the TV — it has never seen the film. That is why this path is built and
/// ``JellyfinSitzungsweg`` remains scaffolding.
///
/// **M3 is thus answered, and by E67 and not by a measurement of its own.**
/// The question was "does a control channel of its own work?"; the setup handoff built
/// the same wire and ran it over the same Bonjour resolution. What comes on top here
/// is the **running** state: A handoff sends a bundle once, a
/// remote holds a connection.
///
/// **Two directions on one connection.** The phone sends ``Command``, the TV
/// sends ``StateMirror`` — both in the same frame as the handoff
/// (``HandoffWire/Frame``: four bytes of length, then JSON). Two connections would be two
/// chances for one to hang, and the viewer could not tell the two apart.
///
/// **Paired since 2026-09-25** (decision 6, ``RemotePairing``). Until then this said
/// "unencrypted, and that is explicitly decided" — with the reason that no secret goes over
/// the wire. That held until the remote keyboard was meant to go into the password field, and
/// it overlooked that anyone on the home network could pause the film. Now the
/// phone signs in with a ``RemoteCredential``, proves it with the first sealed frame,
/// and every frame is AES-GCM under a session key. **Without a credential,
/// ``connect(using:)`` throws** ``RemotePairing/TestError``,
/// with a case that says what to do — no silent failure.
public actor OwnWire: ControlPath {

    /// How long to wait for the TV.
    ///
    /// **Five seconds and not fifteen as for the handoff.** There someone stands in front of the
    /// device with a QR code and has already decided; here they press a name in a list and want
    /// to know whether it works. Five seconds is the limit beyond which you assume that
    /// nothing is happening.
    public static let deadline: TimeInterval = 5

    public private(set) var connected = false

    private var connection: NWConnection?
    private var buffer = Data()

    /// **One stream per connection, and it ends with it** (setup check, E7,
    /// 2026-09-27).
    ///
    /// Until then there was one stream for the whole lifetime of the wire, and ``disconnect()``
    /// never ended it. The remote on the phone learns of the drop exactly at the
    /// end of the loop (`listen` in `RemoteModel`); if the TV forgot the
    /// phone or went off, it kept saying "connected" over a picture that no longer
    /// moved. Now each connection creates a new stream, and whoever reads
    /// ``states`` after connecting gets it — with everything that came since
    /// connecting, the confirmation included.
    public nonisolated var states: AsyncStream<StateMirror> { streamHolder.stream }

    private nonisolated let streamHolder = StreamHolder()

    private let credentials: RemoteCredentialStore?
    private let phoneName: String
    private var login: RemoteLogin?
    /// The credential from the last confirmation — bound to the TV's identifier.
    private var confirmed: RemoteCredential?
    private var ready: OneShot<Result<Void, Error>>?

    /// - Parameters:
    ///   - ausweise: Where the credentials are kept per TV — in the program the Keychain.
    ///     **Without** a store the wire knows no TV and can only pair.
    ///   - telefonname: What the phone is called in the list on the TV.
    public init(credentials: RemoteCredentialStore? = nil, phoneName: String = "iPhone") {
        self.credentials = credentials
        self.phoneName = phoneName
    }

    /// Connect **and sign in** — with the credential stored for this TV.
    ///
    /// **The lookup uses the identifier from the greeting**, not the Bonjour name
    /// (``RemoteCredentialStore``). Throws:
    /// - ``RemotePairing/TestError/unpaired`` if there is no credential **or** the
    ///   TV rejected it with proof — then the credential is already deleted here;
    /// - ``RemotePairing/TestError/dismissed`` on a rejection without proof — the credential
    ///   stays, the UI at most offers to pair again;
    /// - ``RemotePairing/TestError/tvTooOld`` if the TV does not send a greeting.
    public func connect(using target: DeviceDiscovery.Device) async throws {
        try await establish(target, RemoteLogin(credentials: credentials, phoneName: phoneName))
    }

    /// The first pairing — **with the one-time key from the TV's QR code.**
    ///
    /// Creates a new ``RemoteCredential``, sends it across sealed, and stores it
    /// only once the TV has confirmed the sign-in — **bound to the identifier
    /// from its greeting**, and replacing an older one for the same TV. After that
    /// the connection stands as after ``connect(using:)``. Every rejection is called here
    /// ``RemotePairing/TestError/pairingRejected``; an existing credential then stays.
    public func pair(using key: HandoffKey) async throws {
        guard key.applies() else { throw RemotePairing.TestError.pairingRejected }
        let credential = RemoteCredential.fresh(name: key.target)
        let target = DeviceDiscovery.Device(
            name: key.target,
            endpoint: .service(
                name: key.target, type: DeviceDiscovery.service, domain: "local.", interface: nil))
        try await pair(using: key, target: target, credential: credential)
    }

    func pair(
        using key: HandoffKey, target: DeviceDiscovery.Device, credential: RemoteCredential
    ) async throws {
        try await establish(
            target,
            RemoteLogin(
                credential: credential, pairing: key, phoneName: phoneName,
                existing: credentials))
        if let bound = confirmed { credentials?.create(bound) }
    }

    /// Connection, greeting, sign-in, confirmation — **one deadline for everything.**
    private func establish(_ target: DeviceDiscovery.Device, _ newLogin: RemoteLogin) async throws {
        await disconnect()

        let parameters = NWParameters.tcp
        parameters.includePeerToPeer = true
        let incoming = NWConnection(to: target.endpoint, using: parameters)
        connection = incoming
        streamHolder.begin()
        login = newLogin
        confirmed = nil
        let done = OneShot<Result<Void, Error>>()
        ready = done

        try await waitUntilReady(incoming)
        read(incoming)

        let clock = Task { [weak self] in
            try await Task.sleep(for: .seconds(Self.deadline))
            let greeted = await self?.login?.greeted ?? false
            done.give(
                .failure(
                    greeted
                        ? HandoffWire.TestError.timedOut : RemotePairing.TestError.tvTooOld))
        }
        defer { clock.cancel() }
        let pairingProfile = newLogin.pairing != nil
        switch await done.value() {
        case .success:
            // **The connection must still be up.** The confirmation can arrive in the same read
            // as a frame that disconnects it again (E13); without this
            // line the wire would afterwards report "connected" without a connection.
            guard connection === incoming, login != nil else {
                Diagnose.hint(.network, "Remote: confirmed, but dropped again right away")
                throw HandoffWire.TestError.wasCancelled
            }
            connected = true
            Diagnose.step(
                .network,
                pairingProfile ? "Remote: paired and connected" : "Remote: connected")
        case .failure(let error):
            Diagnose.hint(
                .network,
                "Remote: \(pairingProfile ? "pairing" : "connection") failed (\(error))")
            await disconnect()
            throw error
        }
    }

    /// Wait until the connection is up — **or until the deadline expires.**
    ///
    /// **An `NWConnection` without a deadline waits indefinitely.** A TV that is off
    /// answers nothing and rejects nothing; without this clock the phone would show
    /// "connecting…" until someone quits the app.
    private func waitUntilReady(_ incoming: NWConnection) async throws {
        let reply = OneShot<Result<Void, Error>>()

        incoming.stateUpdateHandler = { state in
            switch state {
            case .ready: reply.give(.success(()))
            case .failed(let error): reply.give(.failure(error))
            case .cancelled: reply.give(.failure(HandoffWire.TestError.wasCancelled))
            default: break
            }
        }
        incoming.start(queue: .global(qos: .userInitiated))

        let clock = Task {
            try await Task.sleep(for: .seconds(Self.deadline))
            reply.give(.failure(HandoffWire.TestError.timedOut))
        }
        defer { clock.cancel() }

        switch await reply.value() {
        case .success: return
        case .failure(let error):
            incoming.cancel()
            connection = nil
            throw error
        }
    }

    public func disconnect() async {
        connection?.cancel()
        connection = nil
        connected = false
        buffer = Data()
        login = nil
        ready?.give(.failure(HandoffWire.TestError.wasCancelled))
        ready = nil
        streamHolder.finish()
    }

    /// Send a command — **only sealed**, otherwise not at all.
    public func send(_ command: Command) async throws {
        guard let connection, connected, var session = login else {
            throw HandoffWire.TestError.noService
        }
        let content = try session.wrap(command)
        login = session
        let packet = HandoffWire.Frame.pack(content)

        let reply = OneShot<Error?>()
        connection.send(
            content: packet,
            completion: .contentProcessed { reply.give($0) })
        if let error = await reply.value() { throw error }
    }

    // MARK: - What comes from the TV

    /// Reads continuously and puts every complete frame into the stream.
    ///
    /// **The buffer is the reason a frame exists.** TCP knows no
    /// messages: Two states can arrive in one read, one in two.
    /// Whoever reads without a buffer gets half a JSON at the first longer title.
    private func read(_ connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) {
            [weak self] data, _, done, error in
            guard let self else { return }
            Task {
                guard await self.belongs(connection) else { return }
                if let data, !data.isEmpty { await self.take(data) }
                if error != nil || done {
                    if await self.connected {
                        Diagnose.hint(.network, "Remote: connection to the TV lost")
                    }
                    await self.disconnect()
                    return
                }
                await self.keepReading()
            }
        }
    }

    /// Whether this connection is still the current one.
    ///
    /// **A reader of the old connection must not disconnect the new one.** After ``disconnect()``
    /// the old reader reports "aborted" — and if that arrived while a new connection
    /// is already being made, it would tear the new one down with it. Noticed on the first
    /// reconnect over the real wire (2026-09-25).
    private func belongs(_ which: NWConnection) -> Bool { connection === which }

    private func keepReading() {
        guard let connection else { return }
        read(connection)
    }

    /// Every complete frame through the ``RemoteLogin``.
    ///
    /// **A frame that cannot be opened ends the connection** — unlike
    /// before the pairing, when an unreadable mirror was skipped. Sealed,
    /// it can only be wrong if someone writes in between.
    ///
    /// **A broken header too** (round A.6): Until then this loop read by itself and
    /// then quietly kept waiting, while the ``RemoteReceiver`` hung up at the same spot.
    /// Both now read through ``HandoffWire/Frame/extract(from:)``.
    private func take(_ data: Data) async {
        buffer.append(data)
        while var session = login {
            let content: Data
            switch HandoffWire.Frame.extract(from: &buffer) {
            case .frame(let total): content = total
            case .incomplete: return
            case .broken:
                Diagnose.hint(.network, "Remote: unusable frame header from the TV")
                ready?.give(.failure(RemotePairing.TestError.unreadable))
                await disconnect()
                return
            }
            let events: [RemoteLogin.Event]
            do {
                events = try session.take(content)
            } catch {
                // **Only a rejection with proof deletes the credential** (finding 1.2) — and never
                // when pairing, where the credential does not exist yet.
                if error == .unpaired, session.pairing == nil, let identifier = session.tv {
                    credentials?.forget(tv: identifier)
                    Diagnose.hint(.login, "Remote: proven rejection, credential deleted")
                } else {
                    Diagnose.hint(.login, "Remote: sign-in rejected (\(error))")
                }
                ready?.give(.failure(error))
                await disconnect()
                return
            }
            login = session
            for event in events {
                switch event {
                case .send(let frame):
                    connection?.send(
                        content: HandoffWire.Frame.pack(frame),
                        completion: .contentProcessed { _ in })
                case .confirmed(let credential):
                    confirmed = credential
                    ready?.give(.success(()))
                case .state(let state):
                    streamHolder.give(state)
                }
            }
        }
    }
}

/// The stream of the running connection — **readable from outside without `await`.**
///
/// A lock and not an actor, because ``OwnWire/states`` is `nonisolated`
/// (``ControlPath``): The UI fetches the stream without waiting for the wire.
private final class StreamHolder: @unchecked Sendable {
    private let lock = NSLock()
    private var current: AsyncStream<StateMirror>
    private var output: AsyncStream<StateMirror>.Continuation?

    /// **An ended stream before the first connection** — whoever listens without a connection
    /// learns immediately that there is nothing to hear.
    init() {
        let (stream, output) = AsyncStream<StateMirror>.makeStream()
        output.finish()
        current = stream
    }

    var stream: AsyncStream<StateMirror> {
        lock.lock()
        defer { lock.unlock() }
        return current
    }

    /// A new stream for a new connection; an old one ends in the process.
    func begin() {
        let (stream, incoming) = AsyncStream<StateMirror>.makeStream()
        lock.lock()
        let old = output
        current = stream
        output = incoming
        lock.unlock()
        old?.finish()
    }

    func give(_ state: StateMirror) {
        lock.lock()
        let pending = output
        lock.unlock()
        pending?.yield(state)
    }

    func finish() {
        lock.lock()
        let pending = output
        output = nil
        lock.unlock()
        pending?.finish()
    }
}
