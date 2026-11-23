import Testing

@testable import Playback

/// YouTube trailers never in a dubbed version (2026-11-08). The titles are the real
/// ones from a manifest of the same day.
@Suite("Original audio")
struct OriginalAudioTests {

    private func track(_ title: String, _ language: String?) -> OriginalAudio.Track {
        OriginalAudio.Track(title: title, language: language)
    }

    @Test("The original instead of the German dub")
    func originalInsteadOfDubbed() {
        let tracks = [
            track("العربية - dubbed", "ar"), track("Deutsch - dubbed", "de"),
            track("Español - dubbed", "es"), track("American English - original", "en-US"),
        ]
        #expect(OriginalAudio.choice(tracks) == 3)
    }

    @Test("A German original goes before every other")
    func germanOriginal() {
        let tracks = [track("English - original", "en"), track("Deutsch - original", "de")]
        #expect(OriginalAudio.choice(tracks) == 1)
    }

    @Test("Without an identifier, nothing is decided")
    func withoutIdentifier() {
        #expect(OriginalAudio.choice([track("Default", nil), track("Default", nil)]) == nil)
        #expect(OriginalAudio.choice([track("Deutsch", "de"), track("English", "en")]) == nil)
        #expect(OriginalAudio.choice([]) == nil)
    }

    @Test("Only dubs and one without an identifier: the one without")
    func withoutOriginalFlag() {
        let tracks = [track("Deutsch - dubbed", "de"), track("English", "en")]
        #expect(OriginalAudio.choice(tracks) == 1)
    }

    @Test("An AI version also counts as a dub")
    func aiVersion() {
        let tracks = [track("Deutsch - dubbed-auto", "de"), track("English (US) - original", "en-US")]
        #expect(OriginalAudio.choice(tracks) == 1)
    }
}
