import Foundation
import Testing

@testable import Downloads

/// The table of delivery types — **for each case real headers and real first bytes.**
///
/// **This is the actual value of this build section**, and the reasoning is in the order as
/// a question from the product owner of 2026-09-09: *"are there common formats that we
/// forgot to consider? So that it doesn't show up on every single attempt."*
/// Exactly that is prevented by a check with measured responses and nothing else: a new
/// host shows up here or not at all.
///
/// **All headers below were measured on 2026-09-09** — at the portal bridge on the home server, at the
/// media server of this project (schedule, "Aloha" addendum of 2026-09-08) and at the
/// provider account.
@Suite("Delivery kind")
struct DeliveryKindTests {

    /// 1 · **File with ranges.** Serieshub via the bridge, 561 MB.
    @Test("206 with ranges is a file that can be fetched piecewise")
    func fileInPieces() {
        let probe = Probe(
            status: 206, contentType: "video/mp4", acceptsRanges: "bytes",
            contentRange: "bytes 0-511/561149891", length: 561_149_891,
            start: Data([0, 0, 0, 0x20, 0x66, 0x74, 0x79, 0x70]))
        #expect(DeliveryKind.from(probe) == .fileInPieces)
        #expect(DeliveryKind.from(probe).isDownloadable)
    }

    /// 1b · **A broken `Accept-Ranges` must not cost the file.**
    ///
    /// Measured at the provider account: `Accept-Ranges: 0-2511729429` — the server writes the
    /// range where `bytes` belongs. The response is nevertheless a flawless
    /// `206` with a valid `Content-Range`. **What the response proves counts; what it
    /// claims only appears in the trace.**
    @Test("A nonsensical Accept-Ranges changes nothing about a valid 206")
    func brokenHeader() {
        let probe = Probe(
            status: 206, contentType: "video/mp4", acceptsRanges: "0-2511729429",
            contentRange: "bytes 0-1/2511729429", length: 2_511_729_429)
        #expect(DeliveryKind.from(probe) == .fileInPieces)
        // And the record names the header as unusable instead of as a promise.
        let reason = Resumability.reason(status: 200, acceptsRanges: "0-2511729429")
        #expect(reason.contains("unusable"))
    }

    /// 2 · **File without ranges.** The media server for a transcoded version.
    @Test("200 with Accept-Ranges: none is a file that only goes in one piece")
    func wholeFile() {
        let probe = Probe(
            status: 200, contentType: "video/mp4", acceptsRanges: "none",
            length: 1_970_000_000)
        #expect(DeliveryKind.from(probe) == .wholeFile)
        #expect(DeliveryKind.from(probe).isDownloadable)
    }

    /// 3 · **HLS — and indeed with `206` and `accept-ranges: bytes`.**
    ///
    /// **This is the measurement that refuted the first draft.** The order read:
    /// "200 for lists, 206 for files". Measured, the bridge answers the
    /// flatone list with `206`, `accept-ranges: bytes` and
    /// `content-range: bytes 0-1/53127`. A switch on the status would have written 53 KB of text to disk as a
    /// film.
    @Test("An HLS playlist stays a playlist, even with 206 and ranges")
    func hlsDespite206() {
        let probe = Probe(
            status: 206, contentType: "application/vnd.apple.mpegurl",
            acceptsRanges: "bytes", contentRange: "bytes 0-511/53127", length: 53127,
            start: Data("#EXTM3U\n#EXT-X-VERSION:3\n".utf8))
        #expect(DeliveryKind.from(probe) == .hls)
    }

    /// 3b · **`application/x-mpegURL` is the same** — the Ahorn variant writes it that way.
    @Test("Both spellings of the HLS content type count")
    func hlsSpellings() {
        #expect(DeliveryKind.from(Probe(status: 200, contentType: "application/x-mpegURL")) == .hls)
        #expect(
            DeliveryKind.from(Probe(status: 200, contentType: "application/vnd.apple.mpegurl")) == .hls)
    }

    /// 3c · **The body decides where the content type lies.**
    ///
    /// A reader that passes a list through as `application/octet-stream` is no
    /// special case but the rule for small readers — and `octet-stream` would
    /// otherwise be exactly the row "file in one piece".
    @Test("An #EXTM3U in the body beats a wrong content type")
    func bodyBeatsHeader() {
        let probe = Probe(
            status: 200, contentType: "application/octet-stream",
            start: Data("#EXTM3U\n#EXTINF:4,\nseg.ts\n".utf8))
        #expect(DeliveryKind.from(probe) == .hls)
    }

    /// 3d · **A byte order mark in front changes nothing.** It comes from every reader that
    /// created the list in Windows tools.
    @Test("A byte order mark before the EXTM3U is skipped")
    func byteOrderMark() {
        var raw = Data([0xEF, 0xBB, 0xBF])
        raw.append(Data("#EXTM3U\n".utf8))
        #expect(DeliveryKind.from(Probe(status: 200, contentType: "text/plain", start: raw)) == .hls)
    }

    /// 4 · **MPEG-DASH — recognized and named, not built.**
    @Test("DASH is recognized and rejected with a reason")
    func dash() {
        let probe = Probe(
            status: 200, contentType: "application/dash+xml",
            start: Data("<?xml version=\"1.0\"?><MPD xmlns=".utf8))
        #expect(DeliveryKind.from(probe) == .dash)
        #expect(!DeliveryKind.from(probe).isDownloadable)
        #expect(DeliveryKind.from(probe).rejection == .dash)
    }

    /// 5 · **Endless stream.** The case from E34: an access that only provides `ts`.
    @Test("MPEG-TS without length is an endless stream")
    func endlessStream() {
        let probe = Probe(status: 200, contentType: "video/mp2t")
        #expect(DeliveryKind.from(probe) == .endlessStream)
        #expect(DeliveryKind.from(probe).rejection == .endlessStream)
    }

    /// 5b · **The same `video/mp2t` with a length is an ordinary segment.**
    ///
    /// The difference is exactly the length — an HLS segment is likewise a
    /// transport stream and does have an end. Whoever treated both the same would reject every
    /// TS delivery, including the ones this package is only now able to download.
    @Test("A transport stream with length is not an endless stream")
    func transportStreamWithEnd() {
        let probe = Probe(
            status: 206, contentType: "video/mp2t", acceptsRanges: "bytes",
            contentRange: "bytes 0-511/188000", length: 188_000)
        #expect(DeliveryKind.from(probe) == .fileInPieces)
    }

    /// 6 · **A redirect is not a destination but a signpost.**
    ///
    /// Measured at the provider account: `302` to another machine with a character token.
    @Test("A 302 is named as a redirect and carries its target")
    func redirect() {
        let target = URL(string: "http://vodturk.example:8888/live/play/abc/344604")!
        let probe = Probe(status: 302, contentType: "text/html", next: target)
        #expect(DeliveryKind.from(probe) == .redirect(target))
        #expect(DeliveryKind.from(probe).isDownloadable)
    }

    /// 7 · **The busy access is no statement about the server but about the
    /// moment** — and the only rejection that goes away by itself.
    @Test("551 means connection busy and not no ranges")
    func accessBusy() {
        for status in [429, 509, 512, 551] {
            let probe = Probe(status: status, contentType: "text/html")
            #expect(DeliveryKind.from(probe) == .accessBusy)
            #expect(DeliveryKind.from(probe).rejection == .accessBusy)
        }
    }

    /// 8 · **An error page is not a delivery.**
    ///
    /// Measured at the bridge: `502` with `{"detail":"der Puffer trägt nicht mehr"}`. Downloading it as a
    /// "file in one piece" would yield a film file made of an error message.
    @Test("An error response does not become a file")
    func errorPage() {
        let probe = Probe(
            status: 502, contentType: "application/json",
            start: Data(#"{"detail":"der Puffer trägt nicht mehr"}"#.utf8))
        #expect(DeliveryKind.from(probe) == .unclear("application/json"))
        #expect(DeliveryKind.from(probe).rejection == .unknownFormat("application/json"))
    }

    /// 9 · **What remains is called "unclear" and names the content type.**
    ///
    /// That is the whole intent of the table: with the next unknown host, the screen shows
    /// **what** was delivered — and not "connection lost" for a
    /// response that arrived.
    @Test("An unknown content type travels into the rejection")
    func unknown() {
        let probe = Probe(status: 200, contentType: "application/x-rar-compressed")
        #expect(DeliveryKind.from(probe).rejection == .unknownFormat("application/x-rar-compressed"))
    }

    /// **Every delivery type has either a path or a rejection — and never both or
    /// neither.**
    ///
    /// That is the rule this whole type is built against, and it stands here as a
    /// check so that it is not forgotten at the next new case.
    @Test("Every case carries either a strategy or a rejection")
    func complete() {
        let all: [DeliveryKind] = [
            .fileInPieces, .wholeFile, .hls, .dash, .endlessStream, .accessBusy,
            .redirect(nil), .unclear("x"),
        ]
        for kind in all {
            #expect(kind.isDownloadable == (kind.rejection == nil), "\(kind)")
        }
    }
}
