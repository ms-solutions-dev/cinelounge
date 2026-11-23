import CoreMedia
import Foundation
import Testing

@testable import Core

/// The timeline probe: measures tfdt and trun of the finished chunks of a recording.
///
/// Runs only with `PROBE_TS=<Intake.ts>` (plus `PROBE_WRITER=system` for the
/// system writer) and prints sound and picture gaps, the offset sound end − picture end
/// per chunk, and the histogram of chunk durations. On 2026-09-04 it found the 53
/// holes in the AC-3 sound of TELE MOOS that no on-device test could see.
struct TimelineProbeTests {
    struct Box { let type: String; let body: Data; let version: UInt8; let flags: UInt32 }
    static func boxes(_ d: Data) -> [(String, Data)] {
        var out: [(String, Data)] = []; var i = d.startIndex
        while i + 8 <= d.endIndex {
            let size = Int(d.u32(i)); let type = String(bytes: d[i + 4..<i + 8], encoding: .ascii) ?? "?"
            guard size >= 8, i + size <= d.endIndex else { break }
            out.append((type, d[i + 8..<i + size])); i += size
        }
        return out
    }
    static func find(_ d: Data, _ path: [String]) -> [Data] {
        var level = [d]
        for p in path { level = level.flatMap { boxes($0).filter { $0.0 == p }.map { $0.1 } } }
        return level
    }
    struct Frag {
        var track: UInt32; var start: Int64; var durations: [Int64]; var ctsMin: Int64; var ctsMax: Int64
        var cts: [Int64] = []
    }
    static func fragments(_ moofBody: Data) -> [Frag] {
        var out: [Frag] = []
        for traf in boxes(moofBody).filter({ $0.0 == "traf" }).map({ $0.1 }) {
            var track: UInt32 = 0; var defDur: Int64 = 0; var start: Int64 = 0; var durs: [Int64] = [];
            var ctsList: [Int64] = [];
            var cmin = Int64.max; var cmax = Int64.min
            for (t, b) in boxes(traf) {
                let full = b.u32(b.startIndex); let ver = UInt8(full >> 24); let flags = full & 0xFFFFFF
                switch t {
                case "tfhd":
                    track = b.u32(b.startIndex + 4); var o = b.startIndex + 8
                    if flags & 1 != 0 { o += 8 }; if flags & 2 != 0 { o += 4 }
                    if flags & 8 != 0 { defDur = Int64(b.u32(o)) }
                case "tfdt":
                    start =
                        ver == 1 ? Int64(bitPattern: b.u64(b.startIndex + 4)) : Int64(b.u32(b.startIndex + 4))
                case "trun":
                    let n = Int(b.u32(b.startIndex + 4)); var o = b.startIndex + 8
                    if flags & 1 != 0 { o += 4 }; if flags & 4 != 0 { o += 4 }
                    for _ in 0..<n {
                        var dur = defDur
                        if flags & 0x100 != 0 { dur = Int64(b.u32(o)); o += 4 }
                        if flags & 0x200 != 0 { o += 4 }
                        if flags & 0x400 != 0 { o += 4 }
                        var c: Int64 = 0
                        if flags & 0x800 != 0 {
                            c = ver == 1 ? Int64(Int32(bitPattern: b.u32(o))) : Int64(b.u32(o));
                            cmin = min(cmin, c); cmax = max(cmax, c); o += 4
                        }
                        ctsList.append(c)
                        durs.append(dur)
                    }
                default: break
                }
            }
            out.append(
                Frag(
                    track: track, start: start, durations: durs, ctsMin: cmin == .max ? 0 : cmin,
                    ctsMax: cmax == .min ? 0 : cmax, cts: ctsList))
        }
        return out
    }
    static func timescales(_ header: Data) -> [UInt32: UInt32] {
        var map: [UInt32: UInt32] = [:]
        for trak in find(header, ["moov", "trak"]) {
            guard let tkhd = find(trak, ["tkhd"]).first, let mdhd = find(trak, ["mdia", "mdhd"]).first else {
                continue
            }
            let tv = tkhd[tkhd.startIndex];
            let id = tv == 1 ? tkhd.u32(tkhd.startIndex + 20) : tkhd.u32(tkhd.startIndex + 12)
            let mv = mdhd[mdhd.startIndex];
            let ts = mv == 1 ? mdhd.u32(mdhd.startIndex + 20) : mdhd.u32(mdhd.startIndex + 12)
            map[id] = ts
        }
        return map
    }

    @Test("Timeline of the pieces") func timeline() async throws {
        guard let path = ProcessInfo.processInfo.environment["PROBE_TS"] else { return }
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let store = SegmentStore(retainsEverything: true, label: "Z", logsProduction: false)
        let remuxer = TransportRemuxer(
            store: store,
            writer: ProcessInfo.processInfo.environment["PROBE_WRITER"] == "system" ? .system : .own)
        var i = 0; let step = 188 * 2000
        while i < data.count { remuxer.feed(data.subdata(in: i..<min(i + step, data.count))); i += step }
        await remuxer.finish()
        guard let header = store.headerData else { print("PROBE no header"); return }
        let ts = Self.timescales(header)
        print(
            "PROBE header: timebases \(ts), pieces \(store.count), airtime \(String(format: "%.2f", store.seconds)) s, report: \(remuxer.timestampReport)"
        )
        var prevEnd: [UInt32: Int64] = [:]; var audioGaps: [(Int, Double)] = [];
        var videoGaps: [(Int, Double)] = []
        var offsets: [Double] = []; var lines: [String] = []
        for n in 0..<store.count {
            guard let seg = store.segment(n) else { continue }
            let moofs = Self.boxes(seg).filter { $0.0 == "moof" }
            var vEnd: Double?; var aEnd: Double?; var desc: [String] = []
            for (_, body) in moofs {
                for f in Self.fragments(body) {
                    let scale = Double(ts[f.track] ?? 1)
                    let end = f.start + f.durations.reduce(0, +)
                    let gap = prevEnd[f.track].map { Double(f.start - $0) / scale }
                    prevEnd[f.track] = end
                    let name = f.track == 1 ? "V" : "A"
                    if f.track == 1 {
                        vEnd = Double(end) / scale;
                        if let gap, abs(gap) > 0.0005 { videoGaps.append((n, gap)) }
                    } else {
                        aEnd = Double(end) / scale;
                        if let gap, abs(gap) > 0.0005 { audioGaps.append((n, gap)) }
                    }
                    let uniq = Set(f.durations)
                    desc.append(
                        String(
                            format: "%@ %.3f–%.3f n%d d%@%@", name, Double(f.start) / scale,
                            Double(end) / scale, f.durations.count,
                            uniq.count == 1 ? "\(uniq.first!)" : "var(\(uniq.sorted().prefix(4)))",
                            gap.map { String(format: " gap%+.3f", $0) } ?? ""))
                }
            }
            if let vEnd, let aEnd { offsets.append(aEnd - vEnd) }
            if n < 12
                || !desc.isEmpty && (desc.joined().contains("gap") && !desc.joined().contains("gap+0.000"))
            {
                lines.append("piece \(n): " + desc.joined(separator: " | "))
            }
        }
        for l in lines.prefix(60) { print("PROBE " + l) }
        var histogram: [String: Int] = [:]
        for n in 0..<store.count {
            if let seg = store.segment(n) {
                for (_, body) in Self.boxes(seg).filter({ $0.0 == "moof" }) {
                    for f in Self.fragments(body) where f.track == 1 {
                        let d = Double(f.durations.reduce(0, +)) / Double(ts[1] ?? 90000);
                        histogram[String(format: "%.2f", d), default: 0] += 1
                    }
                }
            }
        }
        print(
            "PROBE piece durations (video): \(histogram.sorted { $0.key < $1.key }.map { "\($0.key) s ×\($0.value)" }.joined(separator: ", "))"
        )
        print(
            "PROBE audio gaps \(audioGaps.count): \(audioGaps.prefix(12).map { "\($0.0):\(String(format: "%+.3f", $0.1))" })"
        )
        print(
            "PROBE video gaps \(videoGaps.count): \(videoGaps.prefix(12).map { "\($0.0):\(String(format: "%+.3f", $0.1))" })"
        )
        let s = offsets.sorted()
        if !s.isEmpty {
            print(
                "PROBE audio end − video end per piece: min \(String(format: "%.3f", s.first!)) median \(String(format: "%.3f", s[s.count/2])) max \(String(format: "%.3f", s.last!))"
            )
        }
    }
}
extension Data {
    func u32(_ i: Int) -> UInt32 {
        UInt32(self[i]) << 24 | UInt32(self[i + 1]) << 16 | UInt32(self[i + 2]) << 8 | UInt32(self[i + 3])
    }
    func u64(_ i: Int) -> UInt64 { UInt64(u32(i)) << 32 | UInt64(u32(i + 4)) }
}
