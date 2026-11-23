import Core
import DesignSystemPhone
import SwiftUI

/// The **index**: one row per catalog, under the name the service reports.
///
/// **The only place in the whole design that promises completeness.** The tab bar
/// cannot — five slots against any number of libraries —, and neither can Home: It
/// shows at most four catalog shelves and is thus a selection. Whoever looks for a
/// catalog finds it here or nowhere.
///
/// **No allow list, no kind check.** Every catalog gets a row, whatever its
/// kind — only that way the fourteenth library of someone else's user does not fall
/// off the end. `Core.Library.Kind` could not classify it anyway: Collections and
/// directories both arrive as `.mixed`.
///
/// **If the index is ever capped, filtered or given an allow list, the design
/// breaks silently** — nothing visible is missing then, only a way.
///
/// **It comes from below, not from the title.** At the large title the choice would lie
/// between y = 152 and 480 and so entirely above the thumb limit of 560.
///
/// **The origin stands once as a heading, not as a badge on every row.**
/// "JF" six times one under the other is no information; the mark on the row says
/// the kind instead.
struct CatalogPickerSheet: View {

    let state: CatalogState
    let chosen: Catalog.Identifier?
    let select: (Catalog) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(groups, id: \.headline) { group in
                if group.isSeparated {
                    // **Set apart, but as a choice.** The downloads are not a third
                    // provider but the cut-out of the others that already lies on the
                    // device — and still the catalog the library
                    // shows when you are in it.
                    Divider().overlay(ColorRole.line.color).padding(.vertical, 6)
                }
                SectionHeader(wording: group.headline)
                ForEach(group.catalogs) { catalog in
                    ChoiceRow(
                        name: name(catalog),
                        icon: catalog.kind.icon,
                        number: catalog.extent?.formatted(.number),
                        chosen: catalog.id == chosen
                    ) {
                        select(catalog)
                    }
                }
            }
        }
    }

    /// A section of the index.
    struct Group {
        let headline: String
        let catalogs: [Catalog]
        let isSeparated: Bool
    }

    /// **Grouped by heading, not by origin.**
    ///
    /// With a media server the two are the same. With two providers they are not: They
    /// share an origin and carry two names — and that was exactly the finding of 2026-09-05.
    /// (how would the system behave if several IPTV providers had been set up?).
    /// Grouped by origin, both would stand under one heading and could not be told
    /// apart.
    ///
    /// **The order is still that of the origins** — own first, then
    /// foreign, last the loaded. Within an origin, the order in which the sources
    /// answer decides; that is the order the user set during
    /// setup.
    var groups: [Group] {
        var built: [Group] = []
        for origin in Self.order {
            let catalogs = state.catalogs(from: origin)
            guard !catalogs.isEmpty else { continue }
            var seen: [String] = []
            for catalog in catalogs {
                let title = headline(catalog)
                guard !seen.contains(title) else { continue }
                seen.append(title)
                built.append(
                    Group(
                        headline: title,
                        catalogs: catalogs.filter { headline($0) == title },
                        isSeparated: origin == .downloads && built.contains { !$0.isSeparated }))
            }
        }
        return built
    }

    /// A catalog's heading — its own group name, otherwise that of its
    /// origin.
    private func headline(_ catalog: Catalog) -> String {
        if let group = catalog.group { return labeled(group) }
        return AppLanguageSetting.text(.init(Self.headline(catalog.origin)))
    }

    private func labeled(_ label: CaptionLabel) -> String {
        switch label {
        case .key(let key): AppLanguageSetting.text(.init(key))
        case .wording(let wording): wording
        }
    }

    /// Own first, then foreign, last the loaded — the same ranking as in
    /// the tab bar and on the TV.
    private static let order: [Catalog.Origin] = [
        .jellyfin, .provider, .channelList, .portals, .downloads,
    ]

    private static func headline(_ origin: Catalog.Origin) -> String {
        switch origin {
        case .jellyfin: "stock.mediaServer"
        case .provider: "stock.provider"
        case .channelList: "tab.live"
        case .portals: "tab.portals"
        case .downloads: "stock.offline"
        }
    }

    /// A key is translated, a wording stands as the service reports it.
    private func name(_ catalog: Catalog) -> String { labeled(catalog.label) }
}
