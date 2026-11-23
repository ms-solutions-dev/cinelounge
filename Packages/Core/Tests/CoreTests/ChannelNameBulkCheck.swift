import Foundation
import Testing

@testable import Core

/// A tool for looking things up, not a test for everyday use.
///
/// Runs only if `CINELOUNGE_CHANNELS` points to a JSON file with Xtream channels —
/// for example the response of `player_api.php?action=get_live_streams`. Tests must
/// not depend on files outside the project; a run over **all** names of a real
/// provider is, however, the only reliable means for the question "does the cleaner
/// hold up with 5389 names too?".
///
/// Fifteen selected examples in ``ChannelNameTests`` prove the rules. What they
/// **cannot** prove: that none of the rules strikes a name nobody thought of. That is
/// exactly what this is for.
///
/// Invocation:
/// ```sh
/// CINELOUNGE_CHANNELS=/path/get_live_streams.json swift test --filter ChannelNameBulkCheck
/// ```
@Suite(
    "Channel names across a whole provider catalog",
    .enabled(if: ProcessInfo.processInfo.environment["CINELOUNGE_CHANNELS"] != nil))
struct ChannelNameBulkCheck {

    private struct Entry: Decodable {
        let name: String
    }

    private func allNames() throws -> [String] {
        let path = try #require(ProcessInfo.processInfo.environment["CINELOUNGE_CHANNELS"])
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        return try JSONDecoder().decode([Entry].self, from: data).map(\.name)
    }

    @Test("No name vanishes that has content")
    func nothingVanishes() throws {
        // The most dangerous outcome: A channel gets an empty name and appears in the list as
        // an empty row. It can then be neither selected nor reported — you see a gap and do
        // not know what is missing.
        let names = try allNames()
        var lost: [String] = []

        for name in names where !ChannelName.isSectionMarker(name) {
            let hasContent = name.contains(where: { $0.isLetter || $0.isNumber })
            if hasContent, ChannelName.display(name).isEmpty {
                lost.append(name)
            }
        }

        #expect(lost.isEmpty, "became empty: \(lost.prefix(10))")
    }

    @Test("No search key becomes empty when the name has letters")
    func searchKeysStayUsable() throws {
        // An empty key means: The channel cannot be found via search and sorts itself to the
        // start. With 5389 channels search is the main access — paging through the list is
        // not an option.
        let names = try allNames()
        var unusable: [String] = []

        for name in names where !ChannelName.isSectionMarker(name) {
            guard name.contains(where: \.isLetter) else { continue }
            if ChannelName.searchKey(name).isEmpty { unusable.append(name) }
        }

        #expect(unusable.isEmpty, "without key: \(unusable.prefix(10))")
    }

    @Test("The cleaner does not noticeably lengthen any name")
    func namesDoNotGrow() throws {
        // Folding makes names shorter or equally long. If one gets longer, a decomposition
        // produced more characters than went in — for example with a character that falls
        // apart into a whole sequence of words. On the TV that would be a line break in the
        // middle of the name.
        let names = try allNames()
        var grown: [(String, String)] = []

        for name in names {
            let cleaned = ChannelName.display(name)
            if cleaned.count > name.count + 2 { grown.append((name, cleaned)) }
        }

        #expect(grown.isEmpty, "grew longer: \(grown.prefix(5))")
    }

    @Test("The cleaner leaves no superscript characters")
    func noDecorationSurvives() throws {
        // The test of the whole: If a superscript character remains anywhere, a mapping is
        // missing in the decomposition — and this channel still cannot be found via a search
        // for "HD" or "4K".
        let names = try allNames()
        var remaining: [String] = []

        for name in names {
            let cleaned = ChannelName.display(name)
            let stillDecorated = cleaned.unicodeScalars.contains { scalar in
                String(scalar).decomposedStringWithCompatibilityMapping != String(scalar)
                    && !scalar.properties.isDiacritic
            }
            if stillDecorated { remaining.append(cleaned) }
        }

        #expect(remaining.isEmpty, "still decorated: \(remaining.prefix(10))")
    }

    @Test("Report on the catalog")
    func report() throws {
        // Not a verdict but a summary to read along with. It makes visible how much the
        // cleaner has to do at all — and whether a new list brings peculiarities nobody has
        // seen here yet.
        let names = try allNames()
        let markers = names.filter(ChannelName.isSectionMarker)
        let changed = names.filter { ChannelName.display($0) != $0 }

        print(
            """

            ── Catalog: \(names.count) channels
               Group headings       \(markers.count)
               changed by cleaner  \(changed.count) (\(100 * changed.count / max(1, names.count)) %)
               Examples:
            \(changed.prefix(6).map { "     \($0)  →  \(ChannelName.display($0))" }.joined(separator: "\n"))
            """)

        #expect(!names.isEmpty)
    }
}
