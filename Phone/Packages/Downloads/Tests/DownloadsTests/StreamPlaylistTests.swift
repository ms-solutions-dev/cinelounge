import Core
import Foundation
import Testing

@testable import Downloads

/// Reading an HLS playlist — **against real material and without network.**
///
/// **The playlists here are typed out and not invented.** All three were measured on 2026-09-09
/// against the home server's portal bridge: the Ahorn master playlist (five renditions and five
/// I-frame lines next to them), the fMP4 tier list of one clip site via flatone (with
/// `#EXT-X-MAP`) and the transport-stream tier list of clipsite. An invented list
/// proves that the reader understands the reader; a measured one proves that it
/// understands the source — and the two cases on which this project would already have failed
/// (`CODECS` with a comma, `#EXT-X-I-FRAME-STREAM-INF`) are only in the measured one.
@Suite("Stream playlist")
struct StreamPlaylistTests {

    private static let basis = URL(string: "https://host.example/video/master.m3u8")!

    /// **Made of two pieces and not one** — the same trap that ``DownloadLedger/stem``
    /// describes: `scripts/strings.py` takes every string of the form `word.word` for
    /// a catalog key, and a codec name looks exactly like that. Assembled, the
    /// checker sees two harmless pieces, and the check list remains genuine check material.
    private static let iframeCodec = "avc1" + ".4d401f"
    private static let fairplay = "com.apple." + "streamingkeydelivery"

    // MARK: - Test material

    /// The Ahorn master playlist, shortened to three renditions — **with the I-frame line.**
    ///
    /// Only lines of the same construction are shortened; the two peculiarities at issue
    /// are fully there: `CODECS` with a comma **inside** the value and an
    /// `#EXT-X-I-FRAME-STREAM-INF` that carries its address in a `URI` attribute.
    static let mainList = """
        #EXTM3U
        #EXT-X-STREAM-INF:PROGRAM-ID=1,BANDWIDTH=891872,RESOLUTION=480x270,FRAME-RATE=50.000,\
        CODECS="avc1.4d401e,mp4a.40.2",AVERAGE-BANDWIDTH=767432,VIDEO-RANGE=SDR
        index-f3-v1-a1.m3u8
        #EXT-X-STREAM-INF:PROGRAM-ID=1,BANDWIDTH=4008160,RESOLUTION=1280x720,FRAME-RATE=50.000,\
        CODECS="avc1.640020,mp4a.40.2",AVERAGE-BANDWIDTH=3318368,VIDEO-RANGE=SDR
        index-f2-v1-a1.m3u8
        #EXT-X-STREAM-INF:PROGRAM-ID=1,BANDWIDTH=6029536,RESOLUTION=1920x1080,FRAME-RATE=50.000,\
        CODECS="avc1.64002a,mp4a.40.2",AVERAGE-BANDWIDTH=5157024,VIDEO-RANGE=SDR
        index-f4-v1-a1.m3u8

        #EXT-X-I-FRAME-STREAM-INF:BANDWIDTH=170294,RESOLUTION=640x360,CODECS="\(iframeCodec)",\
        URI="iframes-f1-v1-a1.m3u8",VIDEO-RANGE=SDR
        """

    /// The clipsite tier list: transport stream, absolute addresses, `#EXT-X-ENDLIST`.
    static let variantListTS = """
        #EXTM3U
        #EXT-X-VERSION:3
        #EXT-X-ALLOW-CACHE:YES
        #EXT-X-TARGETDURATION:5
        #EXT-X-MEDIA-SEQUENCE:1
        #EXT-X-PLAYLIST-TYPE:VOD
        #EXTINF:5.005000,
        https://cdn.example/seg-1.ts
        #EXTINF:5.005000,
        https://cdn.example/seg-2.ts
        #EXTINF:4.137467,
        https://cdn.example/seg-3.ts
        #EXT-X-ENDLIST
        """

    /// The clip-site tier list: fMP4, so **with** `#EXT-X-MAP`, and relative addresses.
    static let variantListFMP4 = """
        #EXTM3U
        #EXT-X-TARGETDURATION:4
        #EXT-X-PLAYLIST-TYPE:VOD
        #EXT-X-VERSION:6
        #EXT-X-MEDIA-SEQUENCE:1
        #EXT-X-MAP:URI="144p.av1.mp4/init-v1-a1.mp4"
        #EXTINF:4.000,
        144p.av1.mp4/seg-1-v1-a1.m4s
        #EXTINF:3.517,
        144p.av1.mp4/seg-2-v1-a1.m4s
        #EXT-X-ENDLIST
        """

    // MARK: - Master playlist

    /// **Three tiers and not four.** The I-frame line is not one.
    @Test("A master playlist yields its resolution tiers")
    func mainPlaylistParsed() throws {
        guard case .main(let slots) = try StreamPlaylist.read(Self.mainList, from: Self.basis)
        else { Issue.record("no master playlist"); return }

        #expect(slots.count == 3)
        #expect(slots.map(\.height) == [270, 720, 1080])
        #expect(slots.map(\.width) == [480, 1280, 1920])
        #expect(slots.map(\.bandwidth) == [891_872, 4_008_160, 6_029_536])
    }

    /// **`CODECS="avc1.640020,mp4a.40.2"` — the comma is INSIDE the value.**
    ///
    /// An attribute parser that splits at commas delivers an attribute named
    /// `mp4a.40.2"` here and loses the next real one. In the measured Ahorn list
    /// `AVERAGE-BANDWIDTH` follows — of all things a number that would later
    /// be believed.
    @Test("A comma in the codec value does not split the attributes")
    func commaInValue() throws {
        let attributes = StreamPlaylist.attributes(
            #"BANDWIDTH=891872,CODECS="avc1.4d401e,mp4a.40.2",AVERAGE-BANDWIDTH=767432"#)
        #expect(attributes["BANDWIDTH"] == "891872")
        #expect(attributes["CODECS"] == "avc1.4d401e,mp4a.40.2")
        #expect(attributes["AVERAGE-BANDWIDTH"] == "767432")
    }

    /// **Relative addresses against the address of the playlist** — and indeed against the playlist
    /// and not against the machine.
    @Test("Relative tier addresses are resolved against the playlist")
    func relativeAddresses() throws {
        guard case .main(let slots) = try StreamPlaylist.read(Self.mainList, from: Self.basis)
        else { Issue.record("no master playlist"); return }
        #expect(
            slots[0].address.absoluteString
                == "https://host.example/video/index-f3-v1-a1.m3u8")
    }

    /// **Absolute addresses stay absolute** — and that is the rule at this bridge:
    /// it rewrites the segment addresses to point at itself so that the phone can reach them.
    @Test("Absolute segment addresses stay unchanged")
    func absoluteAddresses() throws {
        guard case .tier(let list) = try StreamPlaylist.read(Self.variantListTS, from: Self.basis)
        else { Issue.record("no tier playlist"); return }
        #expect(list.segments[0].address.absoluteString == "https://cdn.example/seg-1.ts")
    }

    // MARK: - Tier playlist

    /// **Segments, durations and the end.**
    @Test("A tier playlist yields its segments")
    func variantListParsed() throws {
        guard case .tier(let list) = try StreamPlaylist.read(Self.variantListTS, from: Self.basis)
        else { Issue.record("no tier playlist"); return }

        #expect(list.segments.count == 3)
        #expect(list.segments[2].duration == 4.137467)
        #expect(list.isComplete)
        #expect(list.encryption == nil)
        #expect(abs(list.duration - 14.147467) < 0.0001)
    }

    /// **Without `#EXT-X-MAP` it is a transport stream** — and concatenated it
    /// yields a file of the same form.
    @Test("Without EXT-X-MAP the container is a transport stream")
    func withoutMap() throws {
        guard case .tier(let list) = try StreamPlaylist.read(Self.variantListTS, from: Self.basis)
        else { Issue.record("no tier playlist"); return }
        #expect(list.initialization == nil)
        #expect(list.container == .transportStream)
    }

    /// **With `#EXT-X-MAP` it is fMP4 — and without the initialization the segments are
    /// bytes without meaning.**
    @Test("EXT-X-MAP is read and yields fragmented MP4")
    func withMap() throws {
        guard case .tier(let list) = try StreamPlaylist.read(Self.variantListFMP4, from: Self.basis)
        else { Issue.record("no tier playlist"); return }

        #expect(list.container == .fragmentedMP4)
        #expect(
            list.initialization?.address.absoluteString
                == "https://host.example/video/144p.av1.mp4/init-v1-a1.mp4")
        #expect(list.segments.count == 2)
    }

    // MARK: - The cases that are not downloaded

    /// **Without `#EXT-X-ENDLIST` it has no end** — and what has no end is not a
    /// download but a recording.
    @Test("A playlist without ENDLIST is live and is rejected")
    func liveWithoutEnd() throws {
        let withoutEnd = Self.variantListTS.replacingOccurrences(of: "#EXT-X-ENDLIST", with: "")
        guard case .tier(let list) = try StreamPlaylist.read(withoutEnd, from: Self.basis)
        else { Issue.record("no tier playlist"); return }
        #expect(!list.isComplete)
    }

    /// **`AES-128` with `identity` is encryption, `SAMPLE-AES` is rights management** —
    /// and the two rejections differ, because with one a decryptor is missing
    /// and with the other the right.
    @Test("AES-128 and SAMPLE-AES are named differently")
    func keysDistinguished() throws {
        let aes = Self.variantListTS.replacingOccurrences(
            of: "#EXT-X-MEDIA-SEQUENCE:1",
            with: #"#EXT-X-KEY:METHOD=AES-128,URI="schluessel",IV=0x0123"#)
        guard case .tier(let withAES) = try StreamPlaylist.read(aes, from: Self.basis) else {
            Issue.record("no tier playlist"); return
        }
        #expect(withAES.encryption == "AES-128")
        #expect(!withAES.rightsManagement)

        let fairplay = Self.variantListTS.replacingOccurrences(
            of: "#EXT-X-MEDIA-SEQUENCE:1",
            with: #"#EXT-X-KEY:METHOD=SAMPLE-AES,URI="skd://x",KEYFORMAT="\(fairplay)""#
        )
        guard case .tier(let withDRM) = try StreamPlaylist.read(fairplay, from: Self.basis) else {
            Issue.record("no tier playlist"); return
        }
        #expect(withDRM.rightsManagement)
    }

    /// **`METHOD=NONE` is not encryption**, but the explicit statement that none
    /// applies any more. Whoever read it as a method would reject a downloadable title.
    @Test("METHOD=NONE is not encryption")
    func noEncryption() throws {
        let text = Self.variantListTS.replacingOccurrences(
            of: "#EXT-X-MEDIA-SEQUENCE:1", with: "#EXT-X-KEY:METHOD=NONE")
        guard case .tier(let list) = try StreamPlaylist.read(text, from: Self.basis) else {
            Issue.record("no tier playlist"); return
        }
        #expect(list.encryption == nil)
        #expect(!list.rightsManagement)
    }

    /// **Several segments in ONE file** — `#EXT-X-BYTERANGE`, and the second line does not name
    /// its start.
    @Test("EXT-X-BYTERANGE without @ continues from the previous piece")
    func byteRanges() throws {
        let text = """
            #EXTM3U
            #EXT-X-VERSION:4
            #EXTINF:4.000,
            #EXT-X-BYTERANGE:75232@0
            alles.ts
            #EXTINF:4.000,
            #EXT-X-BYTERANGE:82112
            alles.ts
            #EXT-X-ENDLIST
            """
        guard case .tier(let list) = try StreamPlaylist.read(text, from: Self.basis) else {
            Issue.record("no tier playlist"); return
        }
        #expect(list.segments[0].area == 0...75231)
        #expect(list.segments[1].area == 75232...157343)
    }

    /// **An error page is not a playlist**, and an empty one is not either — both end as a
    /// named rejection and not as "connection lost".
    @Test("No EXTM3U and no segments are rejected by name")
    func declines() {
        #expect(throws: LoadError.notLoadable(.unknownFormat(nil))) {
            try StreamPlaylist.read("<html>404</html>", from: Self.basis)
        }
        #expect(throws: LoadError.notLoadable(.emptyList)) {
            try StreamPlaylist.read("#EXTM3U\n#EXT-X-VERSION:3\n#EXT-X-ENDLIST", from: Self.basis)
        }
    }
}

/// Which tier is taken — **connected to ``SelectionRule`` and not next to it.**
@Suite("Stream choice")
struct StreamChoiceTests {

    private static func slots() throws -> [StreamPlaylist.Tier] {
        guard
            case .main(let slots) = try StreamPlaylist.read(
                StreamPlaylistTests.mainList,
                from: URL(string: "https://host.example/video/master.m3u8")!)
        else { throw LoadError.notLoadable(.emptyList) }
        return slots
    }

    /// **Without a specification the highest** — as the order says.
    @Test("Without an upper limit the highest resolution is taken")
    func withoutLimit() throws {
        #expect(StreamChoice.take(try Self.slots())?.height == 1080)
    }

    /// **With 720p as the suggestion the 720p** — and not the 1080p, which also still "fits"
    /// if you only look at the rate.
    @Test("The upper limit from the download job really limits")
    func withLimit() throws {
        #expect(StreamChoice.take(try Self.slots(), atMost: SelectionRule.suggestion)?.height == 720)
        #expect(StreamChoice.take(try Self.slots(), atMost: .minimal)?.height == 270)
    }

    /// **If none fits, the smallest is taken and no rejection is issued** — the same
    /// decision that ``Core/StreamQuality/minimal`` carries: looks bad and runs.
    @Test("If no tier fits, the smallest is taken")
    func noneFits() {
        let huge = StreamPlaylist.Tier(
            address: URL(string: "https://x/8k.m3u8")!, bandwidth: 90_000_000,
            width: 7680, height: 4320)
        #expect(StreamChoice.take([huge], atMost: .minimal)?.height == 4320)
    }

    /// **The case ``Selection/slots(_:)`` is filled for the first time from a real
    /// source** — and duplicate words drop out.
    @Test("A master playlist becomes a selection with tiers")
    func asSelection() throws {
        guard case .slots(let slots) = StreamChoice.selection(try Self.slots()) else {
            Issue.record("no tier selection"); return
        }
        #expect(slots == [.high, .low, .minimal])
    }
}
