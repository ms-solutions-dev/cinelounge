import Core
import Foundation
import Testing

@testable import PlaylistKit

/// Measurement probe for the on-device finding "Schedule stays empty despite 60.954
/// programmes in the download store" (2026-08-16): the REAL programme guide through the
/// real stretch — parser, download store, time window, schedule — with counters
/// at every station.
///
/// Runs only if `CINELOUNGE_EPG` points to an XMLTV file — in the
/// check run without the file it stays silent instead of turning red.
///
/// **Why `.enabled(if:)` and not `guard … else { return }`** (E2, 2026-08-29):
/// Until today the condition stood as a `guard` in the first line, and thereby
/// all four `#expect` lay behind it. Without the environment variable — that is, in
/// every ordinary run — the test reported "passed" after 0,001 s
/// although not a single expectation had been evaluated. That is literally
/// the case this project wrote down as a lesson on 2026-08-24: *A
/// counter that can never go up is no evidence.* With `.enabled(if:)` the
/// omission appears as "skipped" in the output, and `scripts/check.sh` subtracts
/// it from the run count instead of counting it.
///
/// `try #require` is ruled out as a replacement: it makes the run **red** as soon as
/// the file is missing — and it is missing almost always, because it is 13 MB and
/// does not belong in the test store. The test rig that always runs is
/// ``SchedulePrototypeTests`` on the trimmed recording.
@Suite("Schedule probe on foreign data")
struct SportProbeTests {

    /// The path to the foreign guide, if one is set.
    static let epgPath = ProcessInfo.processInfo.environment["CINELOUNGE_EPG"]

    @Test(
        "Foreign program guide: every stage counts",
        .enabled(if: epgPath != nil, "CINELOUNGE_EPG does not point to an XMLTV file"))
    func realGuideThroughPipeline() async throws {
        let path = try #require(Self.epgPath)
        let file = URL(fileURLWithPath: path)

        let parsed = XMLTVParser.parse(fileURL: file)
        print("Probe: \(parsed.count) broadcasts parsed")
        #expect(!parsed.isEmpty, "the parser must read the file")

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("spielplan-sonde-\(UUID().uuidString)")
        let cache = LiveCache(directory: directory)
        defer { try? FileManager.default.removeItem(at: directory) }
        await cache.save(programmes: parsed)

        let calendar = Calendar.current
        let start = calendar.startOfDay(for: Date())
        let end = calendar.date(byAdding: .day, value: 1, to: start)!
        let day = await cache.programmes(from: start, to: end)
        print("Probe: \(day.count) broadcasts in the day window")
        #expect(!day.isEmpty, "the time window must yield the day")

        var classified = 0
        var live = 0
        var oddities = 0
        for programs in day {
            let kind = SportKind.classify(title: programs.title, channelName: "")
            if let kind {
                classified += 1
                if oddities < 12, kind != .football, kind != .tennis {
                    oddities += 1
                    print("  ? \(kind.rawValue): \(programs.title)")
                }
            }
            if kind != nil, SportPlan.pairing(in: programs.title) != nil { live += 1 }
        }
        print("Probe: \(classified) recognized as sport, \(live) with pairing")

        // The channel names from the guide itself — on the device they come
        // from the channel list, for the measurement the display-names suffice.
        let names = Self.displayNames(in: file)
        print("Probe: \(names.count) channel names found")

        let events = SportPlan.events(from: day, channelNames: names)
        print("Probe: \(events.count) events")
        var perKind: [SportKind: Int] = [:]
        for event in events { perKind[event.kind, default: 0] += 1 }
        for (kind, count) in perKind.sorted(by: { $0.value > $1.value }) {
            print("  \(kind.rawValue): \(count)")
        }
        for event in events.filter({ $0.kind == .football }).prefix(15) {
            print("  ⚽ \(event.competition ?? "—") | \(event.title) [\(event.epgIDs.joined(separator: ","))]")
        }
        #expect(!events.isEmpty, "the real program guide must yield events")
    }

    /// Reads `<channel id="…"><display-name>…</display-name>` from an
    /// XMLTV file — only for the probe, the parser does not need it.
    private static func displayNames(in file: URL) -> [String: String] {
        guard let text = try? String(contentsOf: file, encoding: .utf8),
            let expression = try? NSRegularExpression(
                pattern: "<channel id=\"([^\"]+)\">\\s*<display-name[^>]*>([^<]+)</display-name>")
        else { return [:] }
        var names: [String: String] = [:]
        let range = NSRange(text.startIndex..., in: text)
        expression.enumerateMatches(in: text, range: range) { match, _, _ in
            guard let match, let id = Range(match.range(at: 1), in: text),
                let name = Range(match.range(at: 2), in: text)
            else { return }
            names[String(text[id])] = String(text[name])
        }
        return names
    }
}
