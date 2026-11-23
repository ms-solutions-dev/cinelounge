import AVFoundation
import Core
import Testing

@testable import Playback

/// The translation of the subtitle presentation into the rules of the system engine.
@Suite("Subtitle rules of the system engine")
@MainActor
struct NativeSubtitleStyleTests {

    @Test("The rules carry size and color in the system forms")
    func rulesCarryTheStyle() {
        let rules = NativePlaybackEngine.textStyleRules(
            for: SubtitleStyle(size: .large, color: .yellow)
        )

        #expect(rules.count == 1)
        let attributes = rules[0].textMarkupAttributes
        #expect(attributes[kCMTextMarkupAttribute_RelativeFontSize as String] as? Int == 130)

        // ARGB in the order CoreMedia demands — opacity first. Swapped, it would show only
        // on the TV, as a wrong color instead of as an error.
        let argb = attributes[kCMTextMarkupAttribute_ForegroundColorARGB as String] as? [Double]
        #expect(argb?.first == 1, "the opacity comes first")
        #expect(argb?.count == 4)
    }

    @Test("Without deviation and without a cut, not a single rule results")
    func defaultStyleCreatesNoRule() {
        // **The case that would go wrong silently.** An empty rule is not the same as none:
        // it overwrites the system's accessibility settings with its own defaults, and
        // whoever set larger subtitles there would get the normal ones again. On screen that
        // would look like "just doesn't work".
        #expect(NativePlaybackEngine.textStyleRules(for: .standard).isEmpty)
    }

    @Test("The line position comes along even without a custom style")
    func linePositionAlsoWithoutStyle() {
        let rules = NativePlaybackEngine.textStyleRules(for: .standard, row: 75)

        #expect(rules.count == 1)
        let attributes = rules[0].textMarkupAttributes
        #expect(
            attributes[
                kCMTextMarkupAttribute_OrthogonalLinePositionPercentageRelativeToWritingDirection
                    as String] as? Int == 75)
        // Size and color stay unnamed — the filled picture is a statement about the surface
        // and not about taste.
        #expect(attributes[kCMTextMarkupAttribute_RelativeFontSize as String] == nil)
        #expect(attributes.count == 1)
    }
}
