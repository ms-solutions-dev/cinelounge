import Foundation
import Testing

@testable import Core

/// **The audio choice per title** (AP58 G1, A10): remembered on the TV and on the phone, read in the
/// playback plan that both devices call at start and at the next episode.
@Suite("Audio choice per title")
struct AudioMemoryTests {

    @Test("An episode is remembered under its series, a movie under itself")
    func key() {
        #expect(AudioMemory.title(identifier: "f1", series: "s") == "s")
        #expect(AudioMemory.title(identifier: "film", series: nil) == "film")
        #expect(AudioMemory.title(identifier: "film", series: "") == "film")
    }

    @Test("Remember, overwrite, forget — and the store keeps it")
    func remember() {
        let store = InMemoryStore()
        AudioMemory.memorize("jpn", identifier: "f1", series: "s", in: store)
        #expect(AudioMemory.load(from: store).language(forItem: "s") == "jpn")
        AudioMemory.memorize("deu", identifier: "f2", series: "s", in: store)
        #expect(AudioMemory.load(from: store).language(forItem: "s") == "deu")
        AudioMemory.memorize(nil, identifier: "f2", series: "s", in: store)
        #expect(AudioMemory.load(from: store).language(forItem: "s") == nil)
    }

    @Test("The oldest drop out")
    func limit() {
        var memory = AudioMemory()
        for number in 0...AudioMemory.atMost {
            memory.memorize("deu", forItem: "t\(number)")
        }
        #expect(memory.entries.count == AudioMemory.atMost)
        #expect(memory.language(forItem: "t0") == nil)
        #expect(memory.language(forItem: "t\(AudioMemory.atMost)") == "deu")
    }

    // MARK: - Im Abspielplan

    static func preference(remembered: String?) -> PlaybackPlan.Preference {
        var memory = AudioMemory()
        memory.memorize(remembered, forItem: "serie")
        return PlaybackPlan.Preference(
            audio: AudioPreference(animeOriginal: true), interfaceLanguage: "de",
            audioMemory: memory)
    }

    static func episode() -> MediaItem {
        var title = PlaybackPlanTests.title()
        title.seriesID = "serie"
        return title
    }

    @Test("The remembered language takes precedence over the anime rule — also on the next episode")
    func rememberedTakesPrecedence() {
        for reason in [
            PlaybackPlan.Occasion.start(fixed: nil, fromStart: false), .nextEpisode(withSubtitles: false),
        ] {
            let plan = PlaybackPlanTests.plan(
                reason, title: Self.episode(), preference: Self.preference(remembered: "deu"))
            #expect(plan.audio?.id == "1", "German, although the rule chose Japanese")
            #expect(plan.subtitles?.id != "5", "no German full text over German audio")
        }
    }

    @Test("Without a remembered choice and with a language the file lacks, the rule applies")
    func otherwiseTheRule() {
        let without = PlaybackPlanTests.plan(
            .start(fixed: nil, fromStart: false), title: Self.episode(),
            preference: Self.preference(remembered: nil))
        #expect(without.audio?.id == "3")
        let foreign = PlaybackPlanTests.plan(
            .start(fixed: nil, fromStart: false), title: Self.episode(),
            preference: Self.preference(remembered: "tur"))
        #expect(foreign.audio?.id == "3")
        #expect(foreign.subtitles?.id == "5")
    }
}
