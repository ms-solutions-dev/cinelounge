import Foundation
import SourceProbe
import Testing

@testable import Features

/// **The readers and not the writers** — owner decision 4 of 2026-09-24.
///
/// Audio preference and subtitles have been stored per person since that day (``Core/ProfileStore``).
/// Whether that **takes effect** is decided not by the settings view but by every place that
/// reads during playback: start choice, engine choice, subtitle image. A setting that is
/// stored per profile but is still read from the device in the player is the error
/// "built but not wired up", which has happened five times in this project — and it
/// goes unnoticed because both paths deliver plausible values.
///
/// The calculation itself (A plays with A's preference, B with B's) is checked by
/// `CoreTests/ProfileStoreTests`. This check ensures that the player reads **through this
/// calculation**. The access for that has exactly one name, ``Core/ProfileStore/playback``
/// — by it the readers can be found in the source.
@Suite("Playback preferences: the player reads per profile")
struct PlaybackPreferenceTests {

    /// The sources in which reading and writing happen: the UI and the engines.
    static func sources() throws -> [(name: String, content: String)] {
        var found: [(String, String)] = []
        for location in [CodeLocation.features, .playback] {
            for file in try SourceText.files(in: location) {
                found.append((file.name, file.content))
            }
        }
        return found.sorted { $0.0 < $1.0 }
    }

    static func match(_ patterns: String, in text: String) -> Int {
        guard let expression = try? NSRegularExpression(pattern: patterns) else { return -1 }
        return expression.numberOfMatches(
            in: text, range: NSRange(text.startIndex..., in: text))
    }

    /// Every access to the preferences whose store is **not** the profile's.
    static let bypassingProfile = [
        #"(AudioPreference|SubtitleStyle)\.load\(\s*from:(?!\s*ProfileStore\.playback)"#,
        #"SubtitleStyle\.prefersPlainSubtitles\(\s*from:(?!\s*ProfileStore\.playback)"#,
        #"SubtitleStyle\.setPrefersPlainSubtitles\([^,]+,\s*in:(?!\s*ProfileStore\.playback)"#,
        #"(AudioPreference|SubtitleStyle)\.write[A-Za-z]+\([^,]+,\s*in:(?!\s*ProfileStore\.playback)"#,
        #"\bmode\.save\(\s*to:(?!\s*ProfileStore\.playback)"#,
    ]

    /// **No bundle writer in the UI** (counter-check of 2026-09-24).
    ///
    /// `AudioPreference.save` writes all three keys, `SubtitleStyle.save` both.
    /// After a single switch the **inherited device value** of the other one stood
    /// as an own value in the person's compartment, went into the cloud and there beat the real choice
    /// from the other device. Writing is done per key.
    static let bundles = #"(preference|subtitleStyle|audioPreference|style|ton|subtitles)\.save\("#

    @Test("The UI writes per key, never the whole bundle")
    func noBundle() throws {
        let match = try Self.sources().filter { Self.match(Self.bundles, in: $0.content) != 0 }
        #expect(match.isEmpty, "writes a bundle: \(match.map(\.name))")
    }

    @Test("No reader and no writer bypasses the profile's store")
    func nobodyReadsFromTheDevice() throws {
        var violations: [String] = []
        for (name, content) in try Self.sources() {
            for patterns in Self.bypassingProfile where Self.match(patterns, in: content) != 0 {
                violations.append("\(name): \(patterns)")
            }
        }
        #expect(violations.isEmpty, "reads or writes bypassing the profile: \(violations)")
    }

    /// **The readers of the playback path, counted.** The previous check only sees what
    /// is wrongly there — not what is missing. That was exactly the case with the next episode
    /// and with the jump via the server: There the ASS choice was **not read at all**,
    /// and the default `false` silently decided for VLC.
    static let reader: [(file: String, patterns: String, count: Int)] = [
        ("PlayerScreen.swift", #"SubtitleStyle\.load\(\s*from:\s*ProfileStore\.playback"#, 1),
        ("EngineHost.swift", #"SubtitleStyle\.load\(\s*from:\s*ProfileStore\.playback"#, 1),
    ]

    @Test("Start choice, subtitle image and engine read through the profile")
    func theReadersArePresent() throws {
        let sources = try Self.sources()
        for (file, patterns, count) in Self.reader {
            let content = sources.first { $0.name == file }?.content ?? ""
            #expect(Self.match(patterns, in: content) == count, "\(file): \(patterns)")
        }
    }

    /// **Every engine choice of a library playback goes through the schedule** (AP58 R4).
    ///
    /// Until then start, next episode and jump each had their own
    /// ``Core/PlaybackEngineSelector/decide``, and two forgot the ASS choice — the
    /// default `false` silently decided for VLC. Now they call ``Core/PlaybackPlan``, and there
    /// ``Core/PlaybackPlan/Preference/effective(interfaceLanguage:device:)`` reads audio and
    /// ASS choice from the person's compartment — once.
    @Test("Every engine choice in the player goes through the playback plan, which reads the profile")
    func everyEngineChoiceGoesThroughThePlan() throws {
        let sources = try Self.sources()
        // `PlayerModel` steht seit AP58 R4 in mehreren Dateien (`PlayerModel+….swift`).
        for (file, callCount) in [("MainView", 1), ("PlayerModel", 2)] {
            let content = sources.filter { $0.name == file + ".swift" || $0.name.hasPrefix(file + "+") }
                .map(\.content).joined(separator: "\n")
            #expect(
                Self.match(#"PlaybackEngineSelector\.decide\("#, in: content) == 0,
                "\(file) decides bypassing the plan")
            #expect(Self.match(#"PlaybackPlan\.build\("#, in: content) == callCount, "\(file)")
        }
        let plan = try SourceText.read("PlaybackPlan.swift", in: .core)
        #expect(Self.match(#"PlaybackEngineSelector\.decide\("#, in: plan) == 1)
        #expect(
            Self.match(#"AudioPreference\.load\(\s*from:\s*ProfileStore\.playback"#, in: plan) == 1)
        #expect(
            Self.match(
                #"SubtitleStyle\.prefersPlainSubtitles\(\s*from:\s*ProfileStore\.playback"#,
                in: plan) == 1)
        #expect(
            Self.match(#"prefersPlainSubtitles:\s*preference\.plainSubtitles"#, in: plan) == 1)
    }
}
