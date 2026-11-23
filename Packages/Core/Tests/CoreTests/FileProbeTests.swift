import CoreMedia
import Foundation
import Testing

@testable import Core

/// The file probe: runs an MKV through the file remuxer (as in the player) and
/// measures the finished pieces — frame durations, audio start and end per piece,
/// overlap at the seam. Runs only with `PROBE_MKV=<URL>` and
/// `PROBE_PIECES=<first,last>`.
struct FileProbeTests {
    @Test("File probe") func probe() async throws {
        guard let address = ProcessInfo.processInfo.environment["PROBE_MKV"], let url = URL(string: address)
        else { return }
        let area = (ProcessInfo.processInfo.environment["PROBE_PIECES"] ?? "473,474").split(separator: ",")
            .compactMap { Int($0) }
        let session = try MatroskaFileSession(source: HTTPByteRangeSource(url: url))
        let asset = try await session.start()
        print("PROBE " + session.timeGridReport)
        let (listeDaten, _) = try await URLSession.shared.data(from: asset)
        let list = String(decoding: listeDaten, as: UTF8.self)
        let rows = list.split(separator: "\n").map(String.init)
        let segments = rows.filter { !$0.hasPrefix("#") }
        let headLine = rows.first { $0.hasPrefix("#EXT-X-MAP") } ?? ""
        let headName = headLine.split(separator: "\"").dropFirst().first.map(String.init) ?? "header.mp4"
        let basis = asset.deletingLastPathComponent()
        func resolve(_ name: String) -> URL {
            URL(string: name).flatMap { $0.scheme != nil ? $0 : nil } ?? basis.appendingPathComponent(name)
        }
        print("PROBE list: " + rows.prefix(6).joined(separator: " ¦ "))
        let (header, _) = try await URLSession.shared.data(from: resolve(headName))
        let ts = TimelineProbeTests.timescales(header)
        print("PROBE pieces in list: \(segments.count), Zeitbasen \(ts)")
        var prevEnd: [UInt32: Double] = [:]
        var prevMaxPTS: Double?
        for n in area[0]...area[area.count - 1] where n < segments.count {
            let since = Date()
            let (seg, _) = try await URLSession.shared.data(from: resolve(segments[n]))
            var description: [String] = []
            for (_, body) in TimelineProbeTests.boxes(seg).filter({ $0.0 == "moof" }) {
                for f in TimelineProbeTests.fragments(body) {
                    let scale = Double(ts[f.track] ?? 1)
                    let start = Double(f.start) / scale
                    let end = Double(f.start + f.durations.reduce(0, +)) / scale
                    var hist: [Int64: Int] = [:]
                    for d in f.durations { hist[d, default: 0] += 1 }
                    let name = f.track == 1 ? "video" : "audio"
                    let seam = prevEnd[f.track].map { String(format: " seam %+.3f", start - $0) } ?? ""
                    prevEnd[f.track] = end
                    description.append(
                        String(
                            format: "%@ %.3f–%.3f n%d durations %@%@ cts %d…%d", name, start, end,
                            f.durations.count,
                            hist.sorted { $0.key < $1.key }.map { "\($0.key)×\($0.value)" }.joined(
                                separator: " "), seam, f.ctsMin, f.ctsMax))
                }
            }
            // Darstellungszeiten: Dekodierzeit kumuliert plus cts-Versatz, sortiert.
            var pts: [Double] = []
            for (_, body) in TimelineProbeTests.boxes(seg).filter({ $0.0 == "moof" }) {
                for f in TimelineProbeTests.fragments(body) where f.track == 1 {
                    let scale = Double(ts[1] ?? 600)
                    var dts = f.start
                    for (i, d) in f.durations.enumerated() {
                        pts.append(Double(dts + f.cts[i]) / scale); dts += d
                    }
                }
            }
            // Where the hole sits: decode times and presentation times around each quadruple duration.
            for (_, body) in TimelineProbeTests.boxes(seg).filter({ $0.0 == "moof" }) {
                for f in TimelineProbeTests.fragments(body) where f.track == 1 {
                    let scale = Double(ts[1] ?? 600); var dts = f.start;
                    var row: [(Int, Double, Double)] = []
                    for (i, d) in f.durations.enumerated() {
                        row.append((i, Double(dts) / scale, Double(dts + f.cts[i]) / scale)); dts += d
                    }
                    let median = f.durations.sorted()[f.durations.count / 2]
                    for (i, d) in f.durations.enumerated() where d > median * 2 {
                        let um = row[max(0, i - 3)...min(row.count - 1, i + 3)].map {
                            String(format: "#%d dts %.3f pts %.3f", $0.0, $0.1, $0.2)
                        }
                        print(
                            "PROBE   fourfold duration at sample \(i) of \(f.durations.count): "
                                + um.joined(separator: " | "))
                    }
                }
            }
            pts.sort()
            let deltas = zip(pts, pts.dropFirst()).map { ($1 - $0) * 1000 }
            var hist: [String: Int] = [:]
            for d in deltas { hist[String(format: "%.1f", d), default: 0] += 1 }
            let seam =
                prevMaxPTS.map { String(format: " PTS seam %+.1f ms", ((pts.first ?? 0) - $0) * 1000) } ?? ""
            prevMaxPTS = pts.last
            print(
                "PROBE piece \(n) (\(seg.count / 1024) KB in \(String(format: "%.0f", Date().timeIntervalSince(since))) s): "
                    + description.joined(separator: " | "))
            print(
                "PROBE   PTS gaps ms: "
                    + hist.sorted { Double($0.key)! < Double($1.key)! }.map { "\($0.key)×\($0.value)" }
                    .joined(separator: " ") + seam)
        }
    }
}
