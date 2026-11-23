import Core
import Testing

@testable import Flows

/// **AP79 (2026-10-12):** tabs only where the source can fill them; Info first, Audio &
/// Subtitles last. The cases are the columns of the table in the roadmap.
@Suite("Info area: tabs by capability")
struct InfoBarTests {

    private func state(
        kind: PlaybackTarget.Kind = .recording, series: Bool = false, cast: Int = 0,
        more: Int = 0, chapters: Bool = false
    ) -> InfoBar.Situation {
        InfoBar.Situation(
            kind: kind, series: series, cast: cast, more: more, chapters: chapters)
    }

    @Test("Jellyfin movie with everything: Info, Cast, Similar, Chapters, Audio & Subtitles")
    func jellyfinFilm() {
        let row = InfoBar.tabs(state(cast: 12, more: 8, chapters: true))
        #expect(row == [.info, .cast, .similarTitles, .chapters, .tracks])
    }

    @Test("Jellyfin series: Episodes instead of Similar")
    func jellyfinSeries() {
        let row = InfoBar.tabs(state(series: true, cast: 6, more: 9))
        #expect(row == [.info, .cast, .episodes, .tracks])
    }

    @Test("Xtream series without TMDb identifier: episodes yes, cast no")
    func xtreamSeries() {
        let row = InfoBar.tabs(state(series: true, cast: 0, more: 4))
        #expect(row == [.info, .episodes, .tracks])
    }

    @Test("Xtream movie with nothing: only Info and Audio & Subtitles")
    func xtreamFilm() {
        #expect(InfoBar.tabs(state()) == [.info, .tracks])
    }

    @Test("CL-Server title with TMDb identifier: cast is added, similar is not")
    func portalWithIdentifier() {
        let row = InfoBar.tabs(state(cast: 5, more: 0))
        #expect(row == [.info, .cast, .tracks])
    }

    @Test("Live channels and trailers have no info area")
    func liveAndTrailer() {
        #expect(InfoBar.tabs(state(kind: .live, cast: 3, more: 3)).isEmpty)
        #expect(InfoBar.tabs(state(kind: .trailer, cast: 3)).isEmpty)
    }

    @Test("While the board loads: Info, Chapters, Audio & Subtitles — nothing with a spinner")
    func whileLoading() {
        #expect(InfoBar.tabs(state(chapters: true)) == [.info, .chapters, .tracks])
    }

    @Test("Audio & Subtitles is always far right, Info always far left")
    func scaffold() {
        for cast in [0, 3] {
            for more in [0, 2] {
                for series in [false, true] {
                    for chapters in [false, true] {
                        let row = InfoBar.tabs(
                            state(series: series, cast: cast, more: more, chapters: chapters))
                        #expect(row.first == .info)
                        #expect(row.last == .tracks)
                        #expect(Set(row).count == row.count, "no tab twice")
                    }
                }
            }
        }
    }

    @Test("If the tab under focus disappears, focus goes to Info")
    func remains() {
        #expect(InfoBar.remains(.episodes, in: [.info, .episodes, .tracks]) == .episodes)
        #expect(InfoBar.remains(.episodes, in: [.info, .tracks]) == .info)
        #expect(InfoBar.remains(.tracks, in: [.info, .cast, .tracks]) == .tracks)
    }
}
