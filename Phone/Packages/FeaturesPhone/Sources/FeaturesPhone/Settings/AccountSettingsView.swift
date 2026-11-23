import DesignSystemPhone
import SwiftUI

/// Area 9 · Account.
///
/// **One row per question and no repetition of the account list.** Whoever comes here
/// wants one of three things: switch the account, see what is on this device, or sign out.
/// All three are already fully available elsewhere — here are the doors to them.
struct AccountSettingsView: View {

    let accounts: () -> Void
    let storage: () -> Void
    let certificates: () -> Void
    /// The way to "Devices & Sharing" — `nil` if this build has no cloud (preview, test rig).
    /// A row that leads nowhere would be worse than none: it claims a path.
    var share: (() -> Void)?

    var body: some View {
        ZStack {
            ColorRole.reason.color.ignoresSafeArea()

            VStack(alignment: .leading, spacing: 0) {
                DisclosureRow(
                    title: "settings.account.accounts",
                    icon: Glyph.login.name, action: accounts)
                DisclosureRow(
                    title: "settings.account.storage", icon: Glyph.downloads.name,
                    action: storage)
                DisclosureRow(
                    title: "accounts.certificates", icon: Glyph.check.name,
                    action: certificates)
                if let share {
                    DisclosureRow(
                        title: "pairing.title", icon: Glyph.camera.name,
                        action: share)
                }

                Footnote(message: "settings.account.footnote")
                    .padding(.top, MetricsBoard.phone.gutter)
                Spacer(minLength: 0)
            }
            .padding(.top, MetricsBoard.phone.gutter)
        }
    }
}
