import DesignSystemPhone
import Diagnose
import SwiftUI

/// Area 11 · About — **the only finding from four passes that blocks a
/// submission.**
///
/// **Counted on 2026-09-07, not assumed:** privacy policy, licenses, imprint and
/// version number occurred **zero times** in the whole source, and the language catalog had
/// not a single key for them. App Store guideline **5.1.1(i)** requires the
/// policy explicitly *"within the app in an easily accessible manner"* — not only
/// as a link in App Store Connect.
///
/// **"Delete account" (5.1.1(v)), on the other hand, does not apply**, and that belongs noted here so that
/// it does not become a debate again in the next pass: the trigger of the obligation is
/// literally *"If your app supports account creation"*. This app creates no account — it
/// signs in to a third-party server. **As long as that does not change**, the
/// area is complete; whoever builds user creation in here brings the obligation with it.
///
/// **What lies on this device is not stated here but under Storage.** That is not
/// scattering but the right answer to the privacy question "what do you have on
/// me": it belongs at the place where you can also **delete** it.
///
/// **The reporting path belongs here.** What comes in via a custom channel list is checked by
/// nobody beforehand; guideline 1.2 requires a way to report something for user-generated
/// content. It is one row here and not a form — reports go to the same
/// address that the diagnostic report goes to.
struct AboutView: View {
    @Environment(\.horizontalSizeClass) private var widthClass

    /// Where the version comes from — the same source as in the diagnostic report, so that the
    /// number in a follow-up question and the one in the report never diverge.
    private var details: DeviceDetails { .thisDevice() }

    let privacy: () -> Void
    let licenses: () -> Void
    let report: () -> Void

    var body: some View {
        ZStack {
            ColorRole.reason.color.ignoresSafeArea()

            ScrollSurface {
                VStack(alignment: .leading, spacing: 0) {
                    SettingsCard {
                        ValueRow(title: "about.version", value: details.version)
                        Separator()
                        // **"System" and not "Media server"** (2026-09-07, seen in the
                        // simulator): there stood `details.system`, and that is the version
                        // of **this device** — the row claimed "Media server: iOS
                        // 18.2". Where the media server stands is stated by the account header one level
                        // up; this view does not know its version and should not
                        // guess it.
                        ValueRow(title: "about.system", value: details.system)
                        Separator()
                        ValueRow(title: "about.device", value: SourceAssembly.deviceID)
                    }

                    SettingsCard(header: "about.legal") {
                        DisclosureRow(
                            title: "about.privacy", icon: Glyph.privacy.name,
                            isContained: true, action: privacy)
                        Separator()
                        DisclosureRow(
                            title: "about.licences", icon: Glyph.license.name,
                            isContained: true, action: licenses)
                    }

                    Footnote(message: "about.privacyText")
                        .padding(.bottom, MetricsBoard.phone.section)

                    // **The heading is named differently from the row below it.** In the
                    // simulator "Report channel or title" stood twice one above the other —
                    // a header that repeats its only row says nothing.
                    SettingsCard(header: "about.content") {
                        DisclosureRow(
                            title: "about.report", icon: Glyph.report.name,
                            isContained: true, action: report)
                    }

                    Footnote(message: "about.reportText")
                }
                .contentColumn(widthClass)
                .padding(.top, MetricsBoard.phone.gutter)
            }
        }
    }
}

/// A row that only says something — **without a chevron, because it leads nowhere.**
///
/// ``DisclosureRow`` with an empty action would look the same and be an invitation:
/// a chevron claims a path. The version number has none.
struct ValueRow: View {

    /// How far the row indents — see ``SwiftUI/EnvironmentValues/rowInset``.
    @Environment(\.rowInset) private var inset

    /// Key in the catalog.
    let title: String
    /// Fertiger Wortlaut.
    let value: String

    var body: some View {
        HStack(spacing: MetricsBoard.phone.gutter) {
            Text(appKey: title)
                .font(TypeLevel.text.font)
                .foregroundStyle(ColorRole.text.color)
            Spacer(minLength: Metrics.targetSpacing)
            Text(verbatim: value)
                .font(TypeLevel.footer.font)
                .foregroundStyle(ColorRole.textMatt.color)
                .lineLimit(1)
                .truncationMode(.middle)
                // **Released for copying.** A version number and a
                // device identifier are written into a follow-up question; typing them out is too long for
                // both.
                .textSelection(.enabled)
        }
        .padding(.horizontal, inset)
        .frame(minHeight: Metrics.choiceRow)
        .accessibilityElement(children: .combine)
    }
}

/// The separator inside a card — **indented where icons stand.**
struct Separator: View {

    /// Whether it starts behind the icon column instead of at the text edge.
    var isIndented = false

    @Environment(\.rowInset) private var inset

    var body: some View {
        Divider()
            .overlay(ColorRole.lineQuiet.color)
            // 28 is the edge of the ``IconTile``, ``Styling/MetricsBoard/gutter`` its distance to the
            // text. The indent itself comes from the environment — in a card it is
            // different from on the background.
            .padding(.leading, isIndented ? inset + 28 + MetricsBoard.phone.gutter : inset)
    }
}
