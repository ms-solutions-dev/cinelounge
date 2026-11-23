import Foundation

/// Remembers per channel the token edge address that the panel
/// redirects to — so that the next start bypasses the panel (AP7 · 2).
///
/// **The biggest item in the startup is the provider:** the panel's redirect
/// to its edge costs 0.4–0.8 s per start and yields an
/// address that is valid for minutes. Whoever keeps it saves the detour at the
/// next grab — and, if the token has expired, receives a
/// rejection, whereupon ``LiveRemuxSession`` forgets the address and goes
/// through the panel once. Volatile, in memory only: a token
/// does not survive an app restart, and what it does not survive needs
/// no store.
public final class EdgeMemory: @unchecked Sendable {

    public static let shared = EdgeMemory()

    /// How long an edge address counts as warm. The tokens of the known
    /// providers last considerably longer; the limit protects against an
    /// expired token that would only be noticed after the grab.
    public static let lifetime: TimeInterval = 10 * 60

    private let lock = NSLock()
    private var edges: [URL: (edge: URL, at: Date)] = [:]
    /// Providers (panel hosts) whose edges tolerate no second use.
    ///
    /// **F-006, 2026-09-04:** the edge of plusbalans.eu answers the
    /// remembered address with 509 — the token is valid once. Every warm grab
    /// there would be a detour of a few hundred milliseconds before the cold one;
    /// after the first rejection the app remembers the provider and goes
    /// only through the panel from then on.
    private var unreusableHosts: Set<String> = []

    public init() {}

    public func remember(source: URL, edge: URL, at now: Date = Date()) {
        guard edge != source else { return }
        lock.lock()
        defer { lock.unlock() }
        guard !unreusableHosts.contains(Self.host(of: source)) else { return }
        edges[source] = (edge, now)
    }

    /// The warm address was rejected: the provider does not let its edges
    /// be grabbed twice — from now on only cold for this provider.
    public func rejectWarm(source: URL) {
        lock.lock()
        defer { lock.unlock() }
        edges[source] = nil
        unreusableHosts.insert(Self.host(of: source))
    }

    /// Ob dieser Anbieter warme Adressen duldet.
    public func allowsWarm(source: URL) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return !unreusableHosts.contains(Self.host(of: source))
    }

    static func host(of url: URL) -> String { url.host ?? "" }

    /// The warm address for a channel — `nil` if none or expired.
    public func edge(for source: URL, now: Date = Date()) -> URL? {
        lock.lock()
        defer { lock.unlock() }
        guard let entry = edges[source] else { return nil }
        guard now.timeIntervalSince(entry.at) < Self.lifetime else {
            edges[source] = nil
            return nil
        }
        return entry.edge
    }

    public func forget(source: URL) {
        lock.lock()
        defer { lock.unlock() }
        edges[source] = nil
    }

    public var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return edges.count
    }
}
