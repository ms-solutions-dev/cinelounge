import SwiftUI

/// What **currently applies** at a focus target — the second half of the information.
///
/// **The label says what pressing does; the state says what is now.** Keeping the two
/// separate is no formality: "Pause" alone would conceal whether something
/// is playing, and "playing" alone would conceal what the button does.
///
/// Four forms, because there are four in this app and no more:
/// - ``none`` — a button that only does. "Create new" has no state.
/// - ``chosen(_:)`` — one option among several. The selected one says so, the
///   others **stay silent**: "not selected" on nine of ten rows is
///   information that one ignores after the third time.
/// - ``on(_:)`` — a switch. Here "off" is a real state and not silence;
///   whoever cannot see must be able to hear that it is switched off.
/// - ``key(_:)`` — a state with its own word, such as "paused" or
///   "saved".
/// - ``word(_:)`` — a state whose word comes from the server or the system and
///   therefore has no translation key: the selected audio track, the name of a
///   language.
public enum SelectionState: Sendable, Hashable {
    case none
    case chosen(Bool)
    case on(Bool)
    case key(String?)
    case word(String?)

    /// The state in words — `nil` if there is nothing to say.
    public var announcementText: Text? {
        switch self {
        case .none: nil
        case .chosen(let isChosen): isChosen ? Text(appKey: "a11y.state.selected") : nil
        case .on(let isOn): Text(appKey: isOn ? "common.on" : "common.off")
        case .key(let key): key.map { Text(appKey: $0) }
        case .word(let word):
            // An empty word is not a state but a gap — and reading
            // a gap aloud is worse than staying silent.
            (word?.isEmpty == false) ? word.map { Text(verbatim: $0) } : nil
        }
    }

    /// Does this target carry the trait "selected"?
    ///
    /// **Only the choice among several, not the switch.** A switched-on switch
    /// is not "selected" — the screen reader would otherwise speak of a selection where there
    /// is no second row at all.
    public var isSelected: Bool {
        if case .chosen(true) = self { return true }
        return false
    }

    /// Several states on one target — **because they do not exclude each other.**
    ///
    /// The "Live" row in the sidebar is selected at startup, expanded and
    /// currently syncing: all three at once. A state that displaced the others
    /// would be information that happens to be right.
    ///
    /// **What has nothing to say says nothing** — empty parts drop out, and if
    /// nothing remains, the information stays empty.
    public static func combined(_ states: [SelectionState]) -> Text {
        let words = states.compactMap(\.announcementText)
        guard let first = words.first else { return Text(verbatim: "") }
        return words.dropFirst().reduce(first) { collected, word in
            collected + Text(verbatim: ", ") + word
        }
    }
}

extension View {

    /// Tells the screen reader **what this focus target is and in which state.**
    ///
    /// **The rule of this project differs from the phone's** (AP30, 2026-09-11):
    /// there VoiceOver reads everything that is on the screen; here there is no
    /// finger moving across a surface, but exactly one place where something
    /// happens — the focus. So whatever can take focus is labeled, and nothing
    /// else.
    ///
    /// **`children: .ignore` is part of it and not negotiable.** Without it the
    /// reader also reads the names of the symbols, and `checkmark.circle.fill` is not
    /// information but a file name. Exactly this bug was in every choice row of
    /// Settings: the checkmark was in the tree with `opacity(0)` even when it was not
    /// visible — every row began with "Checkmark", the selected one like the unselected one.
    ///
    /// - Parameters:
    ///   - beschriftung: What this target **does** or **is**.
    ///   - zustand: What currently **applies**.
    public func info(_ label: Text, _ state: SelectionState = .none) -> some View {
        accessibilityElement(children: .ignore)
            .accessibilityLabel(label)
            .accessibilityValue(state.announcementText ?? Text(verbatim: ""))
            .accessibilityAddTraits(state.isSelected ? [.isButton, .isSelected] : .isButton)
    }

    /// The same information for a target at which **several states apply at once**.
    public func info(_ label: Text, _ states: [SelectionState]) -> some View {
        accessibilityElement(children: .ignore)
            .accessibilityLabel(label)
            .accessibilityValue(SelectionState.combined(states))
            .accessibilityAddTraits(
                states.contains(where: \.isSelected) ? [.isButton, .isSelected] : .isButton)
    }

    /// The same information for a label from the language file.
    public func info(appKey: String, _ state: SelectionState = .none) -> some View {
        info(Text(appKey: appKey), state)
    }

    /// The same information for a name that comes from the server and therefore has no
    /// translation key — a channel, a group, a library.
    ///
    /// **An empty name does not get an invented one.** If it is missing, that is a finding and
    /// no occasion for a placeholder: reading "Item" aloud would be worse than
    /// staying silent.
    public func info(name: String, _ state: SelectionState = .none) -> some View {
        info(Text(verbatim: name), state)
    }
}
