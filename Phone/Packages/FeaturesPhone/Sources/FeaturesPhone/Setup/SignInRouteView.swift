import DesignSystemPhone
import SwiftUI

/// Password or code on the TV.
///
/// **The order is reversed on the phone.** On the TV the code is at the top, because
/// typing there is the most expensive operation there is. Here it is cheap — so
/// the password is at the top and the code below. It stays anyway, because it can do something
/// the password cannot: it does not ask for one.
struct SignInRouteView: View {

    let model: SourceFormModel

    var body: some View {
        SetupSheet(
            title: "common.signIn",
            explanation: model.serverName.map { _ in "setup.login.text" },
            error: model.error
        ) {
            VStack(alignment: .leading, spacing: MetricsBoard.phone.gutter) {
                if let name = model.serverName {
                    HintCapsule(wording: name)
                }
                Button {
                    model.choosePassword()
                } label: {
                    Text(appKey: "setup.login.password").frame(maxWidth: .infinity)
                }
                .buttonStyle(.loud)

                Button {
                    Task { await model.startCode() }
                } label: {
                    Text(appKey: "setup.login.code").frame(maxWidth: .infinity)
                }
                .buttonStyle(.quiet)
            }
            .padding(.top, 4)
        }
    }
}
