import Foundation
import SourceProbe
import Testing

/// **Every translated text follows the choice in the app** — tvOS roadmap AP46, same
/// rule as `LanguageBundleTests` on the TV.
///
/// `Text(app:)` reads the environment locale and follows the switch on its own.
/// `String(localized:)` and `NSLocalizedString`, by contrast, read without an argument the language the
/// bundle was started with — around eighty places on the phone stood there in the old language
/// after a language switch. Since the language travels with the profile, it changes
/// even without anyone in the settings; a half-switched interface would be the
/// normal case.
///
/// **The check reads the source of the app and of all phone packages**, because every new
/// place can again be written without a bundle — Foundation's default
/// is exactly the wrong one.
@Suite("The language bundle behind every translated text (phone)")
struct LanguageBundleTests {

    /// The app target and of each phone package only `Sources` — their checks may name the
    /// old pattern as a subject.
    static func sourceFiles() throws -> [(name: String, content: String)] {
        let app = try SourceText.files(in: .phoneApp)
        let packets = try SourceText.files(in: .phonePackages).filter {
            $0.relative.split(separator: "/").dropFirst().first == "Sources"
        }
        return (app + packets).map { ($0.name, $0.content) }
    }

    /// The calls without ``Core/AppLanguageSetting/bundles`` — **without comment lines**, in which
    /// the old pattern may appear as a justification.
    static func withoutBundle(in text: String) -> [String] {
        var discoveries: [String] = []
        for match in text.matches(of: /String\(\s*localized:|NSLocalizedString\(/) {
            let start = match.range.lowerBound
            let lineStart =
                text[..<start].lastIndex(of: "\n").map { text.index(after: $0) } ?? text.startIndex
            if text[lineStart..<start].trimmingCharacters(in: .whitespaces).hasPrefix("//") {
                continue
            }
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
            if !call.contains("AppLanguageSetting.bundles(zu:") { discoveries.append(call) }
        }
        return discoveries
    }

    @Test("No String(localized:) or NSLocalizedString without the app's language bundle")
    func everyTextFollowsTheChoice() throws {
        let files = try Self.sourceFiles()
        #expect(files.count > 100, "the sources were not found")
        var counted = 0
        for (name, content) in files {
            counted += content.components(separatedBy: "AppLanguageSetting.bundles").count - 1
            counted += content.components(separatedBy: "AppLanguageSetting.text(").count - 1
            for finding in Self.withoutBundle(in: content) {
                Issue.record(
                    """
                    \(name): \(finding) — reads the launch language and not the chosen one. \
                    Use `AppLanguageSetting.text(_:)` or pass `bundle: AppLanguageSetting.bundles(zu:)`.
                    """)
            }
        }
        #expect(
            counted > 60,
            "only \(counted) places with a language bundle or `AppLanguageSetting.text` — the scan does not work"
        )
    }

    /// **The root sets the locale and the rebuild** — without it `Text(app:)` and the
    /// computed texts would not follow the switch.
    @Test("The root follows the profile's language")
    func rootFollows() throws {
        let app = try Self.sourceFiles().first { $0.name == "CineLoungeApp.swift" }?.content ?? ""
        #expect(app.contains(".environment(\\.locale, language.locale)"))
        #expect(app.contains(".id(language.identifier)"))
        #expect(app.contains("LanguageState()"))
    }
}
