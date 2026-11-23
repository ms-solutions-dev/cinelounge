import Testing

@testable import FeaturesPhone

/// **The finding of 2026-09-07:** *"the sync button is there but does not work …
/// it is supposed to resynchronize IPTV portals and Jellyfin content."* It
/// emptied the ``ProviderCache`` and reloaded the Home screen — and left the library
/// of the media server, the channels and the portals at their old state.
///
/// What is checked here is the **flow**, not the clearing itself: that clearing comes first and
/// rebuilding only afterwards, that the button keeps spinning while the
/// Home screen is rebuilt beneath it, and that it stops when both halves are back
/// — and only then.
@Suite("Synchronization")
struct SynchronizationTests {

    /// What happened in which order.
    ///
    /// A class and no `inout`: The steps are recorded from two closures
    /// that the ``Synchronization`` held.
    @MainActor
    final class Transcript {
        var steps: [String] = []
    }

    /// Builds a sync that touches nothing — no Keychain, no network.
    @MainActor
    private static func probe(
        _ transcript: Transcript, patience: Duration = .seconds(60)
    ) -> Synchronization {
        Synchronization(
            clear: { transcript.steps.append("cleared") },
            channels: { transcript.steps.append("channels fetched") },
            patience: patience)
    }

    // MARK: - Der Ablauf

    /// **First clear, then rebuild.** The other way round the tabs would get the same sources
    /// once more — exactly that was the error the button had.
    @Test("Clearing happens before the tabs are rebuilt")
    @MainActor
    func cleanupBeforeRebuild() async {
        let transcript = Transcript()
        let sync = Synchronization(
            clear: { transcript.steps.append("cleared") },
            channels: {},
            patience: .seconds(60))
        sync.start()
        #expect(sync.state == 0)
        await sync.run?.value
        #expect(transcript.steps == ["cleared"])
        #expect(sync.state == 1)
    }

    /// **Both halves belong to it.** The forced channel fetch is the long one of the
    /// two; without it "sync" would be an empty word for the Live tab.
    @Test("The channel fetch is part of the sync")
    @MainActor
    func channelsBelongToo() async {
        let transcript = Transcript()
        let sync = Self.probe(transcript)
        sync.start()
        await sync.run?.value
        #expect(transcript.steps == ["cleared", "channels fetched"])
    }

    // MARK: - When the button stops spinning

    /// **The button outlives the Home screen it rebuilds.** If the state were in the
    /// ``StartModel``, the icon would stop spinning at the moment the
    /// sync only begins its work.
    @Test("It keeps spinning until the new Home is up")
    @MainActor
    func keepsSpinningUntilResponse() async {
        let sync = Self.probe(Transcript())
        sync.start()
        await sync.run?.value
        #expect(sync.isRunning)
        sync.homeIsReady(after: sync.state)
        #expect(!sync.isRunning)
    }

    /// **The report of the old Home screen does not count.** Between the tap and the
    /// counting up lies the clearing; a load that ends in that time belongs
    /// to the state before and knows nothing of the sync.
    @Test("A report about the old state ends nothing")
    @MainActor
    func oldReportDoesNotCount() async {
        let sync = Self.probe(Transcript())
        sync.start()
        await sync.run?.value
        sync.homeIsReady(after: sync.state - 1)
        #expect(sync.isRunning)
    }

    /// **Without feedback it calms down on its own.** Whoever taps and switches tabs
    /// immediately leaves behind a Home screen that never loads again — an icon that
    /// spins for the rest of the session claims a process that does not exist.
    @Test("If the report stays out, it stops anyway")
    @MainActor
    func watchdogFinished() async {
        let sync = Self.probe(Transcript(), patience: .zero)
        sync.start()
        await sync.run?.value
        await sync.watchdog?.value
        #expect(!sync.isRunning)
    }

    /// **The watchdog of a finished run does not end the next one.** Whoever taps again right after
    /// the end would otherwise have a sync that immediately reports "given up".
    @Test("A cancelled watchdog does not end the next run")
    @MainActor
    func oldWatchdogStaysSilent() async {
        let sync = Self.probe(Transcript())
        sync.start()
        await sync.run?.value
        let oldWatchdog = sync.watchdog
        sync.homeIsReady(after: sync.state)
        #expect(!sync.isRunning)

        sync.start()
        await oldWatchdog?.value
        #expect(sync.isRunning)
    }

    /// **It does not run twice.** The provider account allows one connection; a second
    /// startup would not be faster but the cause of the next "occupied".
    @Test("A second tap during the run does nothing")
    @MainActor
    func noSecondRun() async {
        let transcript = Transcript()
        let sync = Self.probe(transcript)
        sync.start()
        sync.start()
        await sync.run?.value
        #expect(transcript.steps == ["cleared", "channels fetched"])
        #expect(sync.state == 1)
    }

    // MARK: - Was die Ansichten davon merken

    /// **The sync rebuilds every tab**, via the same ID on which a
    /// changed setup also hangs — see ``ShellModel/setupState``.
    @Test("The tabs get their new identifier")
    @MainActor
    func wrapperRebuilds() async {
        let sync = Self.probe(Transcript())
        let wrapper = ShellModel(
            catalogs: .fromAccesses(jellyfin: true), synchronization: sync)
        let previous = wrapper.setupState
        sync.start()
        await sync.run?.value
        #expect(wrapper.setupState == previous + 1)
    }

    /// **Both triggers count on the same counter.** Otherwise every view would have to read two
    /// IDs, and whoever forgets one rebuilds after the one trigger and not
    /// after the other.
    @Test("Setup and sync count together")
    @MainActor
    func bothTriggersCount() async {
        let sync = Self.probe(Transcript())
        let wrapper = ShellModel(
            catalogs: .fromAccesses(jellyfin: true), synchronization: sync)
        wrapper.episode(.fromAccesses(jellyfin: true, channelList: true))
        sync.start()
        await sync.run?.value
        #expect(wrapper.setupState == 2)
    }

    /// **The Home screen reports back on every path** — also on the one that does not
    /// even load. Without that, on a device without setup the button would spin until the
    /// patience ran out.
    @Test("Even a Home without a source reports back")
    @MainActor
    func homeWithoutSourceReportsIn() async {
        let sync = Self.probe(Transcript())
        sync.start()
        await sync.run?.value
        let start = StartModel(source: nil, synchronization: sync)
        #expect(start.isSynced)
        await start.load()
        #expect(!sync.isRunning)
        #expect(!start.isSynced)
    }

    // MARK: - Ziehen nach unten (08.09.)

    /// **The gesture does what the button did.** Since 2026-09-08 the sync button in
    /// the header no longer exists; if ``StartModel/refresh()`` were only a ``load()``,
    /// the app would have lost the capability without anyone noticing — on the
    /// surface both look the same.
    ///
    /// That is why the check works on the **log** and not on a state bit: Clearing and
    /// re-fetching must really have happened.
    @Test("Pulling down clears and fetches anew")
    @MainActor
    func pullSynchronizes() async {
        let transcript = Transcript()
        let sync = Self.probe(transcript)
        let start = StartModel(source: nil, synchronization: sync)

        await start.refresh()

        #expect(transcript.steps == ["cleared", "channels fetched"])
        #expect(sync.state == 1)
    }

    /// **And it returns only when it is through.** `refreshable` keeps its spinner
    /// exactly as long as its body runs. Without the waiting in ``StartModel/refresh()``
    /// it would vanish immediately while the tabs are still being rebuilt — the viewer would see
    /// "done" and afterwards a list that changes once more.
    @Test("Pulling returns only after the sync")
    @MainActor
    func pullWaitsOut() async {
        let sync = Self.probe(Transcript())
        let start = StartModel(source: nil, synchronization: sync)

        await start.refresh()

        #expect(!sync.isRunning, "the sync is still running when the pull returns")
    }

    /// **Pulling twice is not clearing twice.** The reason is at
    /// ``Synchronization/start()``: With an account with exactly one allowed connection
    /// the second startup is not superfluous but the cause of the next "occupied".
    /// Until now the button held that back via `.disabled` — a gesture has no
    /// `.disabled`, so the lock must take effect below.
    @Test("Pulling twice clears once")
    @MainActor
    func pullingTwiceCleansOnce() async {
        let transcript = Transcript()
        let sync = Self.probe(transcript)
        let start = StartModel(source: nil, synchronization: sync)

        async let first: Void = start.refresh()
        async let secondOne: Void = start.refresh()
        _ = await (first, secondOne)

        #expect(transcript.steps == ["cleared", "channels fetched"])
        #expect(sync.state == 1)
    }
}
