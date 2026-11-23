import Core
import Diagnose
import Foundation

/// Whoever fetches a whole address — **a playlist or a segment, and a probe beforehand.**
///
/// **A contract of its own next to ``BlockFetcher`` and not instead of it.** A range fetcher
/// answers the question "give me bytes a to b of this one file"; here the question is
/// "give me this address" — a different one for each segment, three hundred times. That is
/// not the same thing with different numbers: the range is the exception for a segment
/// (`#EXT-X-BYTERANGE`) and the whole point for a block.
///
/// **Testable without a network, like everything here.** What ``StreamSession`` decides —
/// which tier, from which segment, when to give up — depends on answers and not on lines.
public protocol StreamSource: Sendable {

    /// The one probe from which ``DeliveryKind`` is derived.
    func probe(_ target: TargetAddress) async throws -> Probe

    /// Fetches a whole address; with `area` only a piece of it.
    func fetch(
        _ address: URL, area: ClosedRange<Int64>?, headers: [String: String]
    ) async throws -> Data

    /// Fetches a whole address **to disk** and returns how many bytes arrived.
    ///
    /// **For ``DeliveryKind/wholeFile`` — and the difference is working memory.**
    /// A segment is four seconds of film and fits in memory; a whole file is, as measured,
    /// 2.5 GB and does not fit there. A `Data(contentsOf:)` over it would not be a
    /// slow download but a crash.
    func fetchToFile(_ target: TargetAddress, after location: URL) async throws -> Int64
}

// MARK: - The partial state in segments

/// How many segments are on disk — **and why this is still not a second ledger.**
///
/// ``PartialWriter`` records the house rule: *"No second ledger for progress. How
/// far a download job has got is in the size of its partial file and nowhere
/// else."* The rule is right and not applicable here: from a file of
/// 412 337 129 bytes one cannot tell whether that is 143 or 144 segments — the
/// segments differ in size, and nobody wrote down their sizes.
///
/// **So this is not a second truth but a translation — and it carries its own
/// refutation.** Not only the segment number is stored, but also the byte count at
/// which it held. If that no longer matches the file, the note is wrong and **the file
/// is right**: it starts over from the beginning. That keeps the size of the partial file
/// the truth, exactly as the house rule demands; the note may only say what it is called.
///
/// **The case that forces this is a crash in the middle of appending.** Afterwards half a
/// segment lies in the file. Without the byte count the next run would continue at the
/// next segment and write behind half of one — a file that looks complete and falls
/// apart at one point. That is the same error that
/// ``PortalJob/mayResume(length:tag:changed:)`` stands against, just one level further.
public struct StreamProgress: Sendable {

    private struct Slip: Codable {
        /// Stored keys keep their original (German) names — renaming them would
        /// make data written by earlier versions unreadable (AP85 B4).
        private enum CodingKeys: String, CodingKey {
            case segments = "segmente"
            case bytes
            case trait = "merkmal"
        }

        let segments: Int
        let bytes: Int64
        /// How the playlist the number comes from can be recognised.
        ///
        /// **A host change delivers a different playlist with different segments**, and
        /// "segment 143" means something else there. What is compared is the number of segments
        /// and the total duration — both are in every playlist and can be had without a second
        /// request.
        let trait: String
    }

    public let location: URL

    /// **Next to the partial file and with its name.** That way everyone who finds the
    /// partial file finds it — and a folder in which one name ends in `.part` and one in
    /// `.part.state` explains itself at a glance.
    public init(beside part: URL) {
        self.location = part.appendingPathExtension("stand")
    }

    /// How many segments are on disk — `0` if the note does not match the file.
    public func stored(at bytes: Int64, trait: String) -> Int {
        guard bytes > 0, let data = try? Data(contentsOf: location),
            let watchlist = try? JSONDecoder().decode(Slip.self, from: data)
        else { return 0 }
        guard watchlist.bytes == bytes, watchlist.trait == trait else {
            Diagnose.step(
                .network,
                "Downloads: segment note does not match the partial file "
                    + "(\(watchlist.bytes) B / \(watchlist.trait) against \(bytes) B / \(trait)) "
                    + "— starting over")
            return 0
        }
        return watchlist.segments
    }

    public func memorize(segments: Int, bytes: Int64, trait: String) {
        let watchlist = Slip(segments: segments, bytes: bytes, trait: trait)
        guard let data = try? JSONEncoder().encode(watchlist) else { return }
        // bewusst still: **a note that is not written costs a restart
        // and not a broken file** — and the restart appears as a line in the ledger as soon as
        // it happens. Throwing here would mean aborting a running download over an
        // accessory.
        try? data.write(to: location, options: .atomic)
    }

    public func discard() {
        try? FileManager.default.removeItem(at: location)
    }
}

// MARK: - The session

/// Downloads an HLS delivery — **segment by segment into ONE file.**
///
/// **It takes the place of ``BackgroundSession`` and not a place next to it.** The switch
/// is in ``BackgroundSession/load(mbit:mayContinue:progress:)``; whoever downloads from
/// outside notices nothing of it. That is the condition for the product rule to hold —
/// *"what plays, downloads"* — without every call site knowing the difference.
///
/// **What it shares with the range session, it shares on purpose:** ``AddressProvider`` (a
/// portal address is valid for five minutes, here too), ``PartialWriter`` (appended and not
/// written at a position), `mayContinue` **before every piece** and falling back to the
/// next host. What it does not share is the block computation: there is no total length
/// to compute against, and therefore also no `Content-Range`, no `ETag` and
/// no `416`.
public actor StreamSession {

    private let source: any StreamSource
    private let addresses: any AddressProvider
    private let writer: PartialWriter
    private let progressNote: StreamProgress
    private let clock: @Sendable () -> Date

    private var job: PortalJob

    /// How often a segment may fail in a row.
    ///
    /// **The same three as for the blocks and for the same reason** (see
    /// ``BackgroundSession/attemptsPerBlock``): an interruption on a cell change is the
    /// normal case on the road; on the fourth in a row something else is the cause.
    public static let attemptsPerSegment = 3

    public init(
        job: PortalJob,
        source: any StreamSource,
        addresses: any AddressProvider,
        writer: PartialWriter,
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.job = job
        self.source = source
        self.addresses = addresses
        self.writer = writer
        self.progressNote = StreamProgress(beside: writer.part)
        self.clock = clock
    }

    public var partialState: PortalJob { job }

    /// What went through last, in Mbit/s — `nil` before a segment has gone through.
    public private(set) var measuredRate: Double?

    /// Fetches the playlist and then its segments.
    ///
    /// - Parameter hoechstens: The upper limit from the download job; `nil` means "the best".
    /// - Parameter darfWeiter: **Asked before every segment**, not once at the start — the
    ///   reasoning is given verbatim at ``BackgroundSession/load(mbit:mayContinue:progress:)``
    ///   and does not change because the pieces are now called segments.
    /// - Parameter fortschritt: **Bytes, extrapolated total size and the measured rate.**
    ///
    ///   **Why bytes and not segments go through this path** (2026-09-09): The callback
    ///   is the one that ``Transfer`` fills, and there `loaded`/`total` are in bytes —
    ///   `TransferText` writes "1.2 GB / 3.4 GB · done about 04:20" from them. Writing
    ///   segments into the same fields would give "143 bytes of 620 bytes" on the screen.
    ///   What is delivered is therefore what really lies on disk, and as the total size the
    ///   **extrapolation** from the segments so far. It is an estimate and gets more accurate
    ///   with every segment; a more honest number does not exist beforehand, because nobody
    ///   knows the total length of an HLS delivery.
    ///
    ///   **"Segment 143 of 620" is thus missing from the screen** and for now appears only
    ///   in the diagnostics — that would need two fields on ``Transfer`` and a line in
    ///   ``TransferText``, and both files are not part of this job.
    @discardableResult
    public func load(
        atMost: StreamQuality? = nil,
        mayContinue: @Sendable () async -> Bool = { true },
        progress: @Sendable (Int64, Int64?, Double?) async -> Void = { _, _, _ in }
    ) async throws -> URL {
        while true {
            do {
                return try await loadThrough(
                    atMost: atMost, mayContinue: mayContinue, progress: progress)
            } catch LoadError.notLoadable(let reason) {
                Diagnose.step(
                    .network,
                    "Downloads: \(job.shortForm) — playlist not loadable (\(reason)), "
                        + "looking for the next host")
                // **A rejection can also be down to the host and not to the title.** For
                // Animehub there are four hosts to choose from; if one delivers an encrypted
                // playlist, that says nothing about the other three. The fallback therefore
                // follows the same rule as for ``LoadError/notResumable(_:)``
                // — and when none is left, the rejection stays, with its reason.
                guard await addresses.fallBack() else { throw LoadError.notLoadable(reason) }
                restartFromStart()
            }
        }
    }

    /// **A host change is a restart.** Another host cuts differently — different
    /// segment boundaries, a different count. Continuing to write on the partial state of the
    /// previous one would produce a file that jumps in the middle.
    private func restartFromStart() {
        try? writer.discard()
        progressNote.discard()
        job.reached = 0
        job.segments = nil
        job.validUntil = nil
    }

    private func loadThrough(
        atMost: StreamQuality?,
        mayContinue: @Sendable () async -> Bool,
        progress: @Sendable (Int64, Int64?, Double?) async -> Void
    ) async throws -> URL {
        var (list, target) = try await fetchPlaylist(atMost: atMost)
        let trait = Self.trait(list)

        var written = writer.reached()
        var stored = progressNote.stored(at: written, trait: trait)

        // **A note that points past the end is not one.** It can come from a
        // longer version of the same episode; continuing to write would produce a file made of
        // two cuts.
        if stored > list.segments.count { stored = 0 }
        if stored == 0, written > 0 {
            try? writer.discard()
            written = 0
        }

        Diagnose.step(
            .network,
            "Downloads: \(job.shortForm) is a playlist — \(list.segments.count) segments, "
                + "\(Int(list.duration)) s, \(list.container), from segment \(stored)")

        // **The initialisation comes before the first segment and only there.** For fMP4 it
        // contains what the segments themselves no longer say — tracks, time base, codec. Without
        // it the 211 segments of one provider are bytes without meaning; written a second time it
        // would be a foreign body in the middle of the film.
        if stored == 0, let start = list.initialization {
            let data = try await fetchPiece(start, from: target)
            try append(data, from: written)
            written = writer.reached()
            Diagnose.step(.network, "Downloads: initialization written (\(data.count) B)")
        }

        var index = stored
        while index < list.segments.count {
            guard await mayContinue() else { throw LoadError.wasCancelled }

            let started = clock()
            let data: Data
            do {
                data = try await fetchPiece(list.segments[index], from: target)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                Diagnose.step(
                    .network,
                    "Downloads: segment \(index + 1)/\(list.segments.count) failed after "
                        + "\(Self.attemptsPerSegment) attempts — fetching the playlist anew")
                // **The second attempt fetches the playlist and not just the segment.** A
                // portal address is valid for five minutes; with two thousand seconds of film the
                // segment addresses of the first playlist have long expired, and a `403` on a
                // segment is then not a network error but an expired clock. That is exactly
                // what ``AddressProvider`` is for — only here the whole playlist is renewed,
                // because the expired addresses are in it.
                (list, target) = try await fetchPlaylist(atMost: atMost)
                guard Self.trait(list) == trait else {
                    // **A different playlist means: a different file.** The same decision as
                    // in ``PortalJob/mayResume(length:tag:changed:)``, only with
                    // segment count and playing time instead of `ETag` and length.
                    throw LoadError.differentFile
                }
                data = try await fetchPiece(list.segments[index], from: target)
            }

            recordRate(bytes: Int64(data.count), since: started)
            try append(data, from: written)

            let previous = written
            written = writer.reached()
            // **A segment that does not move the state ends the loop** — the same
            // latch as in ``BackgroundSession``, and for the same reason: a loop
            // whose progress depends on a number it reads must notice when the number
            // stands still. There exactly that cost ninety gigabytes.
            guard written > previous || data.isEmpty else {
                throw LoadError.network("The state does not move — \(written) bytes")
            }

            index += 1
            job.segments = index
            job.reached = written
            progressNote.memorize(segments: index, bytes: written, trait: trait)
            await progress(
                written,
                Self.extrapolated(bytes: written, done: index, total: list.segments.count),
                measuredRate)
        }

        // **What is on disk now is not yet playable in every case — and
        // that appears as a line in the ledger and not as a guess.**
        //
        // Roadmap E34, measured on 2026-09-06: *"Apple's engine plays MPEG-TS only inside
        // an HLS playlist, never raw"* — a raw transport stream ends there as
        // `AVFoundationErrorDomain -11850`. Concatenated fMP4 segments together with their
        // initialisation, by contrast, are an ordinary ISO file and play.
        //
        // **Repackaging is explicitly not this job** (E34 decided and built its
        // own route for that). What this run can contribute is the
        // information about which of the two places one is at — otherwise "finishes downloading, does
        // not play" would look like a download error, and the download was fine.
        if list.container == .transportStream {
            Diagnose.hint(
                .network,
                "Downloads: \(job.shortForm) is a raw transport stream under an "
                    + ".mp4 name — the system player does not take it (E34)")
        }

        try writer.complete()
        progressNote.discard()
        return writer.done
    }

    /// Appends a piece — **only where this run last saw the file**
    /// (check shell H5, ``PartialWriter/append(_:from:)``).
    ///
    /// If it stands elsewhere, someone else has written into it; continuing to write would
    /// produce a file made of two runs. The error leads into the next attempt, which reads
    /// its state anew from the note.
    private func append(_ data: Data, from start: Int64) throws {
        guard try writer.append(data, from: start) else {
            throw LoadError.network(
                "Partial file is at \(writer.reached()) instead of \(start) bytes")
        }
    }

    // MARK: - The parts

    /// The tier playlist to download against — **and the address against which its segments
    /// are to be resolved.**
    ///
    /// **Two requests and not one where a master playlist is present.** It contains no
    /// segments but references; only the second request brings the playlist that matters.
    /// Where there is no master playlist at all — measured at one provider — the second drops
    /// out by itself, without the caller having to know.
    private func fetchPlaylist(
        atMost: StreamQuality?
    ) async throws -> (StreamPlaylist.VariantList, TargetAddress) {
        let target = try await fetchAddress()
        job.validUntil = target.validUntil

        let text = try await read(target.address, headers: target.headers)
        switch try StreamPlaylist.read(text, from: target.address) {
        case .tier(let list):
            return (try verified(list), target)

        case .main(let slots):
            guard let chosen = StreamChoice.take(slots, atMost: atMost) else {
                throw LoadError.notLoadable(.emptyList)
            }
            Diagnose.step(
                .network,
                "Downloads: tier chosen — \(chosen.width ?? 0)x\(chosen.height ?? 0), "
                    + "\(chosen.bandwidth ?? 0) bit/s, of \(slots.count) tiers")

            // **The second base is the address of the tier playlist and not that of the title.**
            // The reasoning is at ``StreamPlaylist/read(_:from:)`` and it is the error that
            // would only show up at the second segment.
            let bottom = TargetAddress(
                chosen.address, validUntil: target.validUntil, headers: target.headers)
            let second = try await read(bottom.address, headers: bottom.headers)
            guard case .tier(let list) = try StreamPlaylist.read(second, from: bottom.address) else {
                // **Two master playlists in a row do not exist.** Whoever continued here
                // would build a loop over the network — and on the screen it would look like
                // a download that never starts.
                throw LoadError.notLoadable(.unknownFormat("nested master playlist"))
            }
            return (try verified(list), bottom)
        }
    }

    /// The three questions to a tier playlist — **each with its own rejection.**
    private func verified(_ list: StreamPlaylist.VariantList) throws -> StreamPlaylist.VariantList {
        if list.rightsManagement {
            throw LoadError.notLoadable(.rightsManagement)
        }
        if let method = list.encryption {
            throw LoadError.notLoadable(.encrypted(method))
        }
        // **Asked last, because a recording with rights management has two reasons and
        // the heavier one belongs first.** "Still running" sounds like waiting; with
        // FairPlay waiting never helps.
        guard list.isComplete else {
            throw LoadError.notLoadable(.liveWithoutEnd)
        }
        return list
    }

    private func read(_ address: URL, headers: [String: String]) async throws -> String {
        let data = try await source.fetch(address, area: nil, headers: headers)
        return String(decoding: data, as: UTF8.self)
    }

    /// One segment, with retry.
    ///
    /// **The segment is retried and not the playlist** — the same calculation as for the
    /// blocks: a dropout on a cell change must not cost twenty minutes of progress,
    /// it costs four seconds of film.
    private func fetchPiece(
        _ segment: StreamPlaylist.Segment, from target: TargetAddress
    ) async throws -> Data {
        var last: (any Error)?
        for attempt in 1...Self.attemptsPerSegment {
            try Task.checkCancellation()
            do {
                return try await source.fetch(
                    segment.address, area: segment.area, headers: target.headers)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                Diagnose.step(
                    .network,
                    "Downloads: segment attempt \(attempt)/\(Self.attemptsPerSegment) "
                        + "failed: \(error)")
                // **Here something really is swallowed, and that is why it is in the ledger** — the same
                // reasoning as in ``BackgroundSession``: the first two dropouts
                // would otherwise be seen by nobody, and they are the answer to the question that comes
                // after every slow download.
                last = error
                if attempt < Self.attemptsPerSegment {
                    // **`try` and not `try?`:** `Task.sleep` throws on cancellation, and a
                    // swallowed throw would mean sitting out the pause anyway.
                    try await Task.sleep(for: .seconds(Double(attempt)))
                }
            }
        }
        throw LoadError.network("\(last.map { "\($0)" } ?? "unbekannt")")
    }

    /// **The cancellation keeps its type** — word for word the same as in
    /// ``BackgroundSession`` and from the same finding of 2026-09-09: whoever wraps it in
    /// ``LoadError/network(_:)`` turns every deliberate pause into a red
    /// warning triangle, and the reason ("Paused — you are on cellular") is lost
    /// before anyone reads it.
    private func fetchAddress() async throws -> TargetAddress {
        do {
            return try await addresses.address()
        } catch is CancellationError {
            // bewusst still: see above — the cancellation is an intention and not a failure.
            throw CancellationError()
        } catch let caughtError as LoadError {
            Diagnose.error(
                .network,
                "Downloads: address not resolved: \(caughtError.localizedDescription) — \(job.shortForm)"
            )
            // **A named rejection stays named** (2026-09-09, the second evening of testing the portals).
            //
            // **The finding:** The screen said "Connection lost. Tap
            // Resume once the network is back." — with a perfectly good network. The bridge
            // had reported an exact reason (for Serieshub even the most exact one
            // there is: "After about 30 resolutions from the same IP the site stops
            // answering on /r?t= … only waiting or a different IP helps"),
            // ``PlaybackSourceAddress.address()`` had translated it correctly into
            // ``LoadError/notLoadable(_:)`` — and this place wrapped it again into
            // ``LoadError/network(_:)`` one level later.
            //
            // **What that costs:** The viewer waits for a better network, which was never the
            // problem, and presses "Resume" against a throttle that only gets
            // longer from it. The whole ``DeliveryKind`` table exists so that a
            // failure has a name; here the name was lost in the last metres.
            throw caughtError
        } catch {
            Diagnose.error(
                .network,
                "Downloads: address not resolved: \(error.localizedDescription) — \(job.shortForm)"
            )
            throw LoadError.network("\(error)")
        }
    }

    private func recordRate(bytes: Int64, since: Date) {
        let duration = clock().timeIntervalSince(since)
        // **Measured too briefly is not measured** — under a tenth of a second one measures the
        // connection setup. With segments of four seconds of film this applies more often than
        // with blocks of eight megabytes; the rate then simply stays the previous one.
        guard duration >= 0.1, bytes > 0 else { return }
        measuredRate = Double(bytes) * 8 / (duration * 1_000_000)
    }

    /// How a playlist is recognised again — **segment count and playing time.**
    ///
    /// **No checksum over the text.** The segment addresses carry tokens with an
    /// expiry time; the same title yields a different text five minutes later and
    /// the same file. A checksum over it would discard the entire partial state after every
    /// renewal — exactly when it is worth the most.
    static func trait(_ list: StreamPlaylist.VariantList) -> String {
        "\(list.segments.count)@\(Int(list.duration.rounded()))"
    }

    /// How large it is expected to become — **an extrapolation and not a number.**
    ///
    /// The total length of an HLS delivery is nowhere; what exists are the segments
    /// that are already on disk. From them times the count a size results that gets more accurate
    /// with every segment — and at the start is about as good as the estimate from the
    /// runtime that ``DownloadJob/estimatedSize`` already shows today.
    static func extrapolated(bytes: Int64, done: Int, total: Int) -> Int64? {
        guard done > 0, total > 0, bytes > 0 else { return nil }
        return Int64((Double(bytes) / Double(done) * Double(total)).rounded())
    }
}

// MARK: - The source that really goes over the network

/// The ``StreamSource`` over `URLSession`.
///
/// **Two sessions, and the difference is worth a measurement.**
///
/// * **The probe goes through an ordinary, ephemeral session.** It must be able to abort
///   after 512 bytes, and that is exactly what a background session cannot do: there the
///   system runs the task to the end, and for a host that ignores the range
///   (``DeliveryKind/wholeFile``) that would be the whole 2.5 GB — for a question that
///   half a kilobyte answers. `URLSession.bytes(for:)` reads as far as you read,
///   and aborts afterwards.
/// * **The segments go through the background session** of ``URLBlockFetcher``, because
///   that is exactly the point of the package: keep downloading while the app is not in the foreground.
///
/// **The probe follows redirects by itself, and that is the right measurement.**
/// ``DeliveryKind/redirect(_:)`` stays in the type anyway: the provider access answers,
/// as measured, with `302` to another machine, and if a chain ever breaks off, the
/// screen should say "the thing is elsewhere" and not "unknown format".
public struct URLStreamSource: StreamSource {

    private let block: URLBlockFetcher
    private let probeSession: URLSession

    public init(block: URLBlockFetcher, probeSession: URLSession? = nil) {
        self.block = block
        self.probeSession = probeSession ?? URLSession(configuration: .ephemeral)
    }

    public func probe(_ target: TargetAddress) async throws -> Probe {
        var request = URLRequest(url: target.address)
        for (name, value) in target.headers { request.setValue(value, forHTTPHeaderField: name) }
        // **First the host's headers, then `Range`** — the same order and
        // the same reasoning as in ``URLBlockFetcher/fetch(_:from:)``.
        request.setValue("bytes=0-\(Probe.bytes - 1)", forHTTPHeaderField: "Range")

        let (stream, reply) = try await probeSession.bytes(for: request)
        guard let http = reply as? HTTPURLResponse else {
            throw LoadError.network("no HTTP response to the probe")
        }

        var start = Data()
        for try await byte in stream {
            start.append(byte)
            if start.count >= Int(Probe.bytes) { break }
        }

        return Probe(
            status: http.statusCode,
            contentType: http.value(forHTTPHeaderField: "Content-Type"),
            acceptsRanges: http.value(forHTTPHeaderField: "Accept-Ranges"),
            contentRange: http.value(forHTTPHeaderField: "Content-Range"),
            length: BlockResponse.totalLength(
                fromContentRange: http.value(forHTTPHeaderField: "Content-Range"))
                ?? http.value(forHTTPHeaderField: "Content-Length").flatMap { Int64($0) },
            next: http.value(forHTTPHeaderField: "Location").flatMap {
                URL(string: $0, relativeTo: target.address)?.absoluteURL
            },
            start: start)
    }

    public func fetch(
        _ address: URL, area: ClosedRange<Int64>?, headers: [String: String]
    ) async throws -> Data {
        try await block.fetchWhole(address, area: area, headers: headers)
    }

    /// **Through the ephemeral session and explicitly not through the background session.**
    ///
    /// That looks like a step backwards and is not one: this path is taken exactly when
    /// the host does not answer ranges — that is, when an interruption costs the
    /// whole download, whichever session ran it. What the background session
    /// would add is the ability to resume **at the same position** after waking up,
    /// and that is exactly what does not exist here. In return this session can do what
    /// the other cannot: write to disk along the way instead of collecting 2.5 GB in memory.
    public func fetchToFile(_ target: TargetAddress, after location: URL) async throws -> Int64 {
        var request = URLRequest(url: target.address)
        for (name, value) in target.headers { request.setValue(value, forHTTPHeaderField: name) }

        let (between, reply) = try await probeSession.download(for: request)
        guard let http = reply as? HTTPURLResponse,
            (200...299).contains(http.statusCode)
        else {
            let status = (reply as? HTTPURLResponse)?.statusCode ?? 0
            if DeliveryKind.busyStatuses.contains(status) {
                throw LoadError.notLoadable(.accessBusy)
            }
            throw LoadError.network("Status \(status) in one piece")
        }

        // **Moved and not copied.** The file at `between` belongs to the system and
        // is gone as soon as this call returns — the same classic error as in
        // ``URLBlockFetcher``, described there as "looks like an empty block".
        if FileManager.default.fileExists(atPath: location.path) {
            try FileManager.default.removeItem(at: location)
        }
        try FileManager.default.moveItem(at: between, to: location)

        let values = try? FileManager.default.attributesOfItem(atPath: location.path)
        return (values?[.size] as? NSNumber)?.int64Value ?? 0
    }
}
