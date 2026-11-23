import Core
import DesignSystemPhone
import SwiftUI

/// The group selection as a **sheet with a search field** — not as a row of chips.
///
/// **Why the row of chips had to go.** The draft drew five curated chips ("All 2.055 ·
/// Germany 1.204 · Turkey 612 · Sport 377 · News 188"); what was built was
/// `ForEach(model.groups)` without an upper limit, and this household's provider carries
/// **96** groups. At 393 points of screen width that is two and a half chips per screen —
/// anyone who wants to reach the last group swipes sideways thirty-eight times.
///
/// **Two levels instead of one** (direction K2c of 2026-09-06): first the prefix, then the
/// subdivision. 96 groups lie on 40 prefixes, and only three of them lead deeper — DE with
/// 23, TR with 20, FR with 14. The full reasoning stands at ``GroupPath``.
///
/// **And the search field is the real handle.** Anyone who knows they are looking for "SOLA
/// BUNDESLIGA" should not climb through two levels. The search covers **both** parts of
/// the name: "bundesliga" finds the group, "de" the country.
struct ChannelGroupSheet: View {

    let routes: [GroupPath]
    /// How many channels are visible in total — the number on "All".
    let total: Int
    /// Which group is currently selected. `nil` means all.
    let chosen: String?
    let select: (String?) -> Void

    @State private var searchTerm = ""
    /// Which country is opened — **one level, not a stack.**
    ///
    /// Two levels are two levels; a stack would be the third build of the same pattern in
    /// this app, and it would have nothing to carry here.
    @State private var pending: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SearchField(text: $searchTerm, placeholder: "live.groupSearch")
                .padding(.horizontal, MetricsBoard.phone.margin)
                .padding(.bottom, Metrics.targetSpacing)

            if let pending, let route = routes.first(where: { $0.land == pending }), !isSearching {
                backRow(route)
                ForEach(route.subdivisions) { part in
                    ChoiceRow(
                        name: part.name, number: part.count.formatted(),
                        chosen: part.group == chosen
                    ) {
                        select(part.group)
                    }
                }
            } else if isSearching {
                match
            } else {
                countryList
            }
        }
        .padding(.bottom, MetricsBoard.phone.gutter)
    }

    private var isSearching: Bool { !searchTerm.trimmingCharacters(in: .whitespaces).isEmpty }

    @ViewBuilder
    private var countryList: some View {
        ChoiceRow(
            name: AppLanguageSetting.text("common.all"),
            number: total.formatted(), chosen: chosen == nil
        ) {
            select(nil)
        }
        ForEach(routes) { route in
            ChoiceRow(
                name: route.land, number: route.count.formatted(),
                // **The checkmark sits on the country when the selected group lies below it.**
                // Otherwise the choice would stand in a level you first have to open to see that you
                // made it.
                chosen: chosen.map { GroupPath.land(from: $0) == route.land } ?? false
            ) {
                if route.leadsDeeper {
                    pending = route.land
                } else if let only = route.subdivisions.first {
                    // **A country with one group is the group.** A second level with one entry would be a
                    // step that decides nothing — and that is the case for 37 of the 40 prefixes.
                    select(only.group)
                }
            }
        }
    }

    /// What the search finds — **across both parts of the name.**
    ///
    /// Flat and not in two levels: Anyone searching wants the result and not the way to it.
    /// The full group name is shown so that "SPORT" stays distinguishable from "DE | SPORT"
    /// and "TR | SPOR".
    @ViewBuilder
    private var match: some View {
        let word = searchTerm.trimmingCharacters(in: .whitespaces)
        let found = routes.flatMap(\.subdivisions).filter {
            $0.group.localizedCaseInsensitiveContains(word)
        }
        if found.isEmpty {
            Footnote(message: "live.groupSearch.none")
        } else {
            ForEach(found) { part in
                ChoiceRow(
                    name: part.group, number: part.count.formatted(),
                    chosen: part.group == chosen
                ) {
                    select(part.group)
                }
            }
        }
    }

    /// The way back from the second level — **and the choice of the whole country next to it.**
    private func backRow(_ route: GroupPath) -> some View {
        HStack(spacing: Metrics.targetSpacing) {
            Button {
                pending = nil
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: Glyph.back.name)
                    Text(verbatim: route.land)
                }
                .font(TypeLevel.label.font)
                .foregroundStyle(ColorRole.textMatt.color)
            }
            .target()
            .accessibilityLabel(Text(app: "common.back"))
            Spacer(minLength: 0)
        }
        .padding(.horizontal, MetricsBoard.phone.margin)
        .padding(.bottom, 4)
    }
}
