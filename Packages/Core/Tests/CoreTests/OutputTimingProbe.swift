import AVFoundation
import Foundation
import Testing

@testable import Core

/// Throwaway probe: the frame times of the REMUXED output.
@Suite("Output timing probe")
struct OutputTimingProbe {
    @Test("Check the output's frame times")
    func videoTiming() async throws {
        guard let path = ProcessInfo.processInfo.environment["CINELOUNGE_TS"] else { return }
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let store = SegmentStore(label: "probe", logsProduction: false)
        let remuxer = TransportRemuxer(store: store)
        var offset = 0
        while offset < data.count {
            let end = min(offset + 65536, data.count)
            remuxer.feed(data.subdata(in: offset..<end))
            offset = end
        }
        await remuxer.finish()
        var file = store.headerData ?? Data()
        for i in 0..<store.count { file += store.segment(i) ?? Data() }
        let out = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("timing.mp4")
        try file.write(to: out)
        let asset = AVURLAsset(url: out)
        let video = try #require(try await asset.load(.tracks).first { $0.mediaType == .video })
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: video, outputSettings: nil)
        reader.add(output)
        _ = reader.startReading()
        var times: [Double] = []
        while let sample = output.copyNextSampleBuffer() {
            let t = sample.presentationTimeStamp
            if t.isValid { times.append(t.seconds) }
        }
        let sorted = times.sorted()
        var gaps: [Double] = []
        for (a, b) in zip(sorted, sorted.dropFirst()) { gaps.append(b - a) }
        let big = gaps.filter { $0 > 0.06 }
        let doubled = gaps.filter { $0 < 0.005 }
        print(
            "Timing probe: \(times.count) frames, span \(String(format: "%.2f", (sorted.last ?? 0) - (sorted.first ?? 0)))s"
        )
        print(
            "Timing probe: gaps min \(String(format: "%.4f", gaps.min() ?? 0)) max \(String(format: "%.4f", gaps.max() ?? 0)), >60ms: \(big.count), duplicates: \(doubled.count)"
        )
        print("Timing probe: first 12 gaps: \(gaps.prefix(12).map { String(format: "%.3f", $0) })")
    }
}
