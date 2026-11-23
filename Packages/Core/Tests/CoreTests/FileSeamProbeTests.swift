import CoreMedia
import Foundation
import Testing

@testable import Core

/// The seam probe: compares the finished pieces of the file remuxer with the
/// **reference list of frames from ffprobe** — which presentation times are missing,
/// which are duplicated, and whether the audio joins up gaplessly at the seam.
///
/// Runs only with `PROBE_MKV=<URL>`, `PROBE_PIECES=<first,last>` and
/// `PROBE_SOLL=<csv>` — the reference list is produced on the server:
///
///     ffprobe -v error -select_streams v:0 -read_intervals 2228%2262 \
///         -show_entries packet=pts_time,dts_time,pos,flags -of csv=p=0 datei.mkv
///
/// **Why a reference list from outside** (F-023, 2026-09-05): The probe over the
/// pieces alone saw "1992×2" and attributed it to the source. Only the comparison
/// with what is in the file showed: the source is gapless, the
/// frames were missing at the seam — the trailing read ended before the keyframe.
struct FileSeamProbeTests {
    @Test("Seam probe against ffprobe") func probe() async throws {
        guard let address = ProcessInfo.processInfo.environment["PROBE_MKV"], let url = URL(string: address),
            let expectedPath = ProcessInfo.processInfo.environment["PROBE_SOLL"]
        else { return }
        let area = (ProcessInfo.processInfo.environment["PROBE_PIECES"] ?? "590,594").split(separator: ",")
            .compactMap { Int($0) }
        let expectedValue = try String(contentsOfFile: expectedPath, encoding: .utf8)
            .split(separator: "\n").compactMap { row -> (pts: Double, key: Bool)? in
                let fields = row.split(separator: ",", omittingEmptySubsequences: false)
                guard fields.count >= 4, let pts = Double(fields[0]) else { return nil }
                return (pts, fields[3].contains("K"))
            }
        let expectedKeys = expectedValue.filter(\.key).map(\.pts).sorted()
        let expectedPTS = expectedValue.map(\.pts).sorted()

        let session = try MatroskaFileSession(source: HTTPByteRangeSource(url: url))
        let asset = try await session.start()
        print("PROBE " + session.timeGridReport)
        let (listData, _) = try await URLSession.shared.data(from: asset)
        let rows = String(decoding: listData, as: UTF8.self).split(separator: "\n").map(String.init)
        let segments = rows.filter { !$0.hasPrefix("#") }
        let headLine = rows.first { $0.hasPrefix("#EXT-X-MAP") } ?? ""
        let headName = headLine.split(separator: "\"").dropFirst().first.map(String.init) ?? "header.mp4"
        let basis = asset.deletingLastPathComponent()
        func resolve(_ name: String) -> URL {
            URL(string: name).flatMap { $0.scheme != nil ? $0 : nil } ?? basis.appendingPathComponent(name)
        }
        let (header, _) = try await URLSession.shared.data(from: resolve(headName))
        let ts = TimelineProbeTests.timescales(header)
        let videoBase = Double(ts[1] ?? 90_000)

        var audioEnd: Double?
        var totalMissing = 0
        var offset: Double?
        for n in area[0]...area[area.count - 1] where n < segments.count {
            let started = Date()
            let (seg, _) = try await URLSession.shared.data(from: resolve(segments[n]))
            var pts: [Double] = []
            var audioGap: Double?
            for (_, body) in TimelineProbeTests.boxes(seg).filter({ $0.0 == "moof" }) {
                for f in TimelineProbeTests.fragments(body) {
                    if f.track == 1 {
                        var dts = f.start
                        for (i, d) in f.durations.enumerated() {
                            pts.append(Double(dts + f.cts[i]) / videoBase)
                            dts += d
                        }
                    } else if f.track == 2 {
                        let scale = Double(ts[f.track] ?? 48000)
                        let start = Double(f.start) / scale
                        if let audioEnd, audioGap == nil { audioGap = start - audioEnd }
                        audioEnd = Double(f.start + f.durations.reduce(0, +)) / scale
                    }
                }
            }
            pts.sort()
            guard let first = pts.first, let last = pts.last else {
                print("PROBE piece \(n): no frames")
                continue
            }
            // The reorder delay is a whole number of frames; it is determined from the
            // first piece by the distance to the nearest keyframe of the
            // reference list and then kept fixed.
            if offset == nil {
                let step = 1001.0 / 24000.0
                let nextKey = expectedKeys.min { abs($0 - first) < abs($1 - first) } ?? first
                offset = ((first - nextKey) / step).rounded() * step
            }
            let v = offset ?? 0
            let raw = pts.map { $0 - v }
            // Expected: all frames from this keyframe up to the next one.
            // Expected window: from the keyframe of this piece up to the first
            // keyframe after its last frame — a piece can carry several
            // groups of pictures.
            guard let from = expectedKeys.min(by: { abs($0 - raw[0]) < abs($1 - raw[0]) }),
                let rearmost = raw.last
            else { continue }
            let upper = expectedKeys.first { $0 > rearmost + 0.001 } ?? .infinity
            let expected = expectedPTS.filter { $0 >= from - 0.001 && $0 < upper - 0.001 }
            var missing: [Double] = []
            var rest = raw
            for e in expected {
                if let i = rest.firstIndex(where: { abs($0 - e) < 0.002 }) {
                    rest.remove(at: i)
                } else {
                    missing.append(e)
                }
            }
            totalMissing += missing.count
            let missingText =
                missing.isEmpty
                ? "complete"
                : "MISSING \(missing.count): "
                    + missing.prefix(8).map { String(format: "%.3f", $0) }.joined(separator: " ")
            let extraText = rest.isEmpty ? "" : " | SURPLUS \(rest.count)"
            let audioText = audioGap.map { String(format: " | audio seam %+.0f ms", $0 * 1000) } ?? ""
            print(
                String(
                    format:
                        "PROBE piece %d (%d KB in %.0f s): picture %.3f–%.3f n%d, expected %.3f–<%.3f n%d — ",
                    n, seg.count / 1024, Date().timeIntervalSince(started), raw.first ?? 0, raw.last ?? 0,
                    raw.count, from, upper, expected.count) + missingText + extraText + audioText)
            _ = last
        }
        print("PROBE END missing frames in total: \(totalMissing)")
        session.stop()
    }
}
