import Foundation
import Testing

@testable import Trailer

/// The choice among the file steps — without YouTube, without network.
@Suite("Trailer resolution")
struct TrailerResolutionTests {

    private func tier(
        _ height: Int?, videoAndAudio: Bool = true, native: Bool = true
    ) -> TrailerResolution.FileTier {
        TrailerResolution.FileTier(
            url: URL(string: "https://example.invalid/\(height ?? 0)")!, height: height,
            videoAndAudio: videoAndAudio, nativelyPlayable: native)
    }

    @Test("The highest tier with picture and sound wins, DASH tracks do not count")
    func highestWithVideoAndAudio() {
        let slots = [
            tier(1080, videoAndAudio: false), tier(720, videoAndAudio: false), tier(360),
            tier(240), tier(480, native: false),
        ]
        #expect(TrailerResolution.choice(slots)?.height == 360)
    }

    @Test("Without a tier with picture and sound, nothing")
    func nothing() {
        #expect(
            TrailerResolution.choice([tier(1080, videoAndAudio: false), tier(nil, native: false)]) == nil)
        #expect(TrailerResolution.choice([]) == nil)
    }

    @Test("Addresses for the YouTube app and the page")
    func addresses() {
        #expect(
            TrailerResolution.youtubeApp("YRrw6Wch8rc")?.absoluteString == "youtube://watch?v=YRrw6Wch8rc")
        #expect(
            TrailerResolution.youtubePage("YRrw6Wch8rc")?.absoluteString
                == "https://www.youtube.com/watch?v=YRrw6Wch8rc")
    }
}
