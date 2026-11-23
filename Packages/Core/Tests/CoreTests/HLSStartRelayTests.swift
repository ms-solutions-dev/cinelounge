import Foundation
import Testing

@testable import Core

/// The list with start marker — the transcription as a pure calculation.
@Suite("Continue Watching via the playlist")
struct HLSStartRelayTests {
    private let base = URL(
        string: "http://192.0.2.10:8096/Videos/abc/main.m3u8?api_key=k&PlaySessionId=p")!

    @Test("The start marker goes after the header, the addresses become absolute")
    func rewriteInsertsStartAndAbsolutizes() {
        let text = """
            #EXTM3U
            #EXT-X-VERSION:7
            #EXT-X-TARGETDURATION:6
            #EXT-X-MAP:URI="hls1/main/-1.mp4?api_key=k"
            #EXTINF:6.000000, nodesc
            hls1/main/0.mp4?api_key=k
            #EXTINF:6.000000, nodesc
            hls1/main/1.mp4?api_key=k
            #EXT-X-ENDLIST
            """
        let out = HLSStartRelay.rewritten(text, base: base, startAt: 1074.5)
        let lines = out.split(separator: "\n").map(String.init)
        #expect(lines[0] == "#EXTM3U")
        #expect(lines[1] == "#EXT-X-START:TIME-OFFSET=1074.500,PRECISE=YES")
        #expect(
            lines.contains(
                "#EXT-X-MAP:URI=\"http://192.0.2.10:8096/Videos/abc/hls1/main/-1.mp4?api_key=k\""))
        #expect(lines.contains("http://192.0.2.10:8096/Videos/abc/hls1/main/1.mp4?api_key=k"))
        #expect(lines.last == "#EXT-X-ENDLIST")
    }

    @Test("The piece that contains the start position gets warmed up")
    func prewarmTargetIsTheSegmentAtStart() {
        let text = [
            "#EXTM3U",
            "#EXT-X-MAP:URI=\"hls1/main/-1.mp4?api_key=k\"",
            "#EXTINF:6.000000, nodesc", "hls1/main/0.mp4?api_key=k",
            "#EXTINF:6.000000, nodesc", "hls1/main/1.mp4?api_key=k",
            "#EXTINF:6.000000, nodesc", "hls1/main/2.mp4?api_key=k",
            "#EXTINF:3.500000, nodesc", "hls1/main/3.mp4?api_key=k",
        ].joined(separator: "\n")
        #expect(
            HLSStartRelay.warmUpTarget(text, base: base, startAt: 13)?.absoluteString
                == "http://192.0.2.10:8096/Videos/abc/hls1/main/2.mp4?api_key=k")
        #expect(
            HLSStartRelay.warmUpTarget(text, base: base, startAt: 18.5)?.absoluteString
                == "http://192.0.2.10:8096/Videos/abc/hls1/main/3.mp4?api_key=k")
        // Before the second piece the server starts at the front anyway.
        #expect(HLSStartRelay.warmUpTarget(text, base: base, startAt: 2) == nil)
        // Past the end there is nothing to warm up.
        #expect(HLSStartRelay.warmUpTarget(text, base: base, startAt: 60) == nil)
    }

    /// **The whole MP4 as a "playlist"** (AP75): An IPTV film with a guessed `hls` ended up here
    /// and was downloaded up to the deadline before the comparison said no.
    @Test("A file that is not a playlist is discarded after the first bytes")
    func noListAfterFirstBytes() async throws {
        let server = try LocalMediaServer()
        let film = Data(repeating: 0x42, count: 8 << 20)
        server.provider = { name in name == "film.mp4" ? (film, "video/mp4") : nil }
        try await server.start()
        defer { server.stop() }
        let address = URL(string: server.address("film.mp4"))!
        await #expect(throws: HLSStartRelay.Failure.self) {
            _ = try await HLSStartRelay.list(address)
        }
        // A real playlist still passes through whole.
        let list = Data("#EXTM3U\n#EXTINF:6,\nhttp://h/s0.mp4\n".utf8)
        server.provider = { name in name == "liste.m3u8" ? (list, "application/vnd.apple.mpegurl") : nil }
        let fetched = try await HLSStartRelay.list(URL(string: server.address("liste.m3u8"))!)
        #expect(fetched == list)
    }

    @Test("Warming up reads the response header and aborts")
    func prewarmHeadOnly() async throws {
        let server = try LocalMediaServer()
        let piece = Data(repeating: 0x00, count: 8 << 20)
        server.provider = { name in name == "s7.mp4" ? (piece, "video/mp4") : nil }
        try await server.start()
        defer { server.stop() }
        let result = await HLSStartRelay.warmUp(URL(string: server.address("s7.mp4"))!)
        #expect(result?.status == 200)
        #expect(await HLSStartRelay.warmUp(URL(string: server.address("nix.mp4"))!)?.status == 404)
    }

    @Test("An existing start marker is replaced, absolute addresses stay")
    func existingStartIsReplaced() {
        let text = "#EXTM3U\n#EXT-X-START:TIME-OFFSET=0\n#EXTINF:6,\nhttp://h/s0.mp4\n"
        let out = HLSStartRelay.rewritten(text, base: base, startAt: 30)
        #expect(out.components(separatedBy: "#EXT-X-START").count == 2)
        #expect(out.contains("TIME-OFFSET=30.000"))
        #expect(out.contains("http://h/s0.mp4"))
    }
}
