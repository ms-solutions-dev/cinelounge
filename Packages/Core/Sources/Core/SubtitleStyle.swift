import Foundation

/// How subtitles are drawn — size and colour.
///
/// Applies to **text subtitles with the system engine**, that is, the regular
/// path since the WebVTT side track. ASS subtitles bring their own typeface,
/// and that is intentional: with anime the layout is part of the content —
/// whoever overrode it would make the track worse, not prettier.
///
/// **A time offset is deliberately missing.** Apple's engine cannot shift the
/// timing of a WebVTT track — that would only work with a subtitle renderer
/// of our own. If the need really arises on the device, that is a project of
/// its own and not a switch; the roadmap lists it as a deliberate limit.
public struct SubtitleStyle: Sendable, Equatable {

    /// Size relative to the system default, in percent.
    public enum Size: String, CaseIterable, Sendable, Identifiable {
        case small, standard, large

        public var id: String { rawValue }

        /// 80/100/130: small stays legible (the 18-arc-minute limit from the 55-inch
        /// calculation), large is a clear step instead of cosmetics.
        public var percent: Int {
            switch self {
            case .small: 80
            case .standard: 100
            case .large: 130
            }
        }
    }

    /// Font colour — white like the system, or yellow for bright pictures.
    public enum Color: String, CaseIterable, Sendable, Identifiable {
        case white, yellow

        public var id: String { rawValue }

        /// Red, green, blue, opacity — each 0…1, so that `Core` stays free of
        /// drawing frameworks. The engine does the conversion to system types.
        public var rgba: (red: Double, green: Double, blue: Double, alpha: Double) {
            switch self {
            case .white: (1, 1, 1, 1)
            case .yellow: (1, 0.84, 0.2, 1)
            }
        }
    }

    public var size: Size
    public var color: Color

    public init(size: Size = .standard, color: Color = .white) {
        self.size = size
        self.color = color
    }

    /// The default: the system draws, as the viewer has set it there.
    public static let standard = SubtitleStyle()

    /// Whether anything is intervened at all — without deviation the track stays
    /// with the system, including its accessibility features.
    public var isStandard: Bool { self == .standard }

    static let sizeKey = "playback.subtitleSize"
    static let colorKey = "playback.subtitleColor"
    static let assKey = "playback.plainSubtitles"

    /// Whether glyph-based subtitles (ASS/SSA) should be fetched **as plain
    /// text** instead of forcing VLC.
    ///
    /// **The choice between two real drawbacks** (roadmap P11): ASS brings its
    /// own typeface — positions, colours, karaoke — and only VLC renders that.
    /// In return one loses there everything Apple's engine does better:
    /// picture-in-picture, the TV's frame rate, lower consumption. Whoever
    /// prefers that has the server convert the track to WebVTT and gets plain
    /// text in the system's typeface.
    ///
    /// Default **off**: with anime the layout is part of the content, and a
    /// default that silently throws it away would be a degradation nobody
    /// ordered.
    public static func prefersPlainSubtitles(from store: any KeyValueStore) -> Bool {
        (try? store.value(for: assKey)) == "1"
    }

    /// Stores the choice — **"off" as a value and not as a delete.**
    ///
    /// Until 2026-09-24, "off" here was `remove`. That was equivalent as long as
    /// only the device value existed. In a ``ProfileStore``, however, deleting
    /// means "back to the device", and then a value switched on at the device
    /// would shine through: the person switches off, and at the next film it is
    /// on again.
    public static func setPrefersPlainSubtitles(_ plain: Bool, in store: any KeyValueStore) {
        try? store.set(plain ? "1" : "0", for: assKey)
    }

    public static func load(from store: any KeyValueStore) -> SubtitleStyle {
        SubtitleStyle(
            size: Size(rawValue: (try? store.value(for: sizeKey)) ?? "") ?? .standard,
            color: Color(rawValue: (try? store.value(for: colorKey)) ?? "") ?? .white
        )
    }

    /// Stores size **and** colour — for takeovers and tests. The UI writes per
    /// key (``writeSize(_:in:)``, ``writeColor(_:in:)``); reasoning at
    /// ``AudioPreference/save(to:)``.
    public func save(to store: any KeyValueStore) {
        Self.writeSize(size, in: store)
        Self.writeColor(color, in: store)
    }

    /// Only the size.
    public static func writeSize(_ size: Size, in store: any KeyValueStore) {
        try? store.set(size.rawValue, for: sizeKey)
    }

    /// Only the colour.
    public static func writeColor(_ color: Color, in store: any KeyValueStore) {
        try? store.set(color.rawValue, for: colorKey)
    }
}
