import AVFoundation
import Foundation
import Testing

@testable import Core

/// The live-edge probe: feeds a recording at PCR rate into the remuxer and
/// lets AVPlayer play along at the edge — stall ticks, jumps, stalls.
/// Runs only with `PROBE_TS=<Intake.ts>`; `PROBE_LEAD=<s>` is the lead
/// at start (probe 2026-09-04: 1 s → every second run a stall, 3 s → zero).
struct LiveRandSondeTests {
    static func pcrIndex(_ d: Data) -> [(Double, Int)] {
        var out: [(Double, Int)] = []; var pcr0: Int64 = -1; let n = d.count / 188
        d.withUnsafeBytes { raw in
            let p = raw.bindMemory(to: UInt8.self)
            for i in 0..<n {
                let b = i * 188
                if p[b + 3] & 0x20 != 0, p[b + 4] > 0, p[b + 5] & 0x10 != 0 {
                    let c =
                        Int64(p[b + 6]) << 25 | Int64(p[b + 7]) << 17 | Int64(p[b + 8]) << 9 | Int64(p[b + 9])
                        << 1 | Int64(p[b + 10]) >> 7
                    if pcr0 < 0 { pcr0 = c }; out.append((Double(c - pcr0) / 90000.0, (i + 1) * 188))
                }
            }
        }
        return out
    }
    @MainActor @Test("PCR edge probe") func probe() async throws {
        guard let path = ProcessInfo.processInfo.environment["PROBE_TS"] else { return }
        let data = try Data(contentsOf: URL(fileURLWithPath: path)); let idx = Self.pcrIndex(data)
        let store = SegmentStore(label: "S"); let remuxer = TransportRemuxer(store: store, writer: .own)
        let stream = try RemuxStream(store: store, isLive: true); let start = Date()
        let f = Task {
            var last = 0;
            for (w, o) in idx {
                let wa = start.addingTimeInterval(w).timeIntervalSinceNow;
                if wa > 0 { try? await Task.sleep(for: .seconds(wa)) };
                if o > last { remuxer.feed(data.subdata(in: last..<o)); last = o }
            }
        }
        let lead = Double(ProcessInfo.processInfo.environment["PROBE_LEAD"] ?? "0") ?? 0
        for _ in 0..<400 where !store.isReady || store.seconds < lead {
            try? await Task.sleep(for: .milliseconds(50))
        }
        print(
            "PROBE START after \(String(format: "%.1f", Date().timeIntervalSince(start))) s with \(String(format: "%.1f", store.seconds)) s buffered"
        )
        try await stream.start(); let item = AVPlayerItem(url: stream.assetURL);
        let player = AVPlayer(playerItem: item); player.volume = 0
        for _ in 0..<200 where item.status == .unknown { try? await Task.sleep(for: .milliseconds(50)) }
        player.play(); var lz = -1.0, still = 0, jumps = 0, lw = Date()
        for _ in 0..<170 {
            try? await Task.sleep(for: .milliseconds(500)); if Date().timeIntervalSince(start) > 88 { break }
            let t = item.currentTime().seconds; let dw = Date().timeIntervalSince(lw); lw = Date()
            if lz >= 0, player.rate > 0 {
                if abs(t - lz) < 0.05 { still += 1 }; if t - lz > dw + 0.4 { jumps += 1 }
            }
            lz = t
        }
        let a = item.accessLog()?.events.last
        print(
            "PROBE END still \(still) jumps \(jumps) stalls \(a?.numberOfStalls ?? -1) report: \(remuxer.timestampReport)"
        )
        f.cancel(); stream.stop()
    }
}
