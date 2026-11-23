import Foundation
import SourceProbe
import Testing

/// **Every translated text follows the choice in the app** (AP46, decision 4, 2026-09-25).
///
/// `Text(app:)` reads the environment locale and follows the switch by itself.
/// `String(localized:)` and `NSLocalizedString`, by contrast, read the
/// **system language** without an argument — around forty places stood in the old
/// language after a language switch. That was already so when the language hung on the device; since it
/// travels with the profile, it also switches without anyone in Settings, and a half-
/// switched interface would be the normal case.
///
/// **The test reads the source text of all packages and the app**, because the places are
/// scattered and each new one can again be written without a bundle — the
/// Foundation default is exactly the wrong one.
@Suite("The language bundle on every translated text")
struct LanguageBundleTests {

    static func sourceFiles() throws -> [(name: String, content: String)] {
        let app = try SourceText.files(in: .tvApp)
        let packets = try SourceText.files(in: .packets).filter {
            $0.relative.split(separator: "/").dropFirst().first == "Sources"
                && !$0.relative.hasPrefix("SourceProbe/")
        }
        return (app + packets).map { ($0.name, $0.content) }
    }

    /// The calls without the language bundle **of the catalog that holds the key** —
    /// **without comment lines**, where the old pattern may stand as a reason.
    ///
    /// **Since the final step of AP58, `AppLanguageSetting.bundles` is no longer enough:** Shared
    /// wordings live in the catalog `WordingKit`, and a call with the app's bundle would not find
    /// them. Allowed are ``Core/AppLanguageSetting/text(_:)`` (no `String(localized:)` at
    /// the place) and `bundle: AppLanguageSetting.bundles(zu: key)`. `AppLanguageSetting.swift`
    /// itself is exempt: it holds the one call that `text(_:)` falls back to.
    ///
    /// **One exception with reason:** `WordingKit.text(_:language:)` lives under `Core` and cannot
    /// see `AppLanguageSetting`; it is handed the language and takes its
    /// `lproj` via `languageBundle(language, …)` — the same calculation that stands behind
    /// `AppLanguageSetting.bundles` (AP58 R0). It is called via `AppLanguageSetting.word`.
    static func withoutBundle(in content: String) -> [String] {
        let text = content
        var discoveries: [String] = []
        for match in text.matches(of: /String\(\s*localized:|NSLocalizedString\(/) {
            let start = match.range.lowerBound
            let lineStart =
                text[..<start].lastIndex(of: "\n").map { text.index(after: $0) } ?? text.startIndex
            if text[lineStart..<start].trimmingCharacters(in: .whitespaces).hasPrefix("//") { continue }
            var depth = 0
            var end = start
            var location = text[start...].firstIndex(of: "(")!
            while location < text.endIndex {
                if text[location] == "(" { depth += 1 }
                if text[location] == ")" {
                    depth -= 1
                    if depth == 0 {
                        end = location
                        break
                    }
                }
                location = text.index(after: location)
            }
            let call = String(text[start...end])
            if !call.contains("AppLanguageSetting.bundles(zu:") && !call.contains("languageBundle(language") {
                discoveries.append(call)
            }
        }
        return discoveries
    }

    @Test("No String(localized:) and no NSLocalizedString without the app's language bundle")
    func everyTextFollowsTheChoice() throws {
        let files = try Self.sourceFiles()
        #expect(files.count > 100, "the sources were not found")
        var counted = 0
        for (name, content) in files {
            let discoveries = Self.withoutBundle(in: content)
            counted += content.components(separatedBy: "AppLanguageSetting.bundles").count - 1
            counted += content.components(separatedBy: "AppLanguageSetting.text(").count - 1
            for fund in discoveries where name != "AppLanguageSetting.swift" {
                Issue.record(
                    """
                    \(name): \(fund) — reads the system language and not the chosen one. \
                    Use `Appsprache.text(_:)` or pass `bundle: Appsprache.buendel(zu:)`.
                    """)
            }
        }
        #expect(
            counted > 30,
            "only \(counted) places with a language bundle or `Appsprache.text` — the scan does not work")
    }

    /// **An inserted value belongs in the key `%@`, not in the string** —
    /// the same test as on the phone (`ProfileStartupPhoneTests`, finding of 2026-09-25).
    /// On the TV it still found seven places in the final step of AP58:
    /// `Text(appKey: "profiles.pinResetRunning \(name) \(device)")` assembles the text **before**
    /// the lookup, and on screen the raw key stood there, including the name.
    /// Runtime keys with a dot (`"state.\(scenario)"`) stay allowed — what is searched for is the
    /// space before the interpolation.
    @Test("No Text(appKey:) with an interpolated value")
    func noInsertedKey() throws {
        var discoveries: [String] = []
        for (name, content) in try Self.sourceFiles() {
            for row in content.split(separator: "\n") where row.contains(/appKey: "[^"]* \\\(/) {
                discoveries.append("\(name): \(row.trimmingCharacters(in: .whitespaces))")
            }
        }
        #expect(discoveries.isEmpty, "\(discoveries)")
    }
}
