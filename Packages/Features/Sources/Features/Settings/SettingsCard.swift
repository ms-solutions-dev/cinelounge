import Core
import DesignSystem
import SwiftUI

/// Where a setting belongs — **to the person or to the device** (AP41/AP46).
///
/// **The one piece of information no app on the market gives.** Whoever changes the
/// preferred audio track does not know whether they do it for themselves or for the
/// household; whoever switches the playback engine does not know whether that also changes
/// the setting on another room's TV. Both cases appear in the same list and look the same.
///
/// **It appears once under the card and not on every row**, unlike what the head of AP46
/// proposed. On every row it would be the same word twenty times one under the other — and
/// the row already carries its value on the right. Under the card it applies to exactly
/// what the focus is on, and is thus unambiguous without repetition.
nonisolated enum Validity: Equatable, Sendable, CaseIterable {

    /// Travels with the person to every device on which their profile is signed in.
    case profile

    /// Stays on this TV, no matter who is signed in.
    case device

    /// The pill next to the sentence — two words, because the sentence resolves it.
    ///
    /// **Written out and not assembled from the name.** `scripts/strings.py` reads usages as
    /// literals; a key built from parts counts as unused to it, and then the next pass clears
    /// away the entry this row needs right now.
    var markKey: String {
        switch self {
        case .profile: "settings.origin.profile"
        case .device: "common.thisDevice"
        }
    }

    /// The sentence next to it that resolves the pill.
    var sentenceKey: String {
        switch self {
        case .profile: "settings.origin.profileHint"
        case .device: "settings.origin.deviceHint"
        }
    }

    /// The colour of the pill.
    ///
    /// **Progress gold for "travels with", muted for the device.** What travels along is the
    /// app's promise and the more conspicuous of the two statements; what stays on the device is
    /// the normal case and needs no colour.
    var color: Color {
        switch self {
        case .profile: ColorRole.progress.color
        case .device: ColorRole.textQuiet.color
        }
    }
}

/// An option in the card's preview.
///
/// **Finished wording and no language key.** The pills speak about language names, server
/// names and numbers — the same split ``DisclosureRow`` made for its value column, and for the
/// same reason: a key per pill would have to be maintained with every new option.
nonisolated struct CardPill: Equatable, Sendable, Identifiable {

    let wording: String
    let chosen: Bool
    /// What the pill stands for when it is chosen in a walkable card.
    ///
    /// **Not the wording**, even though it becomes that when nothing is given: the wording is
    /// translated, and a choice that hung on it would be a different one in every language.
    let identifier: String

    var id: String { identifier }

    init(_ wording: String, chosen: Bool = false, identifier: String? = nil) {
        self.wording = wording
        self.chosen = chosen
        self.identifier = identifier ?? wording
    }
}

/// What can be chosen in a **walkable** card (AP46, decision 6).
///
/// **The action travels with the work item and is skipped in comparison.** The card lives
/// in ``SettingsView``, the choice belongs to the area that builds the row — only it knows
/// where it is written to. A mapping from identifiers to actions in the view would be a
/// second list next to the areas. `==` therefore compares row and choice and not the
/// closure, which cannot be compared.
nonisolated struct CardSelection: Equatable, Sendable {
    /// The identifier of the row that reported the card.
    let row: String
    let select: @MainActor @Sendable (String) -> Void

    static func == (links: CardSelection, right: CardSelection) -> Bool {
        links.row == right.row
    }
}

/// What the right column says about the focused row (AP46, 2026-09-24).
///
/// **Pure data and no view**, so that the computations are testable: whether the footnote
/// appears is a decision with a rule, and nobody can recompute a rule inside a `body`. The
/// same cut as with ``SetupState``.
///
/// **The card hangs on the row and not on the area.** In the design it carries the head of
/// the focused row, its value, its options and its scope; when the focus is one row further,
/// something else is in it. An area has no options, a setting has.
nonisolated struct CardSpec: Equatable, Sendable {

    /// The head in capitals — **the same text as in the row on the left.**
    ///
    /// A repetition, and it is intended: the card stands about 950 points beside the row it
    /// refers to. Without the head you would have to look back and forth between the two to be
    /// sure they belong together — a real loss at three metres.
    let header: String

    /// The head verbatim — for names nobody translates.
    ///
    /// **The same pair as at ``DisclosureRow``** and for the same reason: a server name, a package
    /// name, the name of a channel list needs no key, and one for it would have to be
    /// maintained with every new entry.
    var headerWording: String?

    /// The current value at 38 pt as a language key — **the largest type on the card.**
    ///
    /// **The same pair as for the head, and it was necessary:** the first draft took only
    /// finished wording here, because the values speak about numbers and server names. But with
    /// the first area that reported a card, half of the values lived in the language catalog
    /// ('Automatic', 'Always', 'Small') — fetching them through the catalog and passing them as
    /// wording would have spread the resolution across every call site.
    var statement: String

    /// The value verbatim — for counts, language names and server names.
    var statementWording: String?

    /// The explanatory sentence under the statement, as a language key.
    var explanation: String?

    /// The preview — empty for rows that have nothing to choose.
    var pills: [CardPill] = []

    /// How many options there are **in total**.
    ///
    /// **Separate from ``pills``, because the card cannot show all of them.** Seventy-nine
    /// channel groups as pills would not be a preview but a second list. The difference between
    /// the two numbers determines whether the footnote appears.
    var optionCount: Int?

    /// Where the setting belongs — `nil` where it is not a setting.
    ///
    /// **Leave it out and do not guess.** A row that leads into a sub-screen changes nothing
    /// itself; attributing a scope to it would be a statement about something that only comes
    /// after it.
    var validity: Validity?

    /// Set when the card is **walkable**: its pills are then buttons.
    var selection: CardSelection?

    init(
        header: String = "",
        headerWording: String? = nil,
        statement: String = "",
        statementWording: String? = nil,
        explanation: String? = nil,
        pills: [CardPill] = [],
        optionCount: Int? = nil,
        validity: Validity? = nil,
        selection: CardSelection? = nil
    ) {
        self.header = header
        self.headerWording = headerWording
        self.statement = statement
        self.statementWording = statementWording
        self.explanation = explanation
        self.pills = pills
        self.optionCount = optionCount
        self.validity = validity
        self.selection = selection
    }

    /// The same card after a choice was made in it.
    ///
    /// **The card catches up with the choice itself**, because the row cannot: it has handed
    /// over the focus and reports nothing any more. Without that, after a press on 'Favorites'
    /// 'Continue Watching' would still appear filled — the choice would be written and the
    /// display would claim the opposite.
    nonisolated func withSelection(_ identifier: String) -> CardSpec {
        guard let incoming = pills.first(where: { $0.identifier == identifier }) else { return self }
        var spec = self
        spec.pills = pills.map {
            CardPill($0.wording, chosen: $0.identifier == identifier, identifier: $0.identifier)
        }
        spec.statement = ""
        spec.statementWording = incoming.wording
        return spec
    }

    /// What a row passes upward — **its work item only while it has the focus.**
    ///
    /// **The condition is the entire wiring, and that is why it belongs in a computation.**
    /// Without it all visible rows report at the same time, and ``CardKey`` takes the
    /// **first in the tree** — that is, the topmost of the area, wherever the focus is. The card
    /// would then stand still and say the same to every row: wrong without ever being empty, and
    /// thus the kind of error that on the device is taken for a trifle.
    ///
    /// **In the `body` it would be untestable** — a preference on a view that is not drawn
    /// cannot be read out. As a computation it can, and the counter-test thus hits the wiring and
    /// not just the computation next to it.
    nonisolated static func report(_ spec: CardSpec?, focused: Bool) -> CardSpec? {
        focused ? spec : nil
    }

    /// The card for a switch — **with its state as a statement.**
    ///
    /// **The state appears twice, and that is right:** at the row's checkmark as a glyph, in the
    /// card as a word. From three metres a checkmark is a dot; the word says which of the two
    /// states applies without the need to interpret the shape.
    ///
    /// **`explanation` and `validity` without a default.** If the row already carries its sentence
    /// itself (``SwitchRow/message``), it would appear a second time in the card — then `nil`
    /// is right, and the call site should decide that, not a default. And the scope has to be
    /// read off its store at every site; a default 'this device' would be wrong exactly when it
    /// matters.
    ///
    /// **Here and not in an area**, because three areas have switches. It stood first in
    /// `PlaybackSettings`; with the second area it would have been copied.
    nonisolated static func toggle(
        header: String, on: Bool, explanation: String?, validity: Validity
    ) -> CardSpec {
        CardSpec(
            header: header,
            statement: on ? "common.on" : "common.off",
            explanation: explanation,
            validity: validity)
    }

    /// Whether the footnote "Hold right opens the list to choose" appears.
    ///
    /// **Only when there is really something behind the preview.** With three options and three
    /// pills everything is visible, and the sentence would promise a path to nothing — exactly
    /// the kind of hint you stop believing the second time. With three pills and seventy-nine
    /// options it is the answer to the question you have right now.
    ///
    /// **Never without options**, not even with empty pills: whoever gives no number has no list
    /// behind it — otherwise they would have named it.
    nonisolated var showsListHint: Bool {
        guard let optionCount else { return false }
        return optionCount > pills.count
    }
}

/// The right column: what the focused row configures, written out (AP46).
///
/// **Why a third column at all.** Until here the explanation of a setting stood as a sentence
/// under a section head — for the whole section, not for the row you are on. And what was
/// on offer you only saw after you had pressed. On a TV a press is expensive: whoever wants
/// to know what "Audio preference" can do had to go in, read, and come back with the Menu
/// button.
///
/// **It takes no focus.** The card follows the focus; if it took it itself, it would be empty
/// after the first press to the right and you could not come back. What is to be chosen in
/// it, you choose in the list next to it — the footnote says so.
///
/// **Empty is a state and not an error.** Areas that do not yet report a card leave the
/// column free; that is the visible progress meter of this package, just as
/// ``SettingsRowsTests`` keeps the row counter. A placeholder ("nothing selected")
/// would be text that never says anything.
struct SettingsCard: View {

    let spec: CardSpec?

    /// The focus of the settings page — **only** for the pills of a walkable card.
    let focus: FocusState<String?>.Binding

    /// After a choice in the card: the page catches up its held card
    /// (``CardSpec/withSelection(_:)``).
    let onSelected: (String) -> Void

    /// The prefix of the focus identifiers in the card.
    nonisolated static let focusPrefix = "karte-"

    private var isEnterable: Bool { spec?.selection != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            if let spec {
                card(spec)
                if let validity = spec.validity {
                    validityRow(validity)
                }
            }
            Spacer(minLength: 0)
        }
        .frame(width: SettingsView.cardWidth, alignment: .leading)
        .padding(.top, Self.headerHeight)
        // The card speaks about the row the focus is on — it is not a statement of its own.
        // Whoever has it read out hears the content already from the row itself (`info` on
        // the building block); here it would be the same thing a second time.
        // **Unless it is walkable**: then its pills are buttons, and a button the screen reader
        // does not know is none for someone who cannot see.
        .accessibilityHidden(!isEnterable)
        // **A section of its own only if there is something to enter.** Otherwise 'right' would be
        // an invitation into the void — exactly the reason the card had none until now.
        .modifier(CardSection(active: isEnterable))
    }

    /// Where the card begins vertically.
    ///
    /// **Below the height of the page heading and not on it.** The heading "Settings" applies to
    /// the whole page; a card at the same height would read as a second heading next to it. In
    /// the design it is 96 points.
    static let headerHeight: CGFloat = 96

    @ViewBuilder
    private func card(_ spec: CardSpec) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            headerFont(spec)
                .font(TypeLevel.footer.font)
                .textCase(.uppercase)
                .tracking(1.2)
                .foregroundStyle(ColorRole.textQuiet.color)
                .lineLimit(2)

            statementFont(spec)
                .font(TypeLevel.header.font)
                .foregroundStyle(ColorRole.text.color)
                .fixedSize(horizontal: false, vertical: true)

            if let explanation = spec.explanation {
                Text(appKey: explanation)
                    .font(TypeLevel.footer.font)
                    .foregroundStyle(ColorRole.textMatt.color)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let selection = spec.selection {
                choice(spec.pills, selection: selection)
            } else if !spec.pills.isEmpty {
                lookahead(spec.pills)
            }

            if spec.showsListHint {
                Text(appKey: "settings.card.moreHint")
                    .font(TypeLevel.lowercased.font)
                    .foregroundStyle(ColorRole.textQuiet.color)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 32)
        .padding(.horizontal, 36)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(ColorRole.surface.color))
    }

    @ViewBuilder
    private func statementFont(_ spec: CardSpec) -> some View {
        if let wording = spec.statementWording {
            Text(verbatim: wording)
        } else {
            Text(appKey: spec.statement)
        }
    }

    @ViewBuilder
    private func headerFont(_ spec: CardSpec) -> some View {
        if let wording = spec.headerWording {
            Text(verbatim: wording)
        } else {
            Text(appKey: spec.header)
        }
    }

    /// The preview of the options.
    ///
    /// **Filled means chosen, outlined means possible** — and the chosen one additionally carries
    /// a checkmark. Colour alone never carries; that is the same rule under which the missing
    /// mark got its glyph.
    ///
    /// **They wrap and do not run out of the column.** ``FlowLayout`` instead of `HStack`: three
    /// language names fit side by side, "German · otherwise original" alone fills the line — and
    /// whatever sticks out on the right is cut off on a TV, not scrollable.
    @ViewBuilder
    private func lookahead(_ pills: [CardPill]) -> some View {
        FlowLayout(spacing: 12, lineSpacing: 12) {
            ForEach(pills) { pill in
                HStack(spacing: 10) {
                    if pill.chosen {
                        Image(systemName: Glyph.done.pair.filled)
                            .font(TypeLevel.lowercased.font)
                    }
                    Text(verbatim: pill.wording)
                        .font(TypeLevel.footer.font)
                        .lineLimit(1)
                }
                .foregroundStyle(
                    pill.chosen ? ColorRole.textOnLight.color : ColorRole.textMatt.color
                )
                .padding(.vertical, 12)
                .padding(.horizontal, 24)
                .background(pillBackground(chosen: pill.chosen))
            }
        }
        .padding(.top, 6)
    }

    /// The pills of a **walkable** card — buttons instead of a preview.
    ///
    /// **From the same building block as in the list** (``ChoiceRow``), so that a choice in the
    /// card looks the same, feels the same and is read out the same.
    @ViewBuilder
    private func choice(_ pills: [CardPill], selection: CardSelection) -> some View {
        FlowLayout(spacing: 12, lineSpacing: 12) {
            ForEach(pills) { pill in
                ChoiceRow(
                    wording: pill.wording,
                    chosen: pill.chosen,
                    identifier: Self.focusPrefix + pill.identifier,
                    focus: focus
                ) {
                    selection.select(pill.identifier)
                    onSelected(pill.identifier)
                }
            }
        }
        .padding(.top, 6)
    }

    @ViewBuilder
    private func pillBackground(chosen: Bool) -> some View {
        let form = Capsule(style: .continuous)
        if chosen {
            form.fill(ColorRole.text.color)
        } else {
            form.strokeBorder(ColorRole.line.color, lineWidth: 2)
        }
    }

    /// Pill and sentence under the card — outside, not inside it.
    ///
    /// **Outside, because it does not speak about the value but about the setting.** In the card
    /// it would stand as a fourth item next to head, value and explanation and read as one of
    /// them; below it it is recognisably a statement about the whole.
    @ViewBuilder
    private func validityRow(_ validity: Validity) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 18) {
            Text(appKey: validity.markKey)
                .font(TypeLevel.lowercased.font)
                .tracking(1)
                .foregroundStyle(validity.color)
                .padding(.vertical, 4)
                .padding(.horizontal, 14)
                .overlay(
                    Capsule(style: .continuous)
                        .strokeBorder(validity.color.opacity(0.45), lineWidth: 2))

            Text(appKey: validity.sentenceKey)
                .font(TypeLevel.lowercased.font)
                .foregroundStyle(ColorRole.textQuiet.color)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 8)
    }
}

/// How the focused row passes its card upward.
///
/// **The row reports and the view shows** — the same pattern as ``SettingsFirstEntryKey``,
/// and for the same reason: only the row knows what it configures, and only ``SettingsView``
/// knows where the column stands. A mapping from identifiers to cards in the view would be a
/// second list that you forget with the next area.
///
/// **`reduce` takes the first non-empty one and not the last**, unlike with the first target:
/// exactly one row is focused, so exactly one report is there. If a second ever arrived,
/// that would be an error in the build-up — and then the upper one is the one the focus is on
/// by appearance.
nonisolated struct CardKey: PreferenceKey {
    static let defaultValue: CardSpec? = nil
    static func reduce(value: inout CardSpec?, nextValue: () -> CardSpec?) {
        value = value ?? nextValue()
    }
}

extension View {

    /// Reports the card of this row — **but only while it has the focus.**
    ///
    /// **On the building block and not at the call site.** Sixty-eight places build rows today;
    /// repeating the condition "has focus" at every single one would mean forgetting it at one,
    /// and then something would sit in the card that lights up nowhere.
    func reportsCard(_ spec: CardSpec?, whenFocused focused: Bool) -> some View {
        preference(
            key: CardKey.self,
            value: CardSpec.report(spec, focused: focused))
    }
}

/// The card's focus section — only if it is walkable.
private struct CardSection: ViewModifier {
    let active: Bool
    func body(content: Content) -> some View {
        if active { content.focusSection() } else { content }
    }
}

/// A row's request **to enter the card** — set by ``SettingsView``.
///
/// **An environment action and no focus from outside:** every area keeps its own
/// `@FocusState`, the card stands in the page's focus. The row cannot set the page's focus;
/// it can only ask for it, and the page knows where.
struct EnterCardKey: EnvironmentKey {
    static let defaultValue: @MainActor (String) -> Void = { _ in }
}

extension EnvironmentValues {
    /// Enters the card on the pill with this identifier.
    var enterCard: @MainActor (String) -> Void {
        get { self[EnterCardKey.self] }
        set { self[EnterCardKey.self] = newValue }
    }
}
