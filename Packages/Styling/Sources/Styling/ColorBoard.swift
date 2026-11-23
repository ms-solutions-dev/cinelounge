import Core

/// A colour scheme as numbers — **one board for both devices, with all roles of both.**
///
/// **Why it exists** (AP58, report B finding 13). Until 2026-09-26 two tables stood
/// side by side: `Grundstock.Theme` on the TV (`ground`, `surface`, `brand` …) and a
/// separate `ColorBoard` on the phone (`reason`, `surface`, `rot` …). The same concepts under two
/// names, the TV lacked `outline` and `deep`, the phone `inkOnBright` and the
/// series colour — and of 42 comparable values 20 matched, without a line
/// saying which deviation is intended. Now there is **one** type with the union of the
/// roles (``ColorRole``), and every role has a value per scheme and ``UIPlatform``.
///
/// **Where the numbers come from.** The TV's stay in `Grundstock.Theme` and
/// are only read here (``init(theme:)``) — `grundstock` also carries the reading app and is
/// used by parallel working copies without a branch of their own; a second copy of the
/// TV values at this point would be exactly the duplication that ends here. The phone's
/// stand below as a table (``phoneCinema`` …) — they used to live in `DesignSystemPhone`.
///
/// **The deviations between the devices — decided since decision 24 (2026-09-26):**
/// - `reason`: black on the TV, on the phone `#100A09` ("Cinema") and `#0A0D14`
///   ("Midnight"). **The only platform variant** — across a 55-inch surface the
///   tinted ground turns into a grey veil (see `Theme.cinema`).
/// - "Cinema": quiet text `#9C8A7C` on both devices (previously `#958374` on the TV).
/// - "Midnight": the TV's version on both — blue brand colour, cool surfaces and
///   text. On the phone the brand colour had been red until then.
/// - "Contrast": the phone's version on both — neutral grey surfaces and the brand colour
///   `#C4302B`. On the TV the surfaces were warm-tinted. The TV's focus colour
///   (``tag`` as a glow around the focused element) with the phone's value meets the
///   threshold for controls (3.8 : 1 on the ground, `DesignTVTests`) and is
///   therefore aligned as well.
///
/// Since `grundstock` carries the values itself (e927810 and `g4-colors`), the board reads them
/// unchanged from `Theme`; an override no longer exists.
///
/// **Roles that a device does not draw today** are still populated, so that every board
/// has the same shape and the contrast check can run every role on every device:
/// On the TV ``outline`` and ``outlineSheet`` take the phone's values (recalculated against the
/// TV's surfaces, see `ColorBoardTests`), ``deep`` and ``audio`` are
/// ``lineQuiet`` and ``line`` — as on the phone in "Cinema". On the phone
/// ``textOnLight`` and ``seriesColor`` come from the TV scheme with the same identifier.
///
/// **Why numbers and not `Color`.** This file does not know SwiftUI: That way a
/// scheme can be checked without building a UI. Exactly this calculation was missing when the
/// TV's ground changed from brown to black and the quietest text slipped below the
/// threshold. ``Contrast`` therefore runs through every combination.
public struct ColorBoard: Sendable, Equatable, Identifiable {

    /// The scheme's identifier — `cinema`, `midnight` or `contrast`, the same on both devices
    /// because it is handed over between them.
    public let id: String
    /// Which device these values apply to.
    public let platform: UIPlatform
    /// Translation key of the name that Settings displays.
    public let nameKey: String

    // MARK: - Surfaces

    /// Base surface of all views.
    public let reason: UInt32
    /// Karten, Tafeln, Felder.
    public let surface: UInt32
    /// Raised surface: sheets, active row.
    public let surfaceHigh: UInt32
    public let line: UInt32
    /// Divider within a surface.
    public let lineQuiet: UInt32

    // MARK: - Text

    public let text: UInt32
    /// Second lines and details.
    public let textMatt: UInt32
    /// Accessories and times.
    public let textQuiet: UInt32
    /// Dark text on a light surface, where it may carry a hint of colour — the number in
    /// a golden badge. On the TV `inkOnBright`.
    public let textOnLight: UInt32

    // MARK: - Outlines

    /// Border of chips, fields and segments on the ground — WCAG 1.4.11 demands 3 : 1.
    ///
    /// It is the **border** that is raised, not the fill: A fill with 3 : 1 would be `#825145`,
    /// and ``textMatt`` on it would fall to 2.61 : 1.
    public let outline: UInt32
    /// The same border on the raised sheet — the same threshold against a different background.
    public let outlineSheet: UInt32

    // MARK: - Brand and signals

    /// The lead colour: on the TV also the focus ring, on the phone the fill under the
    /// finger. On the phone the role was called `rot`, on the TV `brand`.
    public let tag: UInt32
    /// Active tab, brand name as text. Formerly `rotHell` / `brandBright`.
    public let brandLight: UInt32
    /// Gradients and background behind text. Formerly `rotTief` / `brandDeep`.
    public let brandDeep: UInt32
    /// Progress — deliberately separate from the lead colour, otherwise it blurs on coloured
    /// tiles. Formerly `gold` / `progress`.
    public let progress: UInt32
    /// The `LIVE` wordmark. Never as a bare dot: With deuteranopia it turns into an
    /// olive-grey bullet.
    public let live: UInt32
    /// Reachable, confirmed. Never alone — always with an icon next to it. Formerly `good` /
    /// `success`.
    public let success: UInt32

    // MARK: - Series color

    /// The dark pole of the fallback series colour, as long as none is determined from the image.
    public let deep: UInt32
    /// The light pole. On the TV the series colour carries the focus ring, on the phone the edge
    /// of the tile and its glow downwards.
    public let audio: UInt32
    /// The fallback series colour as hue and saturation — on the TV `Theme.accent`.
    public let seriesColor: AccentPalette

    public init(
        id: String, platform: UIPlatform, nameKey: String,
        reason: UInt32, surface: UInt32, surfaceHigh: UInt32, line: UInt32, lineQuiet: UInt32,
        text: UInt32, textMatt: UInt32, textQuiet: UInt32, textOnLight: UInt32,
        outline: UInt32, outlineSheet: UInt32,
        tag: UInt32, brandLight: UInt32, brandDeep: UInt32,
        progress: UInt32, live: UInt32, success: UInt32,
        deep: UInt32, audio: UInt32, seriesColor: AccentPalette
    ) {
        self.id = id
        self.platform = platform
        self.nameKey = nameKey
        self.reason = reason
        self.surface = surface
        self.surfaceHigh = surfaceHigh
        self.line = line
        self.lineQuiet = lineQuiet
        self.text = text
        self.textMatt = textMatt
        self.textQuiet = textQuiet
        self.textOnLight = textOnLight
        self.outline = outline
        self.outlineSheet = outlineSheet
        self.tag = tag
        self.brandLight = brandLight
        self.brandDeep = brandDeep
        self.progress = progress
        self.live = live
        self.success = success
        self.deep = deep
        self.audio = audio
        self.seriesColor = seriesColor
    }

    /// The value of a role — for checks that run over all roles.
    public func value(_ role: ColorRole) -> UInt32 {
        switch role {
        case .reason: reason
        case .surface: surface
        case .surfaceHigh: surfaceHigh
        case .line: line
        case .lineQuiet: lineQuiet
        case .text: text
        case .textMatt: textMatt
        case .textQuiet: textQuiet
        case .textOnLight: textOnLight
        case .outline: outline
        case .outlineSheet: outlineSheet
        case .tag: tag
        case .brandLight: brandLight
        case .brandDeep: brandDeep
        case .progress: progress
        case .live: live
        case .success: success
        case .deep: deep
        case .audio: audio
        }
    }
}

// MARK: - The choice

extension ColorBoard {

    /// Where the choice is stored — **the same key on both devices** (AP40, 2026-09-20),
    /// since AP58 R7 also **the same store** (``Core/ColorPattern``).
    public static let storeKey = ColorPattern.key

    /// The phone's key until 2026-09-20, now read only for adoption.
    public static let oldKey = ColorPattern.oldKey

    /// The identifiers in the order in which they are offered.
    public static let identifiers = ["cinema", "midnight", "contrast"]

    /// Today's identifier for one from before 2026-09-20 — ``Core/ColorPattern/newIdentifier(forItem:)``.
    public static func newIdentifier(forItem old: String) -> String {
        ColorPattern.newIdentifier(forItem: old)
    }

    /// All schemes of a device, in the order of Settings.
    public static func all(forItem platform: UIPlatform) -> [ColorBoard] {
        switch platform {
        case .tv: Theme.all.map(ColorBoard.init(theme:))
        case .phone: [phoneCinema, phoneMidnight, phoneContrast]
        }
    }

    /// The board for a stored identifier, or `nil` for nothing or something unknown.
    public static func zu(id identifier: String?, forItem platform: UIPlatform) -> ColorBoard? {
        guard let identifier else { return nil }
        return all(forItem: platform).first { $0.id == identifier }
    }

    /// The board for an identifier, with "Cinema" as fallback — like `Theme.named(_:)`.
    public static func patterns(_ identifier: String?, forItem platform: UIPlatform) -> ColorBoard {
        zu(id: identifier, forItem: platform) ?? all(forItem: platform)[0]
    }
}

// MARK: - TV

extension ColorBoard {

    /// The board of a TV scheme — **read, not copied.**
    ///
    /// The values live in `Grundstock.Theme`; here only the names are translated and the
    /// roles added that the TV does not draw today (see type description).
    public init(theme: Theme) {
        let phone = ColorBoard.phoneBoard(theme.id)
        self.init(
            id: theme.id, platform: .tv, nameKey: theme.nameKey,
            reason: theme.ground, surface: theme.surface, surfaceHigh: theme.surfaceRaised,
            line: theme.line, lineQuiet: theme.lineSoft,
            text: theme.text, textMatt: theme.textDim, textQuiet: theme.textFaint,
            textOnLight: theme.inkOnBright,
            outline: phone.outline, outlineSheet: phone.outlineSheet,
            tag: theme.brand, brandLight: theme.brandBright, brandDeep: theme.brandDeep,
            progress: theme.progress, live: theme.live, success: theme.success,
            deep: theme.lineSoft, audio: theme.line, seriesColor: theme.accent)
    }
}

// MARK: - Phone

extension ColorBoard {

    private static func phoneBoard(_ identifier: String) -> ColorBoard {
        zu(id: identifier, forItem: .phone) ?? phoneCinema
    }

    /// "Cinema" on the phone — the scheme in which the whole design is drawn.
    ///
    /// Two values were changed on 2026-09-02 on the basis of a measurement, not out of
    /// taste: ``textQuiet`` was `#8A776A` and gave 4.34 on ``surface`` and 3.92 on
    /// ``surfaceHigh``. ``outline`` did not exist before at all.
    public static let phoneCinema = ColorBoard(
        id: "cinema", platform: .phone, nameKey: "theme.cinema",
        reason: 0x100A09, surface: 0x1C110F, surfaceHigh: 0x2A1A16,
        line: 0x3A241F, lineQuiet: 0x241512,
        text: 0xF7EBD6, textMatt: 0xB4A093, textQuiet: 0x9C8A7C,
        textOnLight: Theme.cinema.inkOnBright,
        outline: 0x845246, outlineSheet: 0x96604F,
        tag: 0xC4302B, brandLight: 0xE2564A, brandDeep: 0x6B1710,
        progress: 0xE8B54A, live: 0xE05B4C, success: 0x6FA86A,
        deep: 0x241512, audio: 0x3A241F, seriesColor: Theme.cinema.accent)

    /// "Midnight" on the phone — **the TV's version** (decision 24): blue
    /// brand colour, cool surfaces and text. Only ``reason`` stays its own (`#0A0D14` instead of black).
    ///
    /// Until 2026-09-26 the phone carried the logo's red brand colour here and its own, slightly
    /// bluer surfaces. **The brand colour has been minimally darker since then** (`#2D6ACA` instead of
    /// `#2F6FD0`, on both devices): ``text`` on ``tag`` stood at 4.25 : 1, so the loud
    /// button was below 4.5. Now it is 4.54 : 1 — see
    /// `ContrastTests.textOnBrand` in the phone package.
    public static let phoneMidnight = ColorBoard(
        id: "midnight", platform: .phone, nameKey: "theme.midnight",
        reason: 0x0A0D14, surface: 0x11161C, surfaceHigh: 0x1B2129,
        line: 0x2A323C, lineQuiet: 0x171D24,
        text: 0xEAF0F6, textMatt: 0xA6B2BF, textQuiet: 0x808C9A,
        textOnLight: Theme.midnight.inkOnBright,
        outline: 0x4F6280, outlineSheet: 0x60759A,
        tag: 0x2D6ACA, brandLight: 0x5C97EE, brandDeep: 0x123258,
        progress: 0xE8B54A, live: 0xE05B4C, success: 0x6FA86A,
        deep: 0x171D24, audio: 0x2A323C, seriesColor: Theme.midnight.accent)

    /// "Contrast" — pure black, neutral grey surfaces, raised signals. **Since
    /// decision 24 the version of both devices**; on the TV the surfaces were
    /// warm-tinted until 2026-09-26.
    public static let phoneContrast = ColorBoard(
        id: "contrast", platform: .phone, nameKey: "theme.contrast",
        reason: 0x000000, surface: 0x141414, surfaceHigh: 0x232323,
        line: 0x3D3D3D, lineQuiet: 0x1C1C1C,
        text: 0xFFFFFF, textMatt: 0xD6D6D6, textQuiet: 0xB4B4B4,
        textOnLight: Theme.contrast.inkOnBright,
        outline: 0x7A7A7A, outlineSheet: 0x8F8F8F,
        tag: 0xC4302B, brandLight: 0xE2564A, brandDeep: 0x6B1710,
        progress: 0xFFC85C, live: 0xFF7A6B, success: 0x7ED97A,
        deep: 0x1C1C1C, audio: 0x3D3D3D, seriesColor: Theme.contrast.accent)
}

extension ColorBoard: CustomStringConvertible {
    /// So that a failed check names scheme and device and not twenty numbers.
    public var description: String { "\(id)/\(platform.rawValue)" }
}
