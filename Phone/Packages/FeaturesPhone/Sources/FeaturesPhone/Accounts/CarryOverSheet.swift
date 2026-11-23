import DesignSystemPhone
import SecondScreen
import SwiftUI

/// Sheet: what is transferred **before** you agree.
///
/// **The table comes before the consent and not after.** "Transfer setup?"
/// with Yes and No is not a question but a demand: whoever does not know what
/// goes out cannot agree. Here, credential tokens, passwords and the parental-controls
/// PIN go out — that is the list one must have seen.
///
/// **Three sections, because there are three kinds.** What travels along, what stays on the device, and
/// what does not need to travel at all because it is already there. The third is the one that
/// answers the question "and my progress?" before it is asked.
struct CarryOverSheet: View {

    let confirm: () -> Void
    let cancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: MetricsBoard.phone.section) {
            Text(appKey: "handover.title")
                .font(TypeLevel.section.font)
                .foregroundStyle(ColorRole.text.color)
                .padding(.horizontal, MetricsBoard.phone.margin)

            section(
                "handover.travels", Self.travelsAlong, character: Glyph.done.pair.filled,
                color: ColorRole.success.color)
            section(
                "handover.stays", Self.staysHere, character: Glyph.pending.name,
                color: ColorRole.textQuiet.color)
            section(
                "handover.already", Self.isAlreadyThere, character: Glyph.done.pair.outlined,
                color: ColorRole.textMatt.color)

            VStack(spacing: MetricsBoard.phone.gutter) {
                Button(action: confirm) {
                    Text(appKey: "handover.send").frame(maxWidth: .infinity)
                }
                .buttonStyle(.loud)

                Button(action: cancel) {
                    Text(appKey: "common.cancel").frame(maxWidth: .infinity)
                }
                .buttonStyle(.quiet)
            }
            .padding(.horizontal, MetricsBoard.phone.margin)
        }
        .padding(.vertical, MetricsBoard.phone.section)
    }

    private func section(
        _ title: String, _ rows: [String], character: String, color: Color
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionHeader(title: title)
            ForEach(rows, id: \.self) { row in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: character)
                        .font(TypeLevel.label.font)
                        .foregroundStyle(color)
                    Text(appKey: row)
                        .font(TypeLevel.footer.font)
                        .foregroundStyle(ColorRole.textMatt.color)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, MetricsBoard.phone.margin)
            }
        }
    }

    /// **The same enumeration as in ``SetupBundle``, only for humans.**
    ///
    /// `HandoffTests` checks that the two match: what is listed here and has no field
    /// there does not travel — and then this is a promise that nobody keeps.
    static let travelsAlong = [
        "handover.item.server", "handover.item.playlists", "handover.item.bridge",
        "handover.item.keys", "handover.item.look", "handover.item.parental",
        // **Since AP44 (2026-09-21), version 2 of the bundle.** Until then a
        // set-up device arrived over there with **one** person, while four stood here —
        // the mapping "who owns which credential" did not travel along at all.
        "handover.item.profiles",
    ]

    static let staysHere = [
        "handover.item.offline", "handover.item.wifiOnly", "handover.item.deviceID",
    ]

    static let isAlreadyThere = ["handover.item.progress"]
}
