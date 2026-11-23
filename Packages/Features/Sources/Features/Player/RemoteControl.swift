import Core
import DesignSystem
import Foundation
import SecondScreen

/// The bridge between the ``SecondScreen/RemoteReceiver`` and the running player.
///
/// **It decides nothing.** What a command does is known to ``PlayerModel``; this file
/// translates and passes on. Without this separation half the playback logic would stand
/// twice — once for the Siri Remote, once for the phone —, and the two
/// would drift apart at the first refactoring.
///
/// **It lives as long as the app and not as long as the player.** That was the
/// first draft, and it had a hole: a phone that presses "continue watching on the TV"
/// finds a TV that is **playing nothing right now** — and
/// exactly then nobody was listening. The receiver therefore runs from the start; a TV
/// without a running film reports ``StateMirror/idle``, and that is information and
/// not a gap.
///
/// **The player hooks in and out again.** ``adopt(_:)`` on appearing,
/// ``release()`` on leaving — in between it reports what the player does.
///
/// **Reporting happens on every change and not on a clock.** The player knows every
/// movement at the moment it happens; a phone that asked on a clock
/// would put seven thousand questions for a two-hour film to get seven answers that
/// differ.
public final class RemoteControl {

    private let receiver: RemoteReceiver
    /// What this TV is called — the target in the pairing code.
    public let name: String
    /// The paired phones, in the Keychain (decision 6, 2026-09-25).
    private let pairings: RemotePairingLedger
    private weak var player: PlayerModel?
    /// The listener on the player. See ``observe(_:)``.
    private var observation: Task<Void, Never>?

    /// - Parameter name: What this TV is called in the phone's list.
    ///
    /// **The device name and not "CineLounge"** — the rule lives in
    /// ``SecondScreen/ServiceName/remote`` (AP58 R5, finding Z1).
    ///
    /// **Paired since 2026-09-25:** the book of phones lives in the Keychain, and
    /// a phone without pairing sees as the title the sentence `remote.pair.oldPhoneHint` in the
    /// language of this TV — the only thing an older phone can still read.
    public init(
        name: String = ServiceName.remote,
        pairings: RemotePairingLedger = RemotePairingLedger(SecureStore(thisDeviceOnly: true))
    ) {
        self.name = name
        self.pairings = pairings
        receiver = RemoteReceiver(
            name: name, pairings: pairings,
            hint: LanguageFallback.message("remote.pair.oldPhoneHint")
                ?? RemotePairing.defaultHint)
    }

    // MARK: - Pairing

    /// The paired phones, most recent first.
    public var phones: [RemotePairingLedger.Phone] { pairings.phones }

    /// Puts up a pairing code — **the same one-time key as for the handoff**,
    /// three minutes and once. `paired` is called as soon as a phone has used it.
    public func openPairing(
        paired: @escaping @Sendable (RemotePairingLedger.Phone) -> Void
    ) -> HandoffKey {
        let key = HandoffKey.fresh(target: name)
        receiver.paired = paired
        receiver.openPairing(key)
        return key
    }

    public func closePairing() {
        receiver.closePairing()
        receiver.paired = nil
    }

    /// Forgets a phone — its connection drops immediately.
    public func forget(_ phone: RemotePairingLedger.Phone) {
        receiver.forget(phone: phone.id)
    }

    /// The one for the whole app.
    ///
    /// **Shared and not per view**, because a second listener occupied the same service name:
    /// Bonjour then showed two entries for the same TV, of which one can do nothing.
    public static let shared = RemoteControl()

    /// Starts listening — **without a player and already at launch.**
    /// Whether the listener is already running — **a second start would be a second service.**
    ///
    /// Since 2026-09-20 (AP39) it is started from two places: at app launch,
    /// so that the remote is reachable already on the sign-in screen, and
    /// still in ``MainView/onStart()``, where it has stood since AP8. The second call
    /// is meant to do nothing instead of opening a second `NWListener` under the same name
    /// — which does not throw but yields two services on the network, of which the
    /// phone catches the wrong one.
    private var isRunning = false

    ///
    /// **The board registers here and not only at the player** (2026-09-25). Until
    /// then ``SecondScreen/RemoteKeyboard/changed`` hung only on ``observe(_:)`` — that is
    /// only once a film was running. On the sign-in screen, for which AP39 had
    /// moved the listener forward, the phone therefore never learned that a field was open.
    public func start() {
        guard !isRunning else { return }
        isRunning = true
        RemoteKeyboard.changed = { [weak self] in Task { @MainActor in self?.notify() } }
        receiver.perform = { [weak self] command in
            // **To the main thread and not where the frame arrived.** `PlayerModel`
            // is `@MainActor`; a command that reached in directly from the queue of
            // `Network.framework` would be a data race with the
            // UI.
            Task { @MainActor in self?.perform(command) }
        }
        do {
            try receiver.start()
        } catch {
            Diagnostics.playbackProblem(
                "Remote: listener not started — \(error)", since: nil)
            return
        }
        notify()
    }

    /// A player is there — from now on what it does is reported.
    public func adopt(_ player: PlayerModel) {
        self.player = player
        observe(player)
        notify()
    }

    /// The player leaves — **the listener stays.**
    public func release() {
        observation?.cancel()
        player = nil
        notify()
    }

    public func stopListening() {
        receiver.stopListening()
        observation?.cancel()
        player = nil
    }

    /// What happens when the phone wants to open a title.
    ///
    /// **A closure and no source here.** Opening a title means finding it in the
    /// TV's catalogs and sending the navigation there — both
    /// belong to the shell. This file knows neither sources nor navigation, and it should
    /// not get to know either.
    public var openTitle: ((_ identifier: String, _ origin: String, _ from: TimeInterval) -> Void)?

    // MARK: - Inbound

    /// **The switch first, then the player** (Setup check, E9, 2026-09-27). "Open
    /// title" and the remote keyboard need no running player — the keyboard is
    /// built precisely for sign-in, settings and search. Until then this
    /// method discarded `.tap` without a player, and the phone typed into the void.
    private func perform(_ command: Command) {
        switch RemoteSwitch.derive(command, playerPresent: player != nil) {
        case .done, .discarded:
            return
        case .title(let identifier, let origin, let from):
            guard let openTitle else {
                // **Rejected and not half executed.** Whoever has no way to open the title
                // should not do the most similar thing — such as restarting the running film
                // from the beginning because a position came along.
                Diagnostics.playbackStep(
                    "Remote: no way to open a title", since: nil)
                return
            }
            openTitle(identifier, origin, from)
        case .player:
            guard let player else { return }
            switch command {
            case .matches(let expectedValue):
                // **The command says what should apply, and the player switches.** A
                // "toggle" over the wire would, with a lost packet, be the opposite
                // of what the thumb wanted — that is why the comparison stands here.
                if player.isPlaying != expectedValue { player.togglePause() }
            case .jumpTo(let location):
                player.seek(to: location)
            case .jumpBy(let span):
                player.skip(by: span)
            case .audioTrack(let number):
                player.selectAudioTrack(number)
            case .subtitles(let number):
                player.selectSubtitleTrack(number)
            case .halt:
                player.close()
            case .spieleTitel, .tap:
                break
            }
        }
    }

    // MARK: - Outbound

    /// Reports on every change — **and not on a clock.**
    ///
    /// **Since AP32 (2026-09-11) via ``Observation`` instead of Combine.** Previously there hung
    /// four `sink`s here on the model's publishers; `@Observable` has none.
    ///
    /// **The listener carries exactly once**, which is why it re-arms itself at the end. And it
    /// reports **after** the change: `onChange` comes before the new value stands — whoever
    /// read immediately there would send the old one over the wire. The hop via a task
    /// is therefore no convenience but the condition for the number
    /// being correct.
    ///
    /// **The throttling of the position has been dropped, and it was no longer one.** The old
    /// version throttled `position` to half a second, with the reason "it changes
    /// four times per second". That has not been true for a long time: ``PlayerModel/tick()``
    /// writes it **at a half-second pace** (``PlayerModel/tickInterval``) — the throttle
    /// lay exactly on the pace and never took anything away.
    private func observe(_ player: PlayerModel) {
        observation?.cancel()
        listen(player)
        RemoteKeyboard.changed = { [weak self] in Task { @MainActor in self?.notify() } }
    }

    /// One pass of the listener — see ``observe(_:)``.
    private func listen(_ player: PlayerModel) {
        withObservationTracking {
            _ = player.position
            _ = player.status
            _ = player.duration
            _ = player.target
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self, self.player === player else { return }
                self.notify()
                self.listen(player)
            }
        }
    }

    private func notify() {
        guard let player else {
            receiver.notify(StateMirror.idle.withRemoteKeyboard())
            return
        }
        receiver.notify(
            StateMirror(
                title: player.target.title,
                beside: player.target.subtitle,
                // **The identifier is the key to "bring it over here".** It is missing for
                // a channel, and that is right there: it runs equally far everywhere,
                // you would arrive at the same place.
                identifier: player.target.itemID,
                location: player.position,
                // **Zero means "no end" and not "zero seconds".** A channel reports
                // no duration; a zero over the wire would make the phone draw a timeline
                // with nothing to drag.
                duration: player.duration > 0 ? player.duration : nil,
                isRunning: player.isPlaying
            ).withRemoteKeyboard())
    }
}
