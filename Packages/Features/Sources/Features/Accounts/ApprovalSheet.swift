import Core
import DesignSystem
import ParentalControls
import SwiftUI

/// **The manual assignment of foreign ratings** — AP29, 2026-09-11.
///
/// **Without this list, blocking would be a trap.** ``ProtectionRule`` blocks when in
/// doubt, and the doubt is frequent: A server with `TV-MA`, `R` or `NR` returns almost
/// nothing once a limit is set. On the TV that looked like an empty server —
/// no error, no message, just nothing. The to-do list for it had lain ready since 2026-09-10.
/// (``UnrecognizedRatings``) and had no view.
///
/// **Two blocks, and the upper one is the more important.** "FSK 16 → from 16, 41 titles" is
/// verifiable: Whoever sets a limit sees beforehand what it will cost. Without it
/// only the list of failures would stand there, and "TV-MA → from 16" would be an input into
/// the unknown.
///
/// **And the roadmap had named a prerequisite that is none.** It wrote that the
/// collective source was needed because the mirror demands "the raw texts of **every** title".
/// Counted again: `MediaItem.ageRating` is filled in the whole tree in **one** place —
/// ``JellyfinKit/ItemMapping``. A portal and a provider catalog **never** deliver a
/// rating; their titles are "unspecified" and get through anyway. Going through the
/// catalog of the other sources for this would mean querying a single-connection account for a field
/// that is always empty there.
struct ApprovalSheet: View {

    let mirror: ApprovalMirror
    /// Whether an unrecognized rating is currently blocked — **belongs on the ring.**
    ///
    /// "Blocking" is not an assignment but the **absence** of one. What that costs
    /// is decided by this switch, and whoever assigns must see it: If it is set to "off",
    /// the whole list is busywork without effect.
    let blocksUnrecognized: Bool
    let arrange: (String, Int) -> Void
    let redeem: (String) -> Void
    var onClose: () -> Void = {}

    @FocusState private var focus: String?

    /// The levels that can be assigned by hand — **the same five as everywhere.**
    ///
    /// A free number would be more precise and useless: No server delivers "from 14", and a
    /// limit that exists in no rating separates nothing. The reasoning as a whole
    /// is at ``ParentalControls/AgeLimit``.
    private static let slots = AgeLimit.allCases

    var body: some View {
        ZStack {
            ColorRole.reason.color.ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    SettingsHeader("childLock.ratings", hint: "childLock.ratingsHint")

                    if !mirror.pending.isEmpty { noticeRow }

                    openList
                    understoodList
                }
                .frame(maxWidth: 1100, alignment: .leading)
                .padding(.horizontal, MetricsBoard.tv.margin)
                .padding(.vertical, TVMetrics.topMargin)
            }
        }
        .onExitCommand(perform: onClose)
    }

    /// What the open entries currently cost — **a number and not a feeling.**
    private var noticeRow: some View {
        Text(
            app: blocksUnrecognized
                ? "childLock.ratingsBlocked \(mirror.openTitles)"
                : "childLock.ratingsPassing \(mirror.openTitles)"
        )
        .font(TypeLevel.text.font)
        .foregroundStyle(blocksUnrecognized ? ColorRole.progress.color : ColorRole.textMatt.color)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.bottom, 30)
    }

    @ViewBuilder
    private var openList: some View {
        if mirror.pending.isEmpty {
            Text(app: "childLock.ratingsAllKnown")
                .font(TypeLevel.text.font)
                .foregroundStyle(ColorRole.textMatt.color)
                .padding(.bottom, 40)
        } else {
            ForEach(mirror.pending) { entry in
                mappingRow(entry)
            }
            .padding(.bottom, 40)
        }
    }

    /// An open entry together with its ring.
    ///
    /// **The number stands next to the raw text and is not hidden behind it:** "TV-MA (31
    /// titles)" weighs differently from "NR (1 title)", and whoever assigns wants to make the
    /// assignment that has the most effect. The list is therefore ordered by frequency.
    private func mappingRow(_ entry: ApprovalMirror.ContentEntryRecord) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline, spacing: 16) {
                Text(verbatim: entry.rawText)
                    .font(TypeLevel.header.font)
                    .foregroundStyle(ColorRole.text.color)
                Text(app: "common.titleCount \(entry.count)")
                    .font(TypeLevel.footer.font)
                    .foregroundStyle(ColorRole.textMatt.color)
            }

            HStack(spacing: 14) {
                ForEach(Self.slots, id: \.self) { tier in
                    levelButton(entry.rawText, tier)
                }
            }
        }
        .padding(.bottom, 30)
        // One section per row: The ring has five targets side by side, and the
        // jump from one row to the next should not land in the middle of the ring.
        .focusSection()
    }

    private func levelButton(_ rawText: String, _ tier: AgeLimit) -> some View {
        let identifier = "rating-\(rawText)-\(tier.rawValue)"
        return Button {
            arrange(rawText, tier.rawValue)
        } label: {
            Text(verbatim: tier.caption)
                .font(TypeLevel.footer.font)
                .settingsFont(isFocused: focus == identifier)
                .settingsSurface(.pill, isFocused: focus == identifier)
        }
        .bareFocusableButton()
        .focused($focus, equals: identifier)
        .focusHighlight(focus == identifier, scale: Tokens.Focus.buttonScale)
        .info(
            Text(verbatim: rawText) + Text(verbatim: " · ")
                + Text(app: "childLock.ratingsFrom \(tier.rawValue)"))
    }

    /// The evidence page — **and the reversible assignments are in it.**
    ///
    /// An assignment by hand is a person's decision and not a reading;
    /// whoever wants to undo it later must be able to find it. It therefore stands here
    /// and not in the open list — there it is answered, after all.
    @ViewBuilder
    private var understoodList: some View {
        if !mirror.recognized.isEmpty {
            Text(app: "childLock.ratingsKnown")
                .font(TypeLevel.section.font)
                .foregroundStyle(ColorRole.text.color)
                .padding(.bottom, 18)

            ForEach(mirror.recognized) { entry in
                assignmentRow(entry)
            }
        }
    }

    private func assignmentRow(_ entry: ApprovalMirror.ContentEntryRecord) -> some View {
        let identifier = "known-\(entry.rawText)"
        return Button {
            // **Only the assignments by hand can be undone.** "FSK 16 → from 16"
            // is a reading; releasing it would mean training the app out of reading.
            guard entry.byHand else { return }
            redeem(entry.rawText)
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 20) {
                Text(
                    verbatim: entry.rawText.isEmpty
                        ? AppLanguageSetting.text("childLock.ratingsNone")
                        : entry.rawText
                )
                .frame(width: 320, alignment: .leading)
                .lineLimit(1)

                Text(
                    app: entry.alter.map { LocalizedStringKey("childLock.ratingsFrom \($0)") }
                        ?? "childLock.ratingsPasses"
                )
                .frame(width: 200, alignment: .leading)

                Text(app: "common.titleCount \(entry.count)")
                    .foregroundStyle(ColorRole.textMatt.color)

                Spacer(minLength: 0)

                if entry.byHand {
                    Text(app: "childLock.ratingsUndo")
                        .foregroundStyle(ColorRole.textQuiet.color)
                }
            }
            .font(TypeLevel.footer.font)
            .settingsFont(isFocused: focus == identifier)
            .settingsSurface(.readingRow, isFocused: focus == identifier, reason: .clear)
        }
        .bareFocusableButton()
        .focused($focus, equals: identifier)
        .info(
            Text(
                verbatim: entry.rawText.isEmpty
                    ? AppLanguageSetting.text("childLock.ratingsNone") : entry.rawText
            ),
            .key(entry.byHand ? "childLock.ratingsByHand" : nil))
    }
}
