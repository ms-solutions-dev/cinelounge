import Core
import DesignSystem
import SwiftUI

// **The seven rows a setting can be** (AP46, 23./2026-09-24).
//
// **The finding they answer:** ``SettingsMetrics`` unified the *dimensions* in AP26 — four
// paddings, five heights, three outlines became one each. What remained is the meaning:
// switch, choice, navigation and action have since been **the same pill**, and **twenty
// private helper functions in nine files** keep building their row themselves. Whoever sits
// in front of the screen cannot tell from a row what a press does: does something open,
// does something switch, or does something final happen?
//
// **The phone has had the answer since 2026-09-07** — `DisclosureRow`, `SwitchRow`,
// `ChoiceRow`, `Footnote`, `SettingsCard`. This file catches up, and that is the family
// resemblance AP27 established on mark and stripe and which today ends at the first
// settings row.
//
// **Three differences from the phone, all from operation and none from taste:**
//
// 1. **Focus instead of finger.** Every row takes its identifier and the screen's binding.
//    Without that the building block could not carry `focusHighlight` and `info`
//    itself — and that is exactly what AP46 demands: in one place instead of twenty.
// 2. **No icon in the row.** On the phone every row carries one, set in a
//    ``IconTile``. On the TV the symbols stand in the **area list** on the left;
//    repeating them in the content would mean giving the same information twice — on a
//    screen that is three screens long anyway.
// 3. **The missing mark is the existing one.** ``SettingsView`` has drawn it since AP26 as
//    ``Styling/Glyph/toBackfill`` in ``Styling/ColorRole/progress``, and **only outside
//    focus** — on the inverted focus surface the colour would not carry. A second missing
//    presentation would be a second place for the same statement.
//
// **What is deliberately missing here:**
//
// * **A `Fehltzeile` of its own.** The roadmap names it; what was built is "missing" as a
//   **property** of ``DisclosureRow`` — as on the phone. A row of its own would be a second
//   place for the same information, and when building every area you would have to decide
//   which of the two to take.
// * **A `ProfileRow`.** It already exists (`Konten/ProfileRow.swift`), and it carries a
//   profile circle that no settings row otherwise needs.
//
// * **A building block for reading text.** Two places still set ``RowKind/readingRow``
//   themselves: the **paragraph with heading** in ``AboutSettings`` ("Privacy" and its
//   sentence) and the **trace row** in ``DiagnosticsSettings`` (multi-line, with glyph and
//   colour per outcome). Both take focus so that the screen scrolls — an area without a
//   focus target never scrolls on tvOS —, but they do not look alike enough for a common
//   building block. **One with one consumer is too early**; whoever finds the third case
//   then has three to compare instead of one to guess from.
//
// **Two were added on 2026-09-24, both read off the existing code and not invented:**
//
// * **`InputRow`** — six fields in three areas built label, placeholder and surface
//   themselves. That brought out a contradiction that had stood since AP24: the factory
//   gave `kind` a default, and the comment above it demanded the opposite.
// * **`FormButton`** — five buttons that stand **next to** a field and not as a row
//   below it. A full-width ``ActionRow`` would tear the form apart; both share the
//   ``ActionState``.

/// It **leads on** — and says beforehand what is there.
///
/// **The value column is a text inventory of its own and no repetition of the name.** "46 of
/// 79 groups", "2 · one active", "TMDb missing" — it answers the question you would otherwise
/// have to go in to ask. That is the done condition of AP46 and no decoration: a list of
/// nine names with nine chevrons demands nine presses for one piece of information, and on
/// a remote a press is more expensive than on a screen you can touch.
///
/// **The value is truncated, the name is not.** If space runs out, "what is in it" is the
/// more dispensable of the two statements — without the name you would not know what it is
/// talking about.
struct DisclosureRow: View {

    /// The key in the language catalog. Empty if a ``wording`` is given.
    var title: String = ""

    /// The title verbatim — for names nobody translates.
    ///
    /// A server name, a package name, the name of a channel list. The same split as on the
    /// phone and for the same reason: a key for it would have to be maintained with every new
    /// entry.
    var wording: String?

    /// What is in it — finished wording, because the value column speaks about numbers and
    /// names of services.
    var value: String?

    /// Whether the value points to something missing.
    var isMissing = false

    /// What the card on the right says about this row — `nil` as long as the area has not been
    /// converted (AP46, 2026-09-24).
    ///
    /// **`nil` is a statement and no convenience.** The house rule forbids defaults on shared
    /// contracts, because they swallow a decision — just as ``InputRow`` may not guess its
    /// `kind`. Here the opposite is the case: sixty-eight places build rows today, and the column
    /// on the right stays empty until one of them reports something. That is exactly the
    /// progress meter of this package; a required field would have replaced it with sixty-eight
    /// placeholders.
    var card: CardSpec?

    let identifier: String
    let focus: FocusState<String?>.Binding
    let action: () -> Void

    private var isFocused: Bool { focus.wrappedValue == identifier }

    var body: some View {
        Button(action: action) {
            HStack(spacing: SettingsMetrics.spacing) {
                caption
                    .lineLimit(1)
                    .layoutPriority(1)

                Spacer(minLength: SettingsMetrics.spacing)

                if let value {
                    Text(verbatim: value)
                        .font(TypeLevel.lowercased.font)
                        .settingsFont(isFocused: isFocused, muted: true)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }

                if isMissing {
                    Image(systemName: Glyph.toBackfill.name)
                        .font(TypeLevel.lowercased.font)
                        // **The colour gives way in focus**, just as in the area list: on the bright focus
                        // surface it no longer carries, and the glyph alone says it too.
                        .foregroundStyle(
                            isFocused ? ColorRole.reason.color : ColorRole.progress.color)
                }

                Image(systemName: Glyph.next.name)
                    .font(TypeLevel.lowercased.font)
                    .settingsFont(isFocused: isFocused, muted: true)
            }
            .font(TypeLevel.footer.font)
            .settingsSurface(.row, isFocused: isFocused)
        }
        .bareFocusableButton()
        .focused(focus, equals: identifier)
        .info(label, valueInfo)
        .reportsCard(card, whenFocused: isFocused)
    }

    @ViewBuilder
    private var caption: some View {
        if let wording {
            Text(verbatim: wording).settingsFont(isFocused: isFocused)
        } else {
            Text(appKey: title).settingsFont(isFocused: isFocused)
        }
    }

    private var label: Text {
        wording.map { Text(verbatim: $0) } ?? Text(appKey: title)
    }

    /// **The value belongs in the statement and not only on the screen.** Whoever has it read
    /// out otherwise hears nine names and has to open each — exactly the disadvantage that the
    /// value column abolishes for the eye.
    private var valueInfo: SelectionState {
        value.map { SelectionState.word($0) } ?? .none
    }
}

/// It **switches** — on or off, and nothing else.
///
/// **The checkmark stands on the right and not on the left.** On the left it would stand in
/// front of the word and read as a bullet; on the right it is where in every other row the
/// statement stands — and a switch row has exactly one: its state.
struct SwitchRow: View {

    var title: String = ""
    var wording: String?

    /// A sentence under the title — **for the switch that is misunderstood without it.** "Applies
    /// to the device, no matter who is signed in" is no decoration but the difference between
    /// two locks. Where the title suffices, it is left out.
    var message: String?

    @Binding var on: Bool

    /// What the card on the right says — see ``DisclosureRow/card``.
    var card: CardSpec?

    let identifier: String
    let focus: FocusState<String?>.Binding

    private var isFocused: Bool { focus.wrappedValue == identifier }

    var body: some View {
        Button {
            on.toggle()
        } label: {
            HStack(spacing: SettingsMetrics.spacing) {
                VStack(alignment: .leading, spacing: 4) {
                    caption
                        .font(TypeLevel.footer.font)
                        .settingsFont(isFocused: isFocused)
                    if let message {
                        Text(appKey: message)
                            .font(TypeLevel.lowercased.font)
                            .settingsFont(isFocused: isFocused, muted: true)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Image(systemName: on ? Glyph.done.pair.filled : Glyph.done.pair.outlined)
                    .font(TypeLevel.footer.font)
                    .settingsFont(isFocused: isFocused, muted: !on)
            }
            .settingsSurface(.row, isFocused: isFocused)
        }
        .bareFocusableButton()
        .focused(focus, equals: identifier)
        // **`.on` and not `.chosen`.** One reads out "On" or "Off", the other "selected" — and
        // "not selected" is no information for a switch, but silence.
        .info(label, .on(on))
        .reportsCard(card, whenFocused: isFocused)
    }

    @ViewBuilder
    private var caption: some View {
        if let wording { Text(verbatim: wording) } else { Text(appKey: title) }
    }

    private var label: Text {
        wording.map { Text(verbatim: $0) } ?? Text(appKey: title)
    }
}

/// It is **a choice among siblings** — a pill next to other pills.
///
/// **The round outline is the statement** (``RowKind/pill``): there are several here,
/// take one. Drawing a choice as a full row would mean making it look like a list in which
/// every entry stands on its own.
struct ChoiceRow: View {

    var title: String = ""
    var wording: String?
    var chosen = false

    /// A fixed width when several stand in a row and have to be equally wide. Without it the
    /// pill is as wide as its word.
    var width: CGFloat?

    /// What the card on the right says — see ``DisclosureRow/card``.
    var card: CardSpec?

    let identifier: String
    let focus: FocusState<String?>.Binding
    let action: () -> Void

    private var isFocused: Bool { focus.wrappedValue == identifier }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                if chosen {
                    Image(systemName: Glyph.done.pair.filled)
                        .font(TypeLevel.lowercased.font)
                }
                caption
            }
            .font(TypeLevel.footer.font)
            .settingsFont(isFocused: isFocused)
            .settingsSurface(.pill, isFocused: isFocused, width: width)
        }
        .bareFocusableButton()
        .focused(focus, equals: identifier)
        .info(label, .chosen(chosen))
        .reportsCard(card, whenFocused: isFocused)
    }

    @ViewBuilder
    private var caption: some View {
        if let wording { Text(verbatim: wording) } else { Text(appKey: title) }
    }

    private var label: Text {
        wording.map { Text(verbatim: $0) } ?? Text(appKey: title)
    }
}

/// It **switches to the next value on every press** — for choices with two or three values
/// (AP46, product decision 6 of 2026-09-24).
///
/// **Why not the pill row:** three pills are three focus targets on the first level, and the
/// done condition of this package demands fewer than fifteen there. A row is one. **And why
/// not a sub-list:** that cost one more press than today — cycling costs none with two
/// values and at most one with three.
///
/// **The card makes it bearable.** Whoever saw only the row would not know what comes after
/// the next press; on the right therefore **all** values stand as pills, the chosen one
/// filled. From four values on this no longer carries — that is where the walkable card
/// belongs.
///
/// **Not for the app language**, even though it has three values: every press would flip the
/// whole interface into the next language, and on the way to the target you would land in
/// one you cannot read.
struct ToggleRow: View {

    /// An option: a stable identifier and its finished wording.
    struct Option: Equatable, Sendable {
        let identifier: String
        let wording: String
    }

    let title: String
    let options: [Option]
    let chosen: String
    /// The explanatory sentence for the card — `nil` where there is none.
    let explanation: String?
    /// Where the setting belongs. **Without a default**: every site reads it off its store.
    let validity: Validity
    let identifier: String
    let focus: FocusState<String?>.Binding
    let select: (String) -> Void

    private var isFocused: Bool { focus.wrappedValue == identifier }

    private var current: Option? { options.first { $0.identifier == chosen } }

    var body: some View {
        Button {
            if let next = Self.next(after: chosen, in: options.map(\.identifier)) {
                select(next)
            }
        } label: {
            HStack(spacing: SettingsMetrics.spacing) {
                Text(appKey: title)
                    .settingsFont(isFocused: isFocused)
                    .lineLimit(1)
                    .layoutPriority(1)
                Spacer(minLength: SettingsMetrics.spacing)
                if let current {
                    Text(verbatim: current.wording)
                        .font(TypeLevel.lowercased.font)
                        .settingsFont(isFocused: isFocused, muted: true)
                        .lineLimit(1)
                }
                Image(systemName: Glyph.advance.name)
                    .font(TypeLevel.lowercased.font)
                    .settingsFont(isFocused: isFocused, muted: true)
            }
            .font(TypeLevel.footer.font)
            .settingsSurface(.row, isFocused: isFocused)
        }
        .bareFocusableButton()
        .focused(focus, equals: identifier)
        .info(Text(appKey: title), current.map { .word($0.wording) } ?? .none)
        .reportsCard(
            Self.card(
                title: title, options: options, chosen: chosen,
                explanation: explanation, validity: validity), whenFocused: isFocused)
    }

    /// The next value **with wrap-around** — after the last comes the first again.
    ///
    /// **Without wrap-around** you would end up with a row that does nothing any more, and you
    /// would have to know that you cannot go backward. `nil` only if there is nothing to switch.
    /// If the chosen value is not in the list (an old, remembered one), it starts at the first —
    /// otherwise the row would stay stuck on a value you can never reach again.
    nonisolated static func next(after chosen: String, in identifiers: [String]) -> String? {
        guard !identifiers.isEmpty else { return nil }
        guard let location = identifiers.firstIndex(of: chosen) else { return identifiers[0] }
        return identifiers[(location + 1) % identifiers.count]
    }

    /// The card: **all** values as pills, the chosen one filled.
    nonisolated static func card(
        title: String, options: [Option], chosen: String, explanation: String?,
        validity: Validity
    ) -> CardSpec {
        CardSpec(
            header: title,
            statementWording: options.first { $0.identifier == chosen }?.wording ?? "",
            explanation: explanation,
            pills: options.map { CardPill($0.wording, chosen: $0.identifier == chosen) },
            optionCount: options.count,
            validity: validity)
    }
}

/// It **says something and does nothing** — the version number, a row of the diagnostics
/// trace.
///
/// **It takes focus anyway**, and that is no oversight: an area without a focus target
/// **never scrolls on tvOS**, and everything below the screen edge would be unreachable. Its
/// highlight is therefore the quieter one (``RowKind/readingRow``) — it should read as
/// entered, not as an invitation to press.
struct ValueRow: View {

    var title: String = ""
    var wording: String?
    var value: String?

    /// A fixed width for the label — **and without it the row falls apart.**
    ///
    /// **Found with the first addition (2026-09-23), at "About".** The other rows of this file
    /// push their value to the right edge; that is right where the row has a surface and the
    /// value is its end. A value row has **no** surface (`reason: .clear`), stands in a block 900
    /// pt wide and carries short values — "1.2.3", "412". At the far right they would stand about
    /// six hundred points from the name, and the eye no longer connects them. The same finding
    /// as on the iPad, where category name and arrow stood 1900 pixels apart.
    ///
    /// **`nil` means: value at the right edge** — for the value row, which after all stands in a
    /// row with others.
    var titleWidth: CGFloat?

    /// What the card on the right says — see ``DisclosureRow/card``.
    var card: CardSpec?

    let identifier: String
    let focus: FocusState<String?>.Binding

    private var isFocused: Bool { focus.wrappedValue == identifier }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: SettingsMetrics.spacing) {
            caption
                .settingsFont(isFocused: isFocused, muted: true)
                .frame(width: titleWidth, alignment: .leading)
                .lineLimit(1)
                .layoutPriority(1)

            if let value {
                Text(verbatim: value)
                    .settingsFont(isFocused: isFocused)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            Spacer(minLength: 0)
        }
        .font(TypeLevel.footer.font)
        .settingsSurface(.readingRow, isFocused: isFocused, reason: .clear)
        .focusable()
        .focused(focus, equals: identifier)
        .info(label, value.map { SelectionState.word($0) } ?? .none)
        .reportsCard(card, whenFocused: isFocused)
    }

    @ViewBuilder
    private var caption: some View {
        if let wording { Text(verbatim: wording) } else { Text(appKey: title) }
    }

    private var label: Text {
        wording.map { Text(verbatim: $0) } ?? Text(appKey: title)
    }
}

/// The state an action is currently in.
///
/// **Three states, and all three had long been in the existing code** — as a ternary in the
/// label, six times in four files: "Measure"/"Measuring…", "Send"/"Sending…",
/// "Save"/"Saved", "Find server"/"Searching…". The row thereby carried its state in the
/// word alone.
///
/// **And the word alone is not enough** (AP30, shown at ``DiagnosticsSettings``): whoever
/// has it read out hears the label on arrival and learns nothing of the change. At **two** of
/// the six places an `a11y.state.busy` was therefore added by hand, at the other four not —
/// exactly the inequality a building block eliminates.
enum ActionState: Equatable, Sendable {
    /// It waits for a press.
    case ready
    /// It is running — a second press should do nothing.
    case isRunning
    /// It is done, and the row is the receipt.
    case done
    /// It is there, but not available right now — an empty field, a missing access.
    ///
    /// **Not `.disabled(…)`, and on tvOS that is no matter of taste.** A disabled button drops
    /// out of the **focus tree** there: the focus jumps to the geometrically nearest target, and
    /// that lies somewhere afterwards. The house pattern is: stay focusable, look greyed out,
    /// discard the press in the body — ``EinstellungenFokusbaumTests`` watches over it.
    ///
    /// **The fourth case came from ``PortalSettings``** (2026-09-24): the redeem button did it
    /// by hand and correctly, and the comment above it says that the site "first got it wrong".
    /// That is exactly why it belongs in the building block.
    case locked
}

/// It **does something** — "Sign out", "Clear cache", "Forget certificate".
///
/// **Warning means: it takes something away, and it stands last.** The roadmap demands both
/// together, and the reason is the remote: the **first target** of an area is the row on
/// which the focus lands when you enter it. If "Sign out" lies there, a single press is the
/// sign-out — and the one press is on tvOS what an accidental tap would be on a phone, only
/// without a way back.
///
/// **The rank is set here and not decided at the call site**, so that nobody sets it
/// differently in the next area.
struct ActionRow: View {

    var title: String = ""
    var wording: String?

    /// The label while it is running or after it is done.
    ///
    /// **One second key and not two more**, because the call sites hold it that way:
    /// "Measure"/"Measuring…", "Save"/"Saved", "Find server"/"Searching…" each name two words,
    /// never three. Which of the two states is meant is told by ``state``.
    var statusTitle: String?

    /// A glyph to the left of the label — for actions that carry one.
    ///
    /// **It gives way while it is running**, namely to the hourglass: in the existing code
    /// measuring had `hourglass` and sending had `arrow.up.circle`, so two glyphs for the same
    /// state. Which of them means "running now" nobody would know.
    var icon: String?

    var state: ActionState = .ready

    /// Ob sie etwas wegnimmt.
    var warning = false

    let identifier: String
    let focus: FocusState<String?>.Binding
    let action: () -> Void

    private var isFocused: Bool { focus.wrappedValue == identifier }

    var body: some View {
        Button {
            // **The second press is discarded in the body and not at the button** (AP22,
            // 2026-09-11). `.disabled(…)` would on tvOS not be a pale button but
            // **none**: it drops out of the focus tree, tvOS assigns the focus anew, and it then lies
            // somewhere in the middle of the measuring. Being short-lived does not make it harmless —
            // those are exactly the seconds in which you are looking.
            guard state != .isRunning, state != .locked else { return }
            action()
        } label: {
            HStack(spacing: 12) {
                if let character {
                    Image(systemName: character)
                }
                caption
            }
            .font(TypeLevel.footer.font)
            .settingsFont(
                isFocused: isFocused, muted: state == .locked, warning: warning
            )
            .frame(maxWidth: .infinity, alignment: .leading)
            .settingsSurface(.row, isFocused: isFocused)
        }
        .bareFocusableButton()
        .focused(focus, equals: identifier)
        // **The state belongs on the value, where the assistive technology reads it up** (AP30):
        // the changing label is heard only by whoever arrives at the right moment.
        .info(label, .key(Self.info(at: state)))
    }

    private var character: String? { Self.character(at: state, fallback: icon) }

    private var key: String {
        Self.key(at: state, title: title, statusTitle: statusTitle)
    }

    /// The glyph that currently applies.
    ///
    /// **A computation of its own and not a line in the body**, so that it can be checked
    /// without a screen: whether a running action shows the hourglass is otherwise only visible
    /// on the TV — and there only as long as it runs.
    nonisolated static func character(
        at state: ActionState, fallback icon: String?
    )
        -> String?
    {
        switch state {
        case .ready, .locked: icon
        case .isRunning: Glyph.hourglass.name
        case .done: Glyph.done.pair.filled
        }
    }

    /// What the screen reader says about the state.
    ///
    /// **A greyed-out button otherwise sounds like a usable one.** The dimming is colour, and
    /// colour means nothing to the assistive technology — without this line you would hear the
    /// same sentence as for a button that does something, and press in vain.
    ///
    /// **Both keys stand in one piece, and that is right here.** Assembling is the rule for keys
    /// **that do not exist** — a search version without a placeholder, an SF Symbol name. These
    /// two are in the catalog, and `strings.py` should see them as used.
    ///
    /// **The first attempt split them at the dot before the last word** — and reported the
    /// beginning as a missing key, because it looks like one itself. Whoever has to split here
    /// after all, splits so that **no** part contains two words joined by a dot.
    nonisolated static func info(at state: ActionState) -> String? {
        switch state {
        case .ready, .done: nil
        case .isRunning: "a11y.state.busy"
        case .locked: "a11y.state.unavailable"
        }
    }

    /// The key that currently applies.
    ///
    /// **Without ``statusTitle`` it stays at the title**, and that is no oversight: an action
    /// that has only a name ("Sign out") should not suddenly stand empty while it runs. It then
    /// shows the hourglass and keeps its word.
    nonisolated static func key(
        at state: ActionState, title: String, statusTitle: String?
    ) -> String {
        switch state {
        // **Blocked does not mean "in another state".** A button that cannot do anything right now
        // should still say what it would do — "Saved" on an empty field would be a receipt for
        // something that did not happen.
        case .ready, .locked: title
        case .isRunning, .done: statusTitle ?? title
        }
    }

    @ViewBuilder
    private var caption: some View {
        if let wording { Text(verbatim: wording) } else { Text(appKey: key) }
    }

    private var label: Text {
        wording.map { Text(verbatim: $0) } ?? Text(appKey: key)
    }
}

/// It **takes in something** — an address, a name, a password.
///
/// **The label appears twice, and both times with reason.** Above the field it says what is
/// to be typed in (AP5 · B7). **In the placeholder** it appears because tvOS puts a keyboard
/// screen of its own over the whole view on focus — the row above is then covered, and what
/// appears on top is only the field's placeholder. An empty string once stood there, and
/// while typing you saw neither which field was meant nor what you had already entered.
///
/// **It does not highlight in focus, and that is no negligence.** tvOS shows a field in focus
/// as a keyboard screen and not as a bright row; a focus surface under it would be the
/// highlight of a state that nobody sees at that moment.
enum FieldState: Equatable, Sendable {
    /// **Alone under its section head** — larger type, no label of its own.
    ///
    /// The head above already says what is meant; a second label would be the same information
    /// one line spacing lower. And the larger type is no ornament: a key and a server address
    /// stand here that you check **character by character** against a slip of paper.
    case alone
    /// **One of several in a form** — small type, label above.
    ///
    /// Five fields one under the other each need a name, otherwise by the third you no longer
    /// know which it is. The placeholder alone does not carry that: as soon as you type, it is
    /// gone.
    case inRow
}

/// It **takes in something**.
struct InputRow: View {

    var title: String = ""

    @Binding var text: String

    /// **Without a default**, for the same reason as ``kind``: whether a field stands alone or is
    /// one of five only the call site knows, and guessed wrong you see it only on the TV.
    let state: FieldState

    /// What belongs in this field.
    ///
    /// **Without a default, and that is the find during the conversion** (2026-09-24): the
    /// factory from which this building block arose had `kind: InputKind = .identifier` — and above
    /// it a comment that demanded the opposite ("decided per call site … a common default would
    /// be wrong for four of them"). Both had stood side by side since AP24. An address that
    /// begins capitalised is no longer an address, and whoever takes the default notices
    /// nothing. Now every site has to decide.
    let kind: InputKind

    /// Whether the input is concealed.
    ///
    /// **A concealed field gets the remote keyboard as a secret** (2026-09-25, since the remote
    /// wire is paired — product decision 6). Until then it got none: the wire ran without
    /// checking who is speaking, and a password did not belong in it. Now it carries `geheim:
    /// true`, like the password field of the sign-in — the phone shows dots instead of
    /// characters.
    var isHidden = false

    /// How wide the field becomes — **narrower than a row, and on purpose.**
    ///
    /// A field across the whole block width would look as if a whole sentence belonged in it.
    /// 780 pt is about forty characters, and that is the length a server address needs.
    var width: CGFloat = 780

    let identifier: String
    let focus: FocusState<String?>.Binding

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if state == .inRow {
                // The label of an input field says what is to be typed —
                // it is also acted on afterwards (AP5 · B7).
                Text(appKey: title)
                    .font(TypeLevel.footer.font)
                    .foregroundStyle(ColorRole.textMatt.color)
            }

            Group {
                if isHidden {
                    SecureField(AppLanguageSetting.message(title), text: $text)
                        .remoteKeyboard($text, pending: focus.wrappedValue == identifier, isSecret: true)
                } else {
                    TextField(AppLanguageSetting.message(title), text: $text)
                        .keyboard(forItem: kind)
                        .remoteKeyboard($text, pending: focus.wrappedValue == identifier)
                }
            }
            .font(state == .alone ? TypeLevel.header.font : TypeLevel.footer.font)
            .settingsSurface(.pill, isFocused: false)
            .frame(maxWidth: width)
            .focused(focus, equals: identifier)
        }
    }
}

/// Which rank a ``FormButton`` has in its row.
///
/// **Two and not three.** In the existing code, next to every field stands either **one**
/// button that completes the operation, or several side paths — "Save" and "Cancel",
/// "Save" and "Find server". A third rank would have no call site.
enum FormRank: Equatable, Sendable {
    /// The button that completes the operation. One per row.
    case main
    /// A side path — it belongs to the field, but the field is the main thing.
    case beside
}

/// A button that **belongs to an input field** — "Save", "Redeem", "Cancel",
/// "Find server".
///
/// **Why it is no ``ActionRow``**, although both trigger an action: an action row is an
/// **entry in a list** — full width, one line, and the eye moves vertically. These buttons
/// stand **horizontally next to their field**, in an `HStack`, and they refer to exactly what
/// is in it. Drawn as a full row they would tear the form apart, and in the existing code
/// there are five of them: three in ``PortalSettings`` (redeem, save, search), two in
/// ``PlaylistSettings`` (save, cancel).
///
/// **It shares the ``ActionState`` with the action row**, and that is why it stands here and
/// not as a sixth helper function in an area file: all four cases occur here.
/// "Save"/"Saved" is `done`, "Searching…" is `isRunning`, an empty field makes the button
/// `locked`.
struct FormButton: View {

    var title: String = ""
    var wording: String?

    /// The label while it is running or after it is done — as at the
    /// ``ActionRow``, and with the same computation.
    var statusTitle: String?

    var state: ActionState = .ready

    /// **Without a default.** Which button of a row completes the operation only the call site
    /// knows — and a default would mean that a row accidentally carries two main paths or none.
    /// Both you see only on the TV.
    let rank: FormRank

    /// Whether it takes something away — "Delete".
    ///
    /// **That makes it not quieter but louder.** A side path is muted, a warning one is not:
    /// what is irreversible must not look like a marginal button. The same rule stood in the
    /// factory from which this building block arose (`muted: !isDestructive`), only without
    /// a reason.
    var warning = false

    /// A fixed width when several in a row should be equally wide.
    var width: CGFloat?

    let identifier: String
    let focus: FocusState<String?>.Binding
    let action: () -> Void

    private var isFocused: Bool { focus.wrappedValue == identifier }

    var body: some View {
        Button {
            // The same discarded press as in ``ActionRow`` — and here it stood correctly at three
            // of three places in the existing code, each time with its own reasoning in the comment
            // next to it.
            guard state != .isRunning, state != .locked else { return }
            action()
        } label: {
            HStack(spacing: 10) {
                if let character = ActionRow.character(at: state, fallback: nil) {
                    Image(systemName: character)
                }
                caption
            }
            .font(TypeLevel.footer.font)
            // **A side path is muted, the main path is not.** In the existing code all three portal
            // buttons carried `muted: true` — also "Save", which is the main path there. Next to a
            // field that holds a server address that was right: the address is the main thing. In a
            // **form** with five fields it is the completion.
            .settingsFont(
                isFocused: isFocused,
                muted: !warning && (rank == .beside || state == .locked),
                warning: warning
            )
            .settingsSurface(
                .pill, isFocused: isFocused, reason: reason, width: width)
        }
        .bareFocusableButton()
        .focused(focus, equals: identifier)
        .info(label, .key(ActionRow.info(at: state)))
    }

    private var reason: Color {
        rank == .main ? ColorRole.text.color.opacity(0.16) : ColorRole.surface.color
    }

    @ViewBuilder
    private var caption: some View {
        if let wording {
            Text(verbatim: wording)
        } else {
            Text(appKey: ActionRow.key(at: state, title: title, statusTitle: statusTitle))
        }
    }

    private var label: Text {
        wording.map { Text(verbatim: $0) }
            ?? Text(
                appKey: ActionRow.key(
                    at: state, title: title, statusTitle: statusTitle))
    }
}
