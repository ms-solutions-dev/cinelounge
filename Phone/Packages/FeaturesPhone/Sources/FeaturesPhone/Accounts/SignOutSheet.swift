import DesignSystemPhone
import SwiftUI

/// Sheet: Sign out?
///
/// **It names what is deleted along with it — and that is the whole point.** "Sign out?"
/// with Yes and No conceals that afterwards snapshots, Top Shelf badge and image
/// cache are gone; whoever notices that only afterwards takes it for a bug.
///
/// **It appears only for the last account.** As long as a second one exists, removing is one
/// entry fewer and not a cleanup — then this warning would be a threat without cause.
struct SignOutSheet: View {

    let account: Account
    let signOut: () -> Void
    let cancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: MetricsBoard.phone.gutter) {
            Text(appKey: "accounts.signOut.title")
                .font(TypeLevel.section.font)
                .foregroundStyle(ColorRole.text.color)

            Text(appKey: "accounts.signOut.text")
                .font(TypeLevel.footer.font)
                .foregroundStyle(ColorRole.textMatt.color)
                .fixedSize(horizontal: false, vertical: true)

            ForEach(Self.whatIsLost, id: \.self) { row in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: Glyph.failed.name)
                        .font(TypeLevel.label.font)
                        .foregroundStyle(ColorRole.textQuiet.color)
                    Text(appKey: row)
                        .font(TypeLevel.footer.font)
                        .foregroundStyle(ColorRole.textMatt.color)
                }
            }

            Button(action: signOut) {
                Text(appKey: "common.signOut").frame(maxWidth: .infinity)
            }
            .buttonStyle(.loud)
            .padding(.top, MetricsBoard.phone.gutter)

            Button(action: cancel) {
                Text(appKey: "common.cancel").frame(maxWidth: .infinity)
            }
            .buttonStyle(.quiet)
        }
        .padding(.horizontal, MetricsBoard.phone.margin)
        .padding(.vertical, MetricsBoard.phone.section)
    }

    static let whatIsLost = [
        "accounts.signOut.snapshots", "accounts.signOut.images", "accounts.signOut.marks",
    ]
}
