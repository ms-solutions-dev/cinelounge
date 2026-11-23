import Testing

@testable import Core

/// The values come from the first Hollowmark episode, as the server reports them:
/// intro from 0:00 to 1:44, credits from 21:57.
@Suite("Segments of an episode")
struct MediaSegmentTests {

    static let intro = MediaSegment(id: "a", kind: .intro, start: 0, end: 104.1)
    static let outro = MediaSegment(id: "b", kind: .outro, start: 1316.8, end: 1377.4)
    static let segments = [intro, outro]

    @Test("Skipping is offered during the intro")
    func duringIntro() {
        #expect(Self.segments.skippable(at: 12)?.kind == .intro)
        #expect(Self.segments.skippable(at: 0)?.kind == .intro)
    }

    @Test("The offer disappears again after the intro")
    func afterIntro() {
        #expect(Self.segments.skippable(at: 104.1) == nil)
        #expect(Self.segments.skippable(at: 300) == nil)
    }

    @Test("Skipping is offered in the credits too — the next episode depends on it")
    func duringOutro() {
        #expect(Self.segments.skippable(at: 1350)?.kind == .outro)
        #expect(Self.segments.outro?.start == 1316.8)
    }

    @Test("Very short segments are ignored")
    func tooShortToOffer() {
        // A button that flashes for two seconds cannot be hit with the remote
        // and annoys more than it helps.
        let blink = [MediaSegment(id: "c", kind: .intro, start: 10, end: 12)]

        #expect(blink.skippable(at: 11) == nil)
        #expect(blink.skippable(at: 11, minimumDuration: 1)?.kind == .intro)
    }

    @Test("Preview and ads are not offered for skipping")
    func notOffered() {
        #expect(!MediaSegment.Kind.preview.isSkippable)
        #expect(!MediaSegment.Kind.commercial.isSkippable)
        #expect(MediaSegment.Kind.recap.isSkippable)
    }

    @Test("The end of a segment no longer counts as part of it")
    func boundaryIsExclusive() {
        // Otherwise two adjoining sections would both apply
        // for a moment.
        #expect(Self.intro.contains(103.9))
        #expect(!Self.intro.contains(104.1))
    }

    @Test("Segment kinds are read from the server data")
    func kindParsing() {
        #expect(MediaSegment.Kind(rawValue: "Intro") == .intro)
        #expect(MediaSegment.Kind(rawValue: "outro") == .outro)
        #expect(MediaSegment.Kind(rawValue: "Unbekanntes") == .unknown)
    }
}

@Suite("Playback progress")
struct PlaybackProgressTests {

    @Test("Started episodes appear under Continue Watching")
    func resumable() {
        // Real values from the media library: 7.4 % and 59.1 % watched.
        #expect(PlaybackProgress(position: 106, duration: 1440).isResumable)
        #expect(PlaybackProgress(position: 851, duration: 1440).isResumable)
    }

    @Test("Barely started items do not appear")
    func barelyStarted() {
        // Otherwise the list fills with titles that were only tapped. Threshold since
        // 2026-09-28 is Jellyfin's (1 %).
        #expect(!PlaybackProgress(position: 10, duration: 1440).isResumable)
    }

    @Test("Almost finished items do not appear — the next episode belongs there")
    func almostDone() {
        #expect(!PlaybackProgress(position: 1400, duration: 1440).isResumable)
    }

    @Test("Watched items do not appear")
    func watched() {
        #expect(!PlaybackProgress(position: 700, duration: 1440, isWatched: true).isResumable)
    }

    @Test("Fraction and remaining time are computed correctly")
    func math() {
        let p = PlaybackProgress(position: 360, duration: 1440)

        #expect(p.fraction == 0.25)
        #expect(p.remaining == 1080)
    }

    @Test("Without a runtime there is no division by zero")
    func zeroDuration() {
        let p = PlaybackProgress(position: 100, duration: 0)

        #expect(p.fraction == 0)
        #expect(!p.isResumable)
    }
}
