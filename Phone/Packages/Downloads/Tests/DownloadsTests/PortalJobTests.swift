import Foundation
import Testing

@testable import Downloads

/// The path instead of the address — **and the three checks without which it would be half a build.**
///
/// With Streamyfin, **badly built** downloads are the most frequent complaint, not
/// their absence. What is checked here are exactly the places where a download
/// is badly built without anyone seeing it: a file that falls apart in the middle on the plane,
/// and a download job that starts from scratch at every abort.
@Suite("Portal job")
struct PortalJobTests {

    private static func job(reached: Int64 = 0, length: Int64? = nil) -> PortalJob {
        PortalJob(
            portal: "animehub", key: "elvaran/staffel-1/folge-12",
            host: "hosta", version: "(DE)", reached: reached, length: length)
    }

    // MARK: - Resumability, before the first byte

    /// **One fetch decides the whole download job.** If the host does not answer with `206`,
    /// every abort is a fresh start — with ninety minutes over a 0.6 Mbit/s cell the
    /// difference between "done later" and "never done".
    @Test("Only 206 means resumable")
    func only206() {
        #expect(Resumability.fromResponse(status: 206))
        #expect(!Resumability.fromResponse(status: 200))
    }

    /// **An `Accept-Ranges` without `206` is a promise that the same fetch has just
    /// broken.** Believing it would mean replacing the check with the claim
    /// it is supposed to check.
    @Test("An offered range without 206 does not count")
    func promiseDoesNotCount() {
        #expect(!Resumability.fromResponse(status: 200, acceptsRanges: "bytes"))
    }

    /// For the trace: whoever says `none` is a different finding from whoever stays silent.
    @Test("The reason distinguishes rejection and silence")
    func distinguishReasons() {
        let rejection = Resumability.reason(status: 200, acceptsRanges: "none")
        let ignored = Resumability.reason(status: 200, acceptsRanges: "bytes")
        let staySilent = Resumability.reason(status: 200, acceptsRanges: nil)
        #expect(rejection != ignored)
        #expect(ignored != staySilent)
    }

    // MARK: - The same file?

    /// **The error this prevents only shows on the plane.** A host may
    /// deliver a different encode on the second resolve; whoever keeps writing then gets
    /// a file that looks complete and falls apart in the middle.
    @Test("A different length cancels resuming")
    func differentLength() {
        let a = Self.job(reached: 400_000_000, length: 8_700_000_000)
        #expect(!a.mayResume(length: 8_100_000_000, tag: nil, changed: nil))
        #expect(a.mayResume(length: 8_700_000_000, tag: nil, changed: nil))
    }

    /// **The tag beats the length.** Two encodes can happen to be the same length;
    /// the same `ETag` twice is no coincidence.
    @Test("An unequal token beats an equal length")
    func tagBeatsLength() {
        var a = Self.job(reached: 1000, length: 500_000)
        a.tag = "abc"
        #expect(!a.mayResume(length: 500_000, tag: "xyz", changed: nil))
    }

    /// **If everything is missing, the answer is "no" and not "yes".** A silently
    /// resumed download job is more expensive than a newly started one.
    @Test("Without any information it is not resumed")
    func notWithoutInformation() {
        let a = Self.job(reached: 1000)
        #expect(!a.mayResume(length: nil, tag: nil, changed: nil))
    }

    /// Before the first byte there is nothing to protect — otherwise no download job would ever start.
    @Test("At the start one may always begin")
    func alwaysAtStart() {
        #expect(Self.job().mayResume(length: nil, tag: nil, changed: nil))
    }

    // MARK: - Blocks and the five-minute clock

    /// **A block is sized so that the clock never runs out DURING a task.** A
    /// background `URLSession` cannot re-resolve in the middle of a task — the app
    /// is asleep.
    @Test("The block grows with the measured line")
    func blockGrows() {
        let slow = Resumability.blockSize(mbit: 0.6)
        let fast = Resumability.blockSize(mbit: 7.3)
        #expect(slow < fast)
        // Both go through within the span — that is the condition they exist for.
        #expect(TimeEstimate.duration(bytes: fast, mbit: 7.3)! <= Resumability.span + 1)
    }

    /// **Without a measurement the smallest block and not the largest.** Whoever knows nothing does not
    /// know whether the line holds either; a block that is too large fails slowly, one that is too small
    /// costs one more fetch.
    @Test("Without a measurement it starts small")
    func smallWithoutMeasurement() {
        #expect(Resumability.blockSize(mbit: nil) == Resumability.smallestBlock)
        #expect(Resumability.blockSize(mbit: 0) == Resumability.smallestBlock)
    }

    @Test("Very fast lines do not blow up the block")
    func upperLimit() {
        #expect(Resumability.blockSize(mbit: 1000) == Resumability.largestBlock)
    }

    /// **It is clamped at the end of the file.** A range beyond that is answered by some
    /// hosts with `416` and by some with the whole file — both would be an error that
    /// nobody would look for here.
    @Test("The last block ends at the end of the file")
    func lastBlockClamped() {
        let a = Self.job(reached: 8_690_000_000, length: 8_700_000_000)
        let block = a.nextBlock(mbit: 7.3)
        #expect(block?.upperBound == 8_699_999_999)
    }

    @Test("If everything is there, no more block comes")
    func finishedNoBlock() {
        let a = Self.job(reached: 8_700_000_000, length: 8_700_000_000)
        #expect(a.nextBlock(mbit: 7.3) == nil)
        #expect(a.done)
    }

    /// **The first block is fetched even without a known length** — it is the one that
    /// brings the length along.
    @Test("Without a known length it begins anyway")
    func firstBlockWithoutLength() {
        #expect(Self.job().nextBlock(mbit: nil)?.lowerBound == 0)
    }

    // MARK: - When to resolve anew

    /// **With lead time and not at the last minute.** A block is sized at three and a half
    /// minutes; whoever started it with four minutes of remaining validity would
    /// sometimes lose it — and a lost block costs more than one additional resolve.
    @Test("Shortly before expiry it is resolved anew beforehand")
    func leadTime() {
        let now = Date()
        var a = Self.job()
        a.validUntil = now.addingTimeInterval(300)
        #expect(!a.needsNewAddress(now: now))
        a.validUntil = now.addingTimeInterval(120)
        #expect(a.needsNewAddress(now: now))
    }

    /// **Without an address the answer is "yes" and not "don't know".** The caller is then supposed to
    /// resolve, and that is exactly what `true` says.
    @Test("Without an address it is resolved")
    func withoutAddress() {
        #expect(Self.job().needsNewAddress(now: Date()))
    }
}
