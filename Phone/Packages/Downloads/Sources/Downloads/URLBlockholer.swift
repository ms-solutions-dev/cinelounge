import Diagnose
import Foundation

/// The ``BlockFetcher`` that really goes over the network.
///
/// **The session is a background session, and that has exactly one consequence here:** the
/// convenient `async` calls of `URLSession` do not exist there — `data(for:)` **throws** on
/// a background session. Such a session works through delegates, because its tasks are
/// meant to outlive the app. That is why there is a bridge from delegates to `async` here, and
/// not the convenient call that would have failed on the first block.
///
/// **What the system does NOT require for this: an entry in `UIBackgroundModes`.** The
/// background modes apply to things the app does itself — audio, location, voice call. A
/// download is run by the system; it wakes the app when a task is finished. The
/// entry would be not only superfluous but a statement in the review questionnaire that has to be
/// justified.
///
/// **The second half lies in the app target, and it has been there since 2026-09-08** For a
/// block to finish even when the app was **terminated**,
/// `application(_:handleEventsForBackgroundURLSession:completionHandler:)` must be answered and
/// the session restored under the same identifier. This package cannot do that:
/// it has no `UIApplicationDelegate`. It can, however, say **what** it needs —
/// ``WakeNotice`` is the place where the app target hands it over.
///
/// **What then happens to a finished block is still decided here.** After a
/// restart no continuation is waiting for it any more; the bridge then writes it into the
/// partial file named in the job instead of throwing it away — see ``Bridge``.
public final class URLBlockFetcher: BlockFetcher {

    public static let identifier = "dev.ms-solutions.cinelounge.vorrat"

    private let session: URLSession
    private let bridge: Bridge

    /// Where a block belongs — **on the task and not in a table here.**
    ///
    /// **After a restart this table no longer exists.** The system wakes the app
    /// and delivers a finished task; whoever kept the mapping in memory would then not
    /// know which file the bytes belong in and would have to throw them away — fetching exactly the
    /// amount of data again that background downloading is meant to save. In
    /// `taskDescription` it hangs on the task itself, and that survives because the system
    /// holds it.
    /// **Fixed and not mutable.** A fetcher is built per job; re-pointing it
    /// afterwards would mean a running block suddenly points at a different file.
    /// (The compiler puts it more strictly: a `Sendable` with a mutable field is none.)
    public let partialState: DownloadJob.Identifier?

    private func description(_ area: ClosedRange<Int64>) -> String? {
        guard let partialState else { return nil }
        return "\(partialState.rawValue)|\(area.lowerBound)"
    }

    /// **One session per identifier, held in one place** — see ``SessionRegistry``.
    public init(identifier: String = URLBlockFetcher.identifier, partialState: DownloadJob.Identifier? = nil)
    {
        self.partialState = partialState
        let (session, bridge) = SessionRegistry.shared.fetch(identifier)
        self.session = session
        self.bridge = bridge
    }

    /// Builds the background session of this identifier **immediately** — for the system's
    /// wake-up call (shell check H6, 2026-09-27).
    ///
    /// When iOS wakes the terminated app because a block is finished, it delivers the events only
    /// to a session with the same identifier. Until then it was built only by the next
    /// job: the straggler stayed with the system, `urlSessionDidFinishEvents` never
    /// came, and the stored completion handler was never called.
    public static func reconnect(identifier: String) {
        _ = SessionRegistry.shared.fetch(identifier)
    }

    /// For checks and for tools: an ordinary session.
    public init(session: URLSession, partialState: DownloadJob.Identifier? = nil) {
        self.partialState = partialState
        self.bridge = Bridge()
        self.session = session
    }

    public func fetch(
        _ area: ClosedRange<Int64>, from target: TargetAddress
    ) async throws
        -> BlockResponse
    {
        var request = URLRequest(url: target.address)
        // **First the host's headers, then `Range`** (2026-09-09). The order is
        // not a matter of taste: `Range` is ours, and a bridge that accidentally sent one
        // of its own must not overwrite it — otherwise the job would fetch
        // a different range than the one it wants to append.
        for (name, value) in target.headers {
            request.setValue(value, forHTTPHeaderField: name)
        }
        request.setValue(
            "bytes=\(area.lowerBound)-\(area.upperBound)", forHTTPHeaderField: "Range")

        let (data, http) = try await bridge.fetch(
            request, about: session, description: description(area))
        return BlockResponse(
            status: http.statusCode,
            data: data,
            totalLength: BlockResponse.totalLength(
                fromContentRange: http.value(forHTTPHeaderField: "Content-Range")),
            tag: http.value(forHTTPHeaderField: "ETag"),
            changed: http.value(forHTTPHeaderField: "Last-Modified"),
            acceptsRanges: http.value(forHTTPHeaderField: "Accept-Ranges"),
            checksum: BlockResponse.checksum(
                reprDigest: http.value(forHTTPHeaderField: "Repr-Digest"),
                digest: http.value(forHTTPHeaderField: "Digest")))
    }

    /// Fetch a **whole** address — an HLS playlist or a segment.
    ///
    /// **The same background session as for the blocks, and that is the point.** A
    /// download job over three hundred segments takes the same two hours as one over
    /// thirty blocks; running it through a foreground session would mean it stops when
    /// the phone is locked.
    ///
    /// **Without `Range` when no range is requested.** For a playlist there is nothing to
    /// limit, and a range header on a host that takes it seriously would deliver the
    /// first eight megabytes of a 511-byte file — that is, `416` instead of the playlist.
    /// A range only occurs with `#EXT-X-BYTERANGE`, where several segments lie in **one**
    /// file.
    ///
    /// **The status is checked here and not at the caller.** A `403` on a segment
    /// is, on the bridge, the normal case for an expired address; passing it through as data
    /// would mean writing an error page into the film file — and that would only be noticed
    /// on playback.
    public func fetchWhole(
        _ address: URL, area: ClosedRange<Int64>? = nil, headers: [String: String] = [:]
    ) async throws -> Data {
        var request = URLRequest(url: address)
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        if let area {
            request.setValue(
                "bytes=\(area.lowerBound)-\(area.upperBound)", forHTTPHeaderField: "Range")
        }

        let (data, http) = try await bridge.fetch(request, about: session, description: nil)
        guard (200...299).contains(http.statusCode) else {
            if DeliveryKind.busyStatuses.contains(http.statusCode) {
                throw LoadError.notLoadable(.accessBusy)
            }
            throw LoadError.network("Status \(http.statusCode) for \(address.lastPathComponent)")
        }
        return data
    }
}

/// The background sessions — **one per identifier, and it outlives its fetcher.**
///
/// **The finding of 2026-09-09, while re-reading ``URLBlockFetcher/init(identifier:partialState:)``:**
/// there a **new** `URLSession` was created per download job under the same fixed identifier
/// `dev.ms-solutions.cinelounge.downloads`, and the old one was never discarded. Apple answers
/// that with an `NSGenericException`: *"A background URLSession with identifier … already
/// exists!"* — so **not** an error one could catch, but a crash of the
/// program. It would already have been triggered by the second simultaneous download; or by a
/// restart of a job after `.failed` while the first was still standing.
///
/// **Why a table and not a single fixed session.** The identifier is a
/// parameter — checks and tools build their own —, and two identifiers are two
/// sessions. What must not exist is two sessions for **one** identifier.
///
/// **The bridge belongs to the session and not to the job.** It is the delegate, and
/// a session has exactly one; the task identifiers under which it keeps its waiters
/// are assigned by the same session and are therefore unique.
///
/// **Never closed, and that is intentional.** `invalidate` on a background session
/// would discard the system's running tasks — exactly what is meant to
/// outlive the app. A session without tasks costs nothing.
private final class SessionRegistry: @unchecked Sendable {

    static let shared = SessionRegistry()

    private let lock = NSLock()
    private var pending: [String: (session: URLSession, bridge: Bridge)] = [:]

    func fetch(_ identifier: String) -> (URLSession, Bridge) {
        lock.lock()
        defer { lock.unlock() }
        if let da = pending[identifier] { return (da.session, da.bridge) }

        let setup = URLSessionConfiguration.background(withIdentifier: identifier)
        // **Wait instead of fail.** Without this a background session gives up as soon as
        // there is no network right now — and a download store that aborts when entering an elevator
        // is no download store.
        setup.waitsForConnectivity = true
        // **Not left to the system when.** `isDiscretionary` sounds considerate and
        // is wrong here: whoever queues several things at once has a deadline. The consideration
        // lives with us — in ``NetworkRule`` and ``ConnectionScarcity`` —, and there it is
        // explainable.
        setup.isDiscretionary = false
        setup.sessionSendsLaunchEvents = true

        let bridge = Bridge()
        let session = URLSession(configuration: setup, delegate: bridge, delegateQueue: nil)
        pending[identifier] = (session, bridge)
        return (session, bridge)
    }
}

/// The bridge from the background session's delegates to `async`.
///
/// **A task is answered exactly once.** Both delegates can fire — one
/// with the file, the other with the end —, and a continuation resumed twice
/// crashes. That is why the entry is removed the first time and the
/// second call finds nothing.
private final class Bridge: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {

    private struct Waiting {
        let next: CheckedContinuation<(Data, HTTPURLResponse), any Error>
    }

    private let lock = NSLock()
    private var waiters: [Int: Waiting] = [:]

    func fetch(
        _ request: URLRequest, about session: URLSession, description: String?
    ) async throws
        -> (Data, HTTPURLResponse)
    {
        let task = session.downloadTask(with: request)
        // **The mapping travels with the task.** It thus survives the termination of the
        // app — a table in memory would not.
        task.taskDescription = description
        return try await withCheckedThrowingContinuation { next in
            lock.lock()
            waiters[task.taskIdentifier] = Waiting(next: next)
            lock.unlock()
            task.resume()
        }
    }

    private func extract(_ identifier: Int) -> Waiting? {
        lock.lock()
        defer { lock.unlock() }
        return waiters.removeValue(forKey: identifier)
    }

    func urlSession(
        _ session: URLSession, downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        guard let waiting = extract(downloadTask.taskIdentifier) else {
            // **Nobody is waiting any more — so the app was terminated in the meantime.** The block
            // is finished anyway; throwing it away would mean fetching it once more
            // at the next start.
            writeTo(location, loud: downloadTask.taskDescription)
            return
        }
        guard let http = downloadTask.response as? HTTPURLResponse else {
            waiting.next.resume(throwing: LoadError.network("no HTTP response"))
            return
        }
        do {
            // **Read immediately and not later.** The file at `location` belongs to the
            // system and is gone as soon as this call returns — that is the
            // classic error at this spot, and it looks like an empty block.
            let data = try Data(contentsOf: location)
            waiting.next.resume(returning: (data, http))
        } catch {
            // bewusst still: the error is passed on to the waiter and
            // recorded there. An entry here would be the same sentence one level deeper.
            waiting.next.resume(throwing: LoadError.network("\(error)"))
        }
    }

    /// Appends a block to its partial file without anyone waiting for it.
    ///
    /// **It is appended only if the state fits.** If the file already holds more than
    /// where this block begins, it was a straggler to something long since fetched; appending it
    /// would write the same bytes a second time and turn a finished film into a
    /// broken file. **The same latch as in ``BackgroundSession``** — since shell check
    /// H5 really the same: ``PartialWriter/append(_:from:)``, checked and
    /// written under one lock.
    private func writeTo(_ location: URL, loud description: String?) {
        guard let description else { return }
        let split = description.split(separator: "|")
        guard split.count == 2, let start = Int64(split[1]),
            let folder = try? Store.folder()
        else { return }

        let writer = PartialWriter(
            folder: folder, identifier: DownloadJob.Identifier(String(split[0])))
        guard writer.reached() == start, let data = try? Data(contentsOf: location),
            (try? writer.append(data, from: start)) == true
        else { return }
        Diagnose.step(
            .network, "Downloads: block from \(start) appended after waking (\(data.count) B)")
    }

    /// Everything delivered — **now the wake-up notification may be answered.**
    ///
    /// The system gives the woken app time up to this point; whoever reports earlier cuts off
    /// the time in which they could still write the bytes away.
    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        let identifier = session.configuration.identifier ?? URLBlockFetcher.identifier
        Task { @MainActor in await WakeNotice.done(identifier: identifier) }
    }

    func urlSession(
        _ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?
    ) {
        // Without an error the other delegate has already answered; then there is nothing
        // left to do here, and `extract` returns `nil`.
        guard let waiting = extract(task.taskIdentifier) else { return }
        waiting.next.resume(throwing: LoadError.network("\(error.map { "\($0)" } ?? "aborted")"))
    }
}
