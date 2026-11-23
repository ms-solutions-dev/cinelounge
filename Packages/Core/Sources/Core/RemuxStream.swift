import Foundation

/// Downloads and server as one piece — what the player needs for playback.
///
/// **The purpose is that nobody outside knows about HLS.** Whoever wants to play a remuxed
/// stream gets an address here and puts it into an `AVURLAsset`. That a playlist, a header
/// segment and a ring buffer stand behind it is none of the caller's business.
///
/// **Why this belongs together and does not stay two things:** The addresses in the
/// playlist must point to the same port the server listens on — and the system assigns that
/// number only at startup. Kept apart, that would be an ordering you get backwards once and
/// then search for a long time.
public final class RemuxStream: @unchecked Sendable {

    public let store: SegmentStore
    private let server: LocalMediaServer

    /// - Parameters:
    ///   - store: The store the remuxer fills.
    ///   - isLive: Whether the stream keeps running (channel) or ends (recording, film).
    public init(store: SegmentStore, isLive: Bool = true) throws {
        self.store = store
        server = try LocalMediaServer()

        // The responses are rebuilt on every request, not prepared once: With a running channel
        // the playlist grows constantly, and one written once would be outdated by the second
        // fetch. **Hold until what was asked for exists** — the promise from
        // `CAN-BLOCK-RELOAD=YES` and the `PRELOAD-HINT`, see
        // ``RemuxPlaylist/build(pieces:firstIndex:isLive:targetDuration:base:parts:nextIndex:)``.
        // Only for a running stream: a finished file has nothing to wait for.
        if isLive {
            let report = Once()
            server.hold = { name, query in
                guard let index = Self.awaitedSegment(name: name, query: query) else { return }
                // **Once per session into the trace** (2026-09-03): Whether the player really takes the parts
                // path can be seen only on the TV — and only in this request. A single time suffices as
                // proof; every further line would be the same one half a second later.
                if name == "media.m3u8", report.claim() {
                    Diagnostics.verbose(
                        "Playlist requested blocking (segment \(index)) — the player takes the partial-segment path"
                    )
                }
                await store.waitForSegment(index, timeout: Self.holdTimeout)
            }
        }

        server.provider = { [weak self] name in
            guard let self else { return nil }
            let base = self.base

            switch name {
            case "media.m3u8":
                return (
                    Data(store.playlist(isLive: isLive, base: base).utf8),
                    "application/vnd.apple.mpegurl"
                )
            default:
                switch RemuxPlaylist.request(forName: name) {
                case .header(let period)?:
                    guard let data = store.header(period: period) else { return nil }
                    return (data, "video/mp4")
                case .segment(let index)?:
                    guard let data = store.segment(index) else { return nil }
                    return (data, "video/mp4")
                default:
                    return nil
                }
            }
        }
    }

    /// How long a held request waits at most.
    ///
    /// Three seconds: longer than any burst pause of the provider, shorter than the player's
    /// patience. After that it gets what is there — the old playlist for the playlist, a 404
    /// for a piece — and asks again by itself.
    public static let holdTimeout: TimeInterval = 3

    /// What a request waits for — as a pure computation, so it is testable.
    ///
    /// The playlist with `_HLS_msn=<n>` waits for piece n; a piece waits for itself.
    /// Everything else is answered immediately.
    static func awaitedSegment(name: String, query: [String: String]) -> Int? {
        switch RemuxPlaylist.request(forName: name) {
        case .media?:
            return query["_HLS_msn"].flatMap(Int.init)
        case .segment(let index)?:
            return index
        default:
            return nil
        }
    }

    /// A switch that flips exactly once — for the one line per session.
    private final class Once: @unchecked Sendable {
        private let lock = NSLock()
        private var done = false
        func claim() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            guard !done else { return false }
            done = true
            return true
        }
    }

    /// The address root of the server.
    public var base: String { "http://127.0.0.1:\(server.port)" }

    /// Starts the server. **Only afterwards does the address exist.**
    public func start() async throws {
        try await server.start()
    }

    public func stop() { server.stop() }

    /// The address for the `AVURLAsset`.
    ///
    /// Points to the **media playlist**, not to a master playlist — that is not needed, see
    /// ``RemuxPlaylist/Request``.
    public var assetURL: URL { URL(string: RemuxPlaylist.address("media.m3u8", base: base))! }
}
