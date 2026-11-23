import DesignSystemPhone
import SecondScreen
import SwiftUI

/// Sheet: type on the phone, it appears on the TV.
///
/// **The biggest button of the whole design leads here, and that has a reason.** Entering
/// text is the one thing a Siri Remote cannot do — whoever searches
/// "Skefijiot" on the Apple TV swipes across a row of letters and confirms fourteen times. Everything
/// else on a remote is more convenient; this is the difference between one
/// minute and five seconds.
///
/// **The input is mirrored in the sheet.** That is the whole point: whoever types on the phone
/// and checks on the TV whether it arrived looks back and forth between two screens
/// — and types worse than on the row of letters. What stands here is
/// what stands over there.
///
/// **Sending happens on every change and not on submit.** On the TV there is a
/// search field that types along; a field that gets everything at once only after submitting
/// looks like one that receives nothing.
///
/// **A password field on the TV is secret** (decision 6, 2026-09-25): if the
/// mirror reports ``SecondScreen/StateMirror/keyboardSecret``, a password field stands here
/// **without a preset** — the TV then never sends the text back anyway —, and
/// only ``SecondScreen/Command/tap(_:)`` is sent. None of it remains after
/// closing: the text lives only in the state of this sheet.
struct KeyboardSheet: View {

    /// What already stands in the field on the TV — the template when opening.
    let template: String
    /// Whether the TV expects a password.
    let isSecret: Bool
    /// Every change goes over immediately.
    let tap: (String) -> Void
    let done: () -> Void

    @State private var text: String = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        SheetFrame(title: "remote.keyboard") {
            VStack(alignment: .leading, spacing: MetricsBoard.phone.gutter) {
                InputField(
                    text: $text,
                    placeholder: isSecret
                        ? "common.password" : "remote.keyboardPlaceholder",
                    kind: isSecret ? .password : .text
                )
                .focused($isFocused)
                .submitLabel(.done)
                .onSubmit(done)

                Footnote(message: isSecret ? "remote.keyboardSecretHint" : "remote.keyboardHint")
            }
            .padding(.horizontal, MetricsBoard.phone.margin)
            .padding(.top, MetricsBoard.phone.gutter)
        }
        .onAppear {
            text = isSecret ? "" : template
            // **The handle goes straight into the field.** A sheet you first have to tap
            // after opening costs exactly the effort it is supposed to save.
            isFocused = true
        }
        // **Every change and not every keystroke.** `onChange` fires per character; that
        // is right here, because a letter costs nothing over the home network — and
        // anything else would be a field that stutters over there.
        .onChange(of: text) { _, fresh in tap(fresh) }
    }
}

extension KeyboardSheet {

    /// What the sheet starts with — **with a secret field, with nothing.**
    ///
    /// Pulled out separately so that the rule is testable: an older or foreign TV
    /// could send text back despite ``SecondScreen/StateMirror/keyboardSecret``; here
    /// it would never be shown.
    static func template(from state: StateMirror) -> String {
        state.keyboardSecret ? "" : state.keyboardText
    }
}
