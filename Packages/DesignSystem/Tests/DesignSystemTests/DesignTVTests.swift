import Core
import SwiftUI
import Testing

@testable import DesignSystem
@testable import Styling

/// **The TV layer over `Styling`** — the shared rules seen from this side,
/// and the old names with their old values (AP58, 2026-09-26).
@Suite("Design on the TV")
struct DesignTVTests {

    @Test("Every text is legible on every TV surface", arguments: ColorBoard.all(forItem: .tv))
    func contrast(board: ColorBoard) {
        for bottom in ColorRole.backgrounds {
            for top in ColorRole.captions {
                let value = Contrast.ratio(board.value(top), board.value(bottom))
                #expect(value >= Contrast.bodyText, "\(board): \(top) on \(bottom) only \(value)")
            }
        }
        for role in ColorRole.signals {
            #expect(Contrast.carries(board.value(role), to: board.reason, atLeast: Contrast.bodyText))
        }
    }

    @Test("The palette follows the chosen pattern")
    func boardFollowsTheme() {
        #expect(ColorBoard.current == ColorBoard(theme: Theme.current))
        #expect(ColorBoard.current.platform == .tv)
    }

    /// **The TV's focus color** — ``Styling/ColorRole/tag`` as a glow around the
    /// focused element. A control needs 3 : 1 against its surroundings (WCAG 1.4.11).
    ///
    /// Decision 24 gave "Contrast" the phone's brand color (`#C4302B` instead of `#D8433C`) under
    /// the condition that it holds up here: 3.80 : 1 on the background, 3.34 on the surface.
    @Test("The focus color works as a control", arguments: ColorBoard.all(forItem: .tv))
    func focusColor(board: ColorBoard) {
        for bottom in [ColorRole.reason, .surface] {
            #expect(
                Contrast.carries(board.tag, to: board.value(bottom), atLeast: Contrast.control),
                "\(board): focus color on \(bottom) only \(Contrast.ratio(board.tag, board.value(bottom)))"
            )
        }
    }

    /// Without switching the theme: `Theme.current` is a global value, and the tests
    /// run concurrently.
    @Test("The roles yield the colors of the chosen pattern", arguments: ColorRole.allCases)
    func rolesFollowThePattern(role: ColorRole) {
        #expect(role.color == Color(colorValue: ColorBoard(theme: Theme.current).value(role)))
    }

    @Test("Type and metrics of the TV")
    func values() {
        let slots: [TypeLevel] = [.lead, .title, .section, .header, .text, .footer, .lowercased]
        #expect(slots.map(\.points) == [76, 57, 48, 38, 29, 27, 25])
        #expect(TypeLevel.lead.font == Font.system(size: 76, weight: .heavy))
        #expect(TypeLevel.lowercased.font == Font.system(size: 25, weight: .regular))
        #expect(TypeLevel.lineHeight(zu: 38) == 49)
        let m = MetricsBoard.tv
        #expect([m.margin, TVMetrics.topMargin, m.gutter, m.section, m.person] == [80, 60, 40, 56, 168])
        #expect([m.cardRadius, m.fieldRadius, m.sheetRadius] == [12, 16, 28])
        #expect(m.poster == CGSize(width: 240, height: 360))
        #expect(m.episode == CGSize(width: 420, height: 236))
        #expect(LoadingBand.laneWidth == 620)
    }
}
