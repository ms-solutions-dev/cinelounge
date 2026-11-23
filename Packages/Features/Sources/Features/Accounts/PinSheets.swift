import Core
import DesignSystem
import ParentalControls
import SwiftUI

/// Setting a PIN — **enter twice, without a display in between.**
///
/// **The repetition is no formality on tvOS.** The digits stand as dots,
/// the input runs via a shuffled keyboard with the remote, and whoever
/// mistypes here has a PIN they do not know — on a device that then
/// locks them out. The second entry costs twenty seconds and prevents exactly that.
///
/// **If they do not match, the flow starts over.** Repeating only the second one
/// would mean letting people guess which of the two was meant.
struct PinSetSheet: View {

    let catalogTitleKey: String
    let onDone: (String) -> Void
    let onCancel: () -> Void

    /// **The repetition is driven by the sheet** (``PinSheet/assigns``, rules at
    /// ``ParentalControls/PinEntry``) — only the fixed PIN arrives here.
    var body: some View {
        ZStack {
            ColorRole.reason.color.ignoresSafeArea()
            PinSheet(
                reason: nil,
                onSubmit: { pin in
                    onDone(pin)
                    return true
                },
                onCancel: onCancel,
                assigns: true
            )
        }
    }
}

/// Changing a PIN — **first the old one, then the new one twice.**
///
/// **Without the old one an unattended device would be enough to take over the lock**
/// instead of bypassing it. That is the worse case: Whoever bypasses it
/// gets through once; whoever takes it over locks the parent out.
struct PinChangeSheet: View {

    let checkOld: (String) -> Bool
    let onDone: (String) -> Void
    let onCancel: () -> Void

    @State private var oldMatches = false

    var body: some View {
        if oldMatches {
            PinSetSheet(
                catalogTitleKey: "pin.change", onDone: onDone, onCancel: onCancel)
        } else {
            ZStack {
                ColorRole.reason.color.ignoresSafeArea()
                PinSheet(
                    reason: AppLanguageSetting.text("pin.enterOld"),
                    onSubmit: { digits in
                        guard checkOld(digits) else { return false }
                        oldMatches = true
                        return true
                    },
                    onCancel: onCancel
                )
            }
        }
    }
}

/// The way out for someone who has forgotten their PIN.
///
/// **There is no back door, and that is the only honest design.** A second
/// PIN would be a second lock with the same key problem; a question about
/// the place of birth would be a weaker PIN that every child in the house can answer. The
/// only answer that holds: The lock falls — **and everything with it that depends on
/// it.**
///
/// **That is why this sheet names the price before anything is pressed.** The
/// parental controls are reset as a whole: the PIN, the device lock, the account kind. Whoever
/// wants a new PIN afterwards sets it anew — and knows that they are doing so.
///
/// **It does not ask for a password of Jellyfin.** That would be obvious and
/// wrong: On a child account the server is already signed in, and the access token
/// lies in the Keychain. A password that the app does not have at all could not
/// check it either.
struct PinForgottenSheet: View {

    let onReset: () -> Void
    let onCancel: () -> Void

    @FocusState private var focus: String?

    var body: some View {
        ZStack {
            ColorRole.reason.color.ignoresSafeArea()

            VStack(spacing: 30) {
                Text(app: "pin.forgot")
                    .font(TypeLevel.section.font)
                    .foregroundStyle(ColorRole.text.color)

                Text(app: "childLock.pinForgotExplain")
                    .font(TypeLevel.text.font)
                    .foregroundStyle(ColorRole.textMatt.color)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 860)

                HStack(spacing: 18) {
                    button("childLock.pinReset", identifier: "zuruecksetzen", warning: true) {
                        onReset()
                    }
                    button("common.cancel", identifier: "abbrechen", warning: false, action: onCancel)
                }
            }
            .padding(40)
        }
    }

    private func button(
        _ key: String, identifier: String, warning: Bool, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(appKey: key)
                .font(TypeLevel.footer.font)
                .settingsFont(
                    isFocused: focus == identifier, muted: !warning, warning: warning
                )
                .settingsSurface(.pill, isFocused: focus == identifier)
        }
        .bareFocusableButton()
        .focused($focus, equals: identifier)
    }
}
