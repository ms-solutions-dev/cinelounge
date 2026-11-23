import Core
import DesignSystemPhone
import SwiftUI

/// Add an account.
///
/// **Here and only here an account becomes a child account.** The switch sits at creation
/// and nowhere else: an account that can later be turned into a child account can also later
/// be turned back — and whoever knows the PIN then no longer needs to bypass parental
/// controls, they switch them off.
///
/// **On the same server or on another.** Both are the same screen: "second
/// server" and "second person" differ in one field, not in one path.
public struct NewAccountView: View {

    @State private var model: SourceFormModel
    @State private var childAccount = false

    private let ingest: (ServerCredentials, Bool) -> Void

    public init(
        model: SourceFormModel,
        ingest: @escaping (ServerCredentials, Bool) -> Void = { _, _ in }
    ) {
        _model = State(initialValue: model)
        self.ingest = ingest
    }

    public var body: some View {
        ZStack {
            ColorRole.reason.color.ignoresSafeArea()

            ScrollSurface {
                VStack(alignment: .leading, spacing: MetricsBoard.phone.section) {
                    // **The same flow as in setup.** Creating a second account
                    // is the same as the first — a separate, shortened path
                    // for it would be a second place where the same errors can occur
                    // and look different.
                    // **`done` and not just `model`.** Without this way back the
                    // screen ran through to the end and then did nothing: the credential lay
                    // in the Keychain, the switch below it was never applied, and
                    // the only way back was the navigation's back button.
                    SourceFormView(model: model, done: adopt)
                    // **No child-account switch any more** (AP59 N4, 2026-09-30) — whether a child
                    // is watching is stated by the profile. ``childAccount`` stays `false`.
                }
            }
        }
    }

    /// **The switch is read on completion, not when flipped.**
    ///
    /// Before that there is no account the flag could attach to — setup stores
    /// the credential only with the sign-in. Whoever flips the switch once more in between
    /// has not done anything wrong either.
    private func adopt() {
        guard let credential = model.createdCredentials else { return }
        ingest(credential, childAccount)
    }
}
