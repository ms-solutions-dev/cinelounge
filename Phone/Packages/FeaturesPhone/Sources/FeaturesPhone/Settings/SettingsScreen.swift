import DesignSystemPhone
import SwiftUI

/// Eleven areas, four groups, one header.
///
/// **The value column on the right says what is in there** — so one does not have to open
/// an area to see whether something is missing. That is the done condition of this package: a
/// list of names and chevrons forces one tap per question.
///
/// **The rebuild of 2026-09-07** Four passes — iOS platform, design, usability, gaps and
/// market — described the same finding from four sides, and the requirement stated it in one
/// sentence: the area looks rigid, dated and unattractive. Three causes, all here:
///
/// * **Nine identical-looking rows are nine equally important rows.** Each 59 points
///   high, the same indent, the same font, separated by the same hairline. Now four groups in
///   cards, each with its own heading — and the question "where does something come from"
///   no longer sits next to "who may do what".
/// * **No change of material over 531 points.** The prototype draws every group as a
///   card; what was built was a bare `VStack` on the background. See ``SettingsCard``.
/// * **The account was the ninth entry.** Whoever opens the area wants to know first
///   whose settings they are looking at — not last.
///
/// **And since E49 a search sits above it** — see ``SettingsCatalog``. It is the one
/// market finding that none of the examined competitors meets, and it answers the question
/// a value column cannot answer: not "what is in there", but "where is what I am looking
/// for".
///
/// **Two areas were added**, and neither was a matter of taste: Storage (it was one level
/// deeper, and the path there ended in the developer screen) and "About" (privacy policy and
/// licenses were missing entirely — **guideline 5.1.1(i) requires them inside the app**).
public struct SettingsScreen: View {

    @State private var model = SettingsModel()

    /// What is currently being searched for — **empty means: the cards are shown.**
    @State private var searchTerm = ""

    /// Which width class is drawn in — see ``MetricClass``.
    ///
    /// **The finding from the iPad Pro 13″ (1032 points wide), AP7, 2026-09-23:** label on the
    /// left, value right-aligned at the far edge — between "Ratings" and "no key" there were
    /// **up to 1700 points** of empty space, between "Storage" and "37.7 MB" likewise. A
    /// ``DisclosureRow`` is no error; one 992 points wide is: eye and finger have to travel the
    /// whole distance to bring together two pieces of information that belong together.
    ///
    /// **Via the class and never via the device** (see ``MetricClass``): Split View and Stage
    /// Manager give the iPad the compact class with an unchanged device identifier, and there
    /// the full width is correct.
    @Environment(\.horizontalSizeClass) private var widthClass

    private let open: (ViewID) -> Void

    public init(open: @escaping (ViewID) -> Void = { _ in }) {
        self.open = open
    }

    /// The value as text — **here and not in the model.** The model holds the statement, the
    /// view its presentation.
    static func readable(_ value: SettingsModel.Value) -> String {
        switch value.label {
        case .key(let name): SettingsModel.text(name)
        case .wording(let text): text
        }
    }

    public var body: some View {
        ZStack {
            ColorRole.reason.color.ignoresSafeArea()

            ScrollSurface {
                VStack(alignment: .leading, spacing: 0) {
                    LargeTitle(title: "settings.title")
                        .padding(.horizontal, MetricsBoard.phone.margin)
                        .padding(.bottom, MetricsBoard.phone.gutter)

                    // **The search field sits above everything and not in a card.** It
                    // belongs to no area but to all — the same position that iOS
                    // gives it in its own Settings.
                    SearchField(text: $searchTerm, placeholder: "settings.search")
                        .padding(.horizontal, MetricsBoard.phone.margin)
                        .padding(.bottom, MetricsBoard.phone.section)

                    if searchTerm.trimmingCharacters(in: .whitespaces).isEmpty {
                        cards
                    } else {
                        match
                    }
                }
                // **A cap over everything — title, search field and cards together.** Capping
                // only the cards would leave the search field above them standing 992 points wide,
                // and its clear cross would sit at the right edge of the screen, half a meter
                // from the word being typed. The cap is the **column**, not the card. Why cap and center
                // belong together is explained at ``ContentColumn``.
                .contentColumn(widthClass)
                .padding(.top, MetricsBoard.phone.gutter)
            }
        }
        // **Recomputed on every appearance.** Whoever comes back from an area has
        // perhaps changed something there — a value column that shows the state from
        // before is worse than none: it looks right.
        .onAppear { model.calculate() }
        // The error counter arrives later; the ledger is an actor.
        .task { await model.countErrors() }
    }

    /// What is shown without a search term: account header and four groups.
    @ViewBuilder
    private var cards: some View {
        accountHeader

        ForEach(SettingsModel.Area.Group.allCases) { group in
            SettingsCard(header: group.titleKey) {
                let sections = SettingsModel.Area.available.filter {
                    $0.group == group
                }
                ForEach(sections) { area in
                    row(area)
                    if area != sections.last {
                        // **The same ``Separator`` as everywhere.** Here it was written by hand with
                        // `14 + 28 + MetricsBoard.phone.gutter` — the same calculation a second time, and
                        // the 14 became wrong the moment the card inset
                        // changes.
                        Separator(isIndented: true)
                    }
                }
            }
        }
    }

    /// What a search term finds — **one card and no second screen.**
    ///
    /// **The market finding of 2026-09-07:** None of the examined apps has a search across their
    /// settings; iOS itself has had it for years. The most common case is not "I know where it
    /// is" but "I know what it is called" — whoever looks for the subtitle size currently has to
    /// know that it sits under *Playback* and not under *Appearance*. Both would be defensible,
    /// and that is exactly why one guesses wrong.
    ///
    /// **The value column names the area, and that is half the answer.** Whoever has once seen
    /// that "Subtitles" is under *Playback* no longer has to search next time — a search that
    /// only jumps there teaches nothing.
    ///
    /// **The jump goes to the screen and not to the row.** See ``SettingsCatalog``: there is
    /// no anchor per row, and claiming one would be worse than its absence.
    @ViewBuilder
    private var match: some View {
        let found = SettingsCatalog.match(zu: searchTerm)
        if found.isEmpty {
            // **The sentence says what is being searched.** "Nothing found" alone leaves
            // open whether the term was wrong or the setting is missing.
            SettingsCard {
                HintRow(
                    icon: Glyph.Tab.search.outlined, title: "settings.search.none",
                    message: "settings.search.none.text")
            }
        } else {
            SettingsCard {
                ForEach(Array(found.enumerated()), id: \.element.id) { slot, entry in
                    if slot > 0 { Separator(isIndented: true) }
                    DisclosureRow(
                        wording: SettingsModel.text(entry.title),
                        icon: entry.area.icon,
                        value: SettingsModel.text(entry.area.titleKey),
                        isContained: true
                    ) {
                        // **The field is cleared before the screen changes.** Whoever
                        // comes back would otherwise find their old search and not the
                        // settings — the same consideration as for the open swipe in
                        // ``ChannelListsView``.
                        searchTerm = ""
                        open(entry.view)
                    }
                }
            }
        }
    }

    /// Whose settings these are — **as a header and not as a ninth row.**
    ///
    /// It leads to the same place as the old "Account" row; what changes is the ranking and the
    /// information: name and server are shown now, without anyone having to tap.
    private var accountHeader: some View {
        SettingsCard {
            Button {
                open(.accountSettings)
            } label: {
                HStack(spacing: 13) {
                    // **The circle and not ``ProfileImage``.** That one is a button; here
                    // it sits inside one, and a button inside a button takes the outer one's
                    // hit area.
                    Text(verbatim: String(model.accountName.prefix(1)).uppercased())
                        .font(TypeLevel.header.font)
                        .foregroundStyle(ColorRole.text.color)
                        .frame(width: 44, height: 44)
                        .background(ColorRole.brandDeep.color, in: Circle())
                    VStack(alignment: .leading, spacing: 1) {
                        Text(verbatim: model.accountName)
                            .font(TypeLevel.header.font)
                            .foregroundStyle(ColorRole.text.color)
                        Text(verbatim: model.accountLine)
                            .font(TypeLevel.label.font)
                            .foregroundStyle(ColorRole.textMatt.color)
                            .lineLimit(1)
                    }
                    Spacer(minLength: Metrics.targetSpacing)
                    Image(systemName: Glyph.next.name)
                        .font(TypeLevel.label.font)
                        .foregroundStyle(ColorRole.textQuiet.color)
                }
                .padding(.horizontal, Metrics.cardInset)
                .padding(.vertical, 11)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    private func row(_ area: SettingsModel.Area) -> some View {
        let value = model.values[area]
        return DisclosureRow(
            title: area.titleKey,
            icon: area.icon,
            value: value.map(Self.readable),
            isMissing: value?.isMissing ?? false,
            isContained: true
        ) {
            open(area.view)
        }
    }
}
