import AVFoundation
import Foundation
import UniformTypeIdentifiers

/// Serves AVPlayer for an Xtream movie file — **start and file header from the
/// ``HeadCache``, everything else 1:1 from the provider** (AP62, 2026-09-30).
///
/// **The one-connection rule** (iptvhost, proven on 2026-09-30: a second connection kicks out the
/// first): For each request from AVPlayer **at most one** request goes to the provider, and it
/// is cancelled as soon as AVPlayer cancels its own. The provider therefore never gets more
/// at the same time than without this loader — with the store clearly fewer, because the requests for
/// start and header no longer go out at all.
///
/// **Why a ResourceLoader and not a local server:** The hurdle "custom url not redirect"
/// (``Core/LocalMediaServer``) applies to addresses **in** an HLS playlist. Here the
/// MP4 file itself is the item; that is the path the ResourceLoader is built for.
///
/// **What the loader cannot change** (2026-09-30, measured): iptvhost delivers a flat ~0.52 MB/s
/// per connection — that is the file's bitrate, regardless of which range and which identifier.
/// From "ready" to the first picture AVPlayer needs ~2.5–3 MB of movie data, so ~5–6 s; that
/// comes from the provider, and no store changes that. The store saves the header.
final class HeadCacheLoader: NSObject, AVAssetResourceLoaderDelegate, URLSessionDataDelegate,
    @unchecked Sendable
{
    static let schema = "clkopf"

    /// The custom address under which AVPlayer asks — only the scheme is different.
    static func ownAddress(forItem url: URL) -> URL? {
        guard var split = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        split.scheme = schema + "-" + (split.scheme ?? "http")
        return split.url
    }

    static func realAddress(from url: URL) -> URL? {
        guard var split = URLComponents(url: url, resolvingAgainstBaseURL: false),
            let schema = split.scheme, schema.hasPrefix(Self.schema + "-")
        else { return nil }
        split.scheme = String(schema.dropFirst(Self.schema.count + 1))
        return split.url
    }

    /// **Everything runs on this queue:** the callbacks of the ResourceLoader (registered that way), those
    /// of the URLSession (via the `OperationQueue` underneath), ``finish()`` and the deferral.
    let queue = DispatchQueue(label: "cinelounge.kopfvorrat")
    private let target: URL
    private let key: String
    private let downloads: HeadCache
    private let identifier: String
    private let notify: @Sendable (String) -> Void
    private var entry: HeadCache.ContentEntryRecord?
    private var transcript: Transcript?
    private var size: Int64?
    private var contentType = UTType.mpeg4Movie.identifier
    private var finished = false
    private lazy var session: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        let jobQueue = OperationQueue()
        jobQueue.underlyingQueue = queue
        jobQueue.maxConcurrentOperationCount = 1
        return URLSession(configuration: configuration, delegate: self, delegateQueue: jobQueue)
    }()

    /// A request from AVPlayer together with its plan — or the size check (without a request).
    private final class Job {
        let request: AVAssetResourceLoadingRequest?
        var split: [RangeSource]
        /// The range that is supposed to come from the provider right now — `nil` if none is waiting.
        var waiting: Range<Int64>?
        /// The next position that AVPlayer needs from this provider part.
        var location: Int64 = 0
        /// The number in order of arrival — see ``StreamRule/demand(_:)``.
        let order: Int
        /// Overtaken by a younger request — see ``StreamRule/superseded(alter:newer:)``.
        var superseded = false
        init(_ request: AVAssetResourceLoadingRequest?, split: [RangeSource], order: Int) {
            self.request = request
            self.split = split
            self.order = order
        }
        /// AVPlayer's large read-ahead reader (megabytes, not "to the end") — as opposed to
        /// the 64 KB readers at the position it needs right now.
        var isPrefetcher: Bool {
            guard let data = request?.dataRequest else { return false }
            return !data.requestsAllDataToEndOfResource && data.requestedLength >= 1024 * 1024
        }
    }
    private var jobs: [Job] = []
    private var nextOrder = 0
    /// The waiting requests that the stream is based on — without the overtaken ones.
    private var waiters: [Job] { jobs.filter { $0.waiting != nil && !$0.superseded } }

    /// The inner state in one line — reported via ``report()`` as long as the clock is stopped
    /// (AP69). On 2026-10-11 exactly this information was missing from the report: 50 s of "opening" without a word
    /// about whether the stream was running and how far AVPlayer had been served.
    var statusReport: String {
        let waiting = jobs.compactMap { job -> String? in
            guard let area = job.waiting else { return nil }
            return "\(job.location)..<\(area.upperBound)"
                + (job.isPrefetcher ? " (prefetcher)" : "") + (job.superseded ? " (superseded)" : "")
        }
        let rate = streamRate.map { String(format: "%.2f MB/s", $0 / 1_000_000) } ?? "—"
        return "Loader: stream \(stream == nil ? "idle" : "running") at \(streamPosition), rate \(rate), "
            + "delivered up to \(deliveredUpTo), lead \(leadStart)+\(leadTime.count), "
            + "waiting \(waiting.isEmpty ? "—" : waiting.joined(separator: " · "))"
    }

    /// Up to where AVPlayer has been served — for the ``LineMeter`` (AP69). A short
    /// hop onto its own queue; the queue never waits for the main thread, so
    /// the `sync` is harmless here.
    func deliveredUpToNow() -> Int64 {
        queue.sync { deliveredUpTo }
    }

    /// Reports the ``statusReport`` by the same route as all other lines.
    func report() {
        queue.async { [weak self] in
            guard let self, !self.finished else { return }
            self.notify(self.statusReport)
        }
    }

    // MARK: - The single stream

    /// **Strictly one connection to the provider, and it reads continuously** (2026-09-30, learned on the real
    /// iptvhost and on the reproduction).
    ///
    /// Through the ResourceLoader AVPlayer asks for the movie data in large ranges, cancels them
    /// as soon as its own buffer is full (~27 MB), and later asks on 16 KB before the
    /// point of cancellation. Each request sent individually to the provider cost ~0.5 s. Hence:
    /// **one** continuous stream from the position that is needed, and a ``leadTime`` in
    /// memory from which every request is served whose position falls into it. A restart
    /// happens only on a jump; if the stream is far ahead of what was delivered, it rests (the
    /// rules: ``StreamRule``). A `suspend()` on the task does **not** rest it: CFNetwork
    /// then keeps reading into memory in the background without limit (2026-09-30, 128 MB in 6 s).
    private var stream: URLSessionDataTask?
    /// Which position the stream delivers next.
    private var streamPosition: Int64 = 0
    private var streamStarted = Date()
    /// From where and since when the stream delivers data — for the measured rate.
    private var streamStart: Int64 = 0
    private var streamFirstData: Date?
    private var changes = false
    private var streamAttempts = 0
    /// What the stream has delivered — gapless from ``leadStart``.
    private var leadTime = Data()
    private var leadStart: Int64 = 0
    private var leadEnd: Int64 { leadStart + Int64(leadTime.count) }
    /// Up to where AVPlayer has been served from the stream — that measures how far ahead the stream
    /// is and what may go at the front of the look-ahead buffer.
    private var deliveredUpTo: Int64 = 0
    /// When someone was last served — for ``StreamRule/readsPast(streamPosition:needs:catchUpWidth:idleFor:)``.
    private var deliveredSince = Date()
    /// Whether a connection setup is pending — see ``postpone()``; the number invalidates a
    /// running deferral if the connection was opened before.
    private var deferral = false
    private var deferralNumber = 0
    /// This long the loader waits before it opens a connection — and this long if only
    /// a read-ahead reader is waiting (see ``postpone()``).
    static let deferralDuration: DispatchTimeInterval = .milliseconds(60)
    static let prefetcherDeferralDuration: DispatchTimeInterval = .milliseconds(300)
    private var deferralForPrefetcher = false

    /// The measured rate of the running stream in bytes per second — `nil` as long as it is too
    /// young to say anything.
    private var streamRate: Double? {
        guard let since = streamFirstData else { return nil }
        let duration = Date().timeIntervalSince(since)
        let bytes = streamPosition - streamStart
        guard duration >= 0.5, bytes >= 64 * 1024 else { return nil }
        return Double(bytes) / duration
    }

    /// Whether the store matches the file that the provider delivers **now**. iptvhost delivers different
    /// versions under the same identifier (on 2026-09-30: 3.81 GB, later 4.63 GB) — a header
    /// of the wrong version would be a broken film. So first ask for one byte, then serve.
    private enum Check { case none, pending, isRunning, done }
    private var check = Check.none
    private var probeTask: URLSessionDataTask?

    init(target: URL, downloads: HeadCache, notify: @escaping @Sendable (String) -> Void) {
        self.target = target
        self.downloads = downloads
        self.key = HeadCache.key(forItem: target)
        self.identifier = target.lastPathComponent
        self.notify = notify
        super.init()
        entry = downloads.entry(key)
        if let entry {
            contentType = entry.contentType
            check = .pending
            notify(
                "File head in the cache: \(identifier), head \(entry.size - entry.tailStart) bytes — checking size"
            )
        } else {
            notify("File head not in the cache yet: \(identifier) — written along while playing")
        }
    }

    func finish() {
        queue.async {
            self.finished = true
            self.stream?.cancel()
            self.stream = nil
            self.probeTask?.cancel()
            self.probeTask = nil
            self.check = .done
            self.jobs.removeAll()
            self.saveRecording()
            self.session.invalidateAndCancel()
        }
    }

    // MARK: - AVAssetResourceLoaderDelegate

    func resourceLoader(
        _ resourceLoader: AVAssetResourceLoader,
        shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest
    ) -> Bool {
        guard !finished else { return false }
        nextOrder += 1
        let job = Job(loadingRequest, split: [], order: nextOrder)
        jobs.append(job)
        if check == .pending || check == .isRunning {
            // Size first — until then every request waits, so that no byte of the wrong
            // version goes out.
            plane()
            return true
        }
        setUp(job)
        serve(job)
        markSuperseded(hinter: job)
        plane()
        return true
    }

    /// Read-ahead readers that wait far from the new request were left behind by AVPlayer at the jump
    /// — see ``StreamRule/superseded(alter:newer:)``.
    private func markSuperseded(hinter fresh: Job) {
        guard fresh.waiting != nil else { return }
        for old in jobs
        where old !== fresh && old.waiting != nil && old.isPrefetcher && !old.superseded
            && StreamRule.superseded(alter: old.location, newer: fresh.location)
        {
            old.superseded = true
            notify(
                "File head loader: prefetcher at \(old.location) superseded — new request at \(fresh.location)"
            )
        }
    }

    func resourceLoader(
        _ resourceLoader: AVAssetResourceLoader, didCancel loadingRequest: AVAssetResourceLoadingRequest
    ) {
        guard let job = jobs.first(where: { $0.request === loadingRequest }) else { return }
        jobs.removeAll { $0 === job }
        plane()
    }

    // MARK: - The flow

    /// Fixes the plan of a request — now that size and store are settled.
    private func setUp(_ job: Job) {
        guard let request = job.request else { return }
        if let info = request.contentInformationRequest, let size { fill(info, size: size) }
        guard let data = request.dataRequest else {
            if size == nil { job.split = [.provider(0..<2)] }
            return
        }
        let from = data.currentOffset
        let until =
            data.requestsAllDataToEndOfResource
            ? (size ?? Int64.max) : data.requestedOffset + Int64(data.requestedLength)
        if let entry {
            job.split = RangePlan.plan(from: from, until: min(until, entry.size), entry: entry)
        } else {
            job.split = [.provider(from..<until)]
        }
    }

    /// Works through the parts in order: store immediately, at the provider part it waits.
    private func serve(_ job: Job) {
        guard let request = job.request, job.waiting == nil else { return }
        while let part = job.split.first {
            switch part {
            case .cachedStart(let b):
                guard let start = downloads.start(key), b.upperBound <= start.count else {
                    return discardCache(job)
                }
                request.dataRequest?.respond(with: start.subdata(in: Int(b.lowerBound)..<Int(b.upperBound)))
                job.split.removeFirst()
            case .cachedTail(let b):
                guard let tail = downloads.tail(key), let entry else {
                    return discardCache(job)
                }
                let from = Int(b.lowerBound - entry.tailStart)
                let until = Int(b.upperBound - entry.tailStart)
                guard from >= 0, until <= tail.count else { return discardCache(job) }
                request.dataRequest?.respond(with: tail.subdata(in: from..<until))
                job.split.removeFirst()
            case .provider(let b):
                job.waiting = b
                job.location = b.lowerBound
                job.split.removeFirst()
                fromLead(job)
                return
            }
        }
        request.finishLoading()
        jobs.removeAll { $0 === job }
    }

    /// Serves a waiting request from the look-ahead buffer as far as it reaches.
    private func fromLead(_ job: Job) {
        guard let area = job.waiting, job.location >= leadStart, job.location < leadEnd
        else { return }
        let until = min(area.upperBound, leadEnd)
        let from = Int(job.location - leadStart)
        job.request?.dataRequest?.respond(
            with: leadTime.subdata(
                in: leadTime.startIndex + from..<leadTime.startIndex + Int(until - leadStart)))
        job.location = until
        if until > deliveredUpTo {
            deliveredUpTo = until
            deliveredSince = Date()
        }
        if until >= area.upperBound || until >= (size ?? Int64.max) {
            job.waiting = nil
            serve(job)
        }
    }

    /// The position that must come from the provider next — **the foremost reader, otherwise
    /// the youngest read-ahead reader** (``StreamRule/demand(_:)``).
    ///
    /// AVPlayer keeps two requests open at once: a large read-ahead reader and 64 KB readers
    /// at the position it needs right now — on 2026-09-30 on iptvhost 2.8 MB apart (the
    /// tracks are interleaved that way). If the stream followed the newest, it jumped to the rear one,
    /// and the front one lay behind the look-ahead buffer and was never served again: no picture in 40 s.
    /// "The foremost of all" held until 2026-10-11 — until a jump forward made the old
    /// read-ahead reader the foremost (diagnostic F-048).
    private func demand() -> Int64? {
        for job in jobs where job.waiting != nil { fromLead(job) }
        return StreamRule.demand(
            waiters.map {
                .init(location: $0.location, prefetcher: $0.isPrefetcher, order: $0.order)
            })
    }

    /// Decides about the one stream: check, let it run, restart or rest.
    private func plane() {
        guard !finished, !changes, probeTask == nil else { return }
        if check == .pending {
            check = .isRunning
            var request = URLRequest(url: target)
            request.setValue("bytes=0-0", forHTTPHeaderField: "Range")
            // One byte — whoever takes longer for it is dead; then continue without the store.
            request.timeoutInterval = 10
            request.setValue(Self.identifier, forHTTPHeaderField: "User-Agent")
            streamStarted = Date()
            let probe = session.dataTask(with: request)
            probeTask = probe
            probe.resume()
            return
        }
        guard check != .isRunning else { return }
        guard let needs = demand() else {
            return  // nobody is waiting — the stream may be ahead until the look-ahead buffer is full
        }
        if stream != nil {
            // Will the running stream reach the position soon? Then wait.
            let catchUpWidth = StreamRule.catchUpWidth(
                rate: streamRate,
                inTail: StreamRule.inTail(streamPosition: streamPosition, needs: needs, size: size))
            if needs >= leadStart, needs <= streamPosition + catchUpWidth { return }
            changes = true
            stream?.cancel()
            return
        }
        postpone()
    }

    /// **Wait 60 ms before every connection** (2026-09-30, seen on the reproduction): After
    /// the start AVPlayer immediately asks "to the end" and cancels it as soon as it has
    /// seen the `mdat` box — at startup from the store within a millisecond after the start.
    /// Without the deferral a connection to the provider went out for exactly that, and was
    /// cancelled again right away; on a one-connection account with a burst throttle every
    /// avoidable connection is one too many. Whoever is still waiting after the deferral gets it.
    private func postpone() {
        // As soon as AVPlayer has the header, first comes the large read-ahead reader, ~230 ms later the
        // 64 KB reader at the position that is really needed first (2026-09-30, iptvhost: 2.8 MB
        // before it). A read-ahead reader alone does not yet justify a connection: wait up to 300 ms
        // for the reader, then open once at the right position instead of twice —
        // and as soon as it is there, immediately.
        let onlyPrefetchers = jobs.filter { $0.waiting != nil }.allSatisfy(\.isPrefetcher)
        if deferral, deferralForPrefetcher, !onlyPrefetchers {
            deferralNumber += 1
            return openAfterDeferral()
        }
        guard !deferral else { return }
        deferral = true
        deferralForPrefetcher = onlyPrefetchers
        deferralNumber += 1
        let nr = deferralNumber
        let duration = onlyPrefetchers ? Self.prefetcherDeferralDuration : Self.deferralDuration
        queue.asyncAfter(deadline: .now() + duration) { [weak self] in
            guard let self, self.deferralNumber == nr else { return }
            self.openAfterDeferral()
        }
    }

    private func openAfterDeferral() {
        deferral = false
        guard !finished, !changes, stream == nil, probeTask == nil, check != .isRunning,
            let needs = demand()
        else { return }
        open(from: needs)
    }

    private func open(from location: Int64) {
        if location != leadEnd {
            // What was delivered before the jump no longer counts for this look-ahead buffer — otherwise
            // ``StreamRule/shortenTo`` would trim behind its end.
            leadTime = Data()
            leadStart = location
            deliveredUpTo = location
        }
        deliveredSince = Date()
        var request = URLRequest(url: target)
        request.setValue("bytes=\(location)-", forHTTPHeaderField: "Range")
        request.setValue(Self.identifier, forHTTPHeaderField: "User-Agent")
        streamPosition = location
        streamStart = location
        streamFirstData = nil
        streamStarted = Date()
        let fresh = session.dataTask(with: request)
        stream = fresh
        fresh.resume()
    }

    /// The store is gone or does not match — then continue as without it.
    private func discardCache(_ job: Job) {
        notify("File head cache unusable, discarded: \(identifier)")
        forgetCache()
        let rest = job.split.map(\.area)
        guard let from = rest.first?.lowerBound, let until = rest.last?.upperBound else {
            job.request?.finishLoading()
            jobs.removeAll { $0 === job }
            return
        }
        job.split = [.provider(from..<until)]
        serve(job)
    }

    private func forgetCache() {
        downloads.forget(key)
        entry = nil
        // Without a store, recording resumes — otherwise the title would stay without one forever.
        if transcript == nil, let size { transcript = Transcript(size: size) }
    }

    /// The identifier the provider speaks — the same as in the live repackager.
    static let identifier = "VLC/3.0.18 LibVLC/3.0.18"

    private func fill(_ info: AVAssetResourceLoadingContentInformationRequest, size: Int64) {
        info.contentType = contentType
        info.contentLength = size
        info.isByteRangeAccessSupported = true
    }

    // MARK: - URLSessionDataDelegate

    func urlSession(
        _ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        let isProbe = dataTask === probeTask
        guard isProbe || dataTask === stream else { return completionHandler(.cancel) }
        let expected: Int64 = isProbe ? 0 : streamPosition
        let http = response as? HTTPURLResponse
        let start = http.flatMap(Self.rangeStart(from:))
        let ms = Int(Date().timeIntervalSince(streamStarted) * 1000)
        notify(
            "File head loader: from \(expected) → \(http?.statusCode ?? -1), "
                + "range \(http?.value(forHTTPHeaderField: "Content-Range") ?? "—"), \(ms) ms")
        // **Only a response that begins exactly at the requested position.** A 200 with the
        // whole file would mean: bytes from 0 at the position AVPlayer expects — data salad.
        // From position 0, though, the whole file is exactly what was wanted.
        let matches = http.map {
            $0.statusCode == 206 && start == expected || $0.statusCode == 200 && expected == 0
        }
        guard let http, matches == true, let total = Self.totalSize(from: http)
        else {
            notify("File head loader: response does not match the request — aborted")
            if isProbe {
                finishCheck(matches: false)
            } else {
                for job in jobs where job.waiting != nil {
                    job.request?.finishLoading(with: URLError(.badServerResponse))
                }
                jobs.removeAll { $0.waiting != nil }
            }
            return completionHandler(.cancel)
        }
        if isProbe {
            finishCheck(matches: total == entry?.size, total: total)
        } else if let known = size, known != total {
            // Different version under the same identifier: its bytes at the old positions would be
            // data salad. Better an error — on the next start the size probe heals the store.
            notify(
                "File head loader: size changed in the middle of playback (\(known) → \(total)) — aborted")
            for job in jobs where job.waiting != nil {
                job.request?.finishLoading(with: URLError(.badServerResponse))
            }
            jobs.removeAll { $0.waiting != nil }
            return completionHandler(.cancel)
        }
        let newlyKnown = size == nil
        size = total
        if transcript == nil, entry == nil { transcript = Transcript(size: total) }
        if let mime = http.mimeType, let ut = UTType(mimeType: mime), ut.conforms(to: .movie) {
            contentType = ut.identifier
        }
        if newlyKnown {
            // Whoever was waiting for the information gets it now — and their plan.
            for job in jobs {
                if let info = job.request?.contentInformationRequest { fill(info, size: total) }
            }
        }
        // The probe has its information — it should load no more, even if the provider sends the whole file
        // on `bytes=0-0`. As long as it runs, every stream waits.
        completionHandler(isProbe ? .cancel : .allow)
    }

    /// After the one byte: take the store or discard it — and set up the waiting requests.
    private func finishCheck(matches: Bool, total: Int64? = nil, failed: Bool = false) {
        if matches {
            notify("File head cache matches the file at the provider")
        } else if failed {
            // Without a response nothing is known about the version: this time without the store, but it
            // stays on disk for the next start.
            notify("File head cache cannot be checked — without it this time")
            entry = nil
        } else {
            notify(
                "File head cache does not match (different version, \(total.map(String.init) ?? "?") bytes) — discarded, written anew"
            )
            forgetCache()
        }
        size = total ?? size
        check = .done
        for job in jobs where job.split.isEmpty && job.waiting == nil {
            setUp(job)
            serve(job)
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard dataTask === stream, !changes else { return }
        if streamFirstData == nil { streamFirstData = Date() }
        if entry == nil, transcript != nil {
            transcript?.take(data, at: streamPosition)
            if transcript?.headAtFront == true {
                notify("File head is at the front: \(identifier) — nothing to remember")
                transcript = nil
            }
        }
        leadTime.append(data)
        streamPosition += Int64(data.count)
        streamAttempts = 0
        for job in jobs where job.waiting != nil { fromLead(job) }
        // Trim at the front what nobody needs any more.
        let earliestWaiting = waiters.map(\.location).min()
        let newStart = StreamRule.shortenTo(
            leadStart: leadStart, leadEnd: leadEnd, deliveredUpTo: deliveredUpTo,
            earliestWaiting: earliestWaiting, tailZoneHint: size.map { $0 - HeadCache.tailZone })
        if newStart > leadStart {
            leadTime.removeFirst(Int(newStart - leadStart))
            leadStart = newStart
        }
        // Far enough ahead and nobody waiting: rest, instead of loading the whole film.
        if StreamRule.mayRest(
            streamPosition: streamPosition, deliveredUpTo: deliveredUpTo, waiting: earliestWaiting != nil)
        {
            changes = true
            stream?.cancel()
        } else if let needs = demand() {
            if needs < leadStart {
                // The stream never reaches a request behind the look-ahead buffer — restart, instead of
                // waiting for the next request from AVPlayer, which then no longer comes.
                plane()
            } else {
                let still = Date().timeIntervalSince(deliveredSince)
                if StreamRule.readsPast(
                    streamPosition: streamPosition, needs: needs, rate: streamRate, idleFor: still)
                {
                    notify(
                        String(
                            format:
                                "File head loader: stream has been reading past everyone for %.1f s (at %lld, needed %lld) — restarting there",
                            still, streamPosition, needs))
                    plane()
                }
            }
        }
        // Only at the end of the file can the tail be complete — and only there is a look worthwhile.
        if let size, streamPosition >= size { saveRecording() }
    }

    /// **The redirect keeps the range** — iptvhost redirects every request to an edge server;
    /// if `Range` were lost in the process, the file would come from byte 0.
    func urlSession(
        _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void
    ) {
        var next = request
        for header in ["Range", "User-Agent"] {
            if let value = task.originalRequest?.value(forHTTPHeaderField: header) {
                next.setValue(value, forHTTPHeaderField: header)
            }
        }
        completionHandler(next)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if task === probeTask {
            probeTask = nil
            if check == .isRunning { finishCheck(matches: false, failed: true) }
            plane()
            return
        }
        guard task === stream else { return }
        stream = nil
        let hadSwitched = changes
        changes = false
        defer { plane() }
        if hadSwitched { return }  // restarted or rested
        guard let error, (error as? URLError)?.code != .cancelled else {
            saveRecording()
            // The provider closed early without a sound: restart, but not endlessly.
            if error == nil, jobs.contains(where: { $0.waiting != nil }) {
                streamAttempts += 1
                if streamAttempts > 3 {
                    notify("File head loader: stream keeps ending at \(streamPosition) — gave up")
                    for job in jobs where job.waiting != nil {
                        job.request?.finishLoading(with: URLError(.networkConnectionLost))
                    }
                    jobs.removeAll { $0.waiting != nil }
                }
            }
            return
        }
        // Disconnect: restart at the same position, at most three times in a row.
        streamAttempts += 1
        if streamAttempts <= 3 {
            notify(
                "File head loader: stream broke off at \(streamPosition) — new attempt \(streamAttempts)")
            return
        }
        notify("File head loader: stream broke off at \(streamPosition) — \(error.localizedDescription)")
        for job in jobs where job.waiting != nil { job.request?.finishLoading(with: error) }
        jobs.removeAll { $0.waiting != nil }
    }

    /// Start and tail completely there? Then into the store — once. If the end of the file is through and
    /// there is no `moov` in it, the header lies at the front: nothing to store, and the recording can go.
    private func saveRecording() {
        guard entry == nil, let transcript else { return }
        guard let done = transcript.done() else {
            if let size, streamPosition >= size, transcript.reachesToEnd {
                notify("File head is not at the end: \(identifier) — nothing to remember")
                self.transcript = nil
            }
            return
        }
        downloads.save(
            key, size: transcript.size, contentType: contentType, start: done.start,
            tailStart: done.tailStart, tail: done.tail)
        self.transcript = nil
        notify("File head put into the cache: \(identifier), \(done.tail.count) bytes")
    }

    /// The first position from `Content-Range: bytes 100-199/1000`.
    static func rangeStart(from http: HTTPURLResponse) -> Int64? {
        guard let area = http.value(forHTTPHeaderField: "Content-Range"),
            let empty = area.firstIndex(of: " "), let pipe = area.firstIndex(of: "-")
        else { return nil }
        return Int64(area[area.index(after: empty)..<pipe])
    }

    static func totalSize(from http: HTTPURLResponse) -> Int64? {
        if let area = http.value(forHTTPHeaderField: "Content-Range"),
            let slash = area.lastIndex(of: "/"),
            let number = Int64(area[area.index(after: slash)...].trimmingCharacters(in: .whitespaces))
        {
            return number
        }
        return http.statusCode == 200 && http.expectedContentLength > 0 ? http.expectedContentLength : nil
    }
}
