import Core
import CryptoKit
import Diagnose
import Foundation

/// Loading while the app is not in front — **block by block.**
///
/// **The background `URLSession` needs NO entry in `UIBackgroundModes`.** That is the most
/// common mistake at this point: The background modes apply to things the app does itself
/// (audio, location, voice call); a download is run by the system, and it wakes the app
/// when it is finished. An entry there would be not only superfluous but a statement on the
/// App Store review form that has to be justified.
///
/// **Why block by block and not in one go.** A resolved portal address applies for five
/// minutes; a task that runs longer dies in the middle — and the app cannot re-resolve
/// while it sleeps. A block is therefore sized to a good three and a half minutes
/// (``Resumability/blockSize(mbit:span:)``). Between two blocks the app is awake,
/// because the system wakes it for the finished task — **there** it resolves, never in the
/// middle.
///
/// **What is not here is a line.** ``BlockFetcher`` and ``AddressProvider`` are contracts; the
/// session decides and calculates, and both can be tested without a network. That is the
/// same cut as in the rest of the package and for the same reason: What is difficult about
/// a download is the decisions.
public actor BackgroundSession {

    private let fetcher: any BlockFetcher
    private let addresses: any AddressProvider
    private let writer: PartialWriter
    private let clock: @Sendable () -> Date

    /// Who probes and fetches whole addresses — **`nil` means: only the range path.**
    ///
    /// **The fallback is deliberate and not convenience.** A check that brings its own
    /// ``BlockFetcher`` wants to test the range path and not a probe over a line that does not
    /// exist. Whoever passes the real ``URLBlockFetcher`` instead gets the delivery-type table
    /// without a single additional line at the call site — and that was the condition for HLS
    /// titles to load without ``DownloadsManager`` knowing about it.
    private let stream: (any StreamSource)?

    /// The upper limit for the tier choice of an HLS master playlist.
    private let tier: StreamQuality?

    /// What was last known about the file — grows with the first block.
    private var jobState: PortalJob

    /// How many blocks in a row may fail before giving up.
    ///
    /// **Three, and the reason is the cell and not the server.** An interruption at the change
    /// of radio cell is the normal case on the go, not an error; at the fourth one in a row
    /// something else is the cause, and trying on costs battery instead of progress.
    public static let attemptsPerBlock = 3

    public init(
        job: PortalJob,
        fetcher: any BlockFetcher,
        addresses: any AddressProvider,
        writer: PartialWriter,
        stream: (any StreamSource)? = nil,
        tier: StreamQuality? = nil,
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.jobState = job
        self.fetcher = fetcher
        self.addresses = addresses
        self.writer = writer
        // **The real fetcher brings its own stream source.** It hangs on the same background
        // session as its blocks — two sessions under one identifier are a program abort, and the
        // reasoning for that is at ``SessionRegistry``.
        self.stream = stream ?? (fetcher as? URLBlockFetcher).map { URLStreamSource(block: $0) }
        self.tier = tier
        self.clock = clock
        // **The state comes from the file and not from the job that was handed over.** After a
        // crash the stored download job is the older of the two truths — writing went on, noting
        // did not.
        let isPresent = writer.reached()

        // **A partial state about which nothing is known is thrown away BEFORE the first
        // request.** It comes from a run that was interrupted before the first headers were
        // stored; whether the same file lies at the other end can never be determined from it
        // again. Leaving it would cost a whole block that is fetched and immediately discarded —
        // and the check of 2026-09-08 showed exactly that.
        let nothingRecorded =
            job.length == nil && job.tag == nil
            && job.changed == nil
        if isPresent > 0, nothingRecorded {
            try? writer.discard()
            self.jobState.reached = 0
        } else {
            self.jobState.reached = isPresent
        }
    }

    public var job: PortalJob { jobState }

    /// Fetches blocks until the file is complete.
    ///
    /// - Parameter mbit: The measured rate, for the block size. `nil` means "unmeasured",
    ///   and then it starts small instead of guessing.
    /// - Parameter darfWeiter: Asked **before every block**. ``NetworkRule``
    ///   and ``ConnectionScarcity`` hook in here — before every block and not once at the
    ///   start: A phone leaves Wi-Fi in the middle of a download job, and an Apple TV starts
    ///   playing in the middle of a download job.
    /// - Parameter fortschritt: After every block — state, total size and the **measured
    ///   rate** in Mbit/s.
    ///
    ///   **Measured and not guessed.** The rate comes from the block that has just gone
    ///   through: bytes per second, over the path in question. A probe on the side
    ///   (`BandwidthMemory`) measures a different stretch at a different time — and the
    ///   downloads need the number for a sentence that names a time of day. `nil` as long as no
    ///   block is through: Before the first one nobody knows.
    @discardableResult
    public func load(
        mbit: Double?,
        mayContinue: @Sendable () async -> Bool = { true },
        progress: @Sendable (Int64, Int64?, Double?) async -> Void = { _, _, _ in }
    ) async throws -> URL {
        while true {
            do {
                return try await byDeliveryKind(
                    mbit: mbit, mayContinue: mayContinue, progress: progress)
            } catch LoadError.notResumable(let reason) {
                Diagnose.step(
                    .network,
                    "Downloads: \(jobState.key) — host does not support it (\(reason)), "
                        + "looking for the next one")
                // **This is where the promise from ``DownloadChoice`` is redeemed** (2026-09-09): "If the chosen
                // host does not carry, the job takes the next one — without asking."
                // Until then only the throwing was built, and **no caller in the project caught
                // it**. At Animehub four hosts are on offer and three carry; whoever gives up at the
                // first one fails in three of four cases on a choice that
                // nobody made.
                //
                // **The line comes before the reasoning and not after it.** The check step
                // "Silent errors" reads eight lines from the `catch`; a record placed after
                // a long paragraph would look like silence to it — and next time
                // one would believe the checker instead of the file.
                guard await addresses.fallBack() else {
                    throw LoadError.notResumable(reason)
                }
                restartFromStart()
            }
        }
    }

    /// **A host change is a fresh start and not a resume.**
    ///
    /// A different host delivers a different encode — different length, different brand,
    /// different bytes. Continuing to write on the partial state of the previous one would give
    /// a file that looks complete and falls apart in the middle; exactly that is what
    /// ``PortalJob/mayResume(length:tag:changed:)`` otherwise guards against. The
    /// partial state is therefore thrown away **before** the first block of the new host
    /// arrives.
    private func restartFromStart() {
        try? writer.discard()
        jobState.reached = 0
        jobState.length = nil
        jobState.tag = nil
        jobState.changed = nil
        jobState.validUntil = nil
    }

    // MARK: - The switch

    /// **What was delivered decides the path — and here and at no second place.**
    ///
    /// **The finding of 2026-09-09, measured at the bridge:** A Serieshub title arrives as
    /// a file (`206`, `Accept-Ranges: bytes`, 561 149 891 bytes), an flatone title as an
    /// HLS playlist (`application/vnd.apple.mpegurl`, 53 127 bytes of table of contents, the
    /// video lies in 400 segments behind it). Until then both ran into the same block loop, and
    /// the playlist ended on screen as "Connection lost" — for 53 KB of text that had arrived
    /// flawlessly.
    ///
    /// **Why the switch is here and not at the call site:** This session is what
    /// ``DownloadsManager`` starts, and it is the last place at which nobody has yet claimed
    /// anything about the format. A switch one level higher would mean that every future call
    /// site builds it along — exactly the design against which the product question stood
    /// (*"so that it does not show up on every single attempt"*).
    ///
    /// **And why it hangs on behavior and not on the portal name:** because the same reader
    /// delivers both. The full reasoning including measured values is at ``DeliveryKind``; it
    /// belongs where the table is, and not in every switch that uses it.
    ///
    /// **Without ``stream`` everything stays as before.** Then nothing is probed, it is
    /// loaded — that is the path that the checks with their own ``BlockFetcher`` take, and it
    /// should not change through this file.
    private func byDeliveryKind(
        mbit: Double?,
        mayContinue: @Sendable () async -> Bool,
        progress: @Sendable (Int64, Int64?, Double?) async -> Void
    ) async throws -> URL {
        guard let stream else {
            return try await loadThrough(
                mbit: mbit, mayContinue: mayContinue, progress: progress)
        }

        var target = try await fetchAddress()
        jobState.validUntil = target.validUntil
        var kind = try await probe(target)

        // **A redirect is followed by hand exactly once.** `URLSession` otherwise follows it
        // itself, and then there is none here at all; if one arrives anyway, the chain is
        // interrupted (measured at the provider account: `302` to another machine with a
        // character token). Once and not in a loop: Two signposts in a row are, at this point, no
        // longer distinguishable from a redirect loop, and a redirect loop would look on screen
        // like a download that never starts.
        if case .redirect(let behind) = kind {
            guard let behind else { throw LoadError.notLoadable(.unknownFormat("302")) }
            Diagnose.step(.network, "Downloads: \(jobState.shortForm) — redirect, following once")
            target = TargetAddress(
                behind, validUntil: target.validUntil, headers: target.headers)
            kind = try await probe(target)
        }

        Diagnose.step(.network, "Downloads: \(jobState.shortForm) delivers \(kind)")

        switch kind {
        case .fileInPieces:
            return try await loadThrough(
                mbit: mbit, mayContinue: mayContinue, progress: progress)

        case .hls:
            let session = StreamSession(
                job: jobState, source: stream, addresses: addresses, writer: writer,
                clock: clock)
            let done = try await session.load(
                atMost: tier, mayContinue: mayContinue, progress: progress)
            jobState = await session.partialState
            return done

        case .wholeFile:
            return try await loadWhole(
                target, mayContinue: mayContinue, progress: progress)

        // **A redirect behind a redirect.** It has already had its one attempt above; a second
        // would be the redirect loop.
        case .redirect:
            throw LoadError.notLoadable(.unknownFormat("redirect to redirect"))

        case .dash, .endlessStream, .accessBusy, .unclear:
            // **The refusal is certain, but perhaps not for this host.** Hence the same path as with
            // ``LoadError/notResumable(_:)``: first fall back, and when none is left, the refusal
            // with its reason. The exception is the busy account — no other host helps there, because
            // the limit hangs on the **account**; chasing it through four hosts would cost four failed
            // attempts and answer nothing.
            guard let reason = kind.rejection else {
                throw LoadError.network("Delivery kind without a path: \(kind)")
            }
            throw LoadError.notLoadable(reason)
        }
    }

    /// The probe — **half a kilobyte that decides the whole download job.**
    ///
    /// The same calculation as at ``Resumability``: A request before the first byte costs
    /// nothing and answers the question that one otherwise asks after two hours.
    private func probe(_ target: TargetAddress) async throws -> DeliveryKind {
        guard let stream else { return .fileInPieces }
        do {
            return DeliveryKind.from(try await stream.probe(target))
        } catch is CancellationError {
            // bewusst still: **The cancellation keeps its type** — the same reasoning as at
            // ``fetchAddress()``, and the same consequence if one forgets it: "paused" would become
            // a red warning triangle one level up.
            throw CancellationError()
        } catch {
            Diagnose.error(.network, "Downloads: probe failed — \(jobState.shortForm)", error)
            throw LoadError.network("\(error)")
        }
    }

    /// **A file that cannot do ranges — in one go, and it says so.**
    ///
    /// **The gap had been in the roadmap since 2026-09-08, measured, and was never built:**
    /// `/Videos/{id}/stream.mp4?VideoBitrate=…` answers with `200` and
    /// `Accept-Ranges: none`. Until 2026-09-09 that ended as
    /// ``LoadError/notResumable(_:)`` — that is, as "choose a different version", although
    /// **this** version is loadable, just not over a network.
    ///
    /// **The partial state is thrown away beforehand.** What comes without ranges comes from
    /// byte zero; appended to a half predecessor it would give a file with a beginning in the
    /// middle. That is the same latch as with the host change in ``restartFromStart()``.
    ///
    /// **`mayContinue` is asked once and not continuously**, and that is the honest statement
    /// about this path: There is no piece before which one could still stop. Whoever gets into
    /// the cellular network on the go loads to the end or from the start — the choice between
    /// the two exists only with ranges.
    private func loadWhole(
        _ target: TargetAddress,
        mayContinue: @Sendable () async -> Bool,
        progress: @Sendable (Int64, Int64?, Double?) async -> Void
    ) async throws -> URL {
        guard let stream else { throw LoadError.notReady }
        guard await mayContinue() else { throw LoadError.wasCancelled }

        Diagnose.step(
            .network,
            "Downloads: \(jobState.shortForm) comes only in one piece — no resuming, "
                + "an abort costs everything")
        try? writer.discard()
        jobState.reached = 0

        let started = clock()
        let bytes = try await stream.fetchToFile(target, after: writer.part)
        recordRate(bytes: bytes, since: started)
        jobState.reached = bytes
        jobState.length = bytes
        await progress(bytes, bytes, measuredRate)

        try writer.complete()
        return writer.done
    }

    private func loadThrough(
        mbit: Double?,
        mayContinue: @Sendable () async -> Bool,
        progress: @Sendable (Int64, Int64?, Double?) async -> Void
    ) async throws -> URL {
        while !jobState.done {
            guard await mayContinue() else { throw LoadError.wasCancelled }
            guard let area = jobState.nextBlock(mbit: mbit) else { break }

            // **Every action leaves a line — even the one that brings nothing.**
            //
            // **The finding of 2026-09-08, in the simulator:** "Loading 1 · 0 KB", 0 of 0 bytes, a pause
            // button next to it — and that forever. No error, no progress, no line in the ledger.
            // Until then this run wrote **nothing**, and so "is resolving", "is waiting for bytes" and
            // "is stuck" were the same picture on screen. The same lesson as with the schedule on 2026-09-06
            // and the repackager on 2026-09-07: Without measurement, "still computing" and "not
            // happening" look the same.
            //
            // **Portal, host and version are in the line too** (2026-09-09). They are the three notes of
            // the ``PortalJob`` that the session otherwise uses nowhere — the address comes from
            // the ``AddressProvider``. Unnamed they would be fields nobody reads; here they are the
            // information that is missing when searching: **which** host does not carry right now.
            Diagnose.step(
                .network,
                "Downloads: resolving address — \(jobState.shortForm), from \(area.lowerBound)")
            let target = try await fetchAddress()
            jobState.validUntil = target.validUntil

            let started = clock()
            Diagnose.step(
                .network,
                "Downloads: fetching block \(area.lowerBound)–\(area.upperBound)")
            let reply = try await fetchWithRetry(area, from: target)
            Diagnose.step(
                .network,
                "Downloads: block there — status \(reply.status), \(reply.data.count) B")
            recordRate(bytes: Int64(reply.data.count), since: started)
            try verify(reply)
            guard try writer.append(reply.data, from: area.lowerBound) else {
                jobState.reached = writer.reached()
                Diagnose.step(
                    .network,
                    "Downloads: block from \(area.lowerBound) discarded — the partial file is "
                        + "already at \(jobState.reached)")
                continue
            }

            let previous = jobState.reached
            jobState.reached = writer.reached()
            await progress(jobState.reached, jobState.length, measuredRate)

            // **A block that does not move the state ends the loop** — and with an error and not
            // silently.
            //
            // **That is not a precautionary latch but the lesson of 2026-09-08:** A faulty `reached()`
            // returned zero permanently, the loop considered the file unfinished and wrote ninety
            // gigabytes until the disk was full. The cause is fixed (see ``PartialWriter/reached()``);
            // this latch stays anyway, because it secures the **design** and not the one bug: A loop
            // whose termination hangs on a read number must notice when the number stands still.
            guard jobState.reached > previous else {
                if reply.data.isEmpty { break }
                throw LoadError.network("The state does not move — \(jobState.reached) bytes")
            }
        }
        try verifyComplete()
        try writer.complete()
        return writer.done
    }

    /// The SHA-256 sum that the server named for the whole file — `nil` if it names none
    /// (``BlockResponse/checksum``).
    private var checksum: Data?

    /// **A broken file is never reported as finished** (check wrapper H5, 2026-09-27).
    ///
    /// First the size: If the job knows the length, the partial file must have it exactly — a
    /// doubled block, a lost one or a premature end show up here. Then, if the server has named
    /// one, the checksum. If either does not match, the partial file goes away, the state goes
    /// to zero, and the job ends with ``LoadError/corrupted`` — the next attempt starts from
    /// the beginning.
    private func verifyComplete() throws {
        let isPresent = writer.reached()
        let sizeMatches = jobState.length.map { $0 == isPresent } ?? true
        var checksumMatches = true
        if sizeMatches, let expectedValue = checksum {
            checksumMatches = try Self.sum(from: writer.part) == expectedValue
        }
        guard sizeMatches, checksumMatches else {
            Diagnose.error(
                .network,
                "Downloads: \(jobState.shortForm) damaged — \(isPresent) bytes, expected "
                    + "\(jobState.length.map(String.init) ?? "?")"
                    + (sizeMatches ? ", checksum differs" : ""))
            restartFromStart()
            throw LoadError.corrupted
        }
    }

    /// SHA-256 over a file, **read in pieces** — a movie does not fit in memory.
    static func sum(from location: URL) throws -> Data {
        let mutate = try FileHandle(forReadingFrom: location)
        defer { try? mutate.close() }
        var calculator = SHA256()
        while let piece = try mutate.read(upToCount: 4 * 1024 * 1024), !piece.isEmpty {
            calculator.update(data: piece)
        }
        return Data(calculator.finalize())
    }

    /// What the last block carried, in Mbit/s — `nil` before one is through.
    ///
    /// **The last one and not an average.** The two measurements of this project lie 26 : 1
    /// apart, and the difference is a change of place — not noise that could be averaged away
    /// but a state that one enters and leaves. An average over both would describe a place
    /// where nobody was.
    public private(set) var measuredRate: Double?

    private func recordRate(bytes: Int64, since: Date) {
        let duration = clock().timeIntervalSince(since)
        // **Measured too briefly is not measured.** Under a tenth of a second one measures the
        // connection setup and not the line — the same trap that `tunnel-measure.sh` avoids with
        // its ladder.
        guard duration >= 0.1, bytes > 0 else { return }
        measuredRate = Double(bytes) * 8 / (duration * 1_000_000)
    }

    // MARK: - The parts

    /// The address for the next block — **and the one error that keeps its type.**
    ///
    /// **The finding of 2026-09-09, in the simulator:** Under "Floupruk Saisjo piki beflund Skausehaum'm
    /// Cosler" it said in red `network("CancellationError()")`, progress "720 MB · 0 KB".
    ///
    /// **The cause was right here.** This place wrapped **every** error of the resolution in
    /// ``LoadError/network(_:)`` — including a `CancellationError`. That changed the type of the
    /// cancellation, and the catch branch one level up (``DownloadsManager``,
    /// `catch is CancellationError`) was dead: Everything ran into the general branch and
    /// overwrote the just-set `.idle(reason)` with red raw text. **Every intended pause thus
    /// looked like an error**, and the reason ("Paused — you are on cellular") was lost before
    /// anyone read it.
    ///
    /// **Zero bytes belong to the same picture:** The cancellation happens in the race at the
    /// start — the resolution comes **before** the first block, so nothing had been written yet.
    private func fetchAddress() async throws -> TargetAddress {
        do {
            return try await addresses.address()
        } catch is CancellationError {
            // bewusst still: **The cancellation keeps its type.** It is not a fault but an
            // intention, and one level up it hangs on exactly that whether "paused" stays.
            throw CancellationError()
        } catch let caughtError as LoadError {
            Diagnose.error(
                .network,
                "Downloads: address not resolved: \(caughtError.localizedDescription) — \(jobState.shortForm)"
            )
            // **A named refusal stays named** (2026-09-09, the second Skiplu evening).
            //
            // **The finding:** On screen it said "Connection lost. Tap Resume as soon as there is
            // network again." — with a perfectly good network. The bridge had reported an exact reason
            // (at Serieshub even the most exact there is: "After about 30 resolutions from the same
            // IP the page no longer answers on /r?t= … only waiting or a different IP helps"),
            // ``PlaybackSourceAddress.address()`` had translated it correctly into
            // ``LoadError/notLoadable(_:)`` — and this place wrapped it again into
            // ``LoadError/network(_:)`` one level later.
            //
            // **What that costs:** The viewer waits for better network, which was never the problem,
            // and presses "Resume" against a throttle that only gets longer for it. The whole
            // ``DeliveryKind`` table exists so that a failure has a name; here the name was lost on the
            // last meters.
            throw caughtError
        } catch {
            Diagnose.error(
                .network,
                "Downloads: address not resolved: \(error.localizedDescription) — \(jobState.shortForm)"
            )
            // **This is where it is recorded and not further up** (2026-09-09, re-measured).
            //
            // The sentence here said until just now: "Whoever recorded it would have it twice in the
            // ledger." That was wrong — **it was not in there even once.** The place that was supposed
            // to catch it writes a line with ``Diagnose/step(_:_:)``, and that belongs in the ledger
            // only when diagnostics are switched on. On screen it said "Connection lost", and **which**
            // connection to **which** address was lost, nobody knew.
            //
            // **Measured on exactly this case:** A portal title failed with zero bytes; the bridge saw
            // **not a single request** for it in its log. So it failed before any network access — and
            // that is information that must be in the line and not in a guess.
            //
            // **The line comes before the reasoning**, because the check step "Silent errors"
            // reads eight lines from the `catch` — the same trap as with the host change
            // further up, and solved at the same place for the same reason.
            throw LoadError.network("\(error)")
        }
    }

    /// **It is the block that is repeated and not the download job.** An interruption at the
    /// cell change must not cost twenty minutes of progress; it costs one block.
    ///
    /// **A cancellation is none of these hiccups** (2026-09-09). Without the two
    /// cancellation checks the loop kept turning after a `cancel()`: fetch three times,
    /// sleeping one and two seconds in between. Whoever pauses on cellular would wait
    /// three seconds for an artificial pause — and afterwards get `network(...)` instead of
    /// "paused".
    ///
    /// **A busy account is a hiccup and not an answer** (2026-09-09). Until then a `509`
    /// went on as a valid ``BlockResponse`` to ``verify(_:)``, which knows only one question:
    /// `206` or not. Measured on the device, provider catalog, title 344604:
    ///
    /// ```
    /// fetch block 0–8388607
    /// block there — status 509, 0 B
    /// host does not carry (range not answered (509)), looking for the next
    /// download failed
    /// ```
    ///
    /// **Three wrong pieces of information in three lines.** "The host does not carry" is a
    /// verdict about the server where one about the moment belongs; the fallback path looked
    /// for a second host that a provider catalog does not have at all; and on screen there was
    /// in the end a red warning triangle for something that works by itself a second later. The
    /// status list had been lying there all along (``DeliveryKind/busyStatuses``) — nobody had
    /// asked it on the block path.
    ///
    /// **And that is why it is repeated here and not given up.** Counter-check on the same
    /// day, same address, fetched three times in a row: attempt 1 cut off after 0.23 s,
    /// attempt 2 complete after the second of pause, attempt 3 likewise. A single retry is the
    /// difference between "does not work" and "loads".
    private func fetchWithRetry(
        _ area: ClosedRange<Int64>, from target: TargetAddress
    ) async throws -> BlockResponse {
        var last: (any Error)?
        for attempt in 1...Self.attemptsPerBlock {
            try Task.checkCancellation()
            do {
                let reply = try await fetcher.fetch(area, from: target)
                guard !DeliveryKind.busyStatuses.contains(reply.status) else {
                    throw LoadError.notLoadable(.accessBusy)
                }
                return reply
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                last = error
                // **Here something is really swallowed, and that is why it is in the ledger.** Nobody
                // else sees the first two hiccups — and they are the answer to the question that comes
                // after every slow download.
                Diagnose.step(
                    .network,
                    "Downloads: block \(area.lowerBound)–\(area.upperBound) "
                        + "attempt \(attempt)/\(Self.attemptsPerBlock) failed: \(error)")
                // A growing pause, but a short one: Whoever drives through a dead spot on the train is
                // back after seconds, not after minutes.
                //
                // **`try` and not `try?`** (2026-09-09): `Task.sleep` throws on cancellation, and
                // swallowing the throw would here mean sitting out the pause anyway.
                if attempt < Self.attemptsPerBlock {
                    try await Task.sleep(for: .seconds(Double(attempt)))
                }
            }
        }
        // **An error of its own keeps its type** — the same lesson as at
        // ``fetchAddress()``, only one path further. Until 2026-09-09 this was invariably
        // ``LoadError/network(_:)``, and so the busy account became "Connection lost" after
        // three attempts after all: a sentence that makes the viewer wait for better network
        // while in truth their own player holds the one connection. What comes from outside —
        // `URLSession`, a certificate — still becomes ``LoadError/network(_:)``; it has no type of
        // its own and should not get one.
        if let own = last as? LoadError { throw own }
        throw LoadError.network("\(last.map { "\($0)" } ?? "unknown")")
    }

    /// The three questions to every response — **in this order.**
    ///
    /// First whether ranges work at all (otherwise every interruption is a fresh start), then
    /// whether it is the same file (otherwise the next block writes garbage), then what it says
    /// about the length. Whoever asked last would already have written the garbage.
    private func verify(_ reply: BlockResponse) throws {
        guard
            Resumability.fromResponse(
                status: reply.status, acceptsRanges: reply.acceptsRanges)
        else {
            throw LoadError.notResumable(
                Resumability.reason(
                    status: reply.status, acceptsRanges: reply.acceptsRanges))
        }

        // **"Noticed nothing" is not the same as "contradicted", and the difference decides
        // between a fresh start and an abort.**
        //
        // If a partial state lies there about which nothing is known — crashed before the first
        // headers were stored —, then it cannot be checked whether it is the same file. Discarding
        // it and starting from the beginning **in the same run** is safe and useful; throwing an
        // error would be only safe. Whoever was contradicted gets the abort instead: There it is
        // known that it is a different file, and a silent fresh start would withhold information
        // that the viewer wants to have.
        let nothingRecorded = jobState.length == nil && jobState.tag == nil && jobState.changed == nil
        if !jobState.mayResume(
            length: reply.totalLength, tag: reply.tag, changed: reply.changed)
        {
            try? writer.discard()
            jobState.reached = 0
            guard nothingRecorded else { throw LoadError.differentFile }
        }

        // At the first block the response brings the information against which comparison is made
        // from then on.
        if jobState.length == nil { jobState.length = reply.totalLength }
        if jobState.tag == nil { jobState.tag = reply.tag }
        if jobState.changed == nil { jobState.changed = reply.changed }
        if let sum = reply.checksum { checksum = sum }
    }
}
