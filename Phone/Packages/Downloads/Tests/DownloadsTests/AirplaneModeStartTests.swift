import NetworkStatus
import Testing

@testable import Downloads

/// Start without network — **no spinner, no login attempt.**
///
/// Plex lets the library spin endlessly in airplane mode, the Ahorn Mediathek demands an
/// internet connection to play downloaded videos. Both **have** downloads.
/// That is the market gap, and it is one screen in size.
@Suite("Airplane-mode start")
struct AirplaneModeStartTests {

    /// **The check comes before the attempt and not in its failure case.** A
    /// login attempt that fails costs a line in the error log, a wait and
    /// sometimes a spinner — for an answer that was known beforehand.
    @Test("Without a network nothing is even asked")
    func doNotAsk() {
        #expect(!AirplaneModeStart.mayAsk(.none))
        #expect(AirplaneModeStart.mayAsk(NetworkPath(kind: .wifi)))
        #expect(AirplaneModeStart.mayAsk(NetworkPath(kind: .cellular)))
    }

    /// **The downloads always work.** They are on the device; playback needs no
    /// server, no login and no token.
    @Test("The downloads work without a network")
    func downloadsSustain() {
        #expect(AirplaneModeStart.downloadsSustain(without: .none))
    }

    /// **Named instead of left out.** Whoever let the tabs silently disappear would let the
    /// viewer search; whoever left them standing would let them walk into it.
    @Test("What is missing without a network is named")
    func named() {
        #expect(AirplaneModeStart.unavailableWithoutNetwork.count == 4)
        #expect(!AirplaneModeStart.unavailableWithoutNetwork.contains("stock.title"))
    }

    /// **The state of a transfer arises in one place and not per row.** Otherwise each row
    /// decides for itself, and at the next rule change six
    /// of seven are right.
    @Test("Without a network every transfer rests, with a reason")
    func allIdle() {
        let state = Downloads.state(
            forItem: Transfer(id: .init("a")), rule: NetworkRule(), route: .none, claim: .unrestricted)
        #expect(state == .idle(.noNetwork))
    }

    /// **Watching wins against loading.** A film that stutters because of a download is
    /// an error the viewer sees immediately.
    @Test("Whoever is watching has priority over the downloads")
    func watchingWins() {
        let state = Downloads.state(
            forItem: Transfer(id: .init("a")), rule: NetworkRule(),
            route: NetworkPath(kind: .wifi), claim: .playbackOnSecondDevice)
        #expect(state == .waitingForConnection)
    }

    /// **Finished stays finished.** A plane does not turn a completed file into a
    /// half one — nor an error into a waiting state.
    @Test("Final states do not change through the network")
    func finalStatesStay() {
        let done = Transfer(id: .init("a"), state: .done)
        #expect(
            Downloads.state(forItem: done, rule: NetworkRule(), route: .none, claim: .unrestricted) == .done)
    }

    /// **The button disappears where there is nothing to press.** Without network there is nothing
    /// to resume; a button there would repeat the same message when pressed.
    @Test("Without a network there is no Resume button")
    func noButtonWithoutNetwork() {
        #expect(TransferControl.action(forItem: .idle(.noNetwork)) == .none)
        #expect(TransferControl.action(forItem: .idle(.cellular)) == .resume)
        #expect(TransferControl.action(forItem: .isLoading) == .pause)
    }

    /// **The VoiceOver label moves along.** A button whose image changes
    /// and whose label does not says the wrong thing to the screen reader — and nobody
    /// sees it.
    @Test("Every action has its label")
    func labelMoves() {
        #expect(
            TransferControl.label(forItem: .pause)
                != TransferControl
                .label(forItem: .resume))
        #expect(TransferControl.label(forItem: .none).isEmpty)
    }
}
