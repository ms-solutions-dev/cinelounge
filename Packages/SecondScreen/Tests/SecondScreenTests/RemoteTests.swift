import Foundation
import Testing

@testable import SecondScreen

/// The wire between phone and TV — **the running connection.**
///
/// **What a check can prove here and what it cannot.** Whether seeking works is decided by
/// a phone in front of a TV; that stands as a done condition in the schedule and stays
/// there. What it does prove are the places where a failure would stay **silent**: a
/// reordered enumeration that turns "pause" into "louder"; a state that loses a field over
/// the wire; a progress value that goes past one.
@Suite("The remote")
struct RemoteTests {

    // MARK: - The contract of the commands

    /// **The numeric codes are an ordering, not the network format** (corrected on 2026-09-27,
    /// see ``Command/code``). The agreement on the wire is recorded by ``wireFormat()``.
    @Test("Every command keeps its code")
    func codesStayFixed() {
        #expect(Command.matches(true).code == 0)
        #expect(Command.jumpTo(42).code == 1)
        #expect(Command.jumpBy(-10).code == 2)
        #expect(Command.audioTrack(2).code == 3)
        #expect(Command.subtitles(nil).code == 4)
        #expect(Command.spieleTitel(identifier: "a", origin: "b", from: 0).code == 5)
        #expect(Command.tap("x").code == 6)
        #expect(Command.halt.code == 7)
    }

    /// **The agreement is the case names** (ultra e5, round A.7). A phone with a newer version
    /// talks to a TV that still has the old one; whoever renames `jumpBy` turns the double
    /// tap into a command nobody over there knows. Here the form stands as it lies on the
    /// wire — verbatim, so that every rename turns red.
    @Test("The wire format of the commands is fixed: case names and labels")
    func wireFormat() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        func text(_ command: Command) throws -> String {
            String(decoding: try encoder.encode(command), as: UTF8.self)
        }
        #expect(try text(.matches(true)) == #"{"spiele":{"_0":true}}"#)
        #expect(try text(.jumpTo(42)) == #"{"springeAuf":{"_0":42}}"#)
        #expect(try text(.jumpBy(-10)) == #"{"springeUm":{"_0":-10}}"#)
        #expect(try text(.audioTrack(2)) == #"{"tonspur":{"_0":2}}"#)
        #expect(try text(.subtitles(1)) == #"{"untertitel":{"_0":1}}"#)
        #expect(
            try text(.spieleTitel(identifier: "a", origin: "b", from: 5))
                == #"{"spieleTitel":{"ab":5,"herkunft":"b","kennung":"a"}}"#)
        #expect(try text(.tap("x")) == #"{"tippe":{"_0":"x"}}"#)
        #expect(try text(.halt) == #"{"halt":{}}"#)
        // And it is read the way an older device sends it.
        let legacy = Data(#"{"springeUm":{"_0":30}}"#.utf8)
        #expect(try JSONDecoder().decode(Command.self, from: legacy) == .jumpBy(30))
    }

    @Test("Every command survives the trip over the wire")
    func commandsSurviveTheWire() throws {
        let all: [Command] = [
            .matches(true), .matches(false), .jumpTo(2653.5), .jumpBy(-10),
            .jumpBy(30), .audioTrack(3), .subtitles(1),
            .subtitles(nil),
            .spieleTitel(identifier: "morrowfeld", origin: "medienserver", from: 2653),
            .tap("Bolto"), .halt,
        ]

        for command in all {
            let packet = HandoffWire.Frame.pack(try JSONEncoder().encode(command))
            let length = try #require(HandoffWire.Frame.length(from: packet))
            let content = Data(packet.dropFirst(4).prefix(length))

            #expect(try JSONDecoder().decode(Command.self, from: content) == command)
        }
    }

    /// **A text with umlauts and spaces is the normal case and not the edge case.** One types
    /// into a search field, and what stands there is "Das Raunen der Kräne".
    @Test("Typed text survives umlauts and spaces")
    func textSurvives() throws {
        let command = Command.tap("Das Raunen der Kräne · İstanbul")
        let data = try JSONEncoder().encode(command)

        #expect(try JSONDecoder().decode(Command.self, from: data) == command)
    }

    // MARK: - The state mirror

    @Test("The state survives the trip completely")
    func stateSurvives() throws {
        let state = StateMirror(
            title: "Morrowfeld", beside: "S1 · F3", location: 2653, duration: 8297, isRunning: true,
            keyboardOpen: false, keyboardText: "")
        let data = try JSONEncoder().encode(state)

        #expect(try JSONDecoder().decode(StateMirror.self, from: data) == state)
    }

    /// The prototype's numbers, recalculated: 2653 of 8297 seconds.
    @Test("The progress is computed and not sent along")
    func progressComputed() {
        let state = StateMirror(title: "Morrowfeld", location: 2653, duration: 8297)
        let portion = state.progress

        #expect(portion != nil)
        #expect(abs((portion ?? 0) - 0.3197) < 0.001)
    }

    /// **A channel has no end**, and then there is no progress — not a zero. A zero would be a
    /// bar that sits at the start and never moves on.
    @Test("Without a duration there is no progress")
    func noProgressWithoutDuration() {
        #expect(StateMirror(title: "Das Nordlicht", location: 500).progress == nil)
        #expect(StateMirror(title: "x", location: 5, duration: 0).progress == nil)
    }

    /// **The case that would push a bar over the edge.** For a channel the engine occasionally
    /// reports a position beyond the reported duration.
    @Test("The progress stays between zero and one")
    func progressClamped() {
        #expect(StateMirror(title: "x", location: 9999, duration: 100).progress == 1)
        #expect(StateMirror(title: "x", location: -5, duration: 100).progress == 0)
    }

    @Test("Without a title nothing runs")
    func idleDoesNotPlay() {
        #expect(!StateMirror.idle.isPlaying)
        #expect(StateMirror(title: "Morrowfeld").isPlaying)
    }

    /// **There is no volume command, and that is a measurement and not a gap.** tvOS has
    /// **no** interface with which an app sets the system volume — `MPVolumeView` does not
    /// exist there, `AVAudioSession` has no setter. The volume of an Apple TV belongs to the
    /// TV on the HDMI cable. A slider that moves nothing would be worse than none: it looks
    /// like a control, and whoever drags it then looks for the fault in themselves.
    @Test("The wire promises no volume")
    func noVolume() {
        // The wire carries eight commands; a ninth would be the one nobody can redeem.
        let all: [Command] = [
            .matches(true), .jumpTo(0), .jumpBy(0), .audioTrack(0), .subtitles(nil),
            .spieleTitel(identifier: "", origin: "", from: 0), .tap(""), .halt,
        ]
        #expect(Set(all.map(\.code)).count == all.count, "every code occurs once")
        #expect(all.map(\.code).max() == 7)
    }

    // MARK: - Two services, two jobs

    /// **They must not be the same.** One carries a one-time, encrypted procedure, the other a
    /// running connection — and the verified handoff receiver is not to be touched for the
    /// remote.
    @Test("Handoff and remote have different services")
    func twoServices() {
        #expect(DeviceDiscovery.service != HandoffWire.service)
        #expect(DeviceDiscovery.service.hasSuffix("._tcp"))
    }

    /// **The deadline is shorter here than for the handoff, and that is deliberate.** There,
    /// someone stands in front of the device with a QR code and has made up their mind; here
    /// they press a name and want to know whether it works.
    @Test("The remote waits shorter than the handoff")
    func shorterTimeout() {
        #expect(OwnWire.deadline < HandoffWire.deadline)
    }
}
