import AVFoundation
import CoreMedia
import Foundation
import Testing

@testable import Core

/// **The proof that counts: AVFoundation really plays our stream.**
///
/// The tests next to it show that the parts are right — playlist, segment store,
/// valid fMP4. This one asks the only thing that matters in the end: does an
/// `AVPlayerItem` accept the stream?
///
/// **Why this runs on the computer and not on the TV.** The error `-12881` could
/// only be seen on the device until 2026-08-09: build, install, try, read the log — ten
/// minutes per attempt, and so people guessed instead of searching. AVFoundation is
/// the same tool on macOS; here the same error shows up in a tenth of a second. For
/// the first time the log thereby gave a reason instead of a number:
/// `custom url not redirect`.
@Suite("Playback: AVFoundation accepts our stream")
struct RemuxPlaybackTests {

    /// Fills a segment store from the test material — with the **reported** durations.
    ///
    /// - Parameter withAudio: Whether the audio track goes along. Switchable separately,
    ///   so that on a failure it is immediately clear whether it lies with the audio.
    private func filledStore(withAudio: Bool = false) async throws -> SegmentStore {
        let url = try #require(
            Bundle.module.url(forResource: "Fixtures/hevc-live-long", withExtension: "ts")
        )
        let data = try Data(contentsOf: url)
        let video = try #require(TransportStream.inventory(from: data).video)

        let stream = TransportStream.elementaryStream(from: data, pid: video.pid)
        let sets = TransportStream.parameterSets(
            in: TransportStream.units(inElementaryStream: stream), kind: video.kind)
        let format = try SampleAssembly.formatDescription(from: sets, kind: video.kind)

        // The audio needs its description before the head is written — so from the first
        // frame the stream yields.
        var audioFormat: CMFormatDescription?
        var audioPayloads: [TransportStream.ElementaryPayload] = []
        if withAudio, let audio = TransportStream.inventory(from: data).audio {
            audioPayloads = TransportStream.payloads(from: data, pid: audio.pid)
            if let header = audioPayloads.lazy
                .compactMap({ AudioAssembly.frames(in: $0.data).first?.header }).first
            {
                audioFormat = try AudioAssembly.formatDescription(for: header)
            }
        }

        let store = SegmentStore()
        let writer = try FragmentWriter(format: format, audioFormat: audioFormat) { segment in
            if segment.isInitialization {
                store.setHeader(segment.data)
            } else {
                store.append(segment.data, duration: segment.duration)
            }
        }

        // **Interleaved by time and not track by track.** The writer stores both
        // interleaved; whoever feeds in all pictures first and then all audio accumulates
        // the lead in memory — and whatever lies before the session start is lost
        // completely.
        var pending: [(time: CMTime, isAudio: Bool, sample: CMSampleBuffer)] = []

        for unit in TransportStream.accessUnits(from: data, pid: video.pid) {
            guard
                let sample = try? SampleAssembly.sampleBuffer(
                    for: unit, kind: video.kind, format: format)
            else { continue }
            pending.append((sample.presentationTimeStamp, false, sample))
        }
        if let audioFormat {
            for payload in audioPayloads {
                guard let samples = try? AudioAssembly.sampleBuffers(in: payload, format: audioFormat)
                else { continue }
                for sample in samples {
                    pending.append((sample.presentationTimeStamp, true, sample))
                }
            }
        }

        for entry in pending.sorted(by: { $0.time < $1.time }) {
            _ = entry.isAudio ? writer.appendAudio(entry.sample) : writer.append(entry.sample)
        }
        await writer.finish()

        return store
    }

    /// Waits until the playback target is ready or has rejected.
    private func outcome(of item: AVPlayerItem, seconds: Double = 15) async -> AVPlayerItem.Status {
        let deadline = Date().addingTimeInterval(seconds)
        while item.status == .unknown, Date() < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
        return item.status
    }
}

/// **When a channel starts — by airtime, not by number of segments.**
///
/// The recording of Telve 1 HEVC (2026-08-11) refuted the assumption on which the old rule
/// stood: how long a segment becomes is determined by the **channel** via its
/// keyframe interval and not by ``FragmentWriter/segmentDuration``. Measured, 10 s,
/// 5 s, 5 s, 5 s … came out — "three segments" were fifteen seconds of store there,
/// and that is exactly how long the viewer saw nothing.
@Suite("Startup of a channel")
struct LiveReadinessTests {

    private func enough(_ durations: [Double]) -> Bool {
        LiveRemuxSession.hasEnough(
            pieces: durations.count,
            seconds: durations.reduce(0, +),
            wantedPieces: LiveRemuxSession.defaultReadySegments,
            wantedSeconds: LiveRemuxSession.defaultReadySeconds
        )
    }

    @Test("Long pieces let it start sooner")
    func longPiecesStartSooner() {
        // The first two segments of the real channel are fifteen seconds of broadcast —
        // waiting for the third costs only startup time.
        #expect(enough([10, 5]))
    }

    @Test("Short pieces wait for three seconds of broadcast")
    func shortPiecesWaitForSeconds() {
        // **Three seconds, not two segments** (probe 2026-09-04, evening): with segments of half
        // a second the player started with two segments — one second of lead — and ran
        // into the edge with real-time channels. Three target durations are the rule of the
        // HLS specification; the probe showed six of six runs without a stall. One alone
        // stays too little — the lesson of 2026-08-15.
        #expect(!enough([1]))
        #expect(!enough([1, 1]))
        #expect(!enough([0.5, 0.5, 0.5, 0.5, 0.5]))
        #expect(enough([0.5, 0.5, 0.5, 0.5, 0.5, 0.5]))
        #expect(enough([1, 1, 1]))
    }

    @Test("Without a single piece nothing starts")
    func nothingWithoutAPiece() {
        // A playlist without a segment is formally valid — the player accepts it and then
        // silently waits for content that it considers present.
        #expect(!enough([]))
    }

    /// **Never with a single segment** (device finding 2026-08-15, seventh evening test): the
    /// first UHD segment fulfilled the airtime rule alone, the player started with zero
    /// margin and starved at the segment end — dropouts at 0:00, buffer level at 0:09
    /// and 0:29, three times the same handwriting in one diagnosis.
    @Test("A single piece never suffices, however long it is")
    func aSinglePieceNeverSuffices() {
        #expect(!enough([10]))
        #expect(!enough([20]))
        #expect(enough([10, 10]))
    }
}
