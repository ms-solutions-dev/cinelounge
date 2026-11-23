import Core
import DesignSystem
import SwiftUI

/// Section 11 · About — **version, device identifier, privacy, licences, reporting channel.**
///
/// **Guideline 5.1.1(i) applies to tvOS just the same** (AP26, 2026-09-11), and it requires the
/// privacy policy explicitly *"within the app in an easily accessible manner"* —
/// not only as a link in App Store Connect. Before this day not a word of it
/// appeared in the whole tree: `grep privacy|privacy|license|impressum` found nothing outside
/// comments, and the section list knew no case `about`.
///
/// **As text and not as a QR code**, unlike what the roadmap proposed. The
/// proposal assumed that the policy lives elsewhere and has to be referred to from
/// here — the phone project built it as a screen of its own on 2026-09-07, and the
/// same text works here just as well. **A QR code would be a detour via a second device
/// for something this one can show.**
///
/// **Every row is a focusable button without an effect**, and that is not decoration: a
/// section with zero focus targets **never scrolls on tvOS** — everything below the edge would be
/// unreachable. The same lesson as with the log list of Diagnostics, and it is
/// set out there at length.
///
/// **"Delete account" (5.1.1(v)) does not apply**, and that deserves a note so that it does not
/// come up for debate again in the next pass: the trigger of the obligation is literally
/// *"If your app supports account creation"*. This app creates no account — it signs
/// in on a third-party server. Anyone who ever builds user creation in here brings the
/// obligation with it.
struct AboutSettings: View {

    @FocusState private var focus: String?
    @Environment(\.settingsEntryRequest) private var entryRequest

    /// The first target of this section — see ``SettingsFirstEntryKey``.
    static let firstTarget = "about-version"

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {

            block {
                ValueRow(
                    title: "about.version", value: Self.version,
                    titleWidth: Self.titleWidth, identifier: Self.firstTarget, focus: $focus)
                ValueRow(
                    title: "about.build", value: Self.buildNumber,
                    titleWidth: Self.titleWidth, identifier: "about-build", focus: $focus)
                // **The device identifier, because it is needed in every follow-up question.** It
                // is in the diagnostic report and until here could be read only there — anyone
                // writing a message without submitting a report did not have it.
                ValueRow(
                    title: "about.device", value: Self.deviceID,
                    titleWidth: Self.titleWidth, identifier: "about-device", focus: $focus)
            }

            paragraph(
                catalogTitleKey: "about.privacy.title", sentenceKey: "about.privacy.text",
                id: "about-privacy")
            paragraph(
                catalogTitleKey: "about.privacy.deviceTitle", sentenceKey: "about.privacy.deviceText",
                id: "about-privacy-device")
            paragraph(
                catalogTitleKey: "about.privacy.removeTitle", sentenceKey: "about.privacy.removeText",
                id: "about-privacy-remove")

            paragraph(
                catalogTitleKey: "about.report.title", sentenceKey: "about.report.text", id: "about-report")

            paragraph(
                catalogTitleKey: "about.licences.title", sentenceKey: "about.licences.text",
                id: "about-licences")
            licenseList
            // **TMDB attribution** (API terms §3): the official logo, small on purpose (the terms
            // want it less prominent than the app's own marks), plus the notice.
            paragraph(
                catalogTitleKey: nil, sentenceKey: "about.tmdb.notice", id: "about-tmdb",
                logo: "TMDBLogo")
        }
        .padding(.bottom, 60)
        .preference(key: SettingsFirstEntryKey.self, value: Self.firstTarget)
        .onChange(of: entryRequest) { _, _ in focus = Self.firstTarget }
    }

    // MARK: - Building blocks

    private func block<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            content()
        }
        .frame(maxWidth: 900, alignment: .leading)
        .padding(.bottom, 40)
    }

    /// What is left for the label; the rest of the row belongs to the value.
    static let titleWidth: CGFloat = 280

    /// A heading with a paragraph below it — likewise as a focus target.
    private func paragraph(
        catalogTitleKey: String?, sentenceKey: String, id: String, logo: String? = nil
    ) -> some View {
        Button {
        } label: {
            VStack(alignment: .leading, spacing: 10) {
                if let catalogTitleKey {
                    Text(appKey: catalogTitleKey)
                        .font(TypeLevel.header.font)
                        .foregroundStyle(
                            focus == id ? ColorRole.reason.color : ColorRole.text.color)
                }
                if let logo {
                    Image(logo, bundle: .main)
                        .resizable()
                        .scaledToFit()
                        .frame(height: 24)
                        .accessibilityHidden(true)
                }
                Text(appKey: sentenceKey)
                    .font(TypeLevel.footer.font)
                    .foregroundStyle(
                        focus == id ? ColorRole.reason.color : ColorRole.textMatt.color
                    )
                    .fixedSize(horizontal: false, vertical: true)
                    .multilineTextAlignment(.leading)
            }
            .frame(maxWidth: 900, alignment: .leading)
            .settingsSurface(.readingRow, isFocused: focus == id, reason: .clear)
        }
        .bareFocusableButton()
        .focused($focus, equals: id)
        .info(Text(appKey: catalogTitleKey ?? sentenceKey))
        .padding(.bottom, 18)
    }

    /// The third-party packages, one row each.
    ///
    /// **From a generated file and not maintained by hand.** A list that someone
    /// forgets at the next package is worse than none — it claims
    /// completeness. `scripts/licenses.py` writes it from the resolved
    /// dependencies; if the file is missing, an honest row stands here instead of an empty
    /// area.
    @ViewBuilder
    private var licenseList: some View {
        if Licenses.all.isEmpty {
            Text(app: "about.licences.missing")
                .font(TypeLevel.footer.font)
                .foregroundStyle(ColorRole.textQuiet.color)
                .padding(.horizontal, SettingsMetrics.horizontal)
        } else {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Licenses.all, id: \.name) { packet in
                    packageRow(
                        "\(packet.name) \(packet.version)", kind: packet.kindOrGap,
                        id: "licence-" + packet.name)
                }
            }
            .frame(maxWidth: 900, alignment: .leading)
        }
    }

    /// The same row, but with a raw title — a package name is not translated.
    ///
    /// **Since 2026-09-24 on ``ValueRow``** (AP46). The separate factory next to it
    /// has been dropped; its comment had announced it itself ("it falls when ``ValueRow``
    /// takes this over"), and the building block carries both: the **literal** title as
    /// `wording` and the fixed title width that was found here.
    ///
    /// **And a button without an effect is gone with it.** The old factory was a `Button`
    /// whose press deliberately fizzled out — only so that the row can accept the focus.
    /// ``ValueRow`` takes it via `focusable()`, that is, without claiming a button that
    /// does not exist. That is the house rule "no button without an effect", not merely a
    /// refactoring.
    private func packageRow(_ rawTitle: String, kind: String, id: String) -> some View {
        ValueRow(
            wording: rawTitle, value: kind, titleWidth: Self.titleWidth,
            identifier: id, focus: $focus)
    }

    // MARK: - Details

    /// **The same source as the diagnostic report**, so that the number in a follow-up question
    /// and the one in the report never drift apart.
    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
    }

    static var buildNumber: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
    }

    /// The identifier of this device — **shortened, because it is read out.**
    ///
    /// A UUID has 36 characters; nobody reads it off from three metres, and in a
    /// follow-up question the first eight are enough to tell two devices apart. The whole value
    /// is still in the report.
    static var deviceID: String {
        String(DeviceIdentity.id().prefix(8))
    }
}
