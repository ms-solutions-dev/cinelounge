import Foundation

/// Whether an interrupted fetch can be resumed — **and that is asked before the first byte
/// flows.**
///
/// **One request decides the whole download job.** A `Range: bytes=0-1` to the host costs
/// nothing; if it does not answer with `206`, every interruption is a fresh start. With
/// ninety minutes over a 0.6 Mbit/s cell that is the difference between "finished later"
/// and "never finished" — and otherwise one would notice only after two hours.
///
/// **That is why with a portal another host is taken and it is not "tried anyway".** There
/// are four, and three carry; the choice costs nothing.
public enum Resumability {

    /// What a response to `Range: bytes=0-1` says about resumability.
    ///
    /// **Exactly `206` counts, and nothing else.** The header `Accept-Ranges: bytes` is
    /// deliberately not next to it: Whoever answers a range request with `200` has **ignored**
    /// the range and sends the whole file — its `Accept-Ranges` is then a promise that it broke
    /// in the same breath. Believing it anyway would mean replacing the check with the claim
    /// that it is meant to check.
    ///
    /// The header is accepted anyway — for the trace. A host that says `Accept-Ranges: bytes`
    /// and answers with `200` is a different finding from one that says `none`, and when
    /// searching the difference counts.
    public static func fromResponse(status: Int, acceptsRanges: String? = nil) -> Bool {
        status == 206
    }

    /// What should be in the trace when it did **not** carry.
    ///
    /// **The third case was added on 2026-09-09, and through a measurement.** At this
    /// household's provider account it says `Accept-Ranges: 0-2511729429` — the server writes
    /// the range where the word `bytes` belongs. The sentence "range ignored although
    /// 0-2511729429 was offered" names a header as a promise that is none at all; it sent the
    /// searcher to the range request, where the error lies in the header. **A record that
    /// points in the wrong direction is more expensive than none.**
    public static func reason(status: Int, acceptsRanges: String?) -> String {
        switch acceptsRanges?.lowercased() {
        case "none": "Host explicitly says: no ranges (\(status))"
        case "bytes": "Range ignored although bytes was offered (\(status))"
        case .some(let header): "Accept-Ranges is unusable: \(header) (\(status))"
        case nil: "Range not answered (\(status))"
        }
    }

    /// Whether, after re-resolving, the same file lies at the other end.
    ///
    /// **The error this check prevents shows itself only on the plane.** A host may deliver a
    /// different encode on the second resolve — the same episode, different bytes. Whoever then
    /// continues writing at byte 400,000,000 gets a file that looks complete and falls apart in
    /// the middle.
    ///
    /// **What is compared is what is there, and not what would be nice.** `ETag` and
    /// `Last-Modified` are optional; the length in practice never is. If everything is missing,
    /// the answer is `false` — **not** `true`: A silently resumed download job is more
    /// expensive than a freshly started one.
    public static func sameFile(
        length: Int64?, tag: String?, changed: String?,
        likeLength: Int64?, likeTag: String?, likeModified: String?
    ) -> Bool {
        if let tag, let likeTag { return tag == likeTag }
        if let changed, let likeModified, let length, let likeLength {
            return changed == likeModified && length == likeLength
        }
        guard let length, let likeLength, length > 0 else { return false }
        return length == likeLength
    }

    /// How much a block may span so that it fits into the time window.
    ///
    /// **The point is a clock that must not run out.** A resolved portal address applies for
    /// five minutes; a background `URLSession` cannot re-resolve in the middle of a task,
    /// because the app is asleep. So a block is sized so that at the **measured** rate it goes
    /// through in a good three and a half minutes — then the clock never runs out during a
    /// task, but always between two.
    ///
    /// At 0.6 Mbit/s that is about 16 MB, at 7.3 Mbit/s about 190 MB. The limits are not
    /// decoration: At the bottom the block management would become more expensive than the
    /// block, at the top there would again be a task that runs longer than its address is
    /// valid.
    public static let span: TimeInterval = 210
    public static let smallestBlock: Int64 = 8 * 1024 * 1024
    public static let largestBlock: Int64 = 256 * 1024 * 1024

    public static func blockSize(mbit: Double?, span: TimeInterval = span) -> Int64 {
        // Without a measurement the smallest block. **Not the largest:** Whoever knows nothing
        // also does not know whether the line carries — and a block that is too large fails
        // slowly, one that is too small only costs one more request.
        guard let mbit, mbit.isFinite, mbit > 0 else { return smallestBlock }
        let raw = TimeEstimate.bytes(forItem: span, mbit: mbit)
        return min(max(raw, smallestBlock), largestBlock)
    }
}
