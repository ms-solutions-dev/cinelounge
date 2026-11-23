import DesignSystemPhone
import SwiftUI

/// Sign-in with name and password.
///
/// **With an eye button** — the reasoning is at ``InputField/Kind/password``.
///
/// **The name stands above the password and not next to it.** Two fields in a row
/// are two half fields at 353 points, and no name fits in a half field that is
/// longer than "Alex".
struct PasswordView: View {

    @Bindable var model: SourceFormModel

    var body: some View {
        SetupSheet(
            title: "setup.password.title", explanation: "setup.password.text",
            error: model.error
        ) {
            VStack(alignment: .leading, spacing: MetricsBoard.phone.gutter) {
                InputField(
                    text: $model.user, placeholder: "common.username", kind: .name)
                InputField(
                    text: $model.password, placeholder: "common.password",
                    kind: .password)

                if model.isRunning {
                    LoadingState(message: "setup.password.signingIn")
                } else {
                    Button {
                        Task { await model.notify() }
                    } label: {
                        Text(appKey: "common.signIn").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.loud)
                    .disabled(model.user.isEmpty)
                }

                // **An empty password is allowed in Jellyfin** and is not a
                // mistyped entry — accounts for children are often set up that way. The
                // button therefore depends on the name and not on the password.
                Footnote(message: "setup.password.footnote")
            }
            .padding(.top, 4)
        }
    }
}
