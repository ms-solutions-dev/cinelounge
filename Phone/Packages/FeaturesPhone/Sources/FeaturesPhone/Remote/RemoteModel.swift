import Core
import Diagnose
import Flows
import Foundation
import Observation
import SecondScreen

/// What is running on the TV and how far along.
///
/// **It holds the wire, not the view.** A connection that hangs on a view
/// drops at the first sheet change — and the viewer who has opened a sheet does not see
/// why the remote then has to reconnect.
///
/// **The state comes from the TV and is not guessed.** Whoever kept calculating on the phone after a
/// jump would have a different truth than the screen for half a second — and then a jump back as soon as the real state arrives. What
/// stands here is always what applies over there.
@MainActor
@Observable
public final class RemoteModel {

    public enum Situation: Equatable, Sendable {
        /// Searching — no TV reported yet.
        case isSearching
        /// Found, but not connected.
        case found([DeviceDiscovery.Device])
        case connecting
        case connected
        case disrupted(PlaybackPhase)
    }

    public private(set) var state: Situation = .isSearching
    public private(set) var status: StateMirror = .idle

    /// Which TV is chosen — for the header.
    public private(set) var chosen: DeviceDiscovery.Device?

    /// The TVs currently reported — **even if a connection stands.**
    ///
    /// **Needed outside the remote** (2026-09-12): the playback target in the
    /// header must know whether a TV is there at all, and `state` alone does not
    /// answer that — once connected, it carries no list any more. A
    /// second finder in the sheet would be a second Bonjour browser for the same question.
    public private(set) var found: [DeviceDiscovery.Device] = []

    /// Whether a TV is reachable at all.
    ///
    /// **A standing connection counts too.** Whoever is connected has the proof in
    /// hand; the list can nevertheless be empty at this moment.
    public var hasTV: Bool { !found.isEmpty || chosen != nil }

    private let wire: any ControlPath
    private var search: Task<Void, Never>?
    private var listening: Task<Void, Never>?

    /// The most recently triggered command — **the chain that all previous ones hang on.**
    ///
    /// Every command waits until its predecessor has left the wire. Without this chain the
    /// send jobs would run side by side, and two quickly typed letters
    /// could reach the TV in reverse order: the order would then depend on the
    /// scheduler and not on the thumb. The check waits with `await broadcast?.value` for
    /// exactly this job and thereby for all before it — instead of running a clock against the load
    /// of the machine.
    private(set) var broadcast: Task<Void, Never>?

    /// Whoever is waiting for a running state from the TV — see ``awaitState()``.
    private var stateWaiters: [CheckedContinuation<Void, Never>] = []

    /// Where the credentials live — **one per TV** (decision 6, 2026-09-25).
    ///
    /// `nil` means: this model keeps none (a check with its own wire). In operation it is
    /// the Keychain — the same store that ``SecondScreen/OwnWire`` describes.
    private let credentials: RemoteCredentialStore?

    /// What stands there after a refused pairing or login — `nil` means: nothing.
    public private(set) var pairingMessage: PairingMessage?

    /// The TVs this phone is paired with.
    public private(set) var pairings: [RemoteCredential] = []

    /// What was last attempted — **for "Reconnect"** (workstream E, D2-1).
    ///
    /// An unfounded rejection also means, since TV `main` `f8da11f`, "the TV has
    /// no room right now", and when pairing the code is **not** used up. The
    /// next step is therefore the same attempt once more, not a new scan.
    enum Attempt {
        case connect(DeviceDiscovery.Device)
        case pair(HandoffKey)
    }
    private var lastAttempt: Attempt?

    /// - Parameters:
    ///   - draht: **can be injected from outside, so that the chain is testable.** `nil` means
    ///     operation: ``SecondScreen/OwnWire`` **with credential store and device name** —
    ///     without credentials it no longer logs in to any TV since the pairing
    ///     (decision 6).
    ///   - ausweise: the same store for the UI (show and forget pairings).
    ///     Without wire and without store, operation takes the Keychain.
    public init(wire: (any ControlPath)? = nil, credentials: RemoteCredentialStore? = nil) {
        let store =
            credentials ?? (wire == nil ? RemoteCredentialStore(SecureStore(thisDeviceOnly: true)) : nil)
        self.credentials = store
        self.wire = wire ?? OwnWire(credentials: store, phoneName: DeviceName.thisDevice)
        pairings = store?.all ?? []
    }

    // MARK: - Koppeln (Entscheidung 6)

    /// Takes a scanned text — **only a pairing code** (`cinelounge-remote://`).
    ///
    /// - Returns: `false` if the text is not one; then everything stays as it is and the
    ///   reader may keep scanning.
    @discardableResult
    public func pair(text: String) async -> Bool {
        guard
            let key = HandoffKey.fromText(text, schema: RemotePairing.schema),
            let pairer = wire as? any PairingRoute
        else { return false }
        pairingMessage = nil
        listening?.cancel()
        state = .connecting
        lastAttempt = .pair(key)
        do {
            try await pairer.pair(using: key)
            chosen = found.first { $0.name == key.target }
            state = .connected
            readPairings()
            listen()
            Diagnose.step(.network, "Remote: paired with \(key.target)")
        } catch {
            // bewusst still: ``fails(_:on:)`` writes the line into the ledger.
            fails(error, for: key.target)
        }
        return true
    }

    /// Forgets the pairing with a TV — **on the phone only**; the TV keeps
    /// its own list and forgets there.
    public func forget(_ credential: RemoteCredential) {
        credentials?.forget(tv: credential.tv)
        readPairings()
    }

    /// Dismisses the message.
    public func dismissMessage() { pairingMessage = nil }

    /// Tries **the same again** — connecting to the same TV or pairing with the
    /// same, still valid code. The first step after `.dismissed`.
    public func reconnect() async {
        switch lastAttempt {
        case .connect(let device): await connect(using: device)
        case .pair(let key):
            await pair(text: key.asText(schema: RemotePairing.schema))
        case nil: pairingMessage = nil
        }
    }

    private func readPairings() {
        pairings = credentials?.all ?? []
    }

    /// A failure — **a pairing message where it is one, otherwise the network fault.**
    ///
    /// **Nothing is deleted here.** The wire itself has already tidied up `.unpaired`
    /// (only it sees whether the rejection was founded); `.dismissed` must **not**
    /// cost the credential — anyone on the home network can send an unfounded rejection.
    private func fails(_ error: any Error, for name: String) {
        chosen = nil
        readPairings()
        if let report = PairingMessage.zu(error) {
            Diagnose.hint(.network, "Remote: pairing with \(name) refused", error)
            pairingMessage = report
            state = found.isEmpty ? .isSearching : .found(found)
        } else {
            Diagnose.error(.network, "Remote: \(name) is not responding", error)
            state = .disrupted(.networkTV)
        }
    }

    // MARK: - Suchen und verbinden

    public func searchDevices() {
        search?.cancel()
        search = Task { [weak self] in
            for await found in DeviceDiscovery.search() {
                guard let self, !Task.isCancelled else { return }
                self.take(found)
            }
        }
    }

    private func take(_ found: [DeviceDiscovery.Device]) {
        // **The list is always recorded, the state not always.** The
        // playback target asks for the devices, even while the remote is running.
        self.found = found
        // **A standing connection does not overwrite the state.** Bonjour keeps reporting
        // during a running session; whoever reset the state on that would throw
        // the viewer out of the remote while it runs perfectly.
        guard case .connected = state else {
            state = found.isEmpty ? .isSearching : .found(found)
            return
        }
    }

    /// **The old listener goes first** (setup check, E7, 2026-09-27): since every
    /// connection has its own stream, the old one ends on reconnecting — and a
    /// listener still hanging around would report the new connection as ended.
    public func connect(using device: DeviceDiscovery.Device) async {
        listening?.cancel()
        state = .connecting
        chosen = device
        pairingMessage = nil
        lastAttempt = .connect(device)
        do {
            try await wire.connect(using: device)
            state = .connected
            listen()
            Diagnose.step(.network, "Remote: connected to \(device.name)")
        } catch {
            // bewusst still: ``fails(_:on:)`` writes the line into the ledger.
            fails(error, for: device.name)
        }
    }

    public func disconnect() async {
        listening?.cancel()
        await wire.disconnect()
        chosen = nil
        status = .idle
        state = .isSearching
        searchDevices()
    }

    /// Receives the stream of states.
    ///
    /// **If the stream ends, the connection is gone.** This is the only place where
    /// the phone learns of the drop: `NWConnection` reports it to the wire, and the wire lets
    /// its stream run out — really so since 2026-09-27 (E7; until then the
    /// stream never ended, and "connected" kept standing here after the drop). Without this line "connected" would stand over a screen
    /// that moves nothing any more.
    private func listen() {
        listening?.cancel()
        listening = Task { [weak self] in
            guard let self else { return }
            for await fresh in self.wire.states {
                guard !Task.isCancelled else { return }
                self.adopt(fresh)
            }
            guard !Task.isCancelled else { return }
            Diagnose.hint(.network, "Remote: connection ended")
            self.chosen = nil
            self.status = .idle
            self.state = .isSearching
            self.searchDevices()
        }
    }

    // MARK: - Senden

    /// Takes over a state from the TV and wakes whoever is waiting for a running one.
    private func adopt(_ fresh: StateMirror) {
        status = fresh
        guard fresh.isPlaying else { return }
        let waiters = stateWaiters
        stateWaiters = []
        for waiter in waiters { waiter.resume() }
    }

    /// Sends a command — **and reports the drop instead of swallowing it.**
    ///
    /// **In order** (2026-09-26): the job attaches to ``broadcast`` and sends
    /// only when the previous command is through.
    public func send(_ command: Command) {
        let previous = broadcast
        broadcast = Task { [weak self] in
            await previous?.value
            guard let self else { return }
            do {
                try await self.wire.send(command)
            } catch {
                Diagnose.error(.network, "Remote: command not delivered", error)
                self.state = .disrupted(.networkTV)
            }
        }
    }

    /// Pause or resume.
    ///
    /// **The state decides and not a switch on the phone.** A "toggle" would be,
    /// with a lost packet, the opposite of what the thumb wanted.
    public func togglePlayback() {
        send(.matches(!status.isRunning))
    }

    public func jumpBy(_ span: TimeInterval) {
        send(.jumpBy(span))
    }

    public func jumpTo(_ portion: Double) {
        guard let duration = status.duration, duration > 0 else { return }
        send(.jumpTo(min(duration, max(0, portion * duration))))
    }

    public func tap(_ text: String) {
        send(.tap(text))
    }

    /// Waits until a running state from the TV has arrived — **for checks only.**
    ///
    /// **For the event and not for a clock.** The first version polled for two seconds
    /// every ten milliseconds and then returned **silently**; under load
    /// (2026-09-26, full package run) the listener had not had its turn in that time, and
    /// the check then compared an empty state. Now ``adopt(_:)`` wakes exactly
    /// when the state is there — no matter how long the main actor was busy.
    func awaitState() async {
        guard !status.isPlaying else { return }
        await withCheckedContinuation { stateWaiters.append($0) }
    }

    // MARK: - The handoff

    /// Continue watching here what is running on the TV.
    ///
    /// **The play job is built from the identifier and the position** — the origin is read from
    /// the format by ``PlaybackJob/origin(zu:)``. Sending it over the wire would mean
    /// keeping the same information twice; if the two diverge, the wrong one
    /// wins.
    ///
    /// **The TV pauses in the process.** Two screens showing the same movie at the
    /// same position are not continued watching but an echo — and with a provider
    /// account with **one** allowed connection the second would be a `509` anyway.
    public func bringHere() -> PlaybackJob? {
        guard let identifier = status.identifier, status.fetchable else { return nil }
        send(.halt)
        return PlaybackJob(
            identifier: identifier,
            origin: PlaybackJob.origin(zu: identifier),
            startAt: status.location)
    }

    /// Continue watching there what is running here.
    ///
    /// **The position travels along, otherwise it would be "start over".** Exactly that difference
    /// is the purpose of the handoff.
    public func pushOver(_ job: PlaybackJob, from location: TimeInterval) {
        send(
            .spieleTitel(
                identifier: job.identifier,
                origin: job.origin.rawValue,
                from: location))
    }
}
