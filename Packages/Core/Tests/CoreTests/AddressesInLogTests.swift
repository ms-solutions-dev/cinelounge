import Foundation
import SourceProbe
import Testing

/// **No raw address in the trace** — AP50, 2026-09-23.
///
/// **Why an address is a secret.** Providers hand out their channel lists as
/// `http://user:secret@server/list.m3u`, and Xtream appends user and password as a
/// query. A line `\(url.absoluteString, privacy: .public)` writes both into the
/// diagnostic trace — and the trace is what you **submit** when something does not
/// work.
///
/// **The proof that this is no thought experiment:** The submitted report of
/// 2026-08-23 carries to this day two complete accesses, in line 54 and in lines
/// 1826/3658/4317/4451. The source code has not bled since 2026-08-26; the last two
/// places — the own Jellyfin — fell today.
///
/// **The masking is called ``Grundstock/Diagnostics/loggable(_:)``** and removes query,
/// fragment, user and password. This check ensures that nobody writes past it — **not
/// even for the own server**, because the construction is the same and yesterday's
/// exception is tomorrow's rule.
@Suite("Addresses in the log")
struct AddressesInLogTests {

    @Test("No address appears raw and public in the trace")
    func noRawAddress() throws {
        // **Assembled, so that the check does not find itself.** It lies under `Packages/`
        // like the sources, and a search pattern in one piece would be at the very top of
        // the hit list.
        let pattern = "absoluteString" + ", privacy: .public"

        var occurrences: [String] = []
        // Only the sources — a test file may assemble an address.
        for file in try SourceText.files(in: .packets) where file.path.contains("/Sources/") {
            for (nr, row) in file.content.split(separator: "\n", omittingEmptySubsequences: false)
                .enumerated() where row.contains(pattern)
            {
                occurrences.append("\(file.name):\(nr + 1)")
            }
        }

        #expect(
            occurrences.isEmpty,
            """
            \(occurrences.count) place(s) write an address raw into the trace: \
            \(occurrences.joined(separator: ", ")). Providers hand out credentials as \
            `http://user:secret@server/`, and the trace gets submitted. \
            Use `Diagnostics.loggable(url)`.
            """)
    }
}
