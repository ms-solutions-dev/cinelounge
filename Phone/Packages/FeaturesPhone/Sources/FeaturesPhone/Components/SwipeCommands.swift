import DesignSystemPhone
import SwiftUI

/// A command behind a row.
///
/// **A type of its own and not nested in ``SwipeCommands``.** Nested, it would carry
/// the row's content type along: `SwipeCommands<AccountRow>.Command` and
/// `SwipeCommands<ChannelListRow>.Command` would be two different types, and nothing that
/// deals with commands could ever be written generically.
struct SwipeCommand: Identifiable {

    /// Whether it removes something. **Red is the color and not the information** — the
    /// name stands next to it, because red is no warning sign with deuteranopia.
    enum Kind { case neutral, route }

    let id: String
    /// Key in the catalog.
    let title: String
    let icon: String
    var kind: Kind = .neutral
    let action: () -> Void
}

/// What lies behind a row.
///
/// **The finding of 2026-09-06:** Two lists of this app hung their only destructive
/// commands on `.swipeActions` — and those exist only in a `List`. Both sit in a
/// ``ScrollSurface``, so in a `ScrollView`; there the modifier does **nothing**, without
/// anyone being told. An account could not be removed, a channel list could not be
/// deleted, and both looked as if built.
///
/// **Why not simply a `List`.** It would bring the swipe and its own row style with
/// it: the system's separators, insets, background and selection color, which every
/// view of this app would then have to write against. The swipe is the smaller matter.
///
/// **Never the only way to a command.** A gesture you cannot see does not exist for
/// whoever does not know it — that is why the row carries a ``SwipeMark`` that
/// **names the commands**, every command additionally sits in the context menu under
/// the long press, and for the screen reader it is available as
/// ``View/accessibilityAction(named:_:)``. For the screen reader a swipe is no way
/// anyway: It claims the gesture itself.
///
/// **And all three from the same list.** Buttons, context menu and screen reader read
/// ``commands``; maintained separately, the second command at the latest would have
/// been missing from one of the three places — and nobody would have noticed, because
/// each works on its own.
///
/// **The detent is felt and not seen** (2026-09-07, "hits unreliably"). A row that moves
/// along while dragging does not say from when on it **stays** open — the finger is on
/// it, and the buttons behind it only slide out while you are still dragging. The
/// bump when it snaps in is the answer the screen cannot give here: "caught, you may
/// let go." The **executed** command explicitly gets none — see ``Haptics``.
struct SwipeCommands<Content: View>: View {

    /// Whose commands are exposed — `nil` means: none.
    ///
    /// **From outside and one per list.** Two open rows one above the other are the same
    /// error as two open sheets: You no longer know which button belongs to which row. The
    /// same rule as in ``SheetState``, one level deeper.
    @Binding var pending: String?

    let identifier: String
    let commands: [SwipeCommand]

    /// Whether the **drag** is part of it — the long press and the screen reader always stay.
    ///
    /// **The finding of 2026-09-09:** In the download list, this drag fully covered the left
    /// edge strip (`highPriorityGesture`, from twenty points) and so took away the
    /// drawer's gesture for closing (``EdgeSwipe/closes(start:drag:)``,
    /// `simultaneousGesture` from forty). Two meanings for one movement, and the
    /// priority one won.
    ///
    /// **The client's decision: the drawer wins, the row swipe goes.**
    /// Only there — hence a switch on the building block and not a second, swipe-less
    /// block next to it: Whoever turns the drag off wants to keep the **commands**, and
    /// those exist here only once. Two blocks would have them twice, and with the next
    /// command it would be missing in one of the two — exactly the trap this type is
    /// built against.
    ///
    /// **`true` as the default, so that the account and channel lists keep running
    /// unchanged.** There is no drawer above them, and the swipe is their established way.
    var movesAccount = true

    @ViewBuilder let content: Content

    /// How wide a command is. Two side by side are 176 points of 393 — just under half,
    /// and so it stays visible which row they belong to.
    private static var buttonWidth: CGFloat { 88 }

    /// How far the finger has currently dragged.
    ///
    /// **`@GestureState` and not `@State`** (2026-09-07): It was reset only in
    /// `onEnded`. If the system cancels the gesture — a call, a second finger, a switch
    /// to another view —, `onEnded` never comes, and the row stayed half open, without
    /// buttons and without a way back. `@GestureState` falls back to its initial value by
    /// itself when the gesture ends, whatever the reason.
    @GestureState private var drag: CGFloat = 0

    private var span: CGFloat { Self.buttonWidth * CGFloat(commands.count) }

    /// Whether **this** row has the open compartment.
    ///
    /// **And not ``pending`` itself as the trigger.** The state belongs to the whole list:
    /// When switching from one row to the next, every row would see a change, and all of
    /// them would report at once.
    private var isOpen: Bool { movesAccount && pending == identifier }

    private var offset: CGFloat {
        guard movesAccount else { return 0 }
        return max(-span, min(0, (isOpen ? -span : 0) + drag))
    }

    var body: some View {
        ZStack(alignment: .trailing) {
            // **Without the drag, nothing lies behind it either.** The buttons would then be an
            // area nobody ever sees — and they exist twice anyway: in the context menu under
            // the long press and as an action for the screen reader.
            if movesAccount { actions }
            content
                // **The row background has to cover.** Without it the commands would show through
                // the closed row, and the row would look like an error.
                .background(ColorRole.reason.color)
                .offset(x: offset)
                .animation(Motion.expand, value: offset)
                // **The second way, and the only visible one.** Swiping is a
                // gesture you have to know; holding is the one the system
                // offers everywhere. Both take their entries from the same list ``commands``
                // as the buttons behind and the screen reader's actions — a
                // command that exists in one place and not in the other cannot
                // arise this way.
                .contextMenu { menu }
                // **Priority and not alongside** (2026-09-07): The row content is a
                // `Button`, and SwiftUI gives the child's gesture precedence — the
                // press recognizer took the touch before the drag arrived here, and
                // in addition the scroll area pulled on it. The swipe therefore worked
                // only sometimes.
                //
                // **And that is exactly why ``movesAccount`` switches it off and does not hide
                // it.** Priority means: It takes the gesture away from the drawer above
                // before the drawer even sees it.
                //
                // **`.subviews` and not `.none`.** The row content is a `Button`;
                // `.none` would also switch off **its** gestures, and the row could no
                // longer be tapped. `.subviews` removes exactly one gesture: this one.
                .highPriorityGesture(swipe, including: movesAccount ? .all : .subviews)
        }
        .clipped()
        // **Only on opening.** Closing is the way back to the resting state and
        // reports nothing; a bump for it would be the second one per swipe.
        .haptics(.snapped, at: isOpen, when: { _, fresh in fresh })
        .accessibilityElement(children: .contain)
        .modifier(VoiceOverCommands(commands: commands))
    }

    private var actions: some View {
        HStack(spacing: 0) {
            ForEach(commands) { command in
                Button {
                    pending = nil
                    command.action()
                } label: {
                    VStack(spacing: 4) {
                        Image(systemName: command.icon)
                        Text(appKey: command.title)
                            .font(TypeLevel.lowercased.font)
                            .lineLimit(1)
                    }
                    .foregroundStyle(ColorRole.text.color)
                    .frame(width: Self.buttonWidth)
                    .frame(maxHeight: .infinity)
                    .background(command.kind == .route ? ColorRole.tag.color : ColorRole.surfaceHigh.color)
                }
                .buttonStyle(.plain)
                // For the screen reader the same command is available as an action; a
                // button that is reachable only after swiping would be a second,
                // unreachable entry there.
                .accessibilityHidden(true)
            }
        }
    }

    /// **Horizontal and only from twenty points.**
    ///
    /// Below that the scroll area takes over, and that is right: A list that shifts rows
    /// while scrolling is unusable. The direction is checked in addition — a
    /// diagonal drag belongs to whoever has more distance.
    private var swipe: some Gesture {
        DragGesture(minimumDistance: 20)
            .updating($drag) { value, state, _ in
                guard Self.isHorizontal(value) else { return }
                state = value.translation.width
            }
            .onEnded { value in
                // **The same check as on the go** (2026-09-07): Until then the raw width stood here.
                // A predominantly vertical drag therefore moved nothing but pushed the row open on
                // release — it jumped open out of nowhere while the finger was already gone.
                guard Self.isHorizontal(value) else { return }
                let total = (pending == identifier ? -span : 0) + value.translation.width
                // Dragged past half the width means open — otherwise the row snaps back
                // to where it came from.
                pending = total < -span / 2 ? identifier : nil
            }
    }

    /// Does the drag belong to the swipe or to the scroll area?
    ///
    /// **The longer distance wins.** A drag is never perfectly straight; whoever demanded
    /// a fixed slope would lose the fleeting swipe and let the hesitant one through.
    private static func isHorizontal(_ value: DragGesture.Value) -> Bool {
        abs(value.translation.width) > abs(value.translation.height)
    }

    private var menu: some View {
        ForEach(commands) { command in
            Button(role: command.kind == .route ? ButtonRole.destructive : nil) {
                pending = nil
                command.action()
            } label: {
                Label {
                    Text(appKey: command.title)
                } icon: {
                    Image(systemName: command.icon)
                }
            }
        }
    }
}

/// The commands as actions for the screen reader.
///
/// **A modifier of its own, because `ForEach` does not work over modifiers.** The
/// actions have to be attached one by one; a loop in a view's body cannot do that.
private struct VoiceOverCommands: ViewModifier {

    let commands: [SwipeCommand]

    func body(content: Content) -> some View {
        commands.reduce(AnyView(content)) { previous, command in
            AnyView(
                previous.accessibilityAction(named: Text(appKey: command.title)) {
                    command.action()
                })
        }
    }
}

/// The visible hint that something lies behind the row.
///
/// **It names the commands and does not count them.** "Swipe: Delete" says what
/// happens; "swipe left for options" says nothing. And because it arises from the same
/// commands as the buttons behind it, it cannot claim there is one that does not
/// exist.
struct SwipeMark: View {

    let commands: [String]

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: Glyph.back.name)
                .iconSize(9, weight: .semibold)
            Text(
                verbatim: SettingsModel.text("row.swipe") + " "
                    + commands.map(SettingsModel.text).joined(separator: " · "))
        }
        .font(TypeLevel.lowercased.font)
        .foregroundStyle(ColorRole.textQuiet.color)
        .lineLimit(1)
        // The tag explains a gesture that does not exist for the screen reader — there
        // the commands are actions on the row.
        .accessibilityHidden(true)
    }
}
