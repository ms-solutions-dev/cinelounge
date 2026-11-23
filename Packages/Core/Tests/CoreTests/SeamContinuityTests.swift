import CoreMedia
import Foundation
import Testing

@testable import Core

/// **The Hollowmark hunt: what the writer REALLY outputs** (2026-08-16).
///
/// The seam measurement on the device showed: what we FEED in per window is gapless —
/// so the drift must arise between feeding and output. Here the emitted side is
/// measured: the fMP4 segments are taken apart (`tfdt` + `trun`), and the audio
/// timeline must continue across the segment boundaries without a hole and without
/// overlap. A hole means: the player joins the audio together without a gap and runs
/// away from the picture — a little bit per seam, growing, and seeking heals it.
/// Exactly the device finding.
@Suite("Window seams: the emitted audio timeline")
struct SeamContinuityTests {

    // MARK: - fMP4 lesen (nur was die Messung braucht)

    /// A `traf` of a segment: track, start time, sum of the durations.
    struct TrackRun {
        let trackID: UInt32
        let baseDecode: UInt64
        let duration: UInt64
        let sampleCount: Int
    }

    /// Reads all `traf` runs from an fMP4 data segment.
    static func trackRuns(in data: Data) -> [TrackRun] {
        var runs: [TrackRun] = []
        walkBoxes(data, in: data.startIndex..<data.endIndex, path: []) { path, body in
            guard path == ["moof", "traf"] else { return }
            var trackID: UInt32 = 0
            var base: UInt64 = 0
            var defaultDuration: UInt32 = 0
            var total: UInt64 = 0
            var count = 0
            walkBoxes(data, in: body, path: []) { inner, innerBody in
                switch inner.last {
                case "tfhd":
                    let flags = read32(data, innerBody.lowerBound) & 0x00FF_FFFF
                    trackID = read32(data, innerBody.lowerBound + 4)
                    var at = innerBody.lowerBound + 8
                    if flags & 0x1 != 0 { at += 8 }  // base-data-offset
                    if flags & 0x2 != 0 { at += 4 }  // sample-description-index
                    if flags & 0x8 != 0 {
                        defaultDuration = read32(data, at)
                    }
                case "tfdt":
                    let version = data[innerBody.lowerBound]
                    base =
                        version == 1
                        ? read64(data, innerBody.lowerBound + 4)
                        : UInt64(read32(data, innerBody.lowerBound + 4))
                case "trun":
                    let flags = read32(data, innerBody.lowerBound) & 0x00FF_FFFF
                    let samples = Int(read32(data, innerBody.lowerBound + 4))
                    count += samples
                    var at = innerBody.lowerBound + 8
                    if flags & 0x1 != 0 { at += 4 }  // data-offset
                    if flags & 0x4 != 0 { at += 4 }  // first-sample-flags
                    let perSample =
                        (flags & 0x100 != 0 ? 4 : 0)  // duration
                        + (flags & 0x200 != 0 ? 4 : 0)  // size
                        + (flags & 0x400 != 0 ? 4 : 0)  // flags
                        + (flags & 0x800 != 0 ? 4 : 0)  // composition offset
                    for index in 0..<samples {
                        if flags & 0x100 != 0 {
                            total += UInt64(read32(data, at + index * perSample))
                        } else {
                            total += UInt64(defaultDuration)
                        }
                    }
                default:
                    break
                }
            }
            runs.append(
                TrackRun(trackID: trackID, baseDecode: base, duration: total, sampleCount: count))
        }
        return runs
    }

    /// Walks over the boxes of a range and descends into container boxes.
    private static func walkBoxes(
        _ data: Data, in range: Range<Data.Index>, path: [String],
        visit: ([String], Range<Data.Index>) -> Void
    ) {
        let containers: Set<String> = ["moof", "traf"]
        var at = range.lowerBound
        while at + 8 <= range.upperBound {
            let size = Int(read32(data, at))
            guard size >= 8, at + size <= range.upperBound else { return }
            let name = String(
                decoding: data[data.index(at, offsetBy: 4)..<data.index(at, offsetBy: 8)],
                as: UTF8.self)
            let body = (at + 8)..<(at + size)
            let full = path + [name]
            visit(full, body)
            if containers.contains(name) {
                walkBoxes(data, in: body, path: full, visit: visit)
            }
            at += size
        }
    }

    private static func read32(_ data: Data, _ at: Data.Index) -> UInt32 {
        (UInt32(data[at]) << 24) | (UInt32(data[at + 1]) << 16)
            | (UInt32(data[at + 2]) << 8) | UInt32(data[at + 3])
    }

    private static func read64(_ data: Data, _ at: Data.Index) -> UInt64 {
        (UInt64(read32(data, at)) << 32) | UInt64(read32(data, at + 4))
    }

    // MARK: - Die Messung

    /// Builds the file with "audio behind the picture": audio blocks are in the file only
    /// AFTER the next picture block — the interleaving with which Hollowmark is muxed. The
    /// window cut thereby puts the seam audio into the read range of the FOLLOWING window.
    private static func fileWithLaggedAudio() throws -> Data {
        let reader = MatroskaReader()
        let blocks = reader.read(try MatroskaTests.fixture("mkv-hevc-aac"))
        let video = reader.header.video?.number ?? 1

        var merged: [MatroskaReader.Block] = []
        var pendingAudio: [MatroskaReader.Block] = []
        for block in blocks {
            if block.track == video {
                merged.append(block)
                // Held-back audio follows only AFTER the picture — even after a keyframe that opens
                // a new cluster.
                merged.append(contentsOf: pendingAudio)
                pendingAudio.removeAll()
            } else {
                pendingAudio.append(block)
            }
        }
        merged.append(contentsOf: pendingAudio)
        return TestMatroskaFile.make(header: reader.header, blocks: merged, clusterSeconds: 1.0)
    }

    /// What the audio really carries per segment: start, end and packet count.
    ///
    /// **The care in it is no decoration** (AP6 · Q9, expert review 2026-08-24): the audio
    /// track is determined as "the run with the most packets". If a segment carries **no**
    /// audio, this rule chose the picture track — and the check then compared the picture
    /// against itself. It would have stayed green while exactly what it measures was
    /// missing.
    private static func audioRuns(
        of session: MatroskaFileSession, at base: URL
    ) async throws -> [(base: UInt64, end: UInt64, count: Int)] {
        var runs: [(base: UInt64, end: UInt64, count: Int)] = []
        /// The identifier of the audio track — the same across all segments.
        var audioTrack: UInt32?
        for index in 0..<session.pieceCount {
            let (bytes, _) = try await URLSession.shared.data(
                from: base.appendingPathComponent(RemuxPlaylist.segmentName(index)))
            let allRuns = Self.trackRuns(in: bytes)
            try #require(
                allRuns.count >= 2,
                "Piece \(index) carries only \(allRuns.count) track(s) — without audio there is no seam")
            let sortedEntries = allRuns.sorted { $0.sampleCount > $1.sampleCount }
            let sound = sortedEntries[0]
            // The difference must be clear: audio carries many small packets, the picture few
            // large ones. Measured on the test files they are at 379 to 194 and 245 to 125 —
            // just a factor of two. Half of that is required; where both are level, the
            // assignment is guessed and the number below it worthless.
            let clearly = sound.sampleCount * 4 > sortedEntries[1].sampleCount * 5
            try #require(clearly, "Piece \(index): audio and picture cannot be told apart")
            // The same track across all segments: a change of identifier would mean that two
            // different things are being compared.
            if let first = audioTrack {
                try #require(sound.trackID == first, "Piece \(index) switches the audio track")
            } else {
                audioTrack = sound.trackID
            }
            runs.append((sound.baseDecode, sound.baseDecode + sound.duration, sound.sampleCount))
        }
        return runs
    }

    /// How far the audio timeline may jump at a seam, in ticks.
    ///
    /// **There was a packet here, and that was exactly one too many** (2026-09-02, AP10/AP11):
    /// an AAC packet is 1024 ticks, and the check was `abs(gap) <= 1024` — the loss of
    /// **one** packet hits the threshold to the tick and got through. The check thereby
    /// let through exactly the case it was built for. Measured, the seam lies at most 16
    /// ticks (0.3 ms) apart — that is the writer's rounding between the time scales. 128
    /// ticks are plenty of room for that and stay an order of magnitude below a packet.
    static let seamRounding: Int64 = 128

    /// Checks the seams of a segment sequence.
    private static func expectContinuous(
        _ audio: [(base: UInt64, end: UInt64, count: Int)], _ what: String
    ) {
        for (index, pair) in zip(audio, audio.dropFirst()).enumerated() {
            let gap = Int64(pair.1.base) - Int64(pair.0.end)
            #expect(
                abs(gap) <= Self.seamRounding,
                "\(what), seam \(index): audio jumps by \(gap) ticks (hole > 0, overlap < 0)")
        }
    }

    /// Counts the audio packets of an MKV file — the fed-in side.
    private static func audioFrameCount(in file: Data) throws -> Int {
        let reader = MatroskaReader()
        let blocks = reader.read(file)
        let track = try #require(reader.header.audioTracks.first?.number)
        let count = blocks.filter { $0.track == track }.reduce(0) { $0 + $1.frames.count }
        try #require(count > 0, "the test file carries no audio")
        return count
    }

    // MARK: - Die Regel selbst, ohne Uhr

    /// Zeit in Sekunden, in CoreMedias Rechnung.
    private static func t(_ seconds: Double) -> CMTime {
        CMTime(seconds: seconds, preferredTimescale: CMTimeScale(NSEC_PER_SEC))
    }

    @Test("Audio behind the last picture waits, audio before it passes")
    func audioBeyondTheLastPictureWaits() {
        // The normal case: the audio lies behind the picture that is already written — it
        // may pass.
        #expect(
            MatroskaRemuxer.audioPath(time: Self.t(1.0), lastFrame: Self.t(1.5)) == .passThrough)
        // **The boundary belongs to passing**, otherwise the packet would lie there forever
        // at the timestamp of the picture.
        #expect(
            MatroskaRemuxer.audioPath(time: Self.t(1.5), lastFrame: Self.t(1.5)) == .passThrough)
        // The Hollowmark case: at the window end the audio extends beyond the last picture.
        // Passed through, it expires within the writer's deadline.
        #expect(
            MatroskaRemuxer.audioPath(time: Self.t(1.6), lastFrame: Self.t(1.5)) == .holdBack)
        // And at the head of a window, before a picture has been there: wait as well.
        #expect(MatroskaRemuxer.audioPath(time: Self.t(0.0), lastFrame: nil) == .holdBack)
    }
}
