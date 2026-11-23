import Foundation
import Testing

@testable import Core

/// The playlist with which we serve AVFoundation.
///
/// **We are the server here**, although nothing goes onto the network. AVFoundation
/// wants fMP4 offered through an HLS list — so we write one. Whatever is wrong in
/// it leads to a rejection without a reason; that is why every line is checked.
@Suite("Playlist for the remuxer")
struct RemuxPlaylistTests {

    /// An address stem for testing. The port number is made up — nobody listens here, it
    /// is only about the lines that get written.
    let base = "http://127.0.0.1:9"

    @Test("The playlist names the header and segments")
    func listNamesHeaderAndSegments() {
        let list = RemuxPlaylist.build(durations: [2.0, 2.0], base: base)

        #expect(list.hasPrefix("#EXTM3U"))
        #expect(list.contains("#EXT-X-MAP:URI=\"http://127.0.0.1:9/header.mp4\""))
        #expect(list.contains("http://127.0.0.1:9/segment0.m4s"))
        #expect(list.contains("http://127.0.0.1:9/segment1.m4s"))
    }

    /// **The head segment belongs in `EXT-X-MAP`, not in the segment list.** It carries
    /// the descriptions of the stream, no picture — queued like an ordinary segment it
    /// would cause a dropout at this point and a shifted timeline afterwards.
    @Test("The header is not in the segment list")
    func headerIsNotASegment() {
        let list = RemuxPlaylist.build(durations: [2.0], base: base)
        let lines = list.split(separator: "\n").map(String.init)

        let segmentLines = lines.filter { $0.hasPrefix("http://") }
        #expect(segmentLines == ["http://127.0.0.1:9/segment0.m4s"])
    }

    /// A value that is too small makes the player ask too early and treat the list as
    /// faulty.
    @Test("The target duration is the longest, rounded up")
    func targetDurationIsTheLongest() {
        #expect(RemuxPlaylist.build(durations: [1.9, 2.4], base: base).contains("#EXT-X-TARGETDURATION:3"))
    }

    /// For a running channel the front is thrown away. Without continuous numbering the
    /// player would start from the beginning at every refill.
    @Test("The sequence keeps counting when entries are dropped at the front")
    func sequenceContinues() {
        let list = RemuxPlaylist.build(durations: [2.0, 2.0], firstIndex: 7, base: base)

        #expect(list.contains("#EXT-X-MEDIA-SEQUENCE:7"))
        #expect(list.contains("http://127.0.0.1:9/segment7.m4s"))
        #expect(list.contains("http://127.0.0.1:9/segment8.m4s"))
        #expect(!list.contains("segment0.m4s"))
    }

    /// Without an explicit end the player waits at the end for refills that never come.
    @Test("A finished recording is told its end")
    func finishedStreamIsClosed() {
        let list = RemuxPlaylist.build(durations: [2.0], isLive: false, base: base)

        #expect(list.contains("#EXT-X-ENDLIST"))
        #expect(list.contains("#EXT-X-PLAYLIST-TYPE:VOD"))
    }

    @Test("A running channel gets no end")
    func liveStreamStaysOpen() {
        let list = RemuxPlaylist.build(durations: [2.0], isLive: true, base: base)

        #expect(!list.contains("#EXT-X-ENDLIST"))
    }

    // MARK: - Adressen zuordnen

    @Test("Every address finds its piece")
    func requestsAreRecognised() {
        func request(_ address: String) -> RemuxPlaylist.Request? {
            RemuxPlaylist.request(for: URL(string: address)!)
        }

        #expect(request("http://127.0.0.1:9/media.m3u8") == .media)
        #expect(request("http://127.0.0.1:9/header.mp4") == .header(period: 0))
        #expect(request("http://127.0.0.1:9/segment0.m4s") == .segment(0))
        #expect(request("http://127.0.0.1:9/segment42.m4s") == .segment(42))
    }

    /// AVFoundation normalizes addresses along the way — comparing the whole address for
    /// equality has already gone wrong once in this project.
    @Test("The piece is also found with a path in front")
    func pathPrefixDoesNotMatter() {
        #expect(
            RemuxPlaylist.request(for: URL(string: "http://127.0.0.1:9/path/segment3.m4s")!)
                == .segment(3)
        )
    }

    @Test("Unknown addresses yield nothing — instead of a guessed piece")
    func unknownIsNil() {
        #expect(RemuxPlaylist.request(for: URL(string: "http://127.0.0.1:9/irgendwas")!) == nil)
        #expect(RemuxPlaylist.request(for: URL(string: "http://127.0.0.1:9/segmentX.m4s")!) == nil)
    }
    /// **The player should start at the beginning, not look for its entry at the end.**
    ///
    /// Without `EXT-X-START`, AVPlayer looks for its entry point three target durations
    /// before the end of a running list — which does not exist with two segments.
    /// Measured (2026-08-23): ten out of ten startups released with exactly two segments
    /// then sat for four to six seconds on the first picture; every one with three
    /// segments ran immediately.
    @Test("A live playlist says where it starts")
    func liveListDeclaresItsStart() {
        let live = RemuxPlaylist.build(durations: [4, 4], base: "http://h")
        // Since the evening of 2026-09-04: distance to the edge explicitly (`HOLD-BACK`), the
        // entry point equally far before the end — probe with TELE MOOS and SELA 1.
        #expect(live.contains("#EXT-X-SERVER-CONTROL:HOLD-BACK=6.00000"))
        #expect(live.contains("#EXT-X-START:TIME-OFFSET=-6.00000,PRECISE=YES"))

        // A completed file does not need that — there the beginning is the beginning anyway.
        let file = RemuxPlaylist.build(durations: [2, 2], isLive: false, base: "http://h")
        #expect(!file.contains("EXT-X-START"))
    }

    /// **The target duration must not decrease** (RFC 8216 §4.3.3.1): the player derives
    /// its polling interval from it. It was computed from the running window — when a
    /// long first segment slid out, the value dropped from four to two.
    @Test("The target duration never shrinks")
    func targetDurationNeverShrinks() {
        let wide = RemuxPlaylist.build(durations: [10, 2], base: "http://h")
        #expect(wide.contains("#EXT-X-TARGETDURATION:10"))

        // The same window after the long segment has slid out.
        let narrow = RemuxPlaylist.build(durations: [2, 2], targetDuration: 10, base: "http://h")
        #expect(narrow.contains("#EXT-X-TARGETDURATION:10"))

        // And it keeps growing along when a longer segment comes.
        let grown = RemuxPlaylist.build(durations: [12, 2], targetDuration: 10, base: "http://h")
        #expect(grown.contains("#EXT-X-TARGETDURATION:12"))
    }

}

/// The range header of the local server — AP6 · Q10.
///
/// **The finding:** `byteRange` could crash on `bytes=100-50` or an overflow. A
/// `Range` with `lowerBound > upperBound` is a program abort in Swift and not an
/// error — and the server listens on a socket: what comes in there is not decided by
/// the app.
@Suite("The range header of the local server")
struct ByteRangeHeadTests {

    private func area(_ row: String) -> Range<Int>? {
        LocalMediaServer.byteRange(in: row)
    }

    @Test("The ordinary range includes the last number")
    func ordinary() {
        #expect(area("Range: bytes=100-199") == 100..<200)
    }

    @Test("Without an end it runs to the end")
    func withoutEnd() {
        #expect(area("Range: bytes=100-") == 100..<Int.max)
    }

    /// **The crash case.** A reversed range yielded `100..<51`.
    @Test("A reversed range is rejected")
    func reversed() {
        #expect(area("Range: bytes=100-50") == nil)
    }

    /// And the second: `last + 1` overflows.
    @Test("An overflowing range is rejected")
    func overflow() {
        #expect(area("Range: bytes=0-9223372036854775807") == nil)
    }

    @Test("A negative start is rejected")
    func negative() {
        #expect(area("Range: bytes=-50") == nil)
    }

    @Test("What is not a range header is not one")
    func noHead() {
        #expect(area("Host: 127.0.0.1") == nil)
        #expect(area("Range: pages=1-2") == nil)
    }
}
