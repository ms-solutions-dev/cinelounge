import Core
import DesignSystemPhone
import Observation
import PlaylistKit
import SwiftUI

/// Area 3, third level: **arrange and hide 79 groups.**
///
/// **A page of its own and not a sheet, and the reason is a gesture.** Here things are
/// **dragged** — and the drag gesture of a row competes with the drag gesture that closes a
/// sheet. That is not taste, that is a gesture conflict. On top of that come a long list, a
/// search field and an edit mode; none of that belongs in a sheet.
///
/// **Two modes, and that is the answer to four buttons per row.** On the TV every group
/// carries a checkbox, an up arrow, a down arrow and an eye — with 79 groups that is **316
/// targets**. Here there is normally **one** target per row (the eye), and whoever wants to
/// arrange switches to Edit and drags the handle. 316 becomes 79 plus two bulk commands.
///
/// **The card form without a card (2026-09-07).** Of the six sub-screens, this is the only one
/// that gets no ``SettingsCard`` but ``DesignSystemPhone/cardList()`` — the drag
/// gesture exists only in a `List`, and a rebuilt one would swap a system gesture for a
/// custom one.
///
/// **Hidden and not allowed.** What is stored is what should go away — if the provider adds
/// a group, it is visible without any action. With an allow list it would be silently
/// invisible, and one would look for the error in the app.
struct GroupsView: View {

    @State private var model: GroupsModel
    @State private var isArranging = false

    init(source: (any ChannelListingSource)? = nil) {
        _model = State(initialValue: GroupsModel(source: source))
    }

    var body: some View {
        ZStack {
            ColorRole.reason.color.ignoresSafeArea()

            if model.isLoading {
                LoadingState(message: "live.loading")
            } else if model.allGroups.isEmpty {
                HintRow(
                    icon: Glyph.info.name, title: "settings.live.groups.none",
                    message: "settings.live.groups.none.text")
            } else {
                list
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                if !model.allGroups.isEmpty {
                    Button {
                        withAnimation(Motion.expand) { isArranging.toggle() }
                    } label: {
                        Text(appKey: isArranging ? "common.done" : "settings.edit")
                    }
                }
            }
        }
        .task { await model.load() }
    }

    private var list: some View {
        List {
            // **The header section carries no surface.** Search field and bulk row are
            // tools above the list and not entries in it; drawn on the card
            // surface they would look like the first and second group.
            Section {
                SearchField(text: $model.searchTerm, placeholder: "settings.live.groups.search")
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(ColorRole.reason.color)
                    .listRowSeparator(.hidden)

                SummaryRow(
                    wording: SettingsModel.text(
                        "settings.live.groups.count %lld %lld", model.allGroups.count,
                        model.visibleCount),
                    all: { model.setAll(true) },
                    none: { model.setAll(false) }
                )
                .listRowInsets(EdgeInsets())
                .listRowBackground(ColorRole.reason.color)
                .listRowSeparator(.hidden)
            }
            .moveDisabled(true)

            Section {
                ForEach(model.shown) { group in
                    row(group)
                }
                // **Ordering applies to the whole list and not to the filtered one.**
                // Whoever searches and drags at the same time would move a group to a position that lies
                // elsewhere in the unfiltered catalog — the result would not be
                // predictable. That is why dragging is disabled while a search is active.
                .onMove { from, destination in model.move(from: from, after: destination) }
                .moveDisabled(!model.searchTerm.isEmpty)
            } header: {
                if !model.searchTerm.isEmpty {
                    SectionHeader(
                        wording: SettingsModel.text(
                            "settings.live.groups.found %lld", model.shown.count))
                }
            }
        }
        // **The card form from ``DesignSystemPhone/cardList()``** — see there for why
        // a `List` is used here and not an ``SettingsCard``.
        .cardList()
        .scrollContentBackground(.hidden)
        .background(ColorRole.reason.color)
        .sortIf(isArranging)
    }

    /// **Normally the eye is the only target of the row.**
    ///
    /// In Edit it disappears: the system circle is on the left and the drag handle on the
    /// right, and a third target in between could no longer be hit at 393 points — exactly the
    /// error the two modes avoid.
    private func row(_ group: GroupRow) -> some View {
        HStack(spacing: MetricsBoard.phone.gutter) {
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: group.name)
                    .font(TypeLevel.text.font)
                    .foregroundStyle(group.isVisible ? ColorRole.text.color : ColorRole.textQuiet.color)
                    .lineLimit(1)
                Text(verbatim: SettingsModel.text("live.channelCount %lld", group.count))
                    .font(TypeLevel.label.font)
                    .foregroundStyle(ColorRole.textQuiet.color)
            }

            Spacer(minLength: Metrics.targetSpacing)

            if !isArranging {
                Button {
                    model.setEnabled(group.name)
                } label: {
                    Image(
                        systemName: group.isVisible
                            ? Glyph.isVisible.name : Glyph.hidden.name
                    )
                    .font(TypeLevel.footer.font)
                    .foregroundStyle(group.isVisible ? ColorRole.textMatt.color : ColorRole.textQuiet.color)
                    .frame(width: Metrics.target, height: Metrics.target)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(
                    Text(appKey: group.isVisible ? "settings.hide" : "settings.show")
                )
                .accessibilityValue(Text(verbatim: group.name))
            }
        }
        // **``Metrics/cardInset`` and not ``Styling/MetricsBoard/margin`` (2026-09-07).** Since
        // ``DesignSystemPhone/cardList()`` the list itself is already inset 20 points from the
        // screen edge; another 20 inside would make 40, and the group name would sit noticeably
        // narrower than any other row in the area.
        .padding(.horizontal, isArranging ? 0 : Metrics.cardInset)
        .frame(minHeight: Metrics.choiceRow)
        .listRowInsets(
            EdgeInsets(
                top: 0, leading: isArranging ? Metrics.cardInset : 0, bottom: 0,
                trailing: isArranging ? Metrics.cardInset : 0)
        )
        // **Surface and not background.** The row lies in a section of the card; drawn on
        // the background it would be a hole in it.
        .listRowBackground(ColorRole.surface.color)
        .listRowSeparatorTint(ColorRole.lineQuiet.color)
    }
}

/// A group as the list shows it.
public struct GroupRow: Sendable, Equatable, Identifiable {
    public let name: String
    public let count: Int
    public let isVisible: Bool
    public var id: String { name }
}

/// Which groups exist, which are visible and in what order.
///
/// **Saved on toggle, freshly read on every action** — the same rule as in
/// ``LiveSettingsModel``: `LivePreferences` stores all fields in one go, and a held
/// copy would overwrite what has meanwhile been changed elsewhere.
@MainActor
@Observable
public final class GroupsModel {

    /// All of the provider's groups, in the current order.
    public private(set) var allGroups: [GroupRow] = []
    public private(set) var isLoading = false

    public var searchTerm = ""

    private let source: (any ChannelListingSource)?
    private let keychain: any KeyValueStore
    private var counts: [String: Int] = [:]

    public init(source: (any ChannelListingSource)? = nil, keychain: (any KeyValueStore)? = nil) {
        self.source = source
        self.keychain = keychain ?? SecureStore()
    }

    /// What the list shows — **filtered, but never re-sorted.**
    public var shown: [GroupRow] {
        let term = searchTerm.trimmingCharacters(in: .whitespaces).lowercased()
        guard !term.isEmpty else { return allGroups }
        return allGroups.filter { $0.name.lowercased().contains(term) }
    }

    public var visibleCount: Int { allGroups.count(where: \.isVisible) }

    public func load() async {
        guard let source, allGroups.isEmpty else { return }
        isLoading = true
        let catalog = await source.channels()
        isLoading = false
        var tally: [String: Int] = [:]
        var order: [String] = []
        for channels in catalog.channels {
            let name = channels.group ?? ChannelGroup.unnamed
            if tally[name] == nil { order.append(name) }
            tally[name, default: 0] += 1
        }
        counts = tally
        build(order)
    }

    /// Builds the list from the provider's order and the preferences.
    private func build(_ order: [String]) {
        let preferences = LivePreferences.load(from: keychain)
        allGroups = preferences.ordered(order).map {
            GroupRow(
                name: $0, count: counts[$0] ?? 0, isVisible: preferences.allows(group: $0))
        }
    }

    public func setEnabled(_ name: String) {
        let isVisible = allGroups.first { $0.name == name }?.isVisible ?? true
        update { $0.setVisible(!isVisible, group: name) }
    }

    public func setAll(_ isVisible: Bool) {
        let names = allGroups.map(\.name)
        update { preferences in
            for name in names { preferences.setVisible(isVisible, group: name) }
        }
    }

    /// **The new order is stored in full and not as a move.**
    ///
    /// `groupOrder` is a list and not a sorting rule; whoever stored only the moved name would
    /// have to guess the order again when reading.
    public func move(from: IndexSet, after destination: Int) {
        var names = allGroups.map(\.name)
        names.move(fromOffsets: from, toOffset: destination)
        update { $0.setGroupOrder(names) }
    }

    private func update(_ change: (inout LivePreferences) -> Void) {
        var fresh = LivePreferences.load(from: keychain)
        change(&fresh)
        fresh.save(to: keychain)
        build(allGroups.map(\.name))
    }
}
