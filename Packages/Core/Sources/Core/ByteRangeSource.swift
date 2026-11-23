import Foundation

/// A source from which you can fetch pieces without loading the whole.
///
/// **The difference between "works" and "does not work".** A movie is three gigabytes.
/// Whoever wants to play it needs a few seconds of it at any moment — not three gigabytes.
/// Everything else in this corner of the code depends on ranges being retrievable
/// individually.
public protocol ByteRangeSource: Sendable {
    /// How large the file is.
    func length() async throws -> Int
    /// The bytes in this range, end exclusive.
    func bytes(in range: Range<Int>) async throws -> Data
}

/// What can go wrong when you fetch ranges over the network.
public enum ByteRangeFailure: Error, Equatable {
    case noLength
    case badStatus(Int)
    case shortRead(expected: Int, received: Int)
}

/// Fetches ranges over HTTP — the way to the server.
///
/// **`Range` is not a nicety but the precondition.** Jellyfin serves files with
/// `Accept-Ranges: bytes`; a server without that could only deliver from the start, and
/// seeking would be impossible.
public struct HTTPByteRangeSource: ByteRangeSource {

    /// The remuxer's session — **as many connections as the walk through the clusters has
    /// sections, and no more** (``MatroskaClusterWalk/defaultWorkers``).
    ///
    /// Until 2026-09-27 it carried 32 connections per host, so that the walk with 32 workers did
    /// not hang on the six of `URLSession.shared`. It is thereby also the limit for every other
    /// fetch of this session: It should not even open more connections than the disk at the other
    /// end can bear.
    public static let parallelSession: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.httpMaximumConnectionsPerHost = MatroskaClusterWalk.defaultWorkers
        configuration.timeoutIntervalForRequest = 30
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: configuration)
    }()

    /// The line for the **walk through the clusters** — its own, narrow connections.
    ///
    /// **The finding (F-002, 2026-09-28):** A walk that was finishing in the background shared
    /// the four connections of the playback; "Slebubreit Catblolai" was queued behind it. Two connections
    /// of its own, and the playback keeps its four.
    public static let runSession: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.httpMaximumConnectionsPerHost = MatroskaClusterWalk.gearConnections
        configuration.timeoutIntervalForRequest = 30
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: configuration)
    }()

    /// The same source via ``runSession``.
    public func forPass() -> HTTPByteRangeSource {
        HTTPByteRangeSource(
            url: url, headers: headers, session: Self.runSession, allowsHead: allowsHead)
    }

    private let url: URL
    private let session: URLSession
    private let headers: [String: String]

    /// Whether it is worth asking for the length via HEAD first.
    ///
    /// See ``length()``: Xtream providers reset the connection on it, a media server answers
    /// cleanly.
    private let allowsHead: Bool

    public init(
        url: URL,
        headers: [String: String] = [:],
        session: URLSession = .shared,
        allowsHead: Bool = true
    ) {
        self.url = url
        self.headers = headers
        self.session = session
        self.allowsHead = allowsHead
    }

    /// The reason for a network error, short and readable.
    static func reason(_ error: any Error) -> String {
        let code = (error as NSError).code
        switch code {
        case -1001: return "timeout"
        case -1005: return "connection reset (-1005)"
        case -1009: return "no network"
        default: return "error \(code)"
        }
    }

    public func length() async throws -> Int {
        // **HEAD first — but no longer blindly** (on-device finding 2026-08-23).
        //
        // The Xtream provider does not answer HEAD with an error header but with a **TCP reset**: no
        // HTTP response at all. In URLSession that is `-1005`, "The network connection was lost". In
        // ten runs the same ten times — so every provider movie start began with a guaranteed
        // error, which the `try?` here swallowed, costing about 220 ms in the process.
        //
        // Worse than the time was the confusion: In the submitted diagnostics `-1005` stood next to
        // an address, and nobody could say whether that was the HEAD or a real read fetch.
        //
        // The media server, by contrast, answers HEAD reliably, and there it saves a fetch. So no
        // abolition, but a question: Whoever can do partial fetches from a requested position is a
        // media server.
        if allowsHead {
            var request = URLRequest(url: url)
            request.httpMethod = "HEAD"
            for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }

            do {
                let (_, response) = try await session.data(for: request)
                if let http = response as? HTTPURLResponse,
                    (200..<300).contains(http.statusCode),
                    http.expectedContentLength > 0
                {
                    return Int(http.expectedContentLength)
                }
            } catch {
                Diagnostics.verbose(
                    "Length: HEAD failed (\(Self.reason(error))) at "
                        + "\(url.host ?? "?") — continuing with the partial fetch")
            }
        }

        // **The range probe as a second way** (on-device finding 2026-08-15, evening: VOD content no
        // longer plays at all): Xtream panels answer HEAD with `200` and `Content-Length: 0` — the
        // length on which everything here depends stands with them only in the response to a real
        // partial fetch: `Content-Range: bytes 0-0/2573824552`, confirmed by a counter-check on the
        // failed movie. ONE byte is fetched — and via `bytes(for:)` instead of `data(for:)`, because
        // a server that ignores the range starts sending the whole file: `data` would then load
        // gigabytes into memory, `bytes` returns after the header lines and dropping the stream ends
        // the connection.
        return try await lengthViaRangeProbe()
    }

    private func lengthViaRangeProbe() async throws -> Int {
        var probe = URLRequest(url: url)
        probe.setValue("bytes=0-0", forHTTPHeaderField: "Range")
        probe.cachePolicy = .reloadIgnoringLocalCacheData
        for (key, value) in headers { probe.setValue(value, forHTTPHeaderField: key) }

        let (body, response) = try await session.bytes(for: probe)
        defer { body.task.cancel() }
        guard let http = response as? HTTPURLResponse else { throw ByteRangeFailure.noLength }
        guard (200..<300).contains(http.statusCode) else {
            throw ByteRangeFailure.badStatus(http.statusCode)
        }
        if let total = Self.totalLength(
            fromContentRange: http.value(forHTTPHeaderField: "Content-Range"))
        {
            return total
        }
        // Range ignored, but an honest total length in the header: That is enough too.
        guard http.expectedContentLength > 1 else { throw ByteRangeFailure.noLength }
        return Int(http.expectedContentLength)
    }

    /// Reads the total length from a `Content-Range` header.
    ///
    /// The form is `bytes 0-0/2573824552`; behind the slash stands the whole file. A `*` there
    /// means: The server itself does not know it.
    static func totalLength(fromContentRange header: String?) -> Int? {
        guard let header, let slash = header.lastIndex(of: "/") else { return nil }
        guard let total = Int(header[header.index(after: slash)...].trimmingCharacters(in: .whitespaces)),
            total > 0
        else { return nil }
        return total
    }

    public func bytes(in range: Range<Int>) async throws -> Data {
        var request = URLRequest(url: url)
        request.setValue("bytes=\(range.lowerBound)-\(range.upperBound - 1)", forHTTPHeaderField: "Range")
        // No cache: The pieces are large, are mostly needed once, and the TV's memory is better
        // used otherwise.
        request.cachePolicy = .reloadIgnoringLocalCacheData
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }

        // **A second attempt, and exactly one** (on-device finding 2026-08-23: VOD content still does
        // not play — not all of it, that is).
        //
        // "Piotfrodaus 8" and "Jeipik-Bousjinflut" are structurally twins at the provider: same container, same
        // edge, both answer partial fetches, both keep their seek table at the end of the file. One
        // played, the other did not — so it was not the title but a single drop.
        //
        // This edge throws connections away; a retry costs milliseconds and saves the movie. **Only
        // one**, and only on a drop: Whoever keeps asking after a **refusal** runs into the panel's
        // IP throttle (the same lesson as on the retreat in ``LiveRemuxSession``).
        let started = Date()
        var data: Data
        var response: URLResponse
        var attempt = 1
        while true {
            do {
                (data, response) = try await session.data(for: request)
                break
            } catch  where Self.isWorthRetrying(error) && attempt < Self.maximumAttempts {
                // **Three attempts instead of two, with a short pause** (AP3 · V3a).
                //
                // "Slopra" failed on a `-1005`; "Piotfrodaus 8" got the same error twelve seconds later, its
                // second attempt succeeded, and the movie played. **The difference between "works" and
                // "does not work" was a single connection drop** — with exactly one retry the second drop is
                // the end again.
                //
                // The limit stays narrow, and the predecessor's reasoning still holds: Whoever keeps asking
                // after a **refusal** runs into the panel's IP throttle. Exactly that is why
                // ``isWorthRetrying(_:)`` stands here — it distinguishes the drop from the refusal — and no
                // loop over everything.
                //
                // The pause grows because a drop rarely comes alone: The edge throws away several connections
                // at one moment, and an immediate third attempt falls into the same hole.
                let pause = Self.pause(beforeAttempt: attempt + 1)
                Diagnostics.verbose(
                    "Range \(range.lowerBound)–\(range.upperBound): "
                        + "\(Self.reason(error)) — attempt \(attempt + 1) of "
                        + "\(Self.maximumAttempts) after \(Int(pause * 1000)) ms")
                try? await Task.sleep(for: .seconds(pause))
                attempt += 1
            }
        }

        // **Slow fetches belong in the trace**, otherwise "the TV stutters" cannot be told apart from
        // "the server hangs". Only the slow ones: One line per range would drown everything else.
        let took = Date().timeIntervalSince(started)
        if took > 2 {
            Diagnostics.playbackProblem(
                "Slow range \(range.lowerBound)–\(range.upperBound) "
                    + "(\(range.count / 1024) KiB): \(Int(took * 1000)) ms from "
                    + "\(url.host ?? "?")",
                since: started
            )
        }

        guard let http = response as? HTTPURLResponse else { throw ByteRangeFailure.noLength }
        // 200 instead of 206 means: The server ignored the range and sent the whole file. That is not
        // the error you search for later when the TV stutters — so it is named here.
        guard http.statusCode == 206 || http.statusCode == 200 else {
            throw ByteRangeFailure.badStatus(http.statusCode)
        }
        if http.statusCode == 200 {
            // The comment above promised to name this — nobody did it. And the case is nasty: If the
            // response is **exactly as large** as the requested range, the bytes below silently pass
            // through from zero as if they came from the requested position.
            Diagnostics.playbackProblem(
                "Partial fetch ignored: 200 instead of 206 for \(range.lowerBound)–"
                    + "\(range.upperBound), \(data.count) bytes received",
                since: nil
            )
            return try Self.slice(fromWholeFile: data, area: range)
        }
        return data
    }

    /// Whether an error is worth a second attempt.
    ///
    /// Only drops and timeouts. A **refusal** by the provider (403, 509) does not arrive here at
    /// all — it is in the status code, not in the error —, and "no network" does not repeat
    /// itself.
    /// The requested range from a response that ignored the partial fetch (200).
    ///
    /// **A 200 carries the file from byte zero — or an error page** (remuxer check B2,
    /// 2026-09-27). Here stood a slice `lowerBound..<min(upperBound, count)`: If the response was
    /// shorter than the requested position — Xtream panels answer a blocked account with 200 and
    /// an error page —, the end lay before the start and the app crashed. If it was just as long
    /// as the range, the bytes silently passed through from zero as if they came from the
    /// requested position.
    ///
    /// **Even from byte zero, a too-short response stays a ``ByteRangeFailure/shortRead``**
    /// (remuxer check, fix round B, 2026-09-27 — follow-up to B2). Until then it said here
    /// `range.lowerBound > 0 else { return Data(data.prefix(range.count)) }`: If less than
    /// requested came from byte zero, the slice silently delivered the shortened body instead of
    /// an error — the same "from zero it stays with the prefix" decision that B2b had already
    /// documented was wrong for the **short** case: An error page of a blocked Xtream account (a
    /// few hundred bytes of HTML) then looked to the header request like a legitimate, merely
    /// short file start and failed only later — with the misleading
    /// ``MatroskaFileSession/Failure/notMatroska``, far from the actual cause. Now the same rule
    /// applies as from a position above zero: If the response does not reach the requested end,
    /// it is a short read, no matter where it starts.
    static func slice(fromWholeFile data: Data, area range: Range<Int>) throws -> Data {
        guard data.count >= range.upperBound else {
            throw ByteRangeFailure.shortRead(
                expected: range.count, received: max(0, data.count - range.lowerBound))
        }
        return data.subdata(
            in: (data.startIndex + range.lowerBound)..<(data.startIndex + range.upperBound))
    }

    static func isWorthRetrying(_ error: any Error) -> Bool {
        [-1001, -1004, -1005, -1017, -1200, -997].contains((error as NSError).code)
    }

    /// How often a range is tried in total.
    ///
    /// **Three** (AP3 · V3a). Two were too few — the evidence is at the place where retries
    /// happen. Four would be a guess: The drop comes from an edge that throws connections away at
    /// one moment; whoever asks three more times after that only measures their own patience.
    static let maximumAttempts = 3

    /// The pause before an attempt — 120 ms, then 360 ms.
    ///
    /// Short enough that the viewer notices nothing (three attempts together cost less than half a
    /// second), long enough that the second attempt does not fall into the same hole as the first.
    static func pause(beforeAttempt attempt: Int) -> TimeInterval {
        0.12 * pow(3, Double(max(0, attempt - 2)))
    }
}

/// A source from memory — for checks and for small files.
public struct DataByteRangeSource: ByteRangeSource {

    private let data: Data

    public init(_ data: Data) {
        self.data = data
    }

    public func length() async throws -> Int { data.count }

    public func bytes(in range: Range<Int>) async throws -> Data {
        let bottom = min(max(0, range.lowerBound), data.count)
        let top = min(max(bottom, range.upperBound), data.count)
        guard bottom < top else { return Data() }
        return data.subdata(in: (data.startIndex + bottom)..<(data.startIndex + top))
    }
}
