import Foundation

/// Type on the phone, it appears on the TV.
///
/// **The one thing a Siri Remote cannot do.** Whoever searches "Skefijiot" on the Apple TV
/// swipes across a row of letters and confirms fourteen times. Everything else about a
/// remote is more convenient; this is the difference between a minute and five
/// seconds.
///
/// **A bulletin board and not a text field.** This file does not know which field is open on
/// the TV — it only records **that** one is open and what is in it.
/// Whoever passed the field itself in here would tie the wire to the TV's UI,
/// and every new search line would have to know it.
///
/// **Static and not passed as an object.** A search field comes into being deep inside a
/// view; passing an object down to it would mean touching six views
/// that have nothing to do with the remote — and forgetting the seventh at the next field. The same
/// consideration as for ``Volume/fromOutside`` in the phone project.
///
/// **On the main thread and not concurrent.** Both sides of this board sit in the
/// UI: A search field signs in, an arrived text lands in it.
@MainActor
public enum RemoteKeyboard {

    /// Whether a field on the TV is currently waiting for input.
    public private(set) static var pending = false

    /// What is in it — **always empty for a password field.**
    public private(set) static var text = ""

    /// Whether the open field is a password field (AP39, 2026-09-25).
    ///
    /// **Then this board does not hold the text.** A typed text goes into the field
    /// and nowhere else; ``text`` stays empty, and so no mirror can send it
    /// back to a phone either.
    public private(set) static var isSecret = false

    /// Where a text typed on the phone goes — set by the open field.
    private static var receiver: ((String) -> Void)?

    /// Called when something has changed — so that the state goes out.
    public static var changed: (() -> Void)?

    /// A field signs in.
    ///
    /// **The text at sign-in is the template.** Whoever has already typed "Bay" on the TV
    /// and then reaches for the phone should find "Bay" there and not an empty
    /// field — otherwise they type the beginning twice.
    ///
    /// - Parameter geheim: A password field — the existing text is then **not** a
    ///   template, and what arrives is not recorded.
    public static func signIn(
        text existing: String, isSecret isHidden: Bool = false,
        receiver new: @escaping (String) -> Void
    ) {
        pending = true
        isSecret = isHidden
        text = isHidden ? "" : existing
        receiver = new
        changed?()
    }

    /// The text on the TV has changed — **without the phone having sent it.**
    ///
    /// **Without this line the mirror would be wrong after the first letter** (AP24,
    /// 2026-09-11). ``signIn(text:receiver:)`` records the state **at sign-in**;
    /// whoever keeps typing on the TV afterwards would still see the beginning on the phone — and
    /// type over a text that no longer exists in that form.
    ///
    /// **Equal reports nothing.** A text arrived from the phone runs through
    /// ``give(_:)`` into the field and from there back here as a change; without the
    /// comparison, a second report would go out for every typed character.
    public static func refresh(_ new: String) {
        guard pending, !isSecret, new != text else { return }
        text = new
        changed?()
    }

    /// The field is closed.
    public static func signOut() {
        pending = false
        isSecret = false
        text = ""
        receiver = nil
        changed?()
    }

    /// A text comes from the phone.
    ///
    /// **Silently discarded if no field is open.** That happens: The
    /// viewer closes the search on the TV while the last letter is still on its way on the
    /// phone. Writing it somewhere then would be worse than dropping
    /// it.
    ///
    /// **For a password field it goes only into the field** — see ``isSecret``.
    public static func give(_ new: String) {
        guard pending else { return }
        if !isSecret { text = new }
        receiver?(new)
        changed?()
    }
}
