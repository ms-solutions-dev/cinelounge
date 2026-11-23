import Foundation

/// Combines the feeds of the same channel into one entry.
///
/// **The finding** (viewer, 2026-08-29: for one broadcast 10 channels are shown, "something may
/// not fit there either"). The viewer was right, and the source agreed: The schedule names
/// exactly **one** channel ("Kule Sport Plus"). The provider's channel list has ten of them —
/// the same station in ten feeds, all under the same program identifier. In the examined
/// catalog there are four entries for `PusulaSports1.tr`, three of them with the same name:
///
/// ```
/// KIES: Pusula SP⚽RTS 1 RAW
/// KIES: Pusula SP⚽RTS 1 RAW
/// KIES: Pusula SP⚽RTS 1 RAW
/// KIES: Pusula SP⚽RTS 1 ᵁᴴᴰ 3840P
/// ```
///
/// The display was not wrong — but it was unusable: Four chips say the same thing, and the
/// channel bar of one row was full before the second real channel came up.
///
/// **The program identifier is the key, not the name.** It *is* the station: Two different
/// channels never share it, the same station carries it in every version. Only where there
/// is none — with this provider 58 of 75 entries — does it fall back to the name without
/// the version word.
///
/// **What does NOT happen here: choosing.** What belongs together is bundled; which version
/// starts is decided by ``quality(_:)`` and is an ordering, not a deletion. The others stay in
/// the bundle and in the catalog — in the player the whole group remains available to
/// choose from.
public enum ChannelVariants {

    /// A channel with all its feeds, the best first.
    public struct VariantGroup: Sendable, Equatable, Identifiable {
        /// The station name without the version word — "KIES: Pusula SPORTS 1".
        public let name: String
        /// All feeds, ordered by quality.
        public let variants: [Channel]

        public init(name: String, variants: [Channel]) {
            self.name = name
            self.variants = variants
        }

        /// The version that starts.
        public var best: Channel { variants[0] }
        public var count: Int { variants.count }
        public var id: String { best.id }
    }

    /// Bundles a catalog.
    ///
    /// The order of the bundles follows the **first appearance** — that is, the provider's order,
    /// which for many is the familiar channel numbering (same consideration as for
    /// ``LivePreferences/groupOrder``). Within a bundle the quality applies, and for equal
    /// quality again the provider's order.
    public static func bundles(_ channels: [Channel]) -> [VariantGroup] {
        var order: [String] = []
        var collected: [String: [Channel]] = [:]

        for channel in channels {
            let key = key(channel)
            if collected[key] == nil { order.append(key) }
            collected[key, default: []].append(channel)
        }

        return order.compactMap { key in
            guard let variants = collected[key], !variants.isEmpty else { return nil }
            // `enumerated` as a tie-breaker: `sorted` is not stable, and without an anchor two
            // equivalent versions would swap places on every redraw — the same finding as with
            // simultaneous events in the schedule (2026-08-16).
            let ordered =
                variants.enumerated()
                .sorted { links, right in
                    let a = quality(links.element)
                    let b = quality(right.element)
                    return a == b ? links.offset < right.offset : a > b
                }
                .map(\.element)
            return VariantGroup(name: stationName(ordered[0]), variants: ordered)
        }
    }

    /// **One** entry per station — the first, which for a list sorted by "last watched" is the
    /// youngest.
    ///
    /// **The finding (on-device test 2026-09-28):** "TR: Ayaz", "TR: Ayaz HD*" and "TR: Ayaz HQ"
    /// stood three times in a row in "Continue Watching" — three versions of the same station
    /// with the same program guide and the same logo.
    public static func perStation(_ channels: [Channel]) -> [Channel] {
        var seen = Set<String>()
        return channels.filter { seen.insert(key($0)).inserted }
    }

    /// By what two entries are recognised as the same station.
    static func key(_ channel: Channel) -> String {
        if let epg = channel.epgID, !epg.isEmpty { return "epg:" + epg }
        return "name:" + ChannelName.searchKey(stationName(channel))
    }

    /// The name without the version words at the end.
    ///
    /// Only **at the end** and only whole words: "4K Nature" is a channel, "SPORT 1 HD" is a
    /// version of "SPORT 1". And numbers stay, otherwise "Pusula SPORTS 1" would become the station
    /// "Pusula SPORTS".
    public static func stationName(_ channel: Channel) -> String {
        var words = channel.cleanName.split(separator: " ").map(String.init)
        while let last = words.last, isVariantWord(last), words.count > 1 {
            words.removeLast()
        }
        return words.joined(separator: " ")
    }

    /// Whether a word denotes a feed and not the station.
    static func isVariantWord(_ word: String) -> Bool {
        let blank = word.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
            .uppercased()
            .filter { $0.isLetter || $0.isNumber }
        if blank.isEmpty { return true }
        if variantWords.contains(blank) { return true }
        // Resolutions in numeric form: 1080P, 2160I, 3840P, 60FPS.
        return blank.range(of: #"^\d{2,4}(P|I|FPS)$"#, options: .regularExpression) != nil
    }

    static let variantWords: Set<String> = [
        "RAW", "HD", "FHD", "UHD", "SD", "HQ", "LQ",
        "4K", "8K", "2K",
        "HEVC", "H264", "H265", "X264", "X265", "AVC",
        "MOBIL", "MOBILE", "LOW", "BACKUP", "ALT", "MULTI",
        "DOLBY", "AUDIO", "ATMOS", "AC3", "EAC3", "DD", "DDP",
    ]

    /// The quality of a feed — the larger, the better liked.
    ///
    /// **From the name and from nothing else.** The resolution of a stream appears nowhere in the
    /// channel list; it is in the name because the provider writes it there so one can choose.
    /// Where it writes nothing, the middle applies — a nameless version is not a bad one, it is an
    /// unlabelled one, and it may neither beat the 4K version nor fall behind the MOBIL version.
    ///
    /// The **best** word in the name wins, not the last: "UHD 3840P" names the same thing
    /// twice.
    public static func quality(_ channel: Channel) -> Int {
        let words = ChannelName.searchKey(channel.name).split(separator: " ").map(String.init)
        var best = 50
        var found = false
        for word in words {
            guard let tier = tier(word) else { continue }
            best = found ? max(best, tier) : tier
            found = true
        }
        return best
    }

    static func tier(_ word: String) -> Int? {
        switch word {
        case "8K", "4320P": return 120
        case "4K", "UHD", "2160P", "3840P": return 100
        case "FHD", "1080P", "1080I": return 80
        case "HD", "720P": return 60
        case "SD", "576P", "576I", "480P", "360P": return 30
        case "MOBIL", "MOBILE", "LOW", "LQ": return 10
        default: return nil
        }
    }
}
