import SecondScreen
import SwiftUI

/// Attaches an input field to the ``SecondScreen/RemoteKeyboard`` — **by focus.**
///
/// **The one thing a Siri Remote cannot do.** Whoever searches "Skefijiot" on the Apple TV
/// swipes across a row of letters and confirms fourteen times. On the phone that is five
/// seconds. ``RemoteKeyboard`` was built and tested for this — and until
/// 2026-09-11 had **zero callers**: `pending` stayed `false`, and a text typed on the phone
/// was silently discarded in `give(_:)` (AP24).
///
/// **By focus and not by `onAppear`.** A view can carry several fields, and
/// it is already there before one of them is up. `onAppear` would therefore register the wrong field
/// — or two at once, and ``RemoteKeyboard`` holds exactly **one** receiver. What
/// counts is the one question "which field is up **now**", and on
/// tvOS only the focus answers it.
///
/// **Register, sync up, unregister — three movements, one line per field:**
///
/// ```swift
/// TextField(text: $eingabe) { Text(app: `settings.portals.bridgePrompt`) }
///     .focused($focus, equals: "bridge")
///     .ferntastatur($eingabe, offen: focus == "bridge")
/// ```
struct RemoteKeyboardField: ViewModifier {

    @Binding var text: String
    let pending: Bool
    /// A password field — the text only goes in, never back into the mirror (AP39).
    var isSecret = false

    func body(content: Content) -> some View {
        content
            .onChange(of: pending) { _, now in
                if now {
                    // **The existing text is the template.** Whoever has already typed
                    // "Bay" on the TV and then picks up the phone should find "Bay"
                    // there — otherwise they type the beginning twice.
                    RemoteKeyboard.signIn(text: text, isSecret: isSecret) { text = $0 }
                } else {
                    RemoteKeyboard.signOut()
                }
            }
            // **And when the view disappears while the field has the focus.**
            // That is the normal case and no special case: a sheet is closed,
            // an area switched — `onChange(of: pending)` then no longer runs, and
            // without this line the phone would stay on a field that no
            // longer exists. ``RemoteKeyboard/give(_:)`` would write its text into a view
            // nobody sees.
            .onDisappear {
                if pending { RemoteKeyboard.signOut() }
            }
            // **What is typed on the TV goes out too.** Without it the
            // mirror would be wrong after the first letter; the opposite direction — a text
            // arrived from the phone — runs over the same binding and, thanks to the comparison in
            // ``RemoteKeyboard/refresh(_:)``, does not report twice.
            .onChange(of: text) { _, now in
                if pending { RemoteKeyboard.refresh(now) }
            }
    }
}

extension View {

    /// Registers this field with the ``SecondScreen/RemoteKeyboard`` as long as it has the focus.
    ///
    /// - Parameters:
    ///   - text: The content of the field — in both directions.
    ///   - offen: Whether this field currently has the focus.
    ///   - geheim: A password field. **Only since the wire is paired** (decision
    ///     6, 2026-09-25): typing is encrypted, and the text never goes back to the phones
    ///     — not even encrypted (``SecondScreen/RemoteKeyboard/isSecret``).
    public func remoteKeyboard(
        _ text: Binding<String>, pending: Bool, isSecret: Bool = false
    ) -> some View {
        modifier(RemoteKeyboardField(text: text, pending: pending, isSecret: isSecret))
    }
}

/// Registers the **system search** with the remote keyboard — for `.searchable` views.
///
/// **Why these two places cannot use the modifier above.** `.searchable`
/// builds no field of its own; tvOS lays its search screen over it, and there is no
/// `@FocusState` from which "this field is up" could be read. What there is, is
/// `\.isSearching` — **and only within** the view that `.searchable` is attached to.
/// Hence a separate, invisible reader instead of a modifier: it must lie **in** the
/// content, not next to it.
///
/// ```swift
/// inhalt
///     .background { Fernsuche(text: searchText) }
///     .searchable(text: searchText, …)
/// ```
///
/// **It pays off most right here:** "Skefijiot" on the Siri Remote's row of letters
/// is fourteen confirmations; on the phone it is five seconds.
struct RemoteSearch: View {

    @Binding var text: String

    @Environment(\.isSearching) private var isSearching

    var body: some View {
        // **A surface and no `EmptyView`.** What draws nothing SwiftUI may not evaluate
        // at all under some circumstances — and then `onChange` would never run. `Color.clear`
        // is a real view, takes no space and intercepts nothing.
        Color.clear
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .remoteKeyboard($text, pending: isSearching)
    }
}
