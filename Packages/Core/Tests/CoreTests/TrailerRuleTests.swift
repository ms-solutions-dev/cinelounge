import Foundation
import Testing

@testable import Core

/// **AP78 (2026-10-11):** app language, then original, then English; the app's own file only in
/// the app language, before TMDb. Testable without a network — that is exactly why the rule is a function.
@Suite("Trailer language rule")
struct TrailerRuleTests {

    private func video(
        _ id: String, _ language: String?, kind: TrailerVideo.Kind = .trailer, official: Bool = true,
        tag: Int = 1
    ) -> TrailerVideo {
        TrailerVideo(
            youtubeID: id, language: language, kind: kind, official: official, name: id,
            published: Date(timeIntervalSince1970: TimeInterval(tag) * 86400))
    }

    @Test("App language wins, even an unofficial trailer over the official English one")
    func appLanguageFirst() {
        let videos = [
            video("en-off", "en", official: true), video("de-fan", "de", official: false),
        ]
        let choice = TrailerRule.choice(file: nil, videos: videos, appLanguage: "de", original: "en")
        #expect(choice == .youtube(id: "de-fan", language: "de"))
        #expect(choice?.badge == "DE")
    }

    @Test("Original before English: a Turkish film without a German trailer plays Turkish")
    func originalBeforeEnglish() {
        let videos = [video("en", "en"), video("tr", "tr")]
        let choice = TrailerRule.choice(file: nil, videos: videos, appLanguage: "de", original: "tr")
        #expect(choice == .youtube(id: "tr", language: "tr"))
    }

    @Test("English as the last fallback")
    func englishLast() {
        let videos = [video("en", "en")]
        let choice = TrailerRule.choice(file: nil, videos: videos, appLanguage: "de", original: "ja")
        #expect(choice == .youtube(id: "en", language: "en"))
    }

    @Test("Own file in the app language beats TMDb")
    func fileInAppLanguage() {
        let videos = [video("de", "de")]
        let choice = TrailerRule.choice(
            file: TrailerFile(language: "ger"), videos: videos, appLanguage: "de", original: "en")
        #expect(choice == .file(language: "ger"))
        #expect(choice?.badge == "DE")
    }

    @Test("Sample file without a language loses to the German TMDb trailer, beats English")
    func fileWithoutLanguage() {
        let file = TrailerFile(language: nil)
        let withGerman = TrailerRule.choice(
            file: file, videos: [video("de", "de"), video("en", "en")], appLanguage: "de",
            original: "en")
        #expect(withGerman == .youtube(id: "de", language: "de"))

        let englishOnly = TrailerRule.choice(
            file: file, videos: [video("en", "en")], appLanguage: "de", original: "en")
        #expect(englishOnly == .file(language: nil))
        #expect(englishOnly?.badge == nil)
    }

    @Test("Trailer before teaser, official before unofficial, then the newest")
    func rankingWithinOneLanguage() {
        let videos = [
            video("teaser", "de", kind: .teaser, official: true, tag: 9),
            video("old", "de", official: true, tag: 1),
            video("new", "de", official: true, tag: 5),
            video("fan", "de", official: false, tag: 9),
            video("clip", "de", kind: .other, official: true, tag: 9),
        ]
        #expect(TrailerRule.best(videos, language: "de")?.youtubeID == "new")
        #expect(TrailerRule.best([videos[0], videos[4]], language: "de")?.youtubeID == "teaser")
        #expect(TrailerRule.best([videos[4]], language: "de") == nil, "a clip is not a trailer")
    }

    @Test("No match, no button")
    func nothing() {
        #expect(TrailerRule.choice(file: nil, videos: [], appLanguage: "de", original: "en") == nil)
        #expect(
            TrailerRule.choice(
                file: nil, videos: [video("clip", "de", kind: .other)], appLanguage: "de",
                original: "en") == nil)
    }

    @Test("Asking for the original language only when it can decide")
    func query() {
        let en = [video("en", "en")]
        #expect(TrailerRule.missingOriginal(file: nil, videos: en, appLanguage: "de", original: "tr") == "tr")
        #expect(
            TrailerRule.missingOriginal(file: nil, videos: en, appLanguage: "de", original: "en") == nil,
            "English already came along")
        #expect(
            TrailerRule.missingOriginal(file: nil, videos: en, appLanguage: "tr", original: "tr") == nil,
            "the original is the app language")
        #expect(
            TrailerRule.missingOriginal(
                file: nil, videos: en + [video("de", "de")], appLanguage: "de", original: "tr") == nil,
            "German is settled")
        #expect(
            TrailerRule.missingOriginal(
                file: TrailerFile(language: nil), videos: en, appLanguage: "de", original: "tr") == nil,
            "the file wins over the original")
        #expect(
            TrailerRule.missingOriginal(
                file: nil, videos: en + [video("tr", "tr")], appLanguage: "de", original: "tr") == nil,
            "Turkish is already there")
    }

    @Test("Kind from the TMDb field")
    func kind() {
        #expect(TrailerVideo.Kind(tmdb: "Trailer") == .trailer)
        #expect(TrailerVideo.Kind(tmdb: "Teaser") == .teaser)
        #expect(TrailerVideo.Kind(tmdb: "Featurette") == .other)
        #expect(TrailerVideo.Kind(tmdb: nil) == .other)
    }

    @Test("Short form of the language codes")
    func short() {
        #expect(LanguageCode.short("ger") == "de")
        #expect(LanguageCode.short("deu") == "de")
        #expect(LanguageCode.short("EN") == "en")
        #expect(LanguageCode.short("fr") == "fr")
        #expect(LanguageCode.short("fra") == nil)
        #expect(LanguageCode.short(nil) == nil)
    }
}
