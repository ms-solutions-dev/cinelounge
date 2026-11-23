import DesignSystemPhone
import SwiftUI

/// About → Third-party licenses.
///
/// **Apple does not require them, the licenses themselves do.** Apache 2.0 §4 and the MIT
/// license both want notice and license text to be shipped along. Seven third-party packages
/// travel along, all via `jellyfin-sdk-swift`; this app has no dependencies of its own.
///
/// **The list is generated and not maintained** (`scripts/licenses.py`): it reads
/// `Package.resolved` and the license files of the origins. A hand-maintained list would
/// drift apart on the first day someone swaps a package — unnoticed, because a wrong license
/// list looks like a right one.
///
/// **A package without a license file is listed anyway**, with its origin and the explicit
/// note that the text is missing. A made-up entry would be worse than a missing one for a
/// license, and an omitted row would be a claim that the package does not travel along.
struct LicensesView: View {
    @Environment(\.horizontalSizeClass) private var widthClass

    @State private var packets: [LicenseInfo] = []
    @State private var pending: LicenseInfo?

    var body: some View {
        ZStack {
            ColorRole.reason.color.ignoresSafeArea()

            ScrollSurface {
                VStack(alignment: .leading, spacing: 0) {
                    SettingsCard {
                        ForEach(packets) { packet in
                            row(packet)
                            if packet.id != packets.last?.id { Separator() }
                        }
                    }
                    Footnote(message: "licences.footnote")
                    // **TMDB attribution** (API terms §3): official logo, kept small, plus the notice.
                    Image("TMDBLogo", bundle: .main)
                        .resizable()
                        .scaledToFit()
                        .frame(height: 14)
                        .accessibilityHidden(true)
                        .padding(.horizontal, MetricsBoard.phone.margin)
                        .padding(.top, MetricsBoard.phone.section)
                    Footnote(message: "about.tmdb.notice")
                        .padding(.top, MetricsBoard.phone.gutter)
                }
                .contentColumn(widthClass)
                .padding(.top, MetricsBoard.phone.gutter)
            }
        }
        .task { packets = LicenseInfo.all() }
        .sheet(item: $pending) { packet in
            LicenseSheet(packet: packet)
        }
    }

    @ViewBuilder
    private func row(_ packet: LicenseInfo) -> some View {
        // **No text, no chevron.** A path that shows nothing is an invitation into the void; the
        // note then stands in the value column instead of behind a tap.
        if packet.text == nil {
            HStack(spacing: MetricsBoard.phone.gutter) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: packet.name)
                        .font(TypeLevel.text.font)
                        .foregroundStyle(ColorRole.text.color)
                    Text(verbatim: packet.location)
                        .font(TypeLevel.label.font)
                        .foregroundStyle(ColorRole.textQuiet.color)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: Metrics.targetSpacing)
                Text(app: "licences.missing")
                    .font(TypeLevel.footer.font)
                    .foregroundStyle(ColorRole.progress.color)
            }
            .padding(.horizontal, Metrics.cardInset)
            .frame(minHeight: Metrics.choiceRow)
            .accessibilityElement(children: .combine)
        } else {
            DisclosureRow(
                wording: packet.name + DelimiterChars.point + packet.version, value: packet.kind
            ) {
                pending = packet
            }
        }
    }
}

/// The license text itself — **in a sheet and not on a fourth level.**
///
/// It is read and not walked through; a sheet opens, one scrolls, one swipes it away. A level
/// of its own in the stack would mean having to remember the way there.
private struct LicenseSheet: View {
    @Environment(\.horizontalSizeClass) private var widthClass

    let packet: LicenseInfo

    var body: some View {
        ZStack {
            ColorRole.surfaceHigh.color.ignoresSafeArea()
            ScrollSurface {
                VStack(alignment: .leading, spacing: MetricsBoard.phone.gutter) {
                    Text(verbatim: packet.name + DelimiterChars.point + packet.version)
                        .font(TypeLevel.section.font)
                        .foregroundStyle(ColorRole.text.color)
                    Text(verbatim: packet.location)
                        .font(TypeLevel.label.font)
                        .foregroundStyle(ColorRole.textQuiet.color)
                        .textSelection(.enabled)
                    if let addedLater = packet.addedLater {
                        HintRow(
                            icon: Glyph.info.name, color: ColorRole.progress.color,
                            title: "licences.amended %@", wording: addedLater)
                    }
                    // **As text and not as an image.** A license text should be copyable and
                    // readable aloud; an image would be dead for both.
                    Text(verbatim: packet.text ?? "")
                        .font(TypeLevel.label.font)
                        .foregroundStyle(ColorRole.textMatt.color)
                        .textSelection(.enabled)
                        .padding(.top, MetricsBoard.phone.gutter)
                }
                .contentColumn(widthClass)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, MetricsBoard.phone.margin)
                .padding(.top, MetricsBoard.phone.section)
            }
        }
        .presentationDragIndicator(.visible)
        .presentationCornerRadius(MetricsBoard.phone.sheetRadius)
        .presentationBackground(ColorRole.surfaceHigh.color)
    }
}

/// An entry from `App/Resources/Licenses.json`.
struct LicenseInfo: Identifiable, Decodable, Equatable {
    /// Stored keys keep their original (German) names — renaming them would
    /// make data written by earlier versions unreadable (AP85 B4).
    private enum CodingKeys: String, CodingKey {
        case name
        case version = "fassung"
        case location = "ort"
        case kind = "art"
        case text
        case addedLater = "nachgetragen"
    }

    let name: String
    let version: String
    let location: String
    /// `nil` if the origin ships no license file.
    let kind: String?
    let text: String?

    /// The commit the text comes from — **only if it was added afterwards.**
    ///
    /// **The case behind it** (2026-09-07): `jellyfin-sdk-swift` has no license file at version
    /// 2.1.0; it was added only later. The script reads it from the history of the same origin —
    /// and **that has to be said.** A license text that does not come from the shipped state is
    /// not wrong, but it is not the same thing either.
    let addedLater: String?

    var id: String { name }

    /// **From the bundle and not from the network.** A license that first has to be loaded is
    /// missing exactly when someone wants to read it offline.
    static func all() -> [LicenseInfo] {
        guard let fileURL = Bundle.main.url(forResource: "Licenses", withExtension: "json"),
            let data = try? Data(contentsOf: fileURL),
            let read = try? JSONDecoder().decode([LicenseInfo].self, from: data)
        else { return [] }
        return read
    }
}
