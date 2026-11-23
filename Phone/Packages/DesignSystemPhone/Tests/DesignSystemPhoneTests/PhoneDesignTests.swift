import SwiftUI
import Testing

@testable import DesignSystemPhone
@testable import Styling

/// **The phone layer above `Styling`** — the old names with their old values (AP58,
/// 2026-09-26). Type and dimensions are visible on the device; a shifted value should be
/// noticed here and not in the simulator.
@Suite("Design on the phone")
struct PhoneDesignTests {

    @Test("The type levels are the text styles from before")
    func font() {
        #expect(TypeLevel.lead.font == Font.largeTitle.weight(.bold))
        #expect(TypeLevel.title.font == Font.title.weight(.bold))
        #expect(TypeLevel.section.font == Font.title2.weight(.semibold))
        #expect(TypeLevel.header.font == Font.headline)
        #expect(TypeLevel.text.font == Font.body)
        #expect(TypeLevel.footer.font == Font.subheadline)
        #expect(TypeLevel.label.font == Font.footnote)
        #expect(TypeLevel.lowercased.font == Font.caption2.weight(.semibold))
        #expect(TypeLevel.lineHeight(zu: 17) == 23)
    }

    @Test("The metrics are those from before")
    func metrics() {
        #expect(
            [
                MetricsBoard.phone.margin, MetricsBoard.phone.gutter, MetricsBoard.phone.section,
                MetricsBoard.phone.person,
            ]
                == [20, 12, 20, 64])
        #expect(
            [
                MetricsBoard.phone.cardRadius, MetricsBoard.phone.fieldRadius, MetricsBoard.phone.imageRadius,
                MetricsBoard.phone.sheetRadius,
            ]
                == [10, 14, 10, 20])
        #expect(MetricsBoard.phone.poster == CGSize(width: 110, height: 165))
        #expect(MetricsBoard.phone.episode == CGSize(width: 200, height: 112))
        #expect(StripeBand.stripeWidth == 6)
    }

    /// The roles read the chosen theme — without switching it: ``Styling/ColorBoard/current``
    /// is a global, and the tests run concurrently.
    @MainActor
    @Test("The roles yield the colors of the chosen pattern", arguments: ColorRole.allCases)
    func roles(role: ColorRole) {
        #expect(ColorBoard.current.platform == .phone)
        #expect(role.color == Color(colorValue: ColorBoard.current.value(role)))
        #expect(ProfileColor.tag("doesnotexist") == nil)
    }
}
