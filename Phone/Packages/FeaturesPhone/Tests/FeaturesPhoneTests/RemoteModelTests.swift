import Foundation
import SecondScreen
import Testing

@testable import FeaturesPhone

/// A wire that sends nothing to the network — **so that the chain can be checked.**
///
/// **Without it nothing at all could be checked of this model**, because each of its
/// actions ends in an `NWConnection`. What is checked here is not the network —
/// that is decided by a phone in front of a TV —, but the rules before it: which
/// command follows from which state, and what happens when the other side refuses.
private actor ProbeWire: ControlPath {

    var connected = false
    /// What was sent, in order.
    private(set) var sent: [Command] = []
    /// Whether connecting fails.
    var failsOnConnect = false

    private let holder: AsyncStream<StateMirror>.Continuation
    nonisolated let states: AsyncStream<StateMirror>

    init() {
        // **`makeStream` and no unpacked optional.** `AsyncStream { }` hands out the
        // holder only inside the closure, and smuggling it out needs a `!` —
        // which this project's linter rightly rejects.
        let (stream, holder) = AsyncStream<StateMirror>.makeStream()
        states = stream
        self.holder = holder
    }

    func makeFail() { failsOnConnect = true }

    func connect(using target: DeviceDiscovery.Device) async throws {
        if failsOnConnect { throw HandoffWire.TestError.timedOut }
        connected = true
    }

    func disconnect() async { connected = false }

    func send(_ command: Command) async throws {
        guard connected else { throw HandoffWire.TestError.noService }
        if blocksFirst {
            blocksFirst = false
            await withCheckedContinuation { continuation in
                lock = continuation
                parked?.resume()
                parked = nil
            }
        }
        sent.append(command)
    }

    /// Whether the next command gets stuck in the wire until ``open()`` releases it.
    private var blocksFirst = false
    private var lock: CheckedContinuation<Void, Never>?
    private var parked: CheckedContinuation<Void, Never>?

    /// Holds the next command in the wire — **like a line that is stalling right now.**
    func blockFirst() { blocksFirst = true }

    /// Returns as soon as the held command is in the wire.
    func waitUntilParked() async {
        guard lock == nil else { return }
        await withCheckedContinuation { parked = $0 }
    }

    func open() {
        lock?.resume()
        lock = nil
    }

    /// Plays in a state as if it came from the TV.
    func notify(_ state: StateMirror) { holder.yield(state) }
}

/// The remote — **the rules that come before the wire.**
@Suite("Remote")
@MainActor
struct RemoteModelTests {

    private func makeDevice() -> DeviceDiscovery.Device {
        DeviceDiscovery.Device(
            name: "Living Room",
            endpoint: .service(name: "Living Room", type: "_x._tcp", domain: "local", interface: nil))
    }

    @Test("Without a connection the state is 'searching'")
    func initialState() {
        let model = RemoteModel(wire: ProbeWire())

        #expect(model.state == .isSearching)
        #expect(model.status == .idle)
    }

    /// **A TV that does not answer gets its own state** — and not
    /// "No answer from the media server". The server is not involved in a remote;
    /// naming it would send the viewer the same wrong way as the message from 2026-09-06, which
    /// blamed every portal error on the server.
    @Test("If connecting fails, the TV state is shown")
    func failedConnect() async {
        let wire = ProbeWire()
        await wire.makeFail()
        let model = RemoteModel(wire: wire)

        await model.connect(using: makeDevice())

        #expect(model.state == .disrupted(.networkTV))
        #expect(model.chosen == nil, "a TV that does not answer is not kept as chosen")
    }

    @Test("After connecting the name is shown")
    func successfulConnect() async {
        let model = RemoteModel(wire: ProbeWire())

        await model.connect(using: makeDevice())

        #expect(model.state == .connected)
        #expect(model.chosen?.name == "Living Room")
    }

    /// **The state decides and not a switch on the phone.** A "toggle" would be,
    /// with a lost packet, the opposite of what the thumb wanted.
    @Test("The pause button sends the opposite of the reported state")
    func pauseFollowsState() async {
        let wire = ProbeWire()
        let model = RemoteModel(wire: wire)
        await model.connect(using: makeDevice())

        model.togglePlayback()
        await model.broadcast?.value

        #expect(await wire.sent == [.matches(true)], "if it is standing still, it is played")
    }

    /// **Without a duration there is no jumping.** For a channel there is no position to
    /// jump to — and a command into nothing would be a command whose effect
    /// somebody is waiting for.
    @Test("A jump to a portion needs a duration")
    func skipNeedsDuration() async {
        let wire = ProbeWire()
        let model = RemoteModel(wire: wire)
        await model.connect(using: makeDevice())

        model.jumpTo(0.5)
        await model.broadcast?.value

        #expect(model.broadcast == nil, "no command was triggered at all")
        #expect(await wire.sent.isEmpty)
    }

    /// **The sequence of commands is the sequence of thumbs.** If the line stalls at the first
    /// letter, the second must not overtake it — otherwise "ba" arrives at the TV
    /// where "ab" was typed.
    @Test("Commands reach the TV in the order in which they were given")
    func order() async {
        let wire = ProbeWire()
        let model = RemoteModel(wire: wire)
        await model.connect(using: makeDevice())
        await wire.blockFirst()

        model.tap("a")
        model.tap("b")
        await wire.waitUntilParked()
        await Task.yield()
        await wire.open()
        await model.broadcast?.value

        #expect(await wire.sent == [.tap("a"), .tap("b")])
    }

    // MARK: - The handoff

    /// **A channel cannot be fetched**, and that is no restriction: it runs
    /// equally far everywhere, one would arrive at the same position. What "bring here" promises
    /// is "continue watching at *my* position" — and that exists only where there is a position.
    @Test("Without an identifier and without a duration there is nothing to fetch")
    func nothingToFetch() async {
        let wire = ProbeWire()
        let model = RemoteModel(wire: wire)
        await model.connect(using: makeDevice())

        #expect(model.bringHere() == nil, "without a running title")
        await wire.notify(StateMirror(title: "Das Nordlicht", identifier: "sender-1", location: 500))
        await model.awaitState()

        #expect(model.bringHere() == nil, "a channel has no duration")
    }

    /// **The origin does not travel along, it is in the identifier.** Sending it in addition
    /// would mean keeping the same information twice — and if the two
    /// drift apart, the wrong one wins.
    @Test("The fetched job carries identifier, origin and position")
    func fetchedJob() async {
        let wire = ProbeWire()
        let model = RemoteModel(wire: wire)
        await model.connect(using: makeDevice())
        await wire.notify(
            StateMirror(title: "Morrowfeld", identifier: "abc123", location: 2653, duration: 8297))
        await model.awaitState()

        let job = model.bringHere()

        #expect(job?.identifier == "abc123")
        #expect(job?.startAt == 2653)
        #expect(job?.origin == .jellyfin, "read from the format of the identifier")
    }

    /// **The TV stops before it continues here.** Two screens with the same
    /// film at the same position are no Continue Watching but an echo — and with an
    /// account with **one** permitted connection the second would be a `509` anyway.
    @Test("Fetching pauses the TV")
    func fetchHereHoldsOn() async {
        let wire = ProbeWire()
        let model = RemoteModel(wire: wire)
        await model.connect(using: makeDevice())
        await wire.notify(
            StateMirror(title: "Morrowfeld", identifier: "abc123", location: 2653, duration: 8297))
        await model.awaitState()

        _ = model.bringHere()
        await model.broadcast?.value

        #expect(await wire.sent == [.halt])
    }

    /// **The position travels along, otherwise it would be "start from the beginning".** Exactly that difference
    /// is the purpose of the handoff.
    @Test("Pushing over sends the position along")
    func overWithPosition() async {
        let wire = ProbeWire()
        let model = RemoteModel(wire: wire)
        await model.connect(using: makeDevice())

        model.pushOver(
            PlaybackJob(identifier: "abc123", origin: .jellyfin), from: 1234)
        await model.broadcast?.value

        #expect(
            await wire.sent
                == [.spieleTitel(identifier: "abc123", origin: "medienserver", from: 1234)])
    }

    /// **There is no volume, and that is a measurement.** tvOS has no
    /// interface with which an app sets the system volume; that of an Apple TV
    /// belongs to the TV on the HDMI cable. This check records that the omission
    /// is written down — otherwise someone builds it in again on the next pass.
    @Test("Volume is explicitly not built")
    func noVolume() {
        #expect(ControlLimits.volumeUnavailable)
    }
}

/// The limits — **what does not work from here.**
@Suite("Control limits")
struct ControlLimitsTests {

    /// **By duration and not by origin.** A channel has no end and therefore reports
    /// none; a repackager stream likewise. The question "is there an end" is
    /// the same as "can one jump there".
    @Test("Without a duration seeking is not possible")
    func scrubNeedsDuration() {
        #expect(!ControlLimits.canSeek(StateMirror(title: "Das Nordlicht", location: 500)))
        #expect(!ControlLimits.canSeek(StateMirror(title: "x", duration: 0)))
        #expect(ControlLimits.canSeek(StateMirror(title: "Morrowfeld", duration: 8297)))
    }

    /// **A keyboard that can be opened while no field stands over there types into
    /// nothing** — and one notices only when one has finished typing.
    @Test("Typing goes only into an open field")
    func typingNeedsField() {
        #expect(!ControlLimits.canTap(StateMirror(title: "Morrowfeld")))
        #expect(ControlLimits.canTap(StateMirror(keyboardOpen: true)))
    }

    @Test("Without a running title there is nothing to operate")
    func operatingNeedsTitle() {
        #expect(!ControlLimits.canControl(.idle))
        #expect(ControlLimits.canControl(StateMirror(title: "Morrowfeld")))
    }

}

/// Where playback happens — **and that the choice has an effect.**
///
/// **The finding from 2026-09-12, from the product owner, with a screenshot:** the button
/// in the header between profile and download led to a screen that did not look right.
/// The button landed in the developer placeholder ("ziel · Anteil 0.45").
///
/// **Behind it lay four untruths in one place**, and none of them was a crash:
/// ``TargetSheet`` had stood finished since 2026-09-06 and was called only by the detail page
/// — there with `isTVReachable: false` **hard-wired**, the Apple TV row
/// grayed out forever. The target hung on the ``DetailModel`` and thus on one title,
/// while ``HeaderRow`` has said since the same day that it applies to the app. The choice
/// set a value that nobody read. And ``DetailModel/buttonLabel(target:)`` wrote
/// "on Apple TV" on a button that afterwards opened this phone's player.
///
/// What is checked is therefore not the sheet but **what follows from a choice.**
@Suite("The playback target")
@MainActor
struct PlaybackTargetTests {

    private func makeDevice() -> DeviceDiscovery.Device {
        DeviceDiscovery.Device(
            name: "Living Room",
            endpoint: .service(
                name: "Living Room", type: DeviceDiscovery.service, domain: "local.", interface: nil))
    }

    /// **Every check gets its own synchronization.**
    ///
    /// ``ShellModel`` takes it with the default ``Synchronization/shared`` —
    /// a **process-wide** singleton. Swift Testing runs checks side by side; without a version of its own they all
    /// reach into the same state, and
    /// `wire.sent` then carries an entry that a neighboring check triggered.
    ///
    /// **The finding came from the run itself** (2026-09-23): two checks failed in the
    /// full suite and were green three times in a row individually. The same kind as the
    /// race over ``Core/ProfilePointer`` in the sister project — a shared state that
    /// a convenient default hides.
    private func wrapper(_ wire: ProbeWire) -> ShellModel {
        ShellModel(
            synchronization: Synchronization(),
            remote: RemoteModel(wire: wire))
    }

    /// **The target is the connection and no second field beside it.** A stored
    /// value could say "Apple TV" while nothing is there — and exactly this kind of information
    /// was the reason why the sheet had no effect before.
    @Test("Without a connection the target is this phone")
    func withoutConnectionHere() {
        #expect(wrapper(ProbeWire()).target == .phone)
    }

    @Test("With a connected TV the target is the TV")
    func withConnectionThere() async {
        let model = wrapper(ProbeWire())
        await model.remote.connect(using: makeDevice())
        #expect(model.target == .tv)
    }

    /// **The default stays this phone's player** — that too is a promise.
    @Test("Without a connection the loud button plays here")
    func withoutConnectionPlayerHere() async {
        let wire = ProbeWire()
        let model = wrapper(wire)
        model.start(PlaybackJob(identifier: "film-1"), from: 0)
        #expect(model.navigator.current == .player)
        #expect(await wire.sent.isEmpty)
    }

    /// **The core of the handoff:** title and position go over, and the phone then stands
    /// at the remote — not on the detail page while something starts
    /// in the other room.
    @Test("With a connection the title goes to the TV along with its position")
    func withConnectionOver() async {
        let wire = ProbeWire()
        let model = wrapper(wire)
        await model.remote.connect(using: makeDevice())

        // **A real portal identifier** — the separator is `|` and not `:`
        // (``PortalKit/PortalItemID/separator``). With colons it falls through to the
        // media server, and the check would then prove the opposite of what it
        // claims.
        model.start(PlaybackJob(identifier: "serieshub|bowline|1-1", startAt: 610), from: 610)
        await model.remote.broadcast?.value

        #expect(
            await wire.sent == [
                .spieleTitel(identifier: "serieshub|bowline|1-1", origin: "portale", from: 610)
            ])
        #expect(model.navigator.current == .remote)
    }

    /// **The position travels along, otherwise it would be "start from the beginning"** — exactly that difference
    /// is the purpose. At zero it stays zero and is not omitted.
    @Test("From the start goes over as zero and not as an omission")
    func fromStartIsZero() async {
        let wire = ProbeWire()
        let model = wrapper(wire)
        await model.remote.connect(using: makeDevice())

        model.start(PlaybackJob(identifier: "film-7"), from: 0)
        await model.remote.broadcast?.value

        #expect(await wire.sent == [.spieleTitel(identifier: "film-7", origin: "medienserver", from: 0)])
    }

    /// **Chosen is not connected.** ``RemoteModel/chosen`` is already set
    /// while the wire is still being set up — so that the header shows the
    /// TV in that second. A command into a connection that is not up would arrive nowhere,
    /// and the phone would then stand at a remote for something that never started.
    @Test("If connecting fails, it plays here")
    func failedConnectPlaysHere() async {
        let wire = ProbeWire()
        await wire.makeFail()
        let model = wrapper(wire)
        await model.remote.connect(using: makeDevice())

        model.start(PlaybackJob(identifier: "film-1"), from: 0)
        #expect(model.navigator.current == .player)
        #expect(await wire.sent.isEmpty)
    }

    /// **The sheet asks the model and not Bonjour.** Before, reachability stood
    /// as `false` in the call; that grayed out the Apple TV row in every situation.
    @Test("Without a discovered TV none is reachable, with a connection one is")
    func reachability() async {
        let model = wrapper(ProbeWire())
        #expect(model.remote.hasTV == false)
        await model.remote.connect(using: makeDevice())
        #expect(model.remote.hasTV)
    }

    /// **"This iPhone" disconnects.** Whoever wants to play here does not want to play over there
    /// at the same time — and a target that cannot be taken back is the bolt that had already
    /// been noticed once in this project the same day.
    @Test("Back to this phone disconnects")
    func backToPhone() async {
        let model = wrapper(ProbeWire())
        await model.remote.connect(using: makeDevice())
        #expect(model.target == .tv)

        await model.remote.disconnect()
        #expect(model.target == .phone)
    }
}
