import Core
import Flows
import Foundation
import SourceProbe
import Testing

@testable import Features

/// **Parity in the player on the TV** (AP58 G1, decision 27) — the shared rules
/// from `Flows` and `Core`, wired to the `PlayerModel`. The same rules are checked by
/// `PlayerEquivalenceTests` on the phone.
extension PlayerModelTests {

    /// A channel through its own list, with ring — **the session is not started**, it
    /// only carries the ring on which the switch hangs.
    func channelInBuffer() throws -> (PlayerModel, HostDouble, LiveRemuxSession) {
        let (model, host, _) = make(kind: .live, itemID: nil, duration: nil, delivery: .remuxInApp)
        let session = try LiveRemuxSession(source: URL(string: "http://sender.invalid/live/1.ts")!)
        model.remuxHandle = session
        host.engine.timeShiftWindow = 1_000...1_300
        model.position = 1_250
        return (model, host, session)
    }

    @Test("A channel in the buffer jumps within its bounds and back to live")
    func timeOffsetOnTV() throws {
        let (model, host, session) = try channelInBuffer()
        defer { session.stop() }

        #expect(model.hasLiveTimeShift)
        #expect(model.isSeekable)
        #expect(model.isBehindLive)
        #expect(model.remainingLabel == "−00:50")

        model.skip(by: 30)
        #expect(host.engine.seeks.last == 1_280)
        model.skip(by: -600)
        #expect(host.engine.seeks.last == 1_000, "not before the oldest segment")
        model.skip(by: 900)
        #expect(host.engine.seeks.last == 1_300, "not beyond the edge")

        model.jumpToLive()
        #expect(host.engine.liveJumps == 1)
    }

    @Test("A channel without a ring buffer has no time shift")
    func channelWithoutRing() {
        let (model, host, _) = make(kind: .live, itemID: nil, duration: nil, delivery: .remuxInApp)
        host.engine.timeShiftWindow = 1_000...1_300
        #expect(!model.hasLiveTimeShift)
        #expect(model.timeShiftWindow == nil)
        model.jumpToLive()
        #expect(host.engine.liveJumps == 0)
    }

    @Test("A single chapter is no choice — the same rule as on the phone")
    func oneChapter() {
        let host = HostDouble()
        var destination = target()
        destination = PlaybackTarget(
            itemID: destination.itemID, title: destination.title, url: destination.url,
            decision: destination.decision,
            duration: destination.duration, chapters: [Chapter(title: "A", start: 0)], kind: .recording)
        let model = PlayerModel(
            target: destination, engine: host, source: SourceSpy(), audioStore: InMemoryStore())
        #expect(!model.hasChapters)
        #expect(model.chapterFractions.isEmpty)
    }

    /// **New since G1:** the TV also offered the steps for a channel.
    @Test("No speed for a channel")
    func noSpeedOnChannel() {
        let (model, host, _) = make(kind: .live, itemID: nil, duration: nil)
        model.setRate(1.5)
        #expect(!model.supportsSpeed)
        #expect(host.engine.rates.isEmpty)
    }

    @Test("The chosen audio track is remembered for the series")
    func audioIsRemembered() {
        let store = InMemoryStore()
        let (model, _, _) = make(audioStore: store)
        model.audioTracks = [
            PlaybackTrack(id: 1, language: "deu"), PlaybackTrack(id: 2, language: "jpn"),
        ]
        model.selectAudioTrack(2)
        #expect(AudioMemory.load(from: store).language(forItem: "serie") == "jpn")
    }

    @Test("A track without a language and a channel remember nothing")
    func audioWithoutLanguage() {
        let store = InMemoryStore()
        let (model, _, _) = make(audioStore: store)
        model.audioTracks = [PlaybackTrack(id: 3)]
        model.selectAudioTrack(3)
        let (channels, _, _) = make(kind: .live, itemID: nil, audioStore: store)
        channels.audioTracks = [PlaybackTrack(id: 4, language: "deu")]
        channels.selectAudioTrack(4)
        #expect(AudioMemory.load(from: store).entries.isEmpty)
    }

    @Test("A film from the Jellyfin server has no source choice")
    func noSourceChoiceWithoutPortal() async {
        let (model, _, _) = make()
        await model.loadSourceChoice()
        #expect(!model.sourceChoice.isWorthwhile)
    }

    /// **The source choice stands in the track board and under the glitch picture** — the same place
    /// as on the phone.
    @Test("The track board and the fault screen offer the other source")
    func sourceChoiceWiredUp() throws {
        let board = try SourceText.read("Player/TrackChooser.swift", in: .features)
        #expect(board.contains("model.sourceChoice.selectable"))
        #expect(board.contains("model.switchSource(zu: row)"))
        let bar = try SourceText.read("Player/TransportBar.swift", in: .features)
        #expect(bar.contains("\"player.other_source\""))
    }
}
