import Foundation

/// The playlist that AVFoundation gets from us.
///
/// **Here we are the server.** AVFoundation can play fMP4 over HLS, but it wants to be
/// offered the segments through a playlist — so we build one, even though nobody puts it
/// on the network. It describes what we currently hold in memory and is rewritten on every
/// top-up.
///
/// **The header segment is in it as `EXT-X-MAP`, not as the first piece.** It carries the
/// descriptions of the stream, no picture; whoever lines it up like an ordinary segment
/// gets a dropout at that point and a shifted timeline afterwards.
public enum RemuxPlaylist {

    /// A complete address for a piece.
    ///
    /// **Not a custom address scheme, but `http` to the device itself** — and that is the
    /// lesson of 2026-08-09. The obvious way would be a custom scheme and an
    /// `AVAssetResourceLoaderDelegate` that hands out the bytes; it was built, answers all four
    /// requests and still fails. AVFoundation's error log names the reason in three words:
    /// **`custom url not redirect`**. For an address with a custom scheme that sits *inside* an
    /// HLS playlist, the delegate may only **redirect**; it may not deliver data for it. What
    /// was known for `.ts` applies to fMP4 just the same.
    ///
    /// So AVFoundation gets what it expects: ordinary HTTP addresses. Where they point is
    /// decided by ``LocalMediaServer``.
    public static func address(_ name: String, base: String) -> String {
        "\(base)/\(name)"
    }

    public static let headerName = "header.mp4"

    /// The name of a period's header segment: the first is named as always, every further one
    /// carries its number — see ``Piece/period``.
    public static func headerName(period: Int) -> String {
        period == 0 ? headerName : "header\(period).mp4"
    }

    /// The name of a data segment, by its number.
    public static func segmentName(_ index: Int) -> String { "segment\(index).m4s" }

    /// What the playlist needs to know about a piece.
    public struct Piece: Sendable, Equatable {
        public let duration: Double
        /// Whether it begins with a keyframe — see
        /// ``SegmentStore/append(_:duration:independent:)``.
        public let independent: Bool
        /// Which period the piece belongs to. **One period per header segment** (AP7 · 4): if the
        /// audio track changes, the remuxer writes a new header segment, and the playlist tells the
        /// player as `EXT-X-DISCONTINUITY` with a new `EXT-X-MAP` — AVPlayer takes the change
        /// without reloading.
        public let period: Int

        public init(duration: Double, independent: Bool = true, period: Int = 0) {
            self.duration = duration
            self.independent = independent
            self.period = period
        }
    }

    /// Whether the running playlist is emitted as Low-Latency HLS.
    ///
    /// **A switch so it can be flipped without a build** (2026-09-03): On the Mac the parts can be
    /// checked only up to AVFoundation accepting them; whether the TV really takes the parts
    /// path over `127.0.0.1` and HTTP/1.1 only the TV shows. If it does not hold, `false`
    /// brings back the plain playlist — with the same short pieces.
    /// **Off since the evening of 2026-09-04** (F-031): AVPlayer's error comment on the TELE MOOS
    /// dropout read "Low Latency: Server must support http2 ECN and SACK" — the parts path
    /// requires HTTP/2, and the local server speaks HTTP/1.1. On most channels AVPlayer
    /// accepted the parts anyway, but on TELE MOOS it threw "Decoding failed −11855" after a
    /// minute and again right after every rebuild; the "jumps without any input" on the German
    /// HQ channels fit the same picture. The plain playlist with half-second pieces keeps three
    /// pieces of distance — 1.5 s behind the edge instead of one, and with no condition the
    /// server cannot meet.
    public nonisolated(unsafe) static var lowLatency = false

    /// How far behind the edge the player stays with the plain playlist, in seconds — see the
    /// comment where it writes it.
    public nonisolated(unsafe) static var holdBack: Double = 6

    /// How far behind the edge the player should join when using parts — three parts, as Apple
    /// recommends (at least two).
    public static let partHoldBack: Double = 1.0
    /// The smallest part duration the playlist promises. The writer cuts at the NEXT frame
    /// after half a second; at 20 frames per second that is half a second plus a twentieth.
    /// If a piece ever gets longer, the promise grows with it (see `partTarget:` on ``build``)
    /// — it must never be below a listed part, otherwise AVPlayer rejects the whole playlist
    /// (`-12642`, F-004).
    public static let partTarget: Double = 0.6
    /// For how many pieces at the end the parts are listed — the playlist only has to name
    /// them for the last three target durations.
    static let partsListed = 6

    /// Builds the playlist for the segments at hand.
    ///
    /// - Parameters:
    ///   - durations: The length of each segment in seconds.
    ///   - firstIndex: The number of the first listed segment. For a running channel it
    ///     grows, because the front is discarded — the value keeps the count continuous,
    ///     otherwise the player would start over from the beginning on every top-up.
    ///   - isLive: Whether the stream keeps running. A finished playlist is explicitly told
    ///     its end; without that the player would wait at the end for a top-up that never
    ///     comes.
    ///   - base: The address root of the server, e.g. `http://127.0.0.1:52341`.
    ///   - targetDuration: The largest value so far, so it never decreases — see below.
    public static func build(
        durations: [Double],
        firstIndex: Int = 0,
        isLive: Bool = true,
        targetDuration: Int? = nil,
        base: String
    ) -> String {
        build(
            pieces: durations.map { Piece(duration: $0) }, firstIndex: firstIndex,
            isLive: isLive, targetDuration: targetDuration, base: base, parts: false)
    }

    /// The same playlist, with parts — the path of the ``CMAFWriter``.
    ///
    /// - Parameters:
    ///   - pieces: The pieces, together with whether they stand on their own.
    ///   - parts: Whether the pieces are additionally listed as parts (`EXT-X-PART`) — only
    ///     for a running channel. Each piece is then its own part: the player may fetch it as
    ///     soon as it exists, and joins ``partHoldBack`` behind the edge instead of three
    ///     target durations.
    ///   - nextIndex: The number of the piece that comes into being next — the player may
    ///     request it ahead of time (`EXT-X-PRELOAD-HINT`), and the server holds the request
    ///     until it exists.
    public static func build(
        pieces: [Piece],
        firstIndex: Int = 0,
        isLive: Bool = true,
        targetDuration: Int? = nil,
        base: String,
        parts: Bool,
        nextIndex: Int? = nil,
        partTarget: Double = RemuxPlaylist.partTarget
    ) -> String {
        // **The target duration must not decrease.** RFC 8216 §4.3.3.1 requires that it does not
        // change over the lifetime of a playlist — the player derives its polling interval from
        // it. It was computed, however, from the **running window**: when a long first piece
        // slides out at the back, the value dropped from four to two (check agent 2026-08-23). So the
        // caller passes in the highest value so far.
        let durations = pieces.map(\.duration)
        let measured = Int(ceil(durations.max() ?? 2))
        let listsParts = parts && isLive
        var lines = [
            "#EXTM3U",
            "#EXT-X-VERSION:\(listsParts ? 9 : 7)",
            "#EXT-X-TARGETDURATION:\(max(measured, targetDuration ?? 0))",
        ]
        if listsParts {
            // **The player may reload the playlist in a blocking way** — the server holds it until
            // the named piece exists (see ``LocalMediaServer/hold``). Without this promise it would
            // poll at the rhythm of the target duration and see every piece half a second late on
            // average.
            lines.append(
                "#EXT-X-SERVER-CONTROL:CAN-BLOCK-RELOAD=YES,PART-HOLD-BACK=\(format(partHoldBack))")
            lines.append("#EXT-X-PART-INF:PART-TARGET=\(format(max(partTarget, Self.partTarget)))")
        }
        lines.append("#EXT-X-MEDIA-SEQUENCE:\(firstIndex)")
        // The number of the first listed period — so the player does not take a break that has
        // slid out of the window for a new one.
        let firstPeriod = pieces.first?.period ?? 0
        lines.append("#EXT-X-DISCONTINUITY-SEQUENCE:\(firstPeriod)")
        lines.append("#EXT-X-MAP:URI=\"\(address(headerName(period: firstPeriod), base: base))\"")

        // **Where the player should start — explicitly at the beginning.**
        //
        // Without this, with a running playlist AVPlayer looks for its entry point **three target
        // durations before the end** — and that does not exist when the playlist carries only two
        // pieces so far. Measured (check agent 2026-08-23): ten out of ten startups released with
        // exactly two pieces then sat **four to six seconds on the first frame** before the clock
        // ran; every startup with three pieces ran immediately.
        //
        // That is the viewer finding of 2026-08-23: on some channels the picture sat still, and a good
        // while later it started. That the audio also kicked in at that moment was coincidence —
        // both hang on the same clock. The audio was demonstrably always there: piece 0 carries it
        // in all cases checked, and our own MP2 decoder runs 27 times faster than real time even
        // in the debug build.
        //
        // **With parts the setting is dropped**: there `PART-HOLD-BACK` says where to join —
        // three parts behind the edge — and an explicit start at the first piece would pull the
        // entry back to the beginning of the window, i.e. up to forty seconds back.
        if isLive, !listsParts {
            // **The distance to the edge is stated, not guessed** (probe 2026-09-04, recordings of
            // TELE MOOS, SELA 1, Varo): Without a value, AVPlayer keeps three target durations of
            // distance — with half-second pieces, three seconds. Channels with field pairing and deep
            // reordering (TELE MOOS, SELA 1) publish their pieces later, and the player ran into the
            // edge: stalls with a full buffer. `HOLD-BACK` states the distance explicitly; the
            // latency grows by a few seconds.
            if holdBack > 0 {
                lines.append("#EXT-X-SERVER-CONTROL:HOLD-BACK=\(format(holdBack))")
            }
            lines.append("#EXT-X-START:TIME-OFFSET=-\(format(max(holdBack, 3))),PRECISE=YES")
        }
        if !isLive { lines.append("#EXT-X-PLAYLIST-TYPE:VOD") }

        let firstWithParts = max(0, pieces.count - partsListed)
        var period = firstPeriod
        for (offset, piece) in pieces.enumerated() {
            let name = segmentName(firstIndex + offset)
            if piece.period != period {
                period = piece.period
                lines.append("#EXT-X-DISCONTINUITY")
                lines.append("#EXT-X-MAP:URI=\"\(address(headerName(period: period), base: base))\"")
            }
            // A piece above the promise is not a part — it stays an ordinary piece, and the player
            // fetches it as such.
            if listsParts, offset >= firstWithParts, piece.duration <= max(partTarget, Self.partTarget) {
                lines.append(
                    "#EXT-X-PART:DURATION=\(format(piece.duration)),URI=\"\(address(name, base: base))\""
                        + (piece.independent ? ",INDEPENDENT=YES" : ""))
            }
            lines.append("#EXTINF:\(format(piece.duration)),")
            lines.append(address(name, base: base))
        }
        if listsParts, let nextIndex {
            lines.append(
                "#EXT-X-PRELOAD-HINT:TYPE=PART,URI=\"\(address(segmentName(nextIndex), base: base))\"")
        }
        if !isLive { lines.append("#EXT-X-ENDLIST") }

        return lines.joined(separator: "\n") + "\n"
    }

    private static func format(_ seconds: Double) -> String {
        String(format: "%.5f", seconds)
    }

    /// Which piece an address means.
    ///
    /// **A master playlist does not occur here, and that is measured, not assumed (2026-08-09).**
    /// It had been built because AVFoundation supposedly requires one for fMP4 — the
    /// assumption dated from the time when the stream was still rejected for another reason.
    /// Rechecked: an `AVPlayerItem` directly on the media playlist reports `readyToPlay`. One
    /// piece fewer on the way to the first frame.
    ///
    /// It will come back only when there are **several audio tracks to choose from**: separate
    /// tracks need `EXT-X-MEDIA`, and that exists only in a master playlist. As long as the
    /// audio sits in the segment, it is not needed.
    public enum Request: Equatable {
        case media
        /// The header segment of a period — `header.mp4` is period 0.
        case header(period: Int)
        case segment(Int)
    }

    /// Maps a requested address to a piece.
    ///
    /// Deliberately by the last path component and not by the whole address: AVFoundation
    /// normalises it along the way, and a comparison for equality once went wrong because of
    /// that.
    public static func request(for url: URL) -> Request? {
        request(forName: url.lastPathComponent.isEmpty ? (url.host() ?? "") : url.lastPathComponent)
    }

    /// The same for an already extracted name.
    public static func request(forName name: String) -> Request? {
        switch name {
        case "media.m3u8": return .media
        case headerName: return .header(period: 0)
        default:
            if name.hasPrefix("header"), name.hasSuffix(".mp4"),
                let period = Int(name.dropFirst("header".count).dropLast(".mp4".count))
            {
                return .header(period: period)
            }
            guard name.hasPrefix("segment"), name.hasSuffix(".m4s"),
                let index = Int(name.dropFirst("segment".count).dropLast(".m4s".count))
            else { return nil }
            return .segment(index)
        }
    }
}
