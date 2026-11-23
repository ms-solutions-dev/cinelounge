import Testing

@testable import Core

/// The chapter jumps: small rules, but each one the wrong way round would be felt on
/// the TV immediately — a "Back" that always leads to the same start, or a "Next" that
/// skips a chapter.
@Suite("Chapter marks")
struct ChapterTests {

    /// A film with four chapters, deliberately created unsorted — the server guarantees no
    /// order.
    static let chapters: [Chapter] = [
        Chapter(title: "Drittes", start: 1800),
        Chapter(title: "Anfang", start: 0),
        Chapter(title: "Zweites", start: 600),
        Chapter(title: "Finale", start: 4200),
    ]

    @Test("Forward leads to the next start, at the end into nothing")
    func forwardJumps() {
        #expect(Self.chapters.nextStart(after: 100) == 600)
        #expect(Self.chapters.nextStart(after: 700) == 1800)
        // Anyone standing exactly on a start means the next one — not the one after that, and
        // not the same one again.
        #expect(Self.chapters.nextStart(after: 600) == 1800)
        #expect(Self.chapters.nextStart(after: 4200) == nil, "there is nothing after the last one")
    }

    @Test("Back knows the grace period: first to the start, then before it")
    func backwardJumps() {
        // Mitten im Kapitel: an dessen Anfang.
        #expect(Self.chapters.previousStart(before: 900) == 600)
        // Immediately after a start: into the chapter before — otherwise repeated pressing
        // would never get further than the running start.
        #expect(Self.chapters.previousStart(before: 602) == 0)
        // Before the first mark there is nothing more.
        #expect(Self.chapters.previousStart(before: 2) == nil)
    }
}

/// The subtitle presentation: values and store.
@Suite("Subtitle appearance")
struct SubtitleStyleTests {

    @Test("The default does not intervene, any deviation does")
    func standardMeansHandsOff() {
        // Without deviation the system draws according to its accessibility settings — own
        // rules would overwrite them with default values, and nobody would find out why the
        // system setting no longer has any effect.
        #expect(SubtitleStyle().isStandard)
        #expect(!SubtitleStyle(size: .large).isStandard)
        #expect(!SubtitleStyle(color: .yellow).isStandard)
    }

    @Test("Sizes and colors carry the agreed values")
    func valuesAreFixed() {
        #expect(SubtitleStyle.Size.small.percent == 80)
        #expect(SubtitleStyle.Size.standard.percent == 100)
        #expect(SubtitleStyle.Size.large.percent == 130)
        #expect(SubtitleStyle.Color.white.rgba == (1, 1, 1, 1))
        #expect(SubtitleStyle.Color.yellow.rgba.green < 1, "yellow is not white")
    }

    @Test("The store survives saving and loading")
    func roundTrip() {
        let store = InMemoryStore()
        SubtitleStyle(size: .large, color: .yellow).save(to: store)
        #expect(SubtitleStyle.load(from: store) == SubtitleStyle(size: .large, color: .yellow))
    }
}
