import SwiftUI

/// What is typed into an input field — **and what the keyboard may make of it.**
///
/// **"Typing is the most expensive operation" is the hardest condition of this platform.**
/// Whoever enters an address on Apple TV swipes across a row of letters and confirms
/// each character individually; a typo costs the way back, and an
/// **autocorrect** costs it without anyone having done anything wrong. From
/// `vault.example` becomes "Vault. Home", and at three meters distance the
/// capital letter is not seen.
///
/// **The pattern had long been decided in the project and never arrived in six places**
/// (AP24, 2026-09-11): `LoginView` set `.textContentType(.URL)` and
/// `.autocorrectionDisabled()`, `PlaylistLoginView` additionally
/// `.textInputAutocapitalization(.never)` — the fields in Settings, in the move and
/// in the channel search had none of it. The comments there themselves said that the
/// typo is the rule here.
///
/// **Hence an enumeration and not three modifiers per call site.** Three
/// individual lines are three chances to forget one; the seventh place forgets
/// it for certain. This way every field has **one** line, and it says **what** is
/// supposed to be entered there — not which switches that entails.
public enum InputKind: Sendable {

    /// An address — server, bridge, program guide.
    ///
    /// No capitalization, no correction, and `.URL` as content type: on
    /// tvOS it brings the keyboard with `/` and `.` within reach and turns the field into one
    /// that the system recognizes.
    case address

    /// An identifier without meaning — user name, access key, ID number.
    ///
    /// **No `.URL` content type.** An OMDb key is not an address; presenting it as one
    /// would mean offering the system a completion that can only
    /// disturb. What remains is the important part: nothing capitalized, nothing corrected.
    case identifier

    /// Running text — a search term, a self-assigned name.
    ///
    /// **Correction stays off here too.** A search term is a title, and titles
    /// appear in no dictionary; having "Skefijiot" corrected to "Skefijiot" is the
    /// error that is hardest to see. **Capitalization**, on the other hand, stays: a
    /// name that someone assigns themselves may begin with a capital letter.
    case prose
}

extension View {

    /// Sets the keyboard hints for this input kind.
    ///
    /// One line per field, and it says what belongs there:
    ///
    /// ```swift
    /// TextField(text: $address) { Text(app: `settings.portals.bridgePrompt`) }
    ///     .keyboard(forItem: .address)
    /// ```
    public func keyboard(forItem kind: InputKind) -> some View {
        // **Correction is dropped for all three**, and that is the core: what is
        // entered here appears in no dictionary — neither an address nor an
        // access key nor a film title.
        let withContentKind = autocorrectionDisabled()
            .textContentType(kind == .address ? .URL : nil)

        // **`textInputAutocapitalization` does not exist on the Mac.** This package is
        // built for the host during the check run (`swift build` per package) and for the
        // tvOS program; without the switch the first of the two paths breaks. What is
        // missing on the Mac is not missing there: there is no on-screen keyboard that
        // could capitalize.
        #if os(tvOS) || os(iOS) || os(visionOS) || os(watchOS)
            return
                withContentKind
                .textInputAutocapitalization(kind == .prose ? .sentences : .never)
        #else
            return withContentKind
        #endif
    }
}
