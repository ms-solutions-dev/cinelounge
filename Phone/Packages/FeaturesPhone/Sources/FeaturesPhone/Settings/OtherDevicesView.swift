import DesignSystemPhone
import SwiftUI

/// **Other devices** — what connects this phone to a second device (AP59 N7,
/// 2026-09-30), the same structure as on the TV.
///
/// Until then the three paths lay five levels deep in the account area or only behind the
/// header row: giving or fetching a profile via iCloud, setting up the TV, the phone
/// as a remote. Whoever looked for one of them did not look under "Account".
struct OtherDevicesView: View {
    @Environment(\.horizontalSizeClass) private var widthClass

    /// `nil` without iCloud — then "Devices & Sharing" does not exist.
    let share: (() -> Void)?
    let setUpTV: () -> Void
    let remote: () -> Void

    var body: some View {
        ZStack {
            ColorRole.reason.color.ignoresSafeArea()

            ScrollSurface {
                VStack(alignment: .leading, spacing: 0) {
                    SettingsCard {
                        if let share {
                            DisclosureRow(
                                title: "pairing.title", icon: Glyph.share.name,
                                isContained: true, action: share)
                            Separator()
                        }
                        DisclosureRow(
                            title: "settings.handover.title", icon: Glyph.handoff.name,
                            isContained: true, action: setUpTV)
                        Separator()
                        DisclosureRow(
                            title: "remote.title", icon: Glyph.tv.name,
                            isContained: true, action: remote)
                    }
                    Footnote(message: "settings.geraete.footnote")
                        .padding(.bottom, MetricsBoard.phone.section)
                }
                .contentColumn(widthClass)
                .padding(.top, MetricsBoard.phone.gutter)
            }
        }
    }
}
