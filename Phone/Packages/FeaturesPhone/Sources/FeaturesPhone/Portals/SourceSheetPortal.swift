import Core
import DesignSystemPhone
import SwiftUI

/// The source choice of a portal — **three-tier, because there are hosts.**
///
/// **Why a sheet of its own next to ``SourcesSheet``.** With the media server one chooses an
/// upper limit with which the server delivers, and an audio track from the file — two questions to
/// **one** source. A portal has no file at all: it has a list of foreign addresses,
/// and the list is a cross product. Measured at the bridge on 2026-09-06, Animehub
/// delivers **twelve** rows for one episode — four hosts times three language versions —, and flat
/// one below the other "HOSTA" stands there four times. The decomposition is done by ``PortalSourceChoice``.
///
/// **Why it stands in the player and not on the detail page.** Both halves of this
/// sheet presuppose a **resolved** address: the clock at the top counts its deadline, and
/// a change of host is a restart at the same position. On the detail page
/// nothing is resolved — half the view would stand empty there.
///
/// **The difference "plays immediately" versus "looks for the video source first" is not
/// here**, although the design writes it on every row: it is a property of the
/// **portal** (`resolver` in its capabilities) and not of the host. Since
/// 2026-09-06 it stands in the portal choice, where it influences the choice; here it would be
/// the same sentence four times on four rows.
///
/// **The deadline is the normal case on the phone and not the special case.** A
/// host address is valid for five minutes; whoever reads a message in between comes back after
/// expiry. On the TV that hardly happens — there nobody puts the remote
/// down to type.
struct SourceSheetPortal: View {

    let choice: PortalSourceChoice
    /// The identifier of the row that is currently playing.
    let chosen: String?
    /// Until when the running address is valid. `nil` means **unknown**, not "forever".
    let validUntil: Date?
    let select: (PortalHost) -> Void
    let resolveAgain: () -> Void

    @State private var page = 0

    var body: some View {
        SheetFrame(title: "common.sources") {
            deadline
            if fields.count > 1 {
                SegmentRow(pages: fields.map(label), chosen: $page)
            }
            rows
            if choice.rows.isEmpty {
                Footnote(message: "portalsources.none")
            }
            Footnote(message: "portalsources.footnote")
        }
    }

    // MARK: - Die Uhr

    /// How long the address is still valid — **or that it has expired.**
    ///
    /// `TimelineView(.periodic)` and no clock of its own in the model: it runs only as long as
    /// this sheet is visible. A clock in the model would keep running behind the closed sheet
    /// and make the view redraw every second to change a number that
    /// nobody sees.
    @ViewBuilder
    private var deadline: some View {
        if let validUntil {
            TimelineView(.periodic(from: .now, by: 1)) { cadence in
                let rest = validUntil.timeIntervalSince(cadence.date)
                if rest > 0 {
                    Row(
                        icon: Glyph.clock.name, color: ColorRole.textMatt.color,
                        wording: AppLanguageSetting.text("portalsources.valid \(Self.clockTime(rest))"))
                } else {
                    VStack(alignment: .leading, spacing: 6) {
                        Row(
                            icon: Glyph.expire.name, color: ColorRole.progress.color,
                            wording: AppLanguageSetting.text("portalsources.expired"))
                        Footnote(message: "portalsources.expired.text")
                        Chip(title: "portalsources.resolve", action: resolveAgain)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, MetricsBoard.phone.margin)
                    }
                }
            }
        }
    }

    /// "4:12" — minutes and seconds, not "251 seconds".
    ///
    /// `nonisolated`, so that the check can call it without the main actor — the same
    /// reasoning as for ``SourcesSheet/bitrateText(_:)``.
    nonisolated static func clockTime(_ rest: TimeInterval) -> String {
        let total = Int(rest.rounded(.up))
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    // MARK: - Die Zeilen

    /// Which of the three questions this portal asks at all.
    ///
    /// **A segment without content is dropped**, and that is why "three-tier" is the build form and
    /// not the announcement: with Animehub they are provider and version, with the ARD tier and
    /// version. A portal that carried all three would therefore be no special case.
    private var fields: [PortalSourceChoice.Field] {
        PortalSourceChoice.Field.allCases.filter { field in
            switch field {
            case .provider: choice.provider.count > 1
            case .tier: choice.slots.count > 1
            case .version: choice.variants.count > 1
            }
        }
    }

    private var field: PortalSourceChoice.Field {
        fields.indices.contains(page) ? fields[page] : (fields.first ?? .provider)
    }

    /// The running row — from it the two **other** questions are fixed.
    private var running: PortalHost? {
        choice.rows.first { $0.id == chosen }
    }

    private var suggestions: [PortalSourceChoice.Suggestion] {
        choice.suggestions(
            forItem: field,
            provider: field == .provider ? nil : running?.provider,
            tier: field == .tier ? nil : running?.tier,
            version: field == .version ? nil : running?.version)
    }

    private var rows: some View {
        ForEach(suggestions) { suggestion in
            ChoiceRow(
                name: suggestion.value,
                icon: Glyph.sources.name,
                subRow: suggestion.reason,
                chosen: running.flatMap { PortalSourceChoice.value(from: $0, field: field) }
                    == suggestion.value
            ) {
                // **A suggestion without a target does nothing, and it looks like it.** A
                // button that can be pressed and effects nothing is the finding that
                // `scripts/buttons.py` has been looking for since 2026-09-06.
                if let target = suggestion.target { select(target) }
            }
            .disabled(!suggestion.selectable)
            .opacity(suggestion.selectable ? 1 : 0.55)
        }
    }

    private func label(_ field: PortalSourceChoice.Field) -> String {
        switch field {
        case .provider: AppLanguageSetting.text("portalsources.provider")
        case .tier: AppLanguageSetting.text("portalsources.quality")
        case .version: AppLanguageSetting.text("about.version")
        }
    }

    /// Symbol and sentence side by side — the state row at the top of the sheet.
    private struct Row: View {
        let icon: String
        let color: Color
        let wording: String

        var body: some View {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(TypeLevel.label.font)
                Text(verbatim: wording)
                    .font(TypeLevel.label.font)
            }
            .foregroundStyle(color)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, MetricsBoard.phone.margin)
        }
    }
}
