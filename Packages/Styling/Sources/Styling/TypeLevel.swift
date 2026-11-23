import SwiftUI

/// The eight type levels of both devices — **one role, two implementations.**
///
/// The roles already matched almost one to one before, only the names did not
/// (`hero` versus `large`, `title3` versus `section`; report B finding 17). Here each
/// role stands once. **It is implemented differently per device, and that stays so:**
///
/// - **TV: fixed sizes.** tvOS has no Dynamic Type, and the sizes are calculated for
///   a 55-inch TV at three metres (one point = 0.73 arc minutes; below
///   about 18′ reading becomes an effort, so the smallest stand at 25 and 27).
/// - **Phone: text styles.** The design's levels hit the iOS text styles point for point
///   (34 · 28 · 22 · 17 · 17 · 15 · 13 · 11), and via the text styles Dynamic Type comes in
///   every level for free. Fixed point sizes would break at XXL.
///
/// On the TV ``footer`` and ``label`` fall to the same size (27): From three
/// metres a level below no longer holds, and the next smaller one (25) is reserved
/// for accessories.
///
/// **Here — and only here — `.system(size:)` stands as the construction of the scale.** The guard
/// `scripts/type_scale.py` exempts this one file.
public enum TypeLevel: String, Sendable, CaseIterable {
    /// Lead, page title on opening. TV `hero`, phone `large`.
    case lead = "aufmacher"
    /// Titel, Filmtitel. Fernseher `title`, Handy `title`.
    case title = "titel"
    /// Shelf heading. TV `title3`, phone `section`.
    case section = "abschnitt"
    /// Zeilentitel, Knopfbeschriftung. Fernseher `headline`, Handy `header`.
    case header = "kopf"
    /// Body text — on the TV the smallest permitted size for it.
    case text
    /// Zweitzeile, Angaben. Fernseher `caption`, Handy `footer`.
    case footer = "fuss"
    /// Abzeichen, Uhrzeit, Nebenangabe. Fernseher `caption`, Handy `label`.
    case label = "beschriftung"
    /// Accessories and all-caps marks such as `LIVE`. TV `caption2`, phone `lowercased`.
    case lowercased = "klein"

    /// The size in points — fixed on the TV, on the phone the base size of the text style
    /// at the default font size.
    public func points(_ platform: UIPlatform) -> CGFloat {
        switch platform {
        case .tv:
            switch self {
            case .lead: 76
            case .title: 57
            case .section: 48
            case .header: 38
            case .text: 29
            case .footer, .label: 27
            case .lowercased: 25
            }
        case .phone:
            switch self {
            case .lead: 34
            case .title: 28
            case .section: 22
            case .header, .text: 17
            case .footer: 15
            case .label: 13
            case .lowercased: 11
            }
        }
    }

    /// The weight. `nil` means: that of the text style (on the phone `headline` is semibold
    /// by itself), on the TV `regular`.
    ///
    /// **There are no thin weights** — fine strokes vanish in the TV's image
    /// compression and at small size on the phone.
    public func weight(_ platform: UIPlatform) -> Font.Weight? {
        switch (platform, self) {
        case (.tv, .lead): .heavy
        case (.tv, .title), (.tv, .section): .bold
        case (.tv, .header): .semibold
        case (.tv, _): .regular
        case (.phone, .lead), (.phone, .title): .bold
        case (.phone, .section), (.phone, .lowercased): .semibold
        case (.phone, _): nil
        }
    }

    /// The font of this level on this device.
    public func font(_ platform: UIPlatform) -> Font {
        switch platform {
        case .tv:
            return .system(size: points(.tv), weight: weight(.tv) ?? .regular)
        case .phone:
            guard let weight = weight(.phone) else { return textStyle }
            return textStyle.weight(weight)
        }
    }

    private var textStyle: Font {
        switch self {
        case .lead: .largeTitle
        case .title: .title
        case .section: .title2
        case .header: .headline
        case .text: .body
        case .footer: .subheadline
        case .label: .footnote
        case .lowercased: .caption2
        }
    }

    /// How tall a line of a font size stands — **size × line factor, rounded up.**
    ///
    /// Only needed where a line bounds a tile and the height is therefore fixed.
    /// Whoever sets a fixed height for text gets it here — a copied number is the
    /// only way a font change can silently break something.
    public static func lineHeight(zu size: CGFloat, _ platform: UIPlatform) -> CGFloat {
        (size * lineFactor(platform)).rounded(.up)
    }

    /// The line factor — **two justified values in one file, not one.**
    ///
    /// Report B wanted one. Checked (AP58, 2026-09-26): Neither value is chosen,
    /// both are back-calculated — on the TV from the line heights that proved
    /// right on the device (channel list, information column), on the phone from `GESTALTUNG.md`
    /// §2. A shared value visibly changes fixed heights on one device: 1.3 on the TV
    /// raises the 38 line from 49 to 50 points and shifts the channel list; 1.28 on the
    /// phone lowers the 17 line from 23 to 22 points and cuts off descenders
    /// in some fonts. Neither is "visibly uncritical" — so a variant.
    public static func lineFactor(_ platform: UIPlatform) -> CGFloat {
        switch platform {
        case .tv: 1.28
        case .phone: 1.3
        }
    }
}
