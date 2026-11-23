import AVFoundation
import CoreMedia
import Foundation
import Testing

@testable import Core

/// The playback probe for files: runs an MKV through the file remuxer and
/// lets AVPlayer play along from a given position — stalls, jumps, the
/// measured frame rate and the offset between the displayed picture and the audio clock.
/// Runs only with `PROBE_MKV=<URL>`, `PROBE_START=<s>` and `PROBE_DURATION=<s>`.
struct FilePlaybackProbeTests {
    @MainActor @Test("Playback probe") func probe() async throws {
        guard let address = ProcessInfo.processInfo.environment["PROBE_MKV"], let url = URL(string: address)
        else { return }
        let startAt = Double(ProcessInfo.processInfo.environment["PROBE_START"] ?? "1900") ?? 1900
        let duration = Double(ProcessInfo.processInfo.environment["PROBE_DURATION"] ?? "120") ?? 120
        let session = try MatroskaFileSession(
            source: HTTPByteRangeSource(url: url, session: HTTPByteRangeSource.parallelSession))
        // `PROBE_WRITER=system` compares the system writer under the
        // same conditions.
        if ProcessInfo.processInfo.environment["PROBE_WRITER"] == "system" { session.writer = .system }
        // `PROBE_WORKERS=<n>` measures what parallel requests do to the disk.
        if let n = ProcessInfo.processInfo.environment["PROBE_WORKERS"].flatMap(Int.init) {
            session.readAheadWorkers = n
        }
        // What the remuxer needs per piece — fetching and remuxing measured
        // separately — tells whether a stall is down to the network, the writer or the player.
        final class BuildTimes: @unchecked Sendable {
            private let lock = NSLock()
            private var rows: [(Int, Int, TimeInterval, TimeInterval)] = []
            func memorize(_ z: (Int, Int, TimeInterval, TimeInterval)) {
                lock.lock()
                rows.append(z)
                lock.unlock()
            }
            var all: [(Int, Int, TimeInterval, TimeInterval)] {
                lock.lock()
                defer { lock.unlock() }
                return rows
            }
        }
        let buildTimes = BuildTimes()
        session.onProduced = { index, bytes, fetch, repackTime in
            buildTimes.memorize((index, bytes, fetch, repackTime))
        }
        let asset = try await session.start()
        print(
            "PROBE " + session.timeGridReport
                + " — writer \(session.writer), workers \(session.readAheadWorkers)")
        let item = AVPlayerItem(url: asset)
        let output = AVPlayerItemVideoOutput(pixelBufferAttributes: nil)
        item.add(output)
        let player = AVPlayer(playerItem: item)
        player.volume = 0
        for _ in 0..<400 where item.status == .unknown { try? await Task.sleep(for: .milliseconds(50)) }
        await player.seek(
            to: CMTime(seconds: startAt, preferredTimescale: 90_000), toleranceBefore: CMTime.zero,
            toleranceAfter: CMTime.positiveInfinity)
        player.play()
        let start = Date()
        var lastTime = -1.0, still = 0, jumps = 0, lastWall = Date(), lastReport = Date(),
            samples: [String] = []
        var waiting = 0
        var maxDrift = 0.0, minDrift = 0.0
        while Date().timeIntervalSince(start) < duration {
            try? await Task.sleep(for: .milliseconds(250))
            let t = item.currentTime().seconds
            if player.timeControlStatus == .waitingToPlayAtSpecifiedRate { waiting += 1 }
            let wallDelta = Date().timeIntervalSince(lastWall); lastWall = Date()
            if lastTime >= 0, player.rate > 0 {
                if abs(t - lastTime) < 0.05 { still += 1 }
                if t - lastTime > wallDelta + 0.4 { jumps += 1 }
            }
            lastTime = t
            let host = CACurrentMediaTime()
            let itemTime = output.itemTime(forHostTime: host)
            var shown = CMTime.invalid
            if output.hasNewPixelBuffer(forItemTime: itemTime),
                output.copyPixelBuffer(forItemTime: itemTime, itemTimeForDisplay: &shown) != nil,
                shown.isNumeric
            {
                let drift = (shown.seconds - t)
                maxDrift = max(maxDrift, drift); minDrift = min(minDrift, drift)
                if Date().timeIntervalSince(lastReport) >= 10 {
                    lastReport = Date()
                    let rate = item.tracks.map(\.currentVideoFrameRate).max() ?? 0
                    samples.append(
                        String(format: "t=%.1f picture−audio %+.0f ms rate %.2f", t, drift * 1000, rate))
                }
            }
        }
        let a = item.accessLog()?.events.last
        let build = buildTimes.all
        let fetches = build.map(\.2).sorted()
        let repackTime = build.map(\.3).sorted()
        if !build.isEmpty {
            print(
                String(
                    format:
                        "PROBE build: %d pieces, %.1f MB, fetch median %.0f ms max %.0f ms, remux median %.0f ms max %.0f ms",
                    build.count, Double(build.map(\.1).reduce(0, +)) / 1e6, fetches[fetches.count / 2] * 1000,
                    (fetches.last ?? 0) * 1000, repackTime[repackTime.count / 2] * 1000,
                    (repackTime.last ?? 0) * 1000))
            for z in build where z.2 > 2 || z.3 > 1 {
                print(
                    String(
                        format: "PROBE   piece %d: %d KB, fetch %.0f ms, remux %.0f ms", z.0, z.1 / 1024,
                        z.2 * 1000, z.3 * 1000))
            }
        }
        print(
            "PROBE END still \(still) waiting \(waiting) jumps \(jumps) stalls \(a?.numberOfStalls ?? -1) dropped \(a?.numberOfDroppedVideoFrames ?? -1) drift min \(String(format: "%+.0f", minDrift * 1000)) max \(String(format: "%+.0f", maxDrift * 1000)) ms"
        )
        for p in samples { print("PROBE   " + p) }
        session.stop()
    }
}
