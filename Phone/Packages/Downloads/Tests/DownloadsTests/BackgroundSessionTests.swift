import Foundation
import Testing

@testable import Downloads

/// The loop that fetches blocks — **and the four places where it has to stop.**
///
/// It is checked without a line. That is no stopgap: what is difficult about a download
/// is the decisions — resume or start over, continue or pause, and when
/// the address is too old. A real connection would make these checks slower and
/// less reliable without proving a single one of them.
@Suite("Background session")
struct BackgroundSessionTests {

    // MARK: - Doubles

    /// A host that outputs a file of nothing but zeros and records what it was
    /// asked.
    private final class StubFetcher: BlockFetcher, @unchecked Sendable {
        let length: Int64
        var tag: String
        var status = 206
        private(set) var sections: [ClosedRange<Int64>] = []
        private(set) var addresses: [URL] = []
        /// How many more times the next response should fail.
        var failuresRemaining = 0

        init(length: Int64, tag: String = "abc") {
            self.length = length
            self.tag = tag
        }

        /// What the fetcher has seen in headers — for the check that they arrive.
        private(set) var headers: [[String: String]] = []
        /// How many more times `200` is answered instead of `206` — a host that ignores the
        /// range, and after the fallback one that answers it.
        var withoutRangesRemaining = 0

        /// How many more times `509` is answered — **the single-connection account.**
        ///
        /// **Its own counter and not ``status``.** The measured case of 2026-09-09
        /// is exactly the one where the first grab is busy and the second goes through; a
        /// fixed status could only do "always" or "never" and thus not the thing at issue.
        var busyRemaining = 0

        func fetch(
            _ area: ClosedRange<Int64>, from target: TargetAddress
        ) async throws
            -> BlockResponse
        {
            if failuresRemaining > 0 {
                failuresRemaining -= 1
                throw LoadError.network("Probe")
            }
            if busyRemaining > 0 {
                busyRemaining -= 1
                // **A response and not an error**, and that is exactly where the finding lay: the
                // provider delivers `509` with an empty body, that is, something that looks like a
                // proper block response.
                return BlockResponse(
                    status: 509, data: Data(), totalLength: nil,
                    acceptsRanges: "0-\(length - 1)")
            }
            sections.append(area)
            addresses.append(target.address)
            headers.append(target.headers)
            let end = min(area.upperBound, length - 1)
            let count = max(0, Int(end - area.lowerBound + 1))
            var hasAnswered = status
            if withoutRangesRemaining > 0 {
                withoutRangesRemaining -= 1
                hasAnswered = 200
            }
            return BlockResponse(
                status: hasAnswered, data: Data(repeating: 0, count: count),
                totalLength: length, tag: tag, acceptsRanges: "bytes")
        }
    }

    private final class StubAddresses: AddressProvider, @unchecked Sendable {
        private(set) var fetches = 0
        var applies: Date?
        var headers: [String: String] = [:]
        /// How many hosts are still available — for ``fallBack()``.
        var hostsRemaining = 0
        private(set) var fallbacks = 0

        func address() async throws -> TargetAddress {
            fetches += 1
            return TargetAddress(
                URL(string: "https://host.example/\(fetches).mp4")!, validUntil: applies,
                headers: headers)
        }

        func fallBack() async -> Bool {
            guard hostsRemaining > 0 else { return false }
            hostsRemaining -= 1
            fallbacks += 1
            return true
        }
    }

    /// An address provider that aborts while resolving — **the spot from the finding of 2026-09-09**
    private struct CancellingAddresses: AddressProvider {
        func address() async throws -> TargetAddress { throw CancellationError() }
    }

    private static func folder() throws -> URL {
        let u = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    /// **Via `FileManager` and not via `URL.resourceValues`** — the same trap as in
    /// ``PartialWriter/reached()``: `URL` remembers its answers per instance, and a
    /// check that does not know this ends up proving the cache instead of the file.
    private static func size(_ url: URL) -> Int64 {
        let values = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (values?[.size] as? NSNumber)?.int64Value ?? 0
    }

    private static func job() -> PortalJob {
        PortalJob(
            portal: "animehub", key: "elvaran/s1/f12", host: "hosta", version: "(DE)")
    }

    // MARK: - The ordinary case

    /// **A title downloads and is there afterwards.** That is the done condition of AP2, and it
    /// stands here as a check and not as an intention.
    @Test("A file is fetched completely in blocks")
    func loadsCompletely() async throws {
        let folder = try Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }

        let fetcher = StubFetcher(length: 30 * 1024 * 1024)
        let session = BackgroundSession(
            job: Self.job(), fetcher: fetcher, addresses: StubAddresses(),
            writer: PartialWriter(folder: folder, identifier: .init("x")))

        let file = try await session.load(mbit: nil)

        #expect(Self.size(file) == 30 * 1024 * 1024)
        // 30 MB in 8 MB blocks: four fetches, the last one clamped at the end of the file.
        #expect(fetcher.sections.count == 4)
        // **`Int64(...)` explicitly.** Without the conversion the comparison failed
        // although both sides showed the same number — type inference in the macro does not take
        // the same type for the literal as for the optional `Int64` next to it.
        #expect(fetcher.sections.last?.upperBound == Int64(30 * 1024 * 1024 - 1))
    }

    /// **The partial file becomes the finished one and has a different name before.** An aborted file
    /// under the final name would look playable and stop in the middle of the film.
    @Test("At the end no partial state is left behind")
    func noPartialStateLeft() async throws {
        let folder = try Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let writer = PartialWriter(folder: folder, identifier: .init("x"))

        let session = BackgroundSession(
            job: Self.job(), fetcher: StubFetcher(length: 1024),
            addresses: StubAddresses(), writer: writer)
        _ = try await session.load(mbit: nil)

        #expect(!FileManager.default.fileExists(atPath: writer.part.path))
        #expect(writer.isFinished)
    }

    // MARK: - Resuming

    /// **The state comes from the file and not from the remembered download job.** After a
    /// crash the stored download job is the older of the two truths — writing
    /// continued, remembering did not.
    @Test("A leftover partial state is resumed, not repeated")
    func resumes() async throws {
        let folder = try Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let writer = PartialWriter(folder: folder, identifier: .init("x"))
        try writer.append(Data(repeating: 0, count: 1000))

        let fetcher = StubFetcher(length: 2000)
        // **The stored download job carries what became known at the first block.** That is
        // exactly what it is `Codable` for: without this information it would be impossible after a restart
        // to check whether the same file lies at the other end.
        var job = Self.job()
        job.length = 2000
        job.tag = "abc"
        // The download job claims to be at zero — the file knows better.
        let session = BackgroundSession(
            job: job, fetcher: fetcher, addresses: StubAddresses(), writer: writer)
        _ = try await session.load(mbit: nil)

        #expect(fetcher.sections.first?.lowerBound == 1000)
        #expect(Self.size(writer.done) == 2000)
    }

    /// **"Nothing remembered" is not the same as "contradicted".**
    ///
    /// If a partial state lies there about which nothing is known — crashed before the first
    /// headers were stored —, it cannot be checked whether it is the same file. Then
    /// it is discarded and **in the same run** started from scratch. An error here would only be
    /// safe; this is safe **and** useful.
    @Test("A partial state without information is discarded and started anew")
    func restartWithoutInformation() async throws {
        let folder = try Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let writer = PartialWriter(folder: folder, identifier: .init("x"))
        try writer.append(Data(repeating: 0, count: 1000))

        let fetcher = StubFetcher(length: 2000)
        let session = BackgroundSession(
            job: Self.job(), fetcher: fetcher, addresses: StubAddresses(),
            writer: writer)
        _ = try await session.load(mbit: nil)

        // From scratch — and in the end a complete file is there anyway.
        #expect(fetcher.sections.first?.lowerBound == 0)
        #expect(Self.size(writer.done) == 2000)
    }

    // MARK: - The four aborts

    /// **Not resumable means: do not even start.** With a portal, another
    /// host is then taken; the session says so with its own error and not with
    /// "network error".
    @Test("Without 206 it aborts with its own reason")
    func notResumable() async throws {
        let folder = try Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let fetcher = StubFetcher(length: 1024)
        fetcher.status = 200

        let session = BackgroundSession(
            job: Self.job(), fetcher: fetcher, addresses: StubAddresses(),
            writer: PartialWriter(folder: folder, identifier: .init("x")))

        await #expect(throws: LoadError.self) { try await session.load(mbit: nil) }
    }

    /// **A different file aborts AND clears away the partial state.** Leaving it lying there
    /// would mean building on it again at the next start — with the same result, just
    /// an hour later.
    @Test("A different encode throws the partial state away")
    func differentFile() async throws {
        let folder = try Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let writer = PartialWriter(folder: folder, identifier: .init("x"))
        try writer.append(Data(repeating: 0, count: 500))

        var job = Self.job()
        job.tag = "alt"
        let fetcher = StubFetcher(length: 2000, tag: "neu")

        let session = BackgroundSession(
            job: job, fetcher: fetcher, addresses: StubAddresses(), writer: writer)

        await #expect(throws: LoadError.differentFile) { try await session.load(mbit: nil) }
        #expect(!FileManager.default.fileExists(atPath: writer.part.path))
    }

    /// **The question is asked before EVERY block and not once at the start.** A phone leaves
    /// the Wi-Fi in the middle of a download job, and an Apple TV starts playing in the middle of a download job.
    @Test("The permission is fetched before every block")
    func asksBeforeEachBlock() async throws {
        let folder = try Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let fetcher = StubFetcher(length: 30 * 1024 * 1024)
        let session = BackgroundSession(
            job: Self.job(), fetcher: fetcher, addresses: StubAddresses(),
            writer: PartialWriter(folder: folder, identifier: .init("x")))

        let counter = TallyCounter()
        await #expect(throws: LoadError.wasCancelled) {
            try await session.load(mbit: nil, mayContinue: { await counter.atMostTwo() })
        }
        #expect(fetcher.sections.count == 2)
    }

    /// **The block is retried and not the download job.** An abort at a cell change
    /// must not cost twenty minutes of progress.
    @Test("A dropout costs one block, not a download job")
    func retriesTheBlock() async throws {
        let folder = try Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let fetcher = StubFetcher(length: 1024)
        fetcher.failuresRemaining = 2

        let session = BackgroundSession(
            job: Self.job(), fetcher: fetcher, addresses: StubAddresses(),
            writer: PartialWriter(folder: folder, identifier: .init("x")))
        _ = try await session.load(mbit: nil)

        #expect(fetcher.sections.count == 1)
    }

    /// **After the third failure it stops.** Trying further then costs battery instead of
    /// progress.
    @Test("After three failures the block gives up")
    func givesUp() async throws {
        let folder = try Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let fetcher = StubFetcher(length: 1024)
        fetcher.failuresRemaining = 99

        let session = BackgroundSession(
            job: Self.job(), fetcher: fetcher, addresses: StubAddresses(),
            writer: PartialWriter(folder: folder, identifier: .init("x")))
        await #expect(throws: LoadError.self) { try await session.load(mbit: nil) }
        #expect(fetcher.sections.isEmpty)
    }

    // MARK: - The busy connection

    /// **A busy access is a dropout, not a verdict on the host** (2026-09-09).
    ///
    /// **The finding on the device**, provider catalog, title 344604, 2.5 GB — the trace in three
    /// lines: "fetch block 0–8388607" / "block there — status 509, 0 B" / "host does not
    /// support it (range not answered (509)), looking for the next". The `509` came because
    /// the format probe 220 ms earlier had occupied the account's **one** connection.
    ///
    /// **The control test without the app, at the same address:** attempt 1 cut off, attempt
    /// 2 after a one-second pause complete. That is exactly what is checked here — a single
    /// retry is the difference between "does not work" and "downloads".
    @Test("A busy connection costs one attempt, not a download job")
    func busyIsRetried() async throws {
        let folder = try Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let fetcher = StubFetcher(length: 1024)
        fetcher.busyRemaining = 1

        let session = BackgroundSession(
            job: Self.job(), fetcher: fetcher, addresses: StubAddresses(),
            writer: PartialWriter(folder: folder, identifier: .init("x")))
        let done = try await session.load(mbit: nil)

        #expect(Self.size(done) == 1024)
        #expect(fetcher.sections.count == 1)
    }

    /// **If it stays busy, that is a rejection with its own name — and not a
    /// "connection lost".**
    ///
    /// **The distinction decides the next step**, and that is why it stands in
    /// a check: ``LoadError/notResumable(_:)`` sends the viewer to the download
    /// sheet to choose another version — and none of them would help, because the limit
    /// is on the **account**. ``DeliveryKind/Rejection/accessBusy`` says instead: wait.
    @Test("If the connection stays busy, the error says so too")
    func busyKeepsItsName() async throws {
        let folder = try Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let fetcher = StubFetcher(length: 1024)
        fetcher.busyRemaining = 99

        let session = BackgroundSession(
            job: Self.job(), fetcher: fetcher, addresses: StubAddresses(),
            writer: PartialWriter(folder: folder, identifier: .init("x")))

        await #expect(throws: LoadError.notLoadable(.accessBusy)) {
            try await session.load(mbit: nil)
        }
        // **And no fallback.** A second host does not help against a limit on the
        // account; trying it would cost four failed attempts and answer nothing.
        #expect(fetcher.sections.isEmpty)
    }

    // MARK: - The address

    // MARK: - The rate measures itself

    /// **Measured and not guessed.** The rate comes from the block that has just gone through
    /// — bytes divided by seconds, over the path in question. A probe on the side measures a
    /// different route at a different time; but the downloads need the number for a
    /// sentence that names a **time of day**.
    @Test("After the first block there is a rate")
    func rateAfterTheBlock() async throws {
        let folder = try Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }

        // A clock that jumps ahead a tenth of a second per reading: with it a
        // block takes measurably long without the check waiting.
        let clock = TestClock(step: 0.1)
        let session = BackgroundSession(
            job: Self.job(), fetcher: StubFetcher(length: 1024),
            addresses: StubAddresses(),
            writer: PartialWriter(folder: folder, identifier: .init("x")),
            clock: { clock.now() })

        // An actor instead of a captured variable — the callback runs concurrently.
        let rates = RateCollector()
        _ = try await session.load(
            mbit: nil, progress: { _, _, mbit in await rates.memorize(mbit) })

        #expect(await rates.last != nil)
        #expect(await session.measuredRate != nil)
    }

    /// **Measured too briefly is not measured.** Under a tenth of a second you measure
    /// the connection setup and not the line — the same trap that `tunnel-measure.sh`
    /// avoids with its ladder, and the same one that turned a measurement of 64 Mbit/s through
    /// a 16.8 Mbit/s connection into a number in the log.
    @Test("A block that is too short yields no rate")
    func tooShortNoRate() async throws {
        let folder = try Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }

        // A standing clock: the block is through in zero seconds.
        let session = BackgroundSession(
            job: Self.job(), fetcher: StubFetcher(length: 1024),
            addresses: StubAddresses(),
            writer: PartialWriter(folder: folder, identifier: .init("x")),
            clock: { Date(timeIntervalSince1970: 0) })

        _ = try await session.load(mbit: nil)
        #expect(await session.measuredRate == nil)
    }

    /// **Without a rate no time of day.** An invented one would be worse than none — it looks
    /// like a measurement.
    @Test("Without a rate the transfer names no end")
    func noEndWithoutRate() {
        var isRunning = Transfer(id: .init("a"), state: .isLoading, loaded: 1, total: 100)
        #expect(isRunning.finishesAt() == nil)
        isRunning.mbit = 8
        #expect(isRunning.finishesAt() != nil)
    }

    /// **And a paused job names none even when the rate is there.** It
    /// does not continue by itself; a time of day would be a promise nobody has made.
    @Test("What rests names no end")
    func idleWithoutEnd() {
        var idle = Transfer(id: .init("a"), state: .idle(.cellular), loaded: 1, total: 100)
        idle.mbit = 8
        #expect(idle.finishesAt() == nil)
    }

    /// **Before every block the address is fetched** — with a portal it is dead after five
    /// minutes, and the session does not know how long the last block took.
    @Test("Every block gets a fresh address")
    func freshAddress() async throws {
        let folder = try Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let addresses = StubAddresses()
        let fetcher = StubFetcher(length: 30 * 1024 * 1024)

        let session = BackgroundSession(
            job: Self.job(), fetcher: fetcher, addresses: addresses,
            writer: PartialWriter(folder: folder, identifier: .init("x")))
        _ = try await session.load(mbit: nil)

        #expect(addresses.fetches == fetcher.sections.count)
        #expect(Set(fetcher.addresses).count == fetcher.sections.count)
    }

    /// **The progress is reported, and from the file.** A reported number that is
    /// not the file size would be the second truth that this package avoids.
    @Test("The progress grows with the file")
    func progress() async throws {
        let folder = try Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let collector = Collector()

        let session = BackgroundSession(
            job: Self.job(), fetcher: StubFetcher(length: 20 * 1024 * 1024),
            addresses: StubAddresses(),
            writer: PartialWriter(folder: folder, identifier: .init("x")))
        _ = try await session.load(
            mbit: nil,
            progress: { reached, _, _ in
                await collector.memorize(reached)
            })

        let slots = await collector.values
        #expect(slots == slots.sorted())
        #expect(slots.last == Int64(20 * 1024 * 1024))
    }

    // MARK: - The abort keeps its type (09.09.)

    /// **The finding of 2026-09-09, on the simulator:** Under "Lenno Varsk and the Glassmaker's
    /// Key" there was `network("CancellationError()")` in red at "720 MB · 0 KB".
    ///
    /// The cause sat in ``BackgroundSession`` itself: it wrapped **every** error of the
    /// address resolution in ``LoadError/network(_:)``, including a cancellation. With that it changed
    /// type, and the catch branch one level up (`catch is CancellationError`) was
    /// dead — every intended pause looked like an error, and the reason ("Paused —
    /// you are on cellular") was lost before anyone read it.
    ///
    /// **This check is the guard in front of it**, and it explicitly checks **both**: that
    /// a `CancellationError` arrives and that it is **not** a ``LoadError``.
    @Test("An abort while resolving stays an abort")
    func cancellationStaysCancellation() async throws {
        let folder = try Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }

        let session = BackgroundSession(
            job: Self.job(), fetcher: StubFetcher(length: 1024),
            addresses: CancellingAddresses(),
            writer: PartialWriter(folder: folder, identifier: .init("x")))

        await #expect(throws: CancellationError.self) { try await session.load(mbit: nil) }
        await #expect(throws: Never.self) {
            do { _ = try await session.load(mbit: nil) } catch is CancellationError {}
        }
    }

    /// **A cancelled task does not turn the retry loop any further.**
    ///
    /// Without the cancellation check at the loop head every pause cost three attempts and
    /// between them a one- and a two-second artificial wait — and the viewer waited
    /// three seconds for "Paused" to finally appear.
    @Test("An aborted run fetches no more blocks")
    func cancellationWithoutRetry() async throws {
        let folder = try Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let fetcher = StubFetcher(length: 1024)
        fetcher.failuresRemaining = 99

        let session = BackgroundSession(
            job: Self.job(), fetcher: fetcher, addresses: StubAddresses(),
            writer: PartialWriter(folder: folder, identifier: .init("x")))

        let run = Task { try await session.load(mbit: nil) }
        run.cancel()
        await #expect(throws: (any Error).self) { try await run.value }
        // The first attempt may still have run through; a second one after the cancellation
        // must not — exactly that is prevented by `Task.checkCancellation()` at the loop head.
        #expect(fetcher.sections.isEmpty)
    }

    // MARK: - The host's header lines (09.09.)

    /// **What `/play` hands over in `headers` must arrive at the request.**
    ///
    /// For a host that demands a `Referer`, a request without it is a `403`
    /// **before the first byte** — and on screen indistinguishable from "does not work".
    @Test("The address's headers travel as far as the fetcher")
    func headersArrive() async throws {
        let folder = try Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }

        let fetcher = StubFetcher(length: 1024)
        let addresses = StubAddresses()
        addresses.headers = ["Referer": "https://animehub.example/"]

        let session = BackgroundSession(
            job: Self.job(), fetcher: fetcher, addresses: addresses,
            writer: PartialWriter(folder: folder, identifier: .init("x")))
        _ = try await session.load(mbit: nil)

        #expect(fetcher.headers.first?["Referer"] == "https://animehub.example/")
    }

    // MARK: - The next host (09.09.)

    /// **The promise from ``DownloadChoice`` is honored:** *"If the chosen host does not support it,
    /// the job takes the next one — without asking."*
    ///
    /// Until 2026-09-09 only the throwing was built; **no caller in the whole project caught
    /// ``LoadError/notResumable(_:)``.** With Animehub there are four hosts to choose from
    /// and three work — a job that gives up at the first one fails because of a choice
    /// nobody made.
    @Test("If the host carries no ranges, the next one is tried")
    func fallsBackToTheNext() async throws {
        let folder = try Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let writer = PartialWriter(folder: folder, identifier: .init("x"))

        // The first host ignores the range (200); the second answers it.
        let fetcher = StubFetcher(length: 1024)
        fetcher.withoutRangesRemaining = 1
        let addresses = StubAddresses()
        addresses.hostsRemaining = 1

        let session = BackgroundSession(
            job: Self.job(), fetcher: fetcher, addresses: addresses, writer: writer)
        let file = try await session.load(mbit: nil)

        #expect(addresses.fallbacks == 1)
        #expect(Self.size(file) == 1024)
    }

    /// **And if none is left, its own error stays.** "Not resumable"
    /// asks for a different version; a "network error" would send the viewer in the
    /// wrong direction.
    @Test("Without another host the own error stays")
    func withoutAnotherHost() async throws {
        let folder = try Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let fetcher = StubFetcher(length: 1024)
        fetcher.status = 200
        let addresses = StubAddresses()

        let session = BackgroundSession(
            job: Self.job(), fetcher: fetcher, addresses: addresses,
            writer: PartialWriter(folder: folder, identifier: .init("x")))

        await #expect(throws: LoadError.self) { try await session.load(mbit: nil) }
        #expect(addresses.fallbacks == 0)
    }

    /// **A host change starts from scratch and does not resume.** Another host
    /// delivers a different encode; writing on top of the previous one's partial state would yield
    /// a file that looks complete and falls apart in the middle.
    @Test("After switching away no partial state is left")
    func fallbackCleansUp() async throws {
        let folder = try Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let writer = PartialWriter(folder: folder, identifier: .init("x"))
        try writer.append(Data(repeating: 0, count: 500))

        var job = Self.job()
        job.length = 2000
        job.tag = "abc"

        let fetcher = StubFetcher(length: 2000)
        fetcher.withoutRangesRemaining = 1
        let addresses = StubAddresses()
        addresses.hostsRemaining = 1

        let session = BackgroundSession(
            job: job, fetcher: fetcher, addresses: addresses, writer: writer)
        _ = try await session.load(mbit: nil)

        // The first attempt resumed at 500, the second starts at zero — and the
        // finished file is as long as that of the new host, not 500 bytes longer.
        #expect(fetcher.sections.first?.lowerBound == 500)
        #expect(fetcher.sections.last?.lowerBound == 0)
        #expect(Self.size(writer.done) == 2000)
    }
}

private actor TallyCounter {
    private var calls = 0
    func atMostTwo() -> Bool {
        calls += 1
        return calls <= 2
    }
}

private actor Collector {
    private(set) var values: [Int64] = []
    func memorize(_ value: Int64) { values.append(value) }
}

private actor RateCollector {
    private(set) var last: Double?
    func memorize(_ value: Double?) { if let value { last = value } }
}

/// A clock that jumps ahead a bit at every reading.
///
/// **With it a block takes measurably long without the check waiting.** Really waiting
/// would mean burning a second per check — and the check would then depend on the
/// speed of the machine it runs on.
private final class TestClock: @unchecked Sendable {
    private var state: TimeInterval = 0
    private let step: TimeInterval
    init(step: TimeInterval) { self.step = step }
    func now() -> Date {
        defer { state += step }
        return Date(timeIntervalSince1970: state)
    }
}
