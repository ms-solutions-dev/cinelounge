import Foundation
import Network

/// Serves the playlist and segments over `http://127.0.0.1`.
///
/// **Why a server and not a delegate — the finding of 2026-08-09** The route through
/// `AVAssetResourceLoaderDelegate` is built, answers all four requests,
/// and still fails. AVFoundation's error log gives the reason in three words:
/// **`custom url not redirect`**. An address with a custom scheme that appears
/// *inside* an HLS playlist may only be **redirected** by the delegate — it may
/// not supply data for it. The rule known for `.ts` segments applies to fMP4 just
/// the same; the assumption that fMP4 was exempt was wrong.
///
/// Redirecting only helps if there is a target. So we give it one: a
/// server reachable only on the device itself. To AVFoundation this is
/// ordinary HTTP — the path it was built for, with partial requests
/// and everything that goes with it.
///
/// **Nothing goes onto the network anyway.** The bind is explicitly to
/// `127.0.0.1`; that address never leaves the device, and no other machine on the
/// same Wi-Fi can reach it. And responses are served from memory, not
/// from disk — the segments are already there.
public final class LocalMediaServer: @unchecked Sendable {

    /// Where the responses come from.
    ///
    /// A closure instead of a fixed store, so the server does not need to know anything about
    /// the remuxer: it knows names and bytes, nothing else.
    public typealias Provider = @Sendable (_ name: String) -> (data: Data, type: String)?

    /// Whatever **holds** a request until the requested item exists.
    ///
    /// **For Low-Latency HLS** (2026-09-03): the player requests the playlist with
    /// `_HLS_msn=<n>` and an announced part before it exists. The server must not
    /// answer either request immediately — the playlist would be the old one, the part
    /// a 404 — but only once the requested item exists.
    /// The holder receives the name and the query parts and returns when
    /// a response may be sent. Without a holder the server answers immediately.
    public typealias Hold = @Sendable (_ name: String, _ query: [String: String]) async -> Void

    public enum StartFailure: Error {
        case noPort
        case listenerFailed(Error)
    }

    private let listener: NWListener
    private let queue = DispatchQueue(label: "cinelounge.local-media-server")
    private let lock = NSLock()
    private var _provider: Provider?
    private var _hold: Hold?

    /// Siehe ``Hold``.
    public var hold: Hold? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _hold
        }
        set {
            lock.lock()
            defer { lock.unlock() }
            _hold = newValue
        }
    }

    /// Where the server gets its responses from.
    ///
    /// **Settable after the fact and not fixed at construction**, because the
    /// responses contain the port number — and the system only hands that out
    /// at start. Requiring both at construction would require that
    /// something be finished before it has begun.
    public var provider: Provider? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _provider
        }
        set {
            lock.lock()
            defer { lock.unlock() }
            _provider = newValue
        }
    }

    /// The port number the system assigned.
    ///
    /// **Assigned by the system and not chosen fixed:** a fixed number would
    /// already be taken by the second channel in the same session, and the start
    /// would fail without anything being wrong with the stream.
    public private(set) var port: UInt16 = 0

    public init(provider: Provider? = nil) throws {
        _provider = provider

        let parameters = NWParameters.tcp
        // Reachable only on the device itself — see above.
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        // Without this permission a port that was only just released stays
        // blocked for a short while; with fast channel switching that would be a
        // failed start with no visible reason.
        parameters.allowLocalEndpointReuse = true

        do {
            listener = try NWListener(using: parameters)
        } catch {
            throw StartFailure.listenerFailed(error)
        }
    }

    /// Starts the server and returns only once the number is known.
    ///
    /// **The waiting is the point.** The port number is only known once the
    /// system has assigned it — whoever builds the address earlier writes a
    /// zero into it and wonders about a stream that arrives nowhere.
    public func start() async throws {
        let ready = AsyncStream<Result<UInt16, Error>>.makeStream()

        listener.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                guard let raw = self?.listener.port?.rawValue else {
                    ready.continuation.yield(.failure(StartFailure.noPort))
                    return
                }
                self?.port = raw
                ready.continuation.yield(.success(raw))
            case .failed(let error):
                ready.continuation.yield(.failure(StartFailure.listenerFailed(error)))
            default:
                break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        listener.start(queue: queue)

        for await result in ready.stream {
            switch result {
            case .success: return
            case .failure(let error): throw error
            }
        }
        throw StartFailure.noPort
    }

    public func stop() {
        listener.cancel()
    }

    deinit { listener.cancel() }

    /// The address of an item on this server.
    public func address(_ name: String) -> String {
        "http://127.0.0.1:\(port)/\(name)"
    }

    // MARK: - Der Ablauf einer Anfrage

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        receive(on: connection, buffer: Data())
    }

    /// Collects until the head of the request is complete.
    ///
    /// **Piece by piece and not in one go**, because TCP has no message
    /// boundaries: a request can arrive in two packets, and whoever evaluates it
    /// after the first finds half a line.
    private func receive(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) {
            [weak self] chunk, _, isComplete, error in
            guard let self else { return }
            var buffer = buffer
            if let chunk { buffer.append(chunk) }

            if error != nil || (isComplete && buffer.isEmpty) {
                connection.cancel()
                return
            }

            guard let head = Self.headEnd(in: buffer) else {
                if isComplete {
                    connection.cancel()
                } else {
                    self.receive(on: connection, buffer: buffer)
                }
                return
            }

            let request = String(decoding: buffer[..<head], as: UTF8.self)
            self.answer(request, on: connection)
        }
    }

    /// The end of the request head: the blank line.
    private static func headEnd(in data: Data) -> Data.Index? {
        let marker = Data("\r\n\r\n".utf8)
        return data.range(of: marker)?.lowerBound
    }

    private func answer(_ request: String, on connection: NWConnection) {
        let lines = request.split(separator: "\r\n", omittingEmptySubsequences: false)
        guard let requestLine = lines.first else {
            send(status: "400 Bad Request", on: connection)
            return
        }

        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2 else {
            send(status: "400 Bad Request", on: connection)
            return
        }
        let method = String(parts[0])
        let target = String(parts[1].drop(while: { $0 == "/" }))
        // Name and query parts kept apart: `media.m3u8?_HLS_msn=12` means the
        // playlist, and the number says what to wait for.
        let (name, query) = Self.split(target)

        guard method == "GET" || method == "HEAD" else {
            send(status: "405 Method Not Allowed", on: connection)
            return
        }

        // **Partial requests are mandatory.** AVFoundation fetches segments
        // section by section; a server that ignores the range and stubbornly sends everything
        // delivers at the wrong offset, and the decoder reads garbage.
        let range = lines.compactMap(Self.byteRange).first

        // **Hold first, then deliver.** The holder runs asynchronously; the
        // connection waits on its thread in the meantime — for the player this is
        // a response that takes a little longer, and that is exactly what it wants.
        if let hold {
            Task { [weak self] in
                await hold(name, query)
                // Capture first, then pass on: a weak reference inside
                // a further closure is a shared variable, and Swift 6 does not
                // tolerate that in concurrent code.
                guard let self else { return }
                self.queue.async {
                    self.deliver(name, method: method, range: range, on: connection)
                }
            }
        } else {
            deliver(name, method: method, range: range, on: connection)
        }
    }

    /// Splits `name?a=b&c=d` into name and query parts.
    static func split(_ target: String) -> (name: String, query: [String: String]) {
        guard let mark = target.firstIndex(of: "?") else { return (target, [:]) }
        let name = String(target[..<mark])
        var query: [String: String] = [:]
        for pair in target[target.index(after: mark)...].split(separator: "&") {
            let sides = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard let key = sides.first, !key.isEmpty else { continue }
            query[String(key)] = sides.count > 1 ? String(sides[1]) : ""
        }
        return (name, query)
    }

    /// **The provider's work runs alongside the connection queue** (AP72, 2026-10-11).
    /// Until then this spot called the provider on the one serial queue, and an
    /// MKV piece that hangs up to 20 s in construction (``MatroskaFileSession/piece``) held up
    /// every other response — including the playlist and the second piece, which AVPlayer
    /// requests almost simultaneously after a seek. Now a concurrent worker fetches the
    /// piece, and only the response goes back onto the connection's queue.
    private func deliver(
        _ name: String, method: String, range: Range<Int>?, on connection: NWConnection
    ) {
        let provider = self.provider
        work.async { [weak self] in
            let piece = provider?(name)
            guard let self else { return }
            self.queue.async {
                self.respond(piece, name: name, method: method, range: range, on: connection)
            }
        }
    }

    private let work = DispatchQueue(
        label: "cinelounge.local-media-server.work", qos: .userInitiated, attributes: .concurrent)

    private func respond(
        _ piece: (data: Data, type: String)?, name: String, method: String, range: Range<Int>?,
        on connection: NWConnection
    ) {
        guard let piece else {
            // **The 404 belongs in the trace too** (AP6 · Q10): a film whose
            // pieces cannot be built looked in the diagnostics like
            // a film nobody had opened — the server stayed silent, and the
            // player only reported "no picture".
            Diagnostics.playbackProblem(
                "Local server: \(name) not available — 404", since: nil)
            send(status: "404 Not Found", on: connection)
            return
        }

        // **The segment log — thinned out** (user request 2026-08-15: packets
        // instead of a flood of lines). Without this line there was no way to see from outside WHAT
        // the player really fetches; but logging every delivery individually produced
        // hundreds of lines per film. What remains are the informative ones: the head
        // and the first piece (the startup) and every tenth after that (if
        // the fetching stalls, the next line is missing). Playlist requests
        // say nothing and are dropped entirely.
        if Self.isWorthLogging(name) {
            Diagnostics.verbose(
                "Serving \(name)"
                    + (range.map { " [\($0.lowerBound)–\($0.upperBound)]" } ?? ""))
        }

        let start = min(range?.lowerBound ?? 0, piece.data.count)
        let end = min(range?.upperBound ?? piece.data.count, piece.data.count)
        let body = Data(piece.data[start..<max(start, end)])

        var head = range == nil ? "HTTP/1.1 200 OK\r\n" : "HTTP/1.1 206 Partial Content\r\n"
        head += "Content-Type: \(piece.type)\r\n"
        head += "Content-Length: \(body.count)\r\n"
        head += "Accept-Ranges: bytes\r\n"
        if range != nil {
            head += "Content-Range: bytes \(start)-\(max(start, end) - 1)/\(piece.data.count)\r\n"
        }
        // No cache: for a live channel the playlist changes constantly,
        // and a response remembered once would be a standstill.
        head += "Cache-Control: no-store\r\n"
        head += "Connection: close\r\n\r\n"

        var response = Data(head.utf8)
        if method == "GET" { response.append(body) }
        send(response, on: connection)
    }

    /// Reads `Range: bytes=100-199` — both bounds may be missing.
    /// Which deliveries are worth a line — the rule lives with the caller.
    ///
    /// As pure arithmetic, so it can be tested: head and piece 0 carry the
    /// startup, every tenth piece the continuation; playlists say nothing.
    static func isWorthLogging(_ name: String) -> Bool {
        if name.hasSuffix(".m3u8") { return false }
        guard name.hasPrefix("segment"), name.hasSuffix(".m4s"),
            let index = Int(name.dropFirst("segment".count).dropLast(".m4s".count))
        else { return true }  // header.mp4 and everything unexpected
        return index % 10 == 0
    }

    /// Package-internal instead of `private`, so the edge cases can be tested — AP6 · Q10.
    static func byteRange(in line: some StringProtocol) -> Range<Int>? {
        let lower = line.lowercased()
        guard lower.hasPrefix("range:"), let equals = lower.firstIndex(of: "=") else { return nil }
        // **And the unit must be "bytes"** (AP6 · Q10, found while
        // checking): only the header name and the equals sign were checked,
        // so `Range: pages=1-2` passed as a byte range. HTTP knows
        // exactly one unit at this position, and what names another means
        // something else.
        let unit = lower[lower.index(lower.startIndex, offsetBy: 6)..<equals]
            .trimmingCharacters(in: .whitespaces)
        guard unit == "bytes" else { return nil }
        let spec = lower[lower.index(after: equals)...].trimmingCharacters(in: .whitespaces)
        let bounds = spec.split(separator: "-", omittingEmptySubsequences: false)
        guard let start = Int(bounds.first ?? ""), start >= 0 else { return nil }
        // "bytes=100-199" means 100 through 199 inclusive — HTTP counts the
        // last number, Swift does not. A slip costs exactly one byte, and
        // that one byte costs the whole segment.
        //
        // **And a reversed or overflowing range no longer crashes**
        // (AP6 · Q10, expert review 2026-08-24): `bytes=100-50` produced
        // `100..<51` — a `Range` with `lowerBound > upperBound`, and in Swift that
        // is a program abort, not an error. `bytes=0-9223372036854775807`
        // likewise, through the overflow of `last + 1`. Neither comes from
        // our player, but the server listens on a socket, and what
        // comes in there is not up to the app.
        if bounds.count > 1, let last = Int(bounds[1]) {
            guard last >= start, last < Int.max else { return nil }
            return start..<(last + 1)
        }
        return start..<Int.max
    }

    private func send(status: String, on connection: NWConnection) {
        let head = "HTTP/1.1 \(status)\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
        send(Data(head.utf8), on: connection)
    }

    private func send(_ data: Data, on connection: NWConnection) {
        connection.send(
            content: data,
            completion: .contentProcessed { _ in connection.cancel() })
    }
}
