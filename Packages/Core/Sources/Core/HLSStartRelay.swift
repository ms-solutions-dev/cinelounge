import Foundation

/// The media server's playlist via the local server, with
/// the resume position as `EXT-X-START` — so that AVPlayer fetches the
/// right segment first on Continue Watching.
///
/// **The finding** (F-013, F-001, 2026-09-04): Resuming at minute 17
/// took sometimes 1.3 s, sometimes 30. Measured against the server without the app: If
/// the segment at that position is requested directly, it delivers in 0.5–1.1 s. The
/// thirty seconds arise in the player — AVPlayer first fetches segment 0 before the jump,
/// and for that the server has to remux from zero; only then
/// comes the jump, the server restarts, and it works. `StartTimeTicks`
/// in the address is forbidden by the server (F-014). What remains is the playlist
/// itself: It passes through here, gets `#EXT-X-START:TIME-OFFSET=<position>`,
/// and AVPlayer begins there — the first requested segment is the one at the
/// position, and the server starts its ffmpeg right there. App-side, without a
/// setting on the server; the player keeps fetching the segments directly.
public final class HLSStartRelay: @unchecked Sendable {

    public enum Failure: Error {
        case notAPlaylist
        case fetchFailed(Int)
    }

    private let server: LocalMediaServer
    public let startAt: TimeInterval
    private let playlist: Data

    /// Fetches the playlist, rewrites it and serves it locally.
    public init(source: URL, startAt: TimeInterval) async throws {
        self.startAt = startAt
        let data = try await Self.list(source)
        guard let text = String(data: data, encoding: .utf8) else { throw Failure.notAPlaylist }
        let rewritten = Self.rewritten(text, base: source, startAt: startAt)
        playlist = Data(rewritten.utf8)
        // **The segment at the start position is warmed up** (F-015, 2026-09-05).
        // The server does not start ffmpeg at the playlist but at the
        // first segment request — and AVPlayer first requests the head segment,
        // which knows no position: ffmpeg ran from zero, was aborted at the jump
        // and restarted at the position, or the server
        // waited until the remux from zero got there (9–30 s startup).
        // `StartTimeTicks` in the address does not help (F-014: the
        // segment endpoint throws it back). If, on the other hand, someone requests the
        // segment at the position FIRST, the server starts there (`-ss`, proven at the server:
        // 1.5 s to the segment, the head afterwards in 37 ms) — and the
        // engine's requests meet a running job.
        if let target = Self.warmUpTarget(text, base: source, startAt: startAt) {
            await Self.warmUp(target)
        }
        let content = playlist
        server = try LocalMediaServer()
        server.provider = { name in
            guard name == "media.m3u8" else { return nil }
            return (content, "application/vnd.apple.mpegurl")
        }
        try await server.start()
        Diagnostics.playbackStep(
            String(
                format: "Continue Watching: playlist with start marker at %.1f s via the local server",
                startAt),
            since: nil)
    }

    public var assetURL: URL {
        URL(string: RemuxPlaylist.address("media.m3u8", base: "http://127.0.0.1:\(server.port)"))!
    }

    public func stop() { server.stop() }

    /// The rewrite as pure computation: Addresses become absolute, the
    /// start tag goes after the header, an existing one is replaced.
    public static func rewritten(_ text: String, base: URL, startAt: TimeInterval) -> String {
        let start = String(format: "#EXT-X-START:TIME-OFFSET=%.3f,PRECISE=YES", startAt)
        var lines: [String] = []
        var inserted = false
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw).trimmingCharacters(in: .init(charactersIn: "\r"))
            if line.hasPrefix("#EXT-X-START") { continue }
            if line.hasPrefix("#EXT-X-MAP:"), let range = line.range(of: "URI=\"") {
                let rest = line[range.upperBound...]
                if let end = rest.firstIndex(of: "\"") {
                    let uri = String(rest[..<end])
                    lines.append(
                        String(line[..<range.upperBound]) + absolute(uri, base: base) + String(rest[end...]))
                    continue
                }
            }
            if !line.isEmpty, !line.hasPrefix("#") {
                lines.append(absolute(line, base: base))
                continue
            }
            lines.append(line)
            if !inserted, line.hasPrefix("#EXTM3U") {
                lines.append(start)
                inserted = true
            }
        }
        return lines.joined(separator: "\n")
    }

    static func absolute(_ uri: String, base: URL) -> String {
        if uri.hasPrefix("http://") || uri.hasPrefix("https://") { return uri }
        return URL(string: uri, relativeTo: base)?.absoluteString ?? uri
    }

    /// The address of the segment containing the start position — summed from the
    /// playlist's `EXTINF` durations. `nil` without segments or for
    /// a position before the second segment (the server starts at the front
    /// anyway then).
    static func warmUpTarget(_ text: String, base: URL, startAt: TimeInterval) -> URL? {
        var sum: TimeInterval = 0
        var duration: TimeInterval?
        var index = 0
        for raw in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = String(raw).trimmingCharacters(in: .init(charactersIn: "\r"))
            if line.hasPrefix("#EXTINF:") {
                let number = line.dropFirst("#EXTINF:".count).split(separator: ",").first ?? ""
                duration = TimeInterval(number.trimmingCharacters(in: .whitespaces))
                continue
            }
            guard !line.isEmpty, !line.hasPrefix("#"), let d = duration else { continue }
            if startAt < sum + d {
                guard index >= 1 else { return nil }
                return URL(string: absolute(line, base: base))
            }
            sum += d
            index += 1
            duration = nil
        }
        return nil
    }

    /// Fetches the playlist — and aborts as soon as the first bytes say it is not one.
    ///
    /// **The whole file as "playlist"** (AP75, 2026-10-11): An IPTV film with a guessed
    /// delivery route `hls` landed here with its MP4 address, and `data(for:)` downloaded it up to the
    /// 20 s deadline before `hasPrefix("#EXTM3U")` said no. Now
    /// ``listHeader`` decides after the first seven bytes; a real playlist is still read in full
    /// — including that of a two-hour film with a few hundred kilobytes.
    static let listHeader = Data("#EXTM3U".utf8)

    static func list(_ source: URL, session: URLSession = .shared) async throws -> Data {
        var request = URLRequest(url: source)
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.timeoutInterval = 20
        let (stream, response) = try await session.bytes(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            stream.task.cancel()
            throw Failure.fetchFailed(http.statusCode)
        }
        var data = Data()
        for try await byte in stream {
            data.append(byte)
            if data.count == listHeader.count, data != listHeader {
                stream.task.cancel()
                throw Failure.notAPlaylist
            }
        }
        guard data.starts(with: listHeader) else { throw Failure.notAPlaylist }
        return data
    }

    /// How long to wait for the warmed-up segment — the server
    /// computes it fresh at the position, with hardware in one to two seconds.
    static let warmUpDeadline: TimeInterval = 12

    /// What the warm-up yielded — the status and the time to the response head.
    struct WarmUp: Equatable {
        let status: Int
        let ms: Int
    }

    /// Warms up the segment at the start position — **only up to the response head** (AP75).
    ///
    /// The purpose is that the server starts computing there; the request is enough for that.
    /// Until now `data(for:)` downloaded the whole segment, on the phone over cellular a
    /// few megabytes that the engine fetches again right afterwards. As soon as the head is there,
    /// the connection is aborted.
    @discardableResult
    static func warmUp(_ target: URL, session: URLSession = .shared) async -> WarmUp? {
        var request = URLRequest(url: target)
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.timeoutInterval = warmUpDeadline
        let startedAt = Date()
        do {
            let (stream, response) = try await session.bytes(for: request)
            stream.task.cancel()
            let result = WarmUp(
                status: (response as? HTTPURLResponse)?.statusCode ?? 0,
                ms: Int(Date().timeIntervalSince(startedAt) * 1000))
            Diagnostics.playbackStep(
                "Continue Watching: segment at the start position warmed up — \(result.status) "
                    + "after \(result.ms) ms, head is enough",
                since: nil)
            return result
        } catch {
            Diagnostics.playbackStep(
                "Continue Watching: warm-up failed (\(Diagnostics.explain(error))) — the engine fetches it itself",
                since: nil)
            return nil
        }
    }
}
