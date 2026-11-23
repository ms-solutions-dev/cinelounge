import Foundation
import Testing

@testable import PlaylistKit

/// The kind detection decides whether an entry ends up in the channel list or in the
/// library. It must not rely on a single feature,
/// because none is reliable — so every clue is
/// recorded individually here, and also what wins in contradictions.
@Suite("Recognizing the kind of an entry")
struct StreamKindTests {

    private func detect(_ url: String, duration: Double? = -1, group: String? = nil) -> StreamKind {
        StreamKind.detect(duration: duration, url: URL(string: url), group: group)
    }

    // MARK: - The path, strongest hint

    @Test("The Xtream paths are recognized")
    func xtreamPaths() {
        #expect(detect("http://s:8080/live/user/pass/123.ts") == .live)
        #expect(detect("http://s:8080/movie/user/pass/456.mp4") == .movie)
        #expect(detect("http://s:8080/series/user/pass/789.mp4") == .episode)
    }

    @Test("The path beats the file extension")
    func pathBeatsExtension() {
        // Happens: a film delivered as .ts. The path is the
        // provider's intent, the extension only the container.
        #expect(detect("http://s/movie/u/p/1.ts") == .movie)
        // And the other way round: a channel as .mp4.
        #expect(detect("http://s/live/u/p/1.mp4") == .live)
    }

    @Test("The path beats the duration too")
    func pathBeatsDuration() {
        // A real duration on a channel is a mistake of the generator.
        #expect(detect("http://s/live/u/p/1.ts", duration: 3600) == .live)
    }

    // MARK: - Die Dateiendung

    @Test("Live streams are recognized by their extension")
    func liveExtensions() {
        #expect(detect("http://s/1.ts") == .live)
        #expect(detect("http://s/kanal.m3u8") == .live)
        #expect(detect("http://s/kanal.mpd") == .live)
    }

    @Test("File extensions point to on-demand content")
    func fileExtensions() {
        #expect(detect("http://s/film.mp4", duration: nil) == .movie)
        #expect(detect("http://s/film.mkv", duration: nil) == .movie)
        #expect(detect("http://s/film.avi", duration: nil) == .movie)
    }

    @Test("A file in a series group is an episode")
    func fileInSeriesGroup() {
        // The extension says "file", the group name says "series" — together that
        // makes an episode, not a film.
        #expect(detect("http://s/e01.mp4", group: "📺 Serien | Drama") == .episode)
    }

    // MARK: - Der Gruppenname

    @Test("Group names with VOD point to movies")
    func vodGroups() {
        #expect(detect("http://s/1", group: "🎬 VOD | Filme") == .movie)
        #expect(detect("http://s/1", group: "MOVIES - Action") == .movie)
        #expect(detect("http://s/1", group: "Kino Neuheiten") == .movie)
    }

    @Test("Group names with Serie point to episodes")
    func seriesGroups() {
        #expect(detect("http://s/1", group: "Serien | Flimmerkiste") == .episode)
        #expect(detect("http://s/1", group: "TR Diziler") == .episode)
    }

    @Test("If both are in the group name the series wins")
    func seriesBeatsMovieInGroup() {
        // "VOD | Serien" is the most common spelling. "VOD" is the umbrella term,
        // "Serien" the more precise statement.
        #expect(detect("http://s/1", group: "VOD | Serien") == .episode)
    }

    @Test("Ordinary channel groups do not point to on-demand content")
    func liveGroups() {
        #expect(detect("http://s/1", group: "🇩🇪 DE | Sport") == .live)
        #expect(detect("http://s/1", group: "Nachrichten") == .live)
        #expect(detect("http://s/1", group: "TR · Genel") == .live)
    }

    @Test("Upper and lower case do not matter")
    func caseInsensitive() {
        #expect(detect("http://s/1", group: "vod") == .movie)
        #expect(detect("http://s/1", group: "VOD") == .movie)
        #expect(detect("http://s/1", group: "Vod") == .movie)
        #expect(detect("http://S/MOVIE/u/p/1.MP4") == .movie)
    }

    // MARK: - The duration, weakest feature

    @Test("A real duration points to on-demand content when nothing else is available")
    func durationAsLastResort() {
        #expect(detect("http://s/irgendwas", duration: 7200) == .movie)
    }

    @Test("Duration minus one alone does not make a channel")
    func minusOneIsWeak() {
        // Many generators blindly write -1 into every row, films included.
        // So -1 must not outvote the stronger features.
        #expect(detect("http://s/movie/u/p/1.mp4", duration: -1) == .movie)
        #expect(detect("http://s/film.mp4", duration: -1) == .movie)
    }

    // MARK: - Im Zweifel

    @Test("Without any clue it is Live")
    func defaultsToLive() {
        // The more harmless mistake: a film in the channel list is a
        // cosmetic flaw. A channel that counts as a film disappears from the
        // channel list, and nobody knows where it went.
        #expect(detect("http://s/stream", duration: nil, group: nil) == .live)
        #expect(detect("http://s/stream", duration: -1, group: "") == .live)
    }

    @Test("An unusable address does not lead to a crash")
    func noURL() {
        #expect(StreamKind.detect(duration: nil, url: nil, group: nil) == .live)
        #expect(StreamKind.detect(duration: 3600, url: nil, group: nil) == .movie)
    }

    @Test("All kinds are enumerable — for filters in the UI")
    func allCases() {
        #expect(StreamKind.allCases.count == 3)
        #expect(Set(StreamKind.allCases.map(\.rawValue)).count == 3)
    }
}
