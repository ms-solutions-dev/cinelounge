import Foundation

/// Asks the **bytes** which container is really there.
///
/// **The finding** (AP3 · V3c, expert review 2026-08-24): If the file is called `.mp4`, it goes
/// straight to direct delivery, and the remuxer is never asked. The name comes from the
/// provider's Xtream information, and that is a claim — AVFoundation never opens a Matroska
/// behind a `.mp4` name, and the viewer sees a black picture for no reason.
///
/// **It asks only where the answer can change something.** If the information claims a
/// container that Apple's engine does not open anyway, the file is remuxed — if the claim is
/// wrong there, the remuxer notices itself. The mistake becomes expensive only in the other
/// direction: The file is called `.mp4`, so nobody asks.
///
/// **And it asks no more than it must** (AP69, 2026-10-11). Until then, before every Xtream
/// start a separate connection went out via `URLSession.shared` — without the identifier the
/// provider demands, without a cap on a 200 response (the whole file!), and it forgot the
/// result immediately. On a one-connection account that was the third connection next to the
/// size probe and the stream. Now: first the ``start`` from the file-head downloads,
/// otherwise a connection with the identifier that aborts after ``bytes`` — and the result
/// stays remembered per address.
public enum ContainerProbe {
    /// How many bytes are read from the start.
    ///
    /// Four kilobytes. The three identifiers are in the first 600 bytes; the transport stream's
    /// grid needs the most of those (three gaps of 188). The rest is slack for providers that
    /// prepend a few bytes — and still less than a single segment.
    public static let bytes = 4096

    /// The container according to the first bytes — or `nil` if they are silent or cannot be
    /// fetched.
    ///
    /// **A failure is not a finding.** If the other end does not answer, the provider's
    /// information stands: A claim is still better than no statement at all, and startup should
    /// not fail on this probe.
    ///
    /// - Parameters:
    ///   - anfang: The first bytes of the file, if already available (file-head downloads). Then
    ///     no request goes out.
    ///   - headers: What the request carries — for the Xtream provider the identifier without
    ///     which it closes the connection without a word.
    public static func read(
        _ url: URL, start: Data? = nil, headers: [String: String] = [:],
        session: URLSession = .shared
    ) async -> MediaSource.Container? {
        if let start, let finding = MediaSource.Container.fromBytes(start) {
            memo.memorize(finding, forItem: url)
            return finding
        }
        if let remembered = memo.finding(forItem: url) { return remembered }
        var request = URLRequest(url: url)
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        request.setValue("bytes=0-\(bytes - 1)", forHTTPHeaderField: "Range")
        // Keep it short: The probe sits in the startup path, and the viewer waits out whatever it
        // costs.
        request.timeoutInterval = 4
        guard let (stream, response) = try? await session.bytes(for: request),
            let http = response as? HTTPURLResponse,
            http.statusCode == 206 || http.statusCode == 200
        else { return nil }
        // Read only as much as needed — with a 200 the whole file would otherwise arrive.
        var data = Data()
        data.reserveCapacity(bytes)
        do {
            for try await byte in stream {
                data.append(byte)
                if data.count >= bytes { break }
            }
        } catch {
            // bewusst still: An abort after the first bytes is not worth a finding — what is there
            // is enough for the identifier; if nothing came at all, the container simply stays unknown.
            if data.isEmpty { return nil }
        }
        let finding = MediaSource.Container.fromBytes(data)
        if let finding { memo.memorize(finding, forItem: url) }
        return finding
    }

    /// Whether the probe is worth it for this case at all.
    ///
    /// Two conditions, and both are necessary:
    ///
    /// - **No media server.** Its information comes from its own analysis of the file and not
    ///   from a list; checking it would mean distrusting it where it knows better.
    /// - **The claimed container is one that Apple's engine opens.** Only then does a false
    ///   claim lead to direct delivery and thus into nothing.
    public static func isWorthwhile(claimed: MediaSource.Container, hasMediaServer: Bool) -> Bool {
        !hasMediaServer && claimed.isNativelySupported
    }

    /// What the probe already knows for an address — the container of a file does not change
    /// between two starts. `nil` if never asked.
    public static func remembered(forItem url: URL) -> MediaSource.Container? { memo.finding(forItem: url) }

    /// For checks: forget everything remembered.
    public static func forget() { memo.forget() }

    private static let memo = Memo()

    /// The findings per address, behind a lock — the probe runs from several tasks.
    private final class Memo: @unchecked Sendable {
        private let lock = NSLock()
        private var findings: [URL: MediaSource.Container] = [:]
        func finding(forItem url: URL) -> MediaSource.Container? {
            lock.withLock { findings[url] }
        }
        func memorize(_ finding: MediaSource.Container, forItem url: URL) {
            lock.withLock { findings[url] = finding }
        }
        func forget() { lock.withLock { findings.removeAll() } }
    }
}
