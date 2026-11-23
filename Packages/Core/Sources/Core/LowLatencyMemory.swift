import Foundation

/// Remembers the channels for which AVPlayer rejected the partial-segment path.
///
/// **The finding** (F-019, 2026-09-04, "DE: TELE MOOS HQ"): after 14.9 s and once
/// more after 5.8 s "Playback broke off — decoding failed
/// [-11855] · CoreMediaErrorDomain -15410 · Low Latency: Server must support
/// http2 ECN and SACK". The local server speaks HTTP/1.1, and AVPlayer
/// mostly accepts the partial-segment promise over it — not for this channel, and
/// then the picture breaks every few seconds. A channel that has shown this once
/// gets its playlist **without parts** from the next rebuild: the
/// ordinary HLS path with half-second segments, a tick later on screen, but
/// without the breakage. Volatile, in memory — the next app start
/// tries parts again.
public final class LowLatencyMemory: @unchecked Sendable {

    public static let shared = LowLatencyMemory()

    private let lock = NSLock()
    private var rejected: Set<URL> = []

    public init() {}

    public func reject(_ source: URL) {
        lock.lock()
        defer { lock.unlock() }
        rejected.insert(source)
    }

    public func isRejected(_ source: URL) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return rejected.contains(source)
    }

    public var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return rejected.count
    }
}
