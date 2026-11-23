import Core
import Testing

@testable import Styling

/// **One board, two devices** — and on neither does a colour change (AP58, 2026-09-26).
///
/// The phone's values are copied again here, **on purpose**: They are the
/// state before the move from `DesignSystemPhone`. If someone changes one of them, they change the
/// phone visibly — that should be a decision and not a side effect of tidying up.
@Suite("The color board")
struct ColorBoardTests {

    /// Reading is from `Theme`, without an override — `grundstock` carries the values from
    /// decision 24 itself.
    @Test("The TV board reads Theme and copies nothing", arguments: Theme.all)
    func tvReadsTheme(theme: Theme) {
        let board = ColorBoard(theme: theme)
        #expect(board.platform == .tv)
        #expect(board.id == theme.id)
        #expect(board.nameKey == theme.nameKey)
        let pairs: [(ColorRole, UInt32)] = [
            (.reason, theme.ground), (.surface, theme.surface), (.surfaceHigh, theme.surfaceRaised),
            (.line, theme.line), (.lineQuiet, theme.lineSoft), (.text, theme.text),
            (.textMatt, theme.textDim), (.textQuiet, theme.textFaint),
            (.textOnLight, theme.inkOnBright), (.tag, theme.brand),
            (.brandLight, theme.brandBright), (.brandDeep, theme.brandDeep),
            (.progress, theme.progress), (.live, theme.live), (.success, theme.success),
        ]
        for (role, fromTheme) in pairs {
            #expect(board.value(role) == fromTheme, "\(theme.id): \(role)")
        }
        #expect(board.seriesColor == theme.accent)
    }

    @Test("The phone boards carry their values")
    func phoneUnchanged() {
        let cinema = ColorBoard.phoneCinema
        #expect(
            [
                cinema.reason, cinema.surface, cinema.surfaceHigh, cinema.line, cinema.lineQuiet,
                cinema.text, cinema.textMatt, cinema.textQuiet, cinema.outline, cinema.outlineSheet,
                cinema.tag, cinema.brandLight, cinema.brandDeep, cinema.progress, cinema.live,
                cinema.success, cinema.deep, cinema.audio,
            ] == [
                0x100A09, 0x1C110F, 0x2A1A16, 0x3A241F, 0x241512, 0xF7EBD6, 0xB4A093, 0x9C8A7C,
                0x845246, 0x96604F, 0xC4302B, 0xE2564A, 0x6B1710, 0xE8B54A, 0xE05B4C, 0x6FA86A,
                0x241512, 0x3A241F,
            ])
        let night = ColorBoard.phoneMidnight
        #expect(
            [
                night.reason, night.surface, night.surfaceHigh, night.line, night.lineQuiet,
                night.text, night.textMatt, night.textQuiet, night.outline, night.outlineSheet,
                night.tag, night.brandLight, night.brandDeep, night.progress, night.live,
                night.success, night.deep, night.audio,
            ] == [
                0x0A0D14, 0x11161C, 0x1B2129, 0x2A323C, 0x171D24, 0xEAF0F6, 0xA6B2BF, 0x808C9A,
                0x4F6280, 0x60759A, 0x2D6ACA, 0x5C97EE, 0x123258, 0xE8B54A, 0xE05B4C, 0x6FA86A,
                0x171D24, 0x2A323C,
            ])
        let high = ColorBoard.phoneContrast
        #expect(
            [
                high.reason, high.surface, high.surfaceHigh, high.line, high.lineQuiet,
                high.text, high.textMatt, high.textQuiet, high.outline, high.outlineSheet,
                high.tag, high.brandLight, high.brandDeep, high.progress, high.live,
                high.success, high.deep, high.audio,
            ] == [
                0x000000, 0x141414, 0x232323, 0x3D3D3D, 0x1C1C1C, 0xFFFFFF, 0xD6D6D6, 0xB4B4B4,
                0x7A7A7A, 0x8F8F8F, 0xC4302B, 0xE2564A, 0x6B1710, 0xFFC85C, 0xFF7A6B, 0x7ED97A,
                0x1C1C1C, 0x3D3D3D,
            ])
    }

    /// The identifier is handed over between the devices (AP40) — it must mean the same
    /// schemes in the same order on both sides.
    @Test("Both devices carry the same identifiers")
    func identifiersEqual() {
        for platform in UIPlatform.allCases {
            #expect(ColorBoard.all(forItem: platform).map(\.id) == ColorBoard.identifiers)
            #expect(ColorBoard.all(forItem: platform).allSatisfy { $0.platform == platform })
        }
        #expect(Theme.all.map(\.id) == ColorBoard.identifiers)
    }

    @Test("Unknown falls back to Cinema, old is translated")
    func fallback() {
        #expect(ColorBoard.patterns("doesnotexist", forItem: .phone) == .phoneCinema)
        #expect(ColorBoard.patterns(nil, forItem: .tv).id == "cinema")
        #expect(ColorBoard.zu(id: nil, forItem: .phone) == nil)
        #expect(ColorBoard.newIdentifier(forItem: "kontrast") == "contrast")
        #expect(ColorBoard.newIdentifier(forItem: "new") == "new")
    }

    /// **Decision 24 (2026-09-26): Between the devices only the ground differs.**
    /// "Contrast" is neutral grey on both, "Midnight" blue on both with the TV's
    /// surfaces, "Cinema" carries the quiet text `#9C8A7C` on both.
    @Test("Both devices show the same pattern, except for the ground", arguments: ColorBoard.identifiers)
    func decision24(identifier: String) {
        let tv = ColorBoard.patterns(identifier, forItem: .tv)
        let phone = ColorBoard.patterns(identifier, forItem: .phone)
        let different = ColorRole.allCases.filter { tv.value($0) != phone.value($0) }
        #expect(different.allSatisfy { $0 == .reason }, "\(identifier): \(different)")
        #expect(tv.seriesColor == phone.seriesColor)
        #expect(tv.reason == 0x000000)
    }

    @Test("The decided values")
    func decidedValues() {
        #expect(ColorBoard.patterns("cinema", forItem: .tv).textQuiet == 0x9C8A7C)
        #expect(ColorBoard.patterns("contrast", forItem: .tv).surface == 0x141414)
        #expect(ColorBoard.patterns("midnight", forItem: .phone).tag == 0x2D6ACA)
        #expect(ColorBoard.patterns("midnight", forItem: .tv).tag == 0x2D6ACA)
        #expect(ColorBoard.patterns("midnight", forItem: .phone).reason == 0x0A0D14)
    }
}

/// Every board of both devices against the thresholds — **over every role, not over examples.**
@Suite("Contrast of both devices")
struct BoardContrastTests {

    static let allBoards = UIPlatform.allCases.flatMap { ColorBoard.all(forItem: $0) }

    @Test("Every text is legible on every background", arguments: allBoards)
    func font(board: ColorBoard) {
        for bottom in ColorRole.backgrounds {
            for top in ColorRole.captions {
                let value = Contrast.ratio(board.value(top), board.value(bottom))
                #expect(
                    value >= Contrast.bodyText,
                    "\(board): \(top) on \(bottom) only reaches \(value)")
            }
        }
    }

    @Test("Every outline is visible on its background", arguments: allBoards)
    func outlines(board: ColorBoard) {
        #expect(Contrast.carries(board.outline, to: board.reason, atLeast: Contrast.control))
        #expect(
            Contrast.carries(
                board.outlineSheet, to: board.surfaceHigh, atLeast: Contrast.control))
    }

    @Test("Signals are legible on the ground", arguments: allBoards)
    func signals(board: ColorBoard) {
        for role in ColorRole.signals {
            let value = Contrast.ratio(board.value(role), board.reason)
            #expect(value >= Contrast.bodyText, "\(board): \(role) only reaches \(value)")
        }
    }

    @Test("The formula is the one from Grundstock")
    func oneFormula() {
        #expect(Contrast.ratio(0xFFFFFF, 0x000000) == 21)
        #expect(Contrast.ratio(0x958374, 0x2A1A16) == Theme.contrastRatio(0x958374, 0x2A1A16))
        #expect(Contrast.luminance(0xFFFFFF) == 1)
        #expect(abs(Contrast.ratio(0x9C8A7C, 0x100A09) - 5.93) < 0.01)
    }
}
