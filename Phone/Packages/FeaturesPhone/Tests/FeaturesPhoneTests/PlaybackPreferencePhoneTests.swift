import Foundation
import SourceProbe
import Testing

/// **Audio preference and subtitles belong to the profile** — tvOS roadmap AP46, phone
/// row "Phone: read audio preference and subtitles per profile", 2026-09-25.
///
/// The same guards as `PlaybackPreferenceTests` on the TV, over the sources of this
/// package: Until today the player read `AudioPreference.load(from: SecureStore())`, and
/// `PlaybackView` wrote the whole bundle to the device. Nothing visible was broken —
/// the choice applied to whoever picked up the phone, and did not arrive on any other
/// device.
@Suite("Playback preferences on the phone: per profile")
struct PlaybackPreferencePhoneTests {

    /// All source files of `FeaturesPhone`, **without pure comment lines** — an explanation
    /// may name the old path.
    static func sources() throws -> [(name: String, content: String)] {
        try SourceText.files(in: .featuresPhone)
            .map { ($0.name, withoutComment($0.content)) }
            .sorted { $0.0 < $1.0 }
    }

    static func withoutComment(_ text: String) -> String {
        text
            .split(separator: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
    }

    static func match(_ pattern: String, in text: String) -> Int {
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return -1 }
        return expression.numberOfMatches(in: text, range: NSRange(text.startIndex..., in: text))
    }

    /// Every reader and writer that does **not** go through the profile compartment.
    static let bypassingProfile = [
        #"(AudioPreference|SubtitleStyle|SubtitleMode)\.load\(\s*from:(?!\s*ProfileStore\.playback)"#,
        #"(AudioPreference|SubtitleStyle)\.write[A-Za-z]+\([^,]+,\s*in:(?!\s*ProfileStore\.playback)"#,
        #"\$0\.save\(\s*to:(?!\s*ProfileStore\.playback)"#,
    ]

    /// A whole bundle written — the finding of the counter-check on the TV.
    static let bundles = #"(ton|untertitel|preference|style)\.save\("#

    @Test("No reader and no writer bypasses the profile's compartment")
    func nobodyBypassesProfile() throws {
        var violations: [String] = []
        for (name, content) in try Self.sources() {
            for pattern in Self.bypassingProfile where Self.match(pattern, in: content) != 0 {
                violations.append("\(name): \(pattern)")
            }
        }
        #expect(violations.isEmpty, "bypasses the profile: \(violations)")
    }

    @Test("The UI writes per key, never the whole bundle")
    func noBundle() throws {
        let match = try Self.sources().filter { Self.match(Self.bundles, in: $0.content) != 0 }
        #expect(match.isEmpty, "writes a bundle: \(match.map(\.name))")
    }

    /// **The readers exist** — otherwise the first check would be green because nobody reads
    /// any more.
    @Test("Track choice and settings read through the profile")
    func theReadersArePresent() throws {
        let sources = try Self.sources()
        let expected: [(String, String)] = [
            // **Since AP58 R4 the playback plan reads** (``Core/PlaybackPlan``) — the same place as on
            // the TV; the source calls it with the applicable preferences.
            ("JellyfinPlayerSource.swift", #"PlaybackPlan\.Preference\.effective\("#),
            ("PlaybackView.swift", #"SubtitleStyle\.load\(\s*from:\s*ProfileStore\.playback"#),
            ("PlaybackView.swift", #"AudioPreference\.load\(\s*from:\s*ProfileStore\.playback"#),
            ("SettingsModel.swift", #"SubtitleStyle\.load\(\s*from:\s*ProfileStore\.playback"#),
        ]
        for (file, pattern) in expected {
            let content = sources.first { $0.name == file }?.content ?? ""
            #expect(Self.match(pattern, in: content) == 1, "\(file): \(pattern)")
        }
    }

    /// **The cloud syncs preferences and brand only when the Keychain is connected.** On the
    /// TV all checks were green while the app never connected the brand — the checks set the
    /// store by hand.
    @Test("The cloud startup attaches the Keychain")
    func cloudConnects() throws {
        let text = Self.withoutComment(try SourceText.read("CloudStartup.swift", in: .phoneApp))
        #expect(Self.match(#"\.attachKeychain\(\s*keychain\s*\)"#, in: text) == 1)
        #expect(Self.match(#"moveBundle:\s*keychain"#, in: text) == 1)
    }
}
