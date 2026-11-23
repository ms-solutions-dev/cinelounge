import DesignSystemPhone
import ParentalControls
import SwiftUI

/// Assign age ratings.
///
/// **On the left the server's raw text, on the right the interpretation.** `MediaItem.ageRating` was
/// **displayed** in four places and **checked** in none; the raw text is the server's,
/// and it is not standardized: "FSK 16", "16", "DE-16", "R", "TV-MA", "Not Rated", empty —
/// anything is possible, even nothing.
///
/// **What could not be interpreted stands as a block of its own and is not concealed.**
/// Without this list blocking would be a trap: a parent who is missing thirty-one titles
/// searches for the error in the app and never finds it. With the list they see "TV-MA —
/// not classified" and can assign it in one move.
///
/// **The assignment is a sheet with five levels and no keyboard.** That is exactly what the
/// phone is better at than the TV: a list you swipe through, and a tap on
/// the level.
struct ApprovalsView: View {

    let state: ParentalControlsState

    /// Where the raw texts come from. **Without a source the sheet stays empty and says so** —
    /// an invented list would be worse than an empty one.
    var source: (any ApprovalsSource)?

    @State private var isLoading = false
    @State private var toClassify: ApprovalMirror.ContentEntryRecord?

    var body: some View {
        ZStack {
            ColorRole.reason.color.ignoresSafeArea()

            ScrollSurface {
                VStack(alignment: .leading, spacing: 0) {
                    Footnote(message: "childLock.ratings.intro")

                    if isLoading {
                        LoadingState(message: "childLock.ratings.loading")
                    } else {
                        recognized
                        pending
                    }

                    // **Channels and portals have no rating.** There is nothing to assign for them here
                    // — there the only help is to switch off the whole area.
                    HintRow(
                        icon: Glyph.info.name, title: "childLock.ratings.noRatings",
                        message: "childLock.ratings.noRatings.text")
                }
                .padding(.top, MetricsBoard.phone.gutter)
            }
        }
        .task { await load() }
        .sheet(item: $toClassify) { entry in
            LevelSheet(entry: entry) { age in
                if let age {
                    state.arrange(entry.rawText, to: age)
                } else {
                    state.redeem(entry.rawText)
                }
                toClassify = nil
            }
            .presentationDetents([.fraction(Metrics.sheetSmall), .large])
            .presentationDragIndicator(.visible)
            .presentationCornerRadius(MetricsBoard.phone.sheetRadius)
            .presentationBackground(ColorRole.surfaceHigh.color)
        }
    }

    // MARK: - Understood

    /// **The evidence page.** "FSK 16 → from 16, 41 titles" is verifiable — and whoever sets a
    /// limit sees beforehand what it will cost.
    @ViewBuilder
    private var recognized: some View {
        if !state.mirrored.recognized.isEmpty {
            SectionHeader(title: "childLock.ratingsKnown")
            ForEach(state.mirrored.recognized) { entry in
                ApprovalRow(entry: entry) {
                    // **Only what was assigned by hand can be undone.** "FSK 16" is
                    // a reading; reinterpreting it would mean overriding the server's rating,
                    // and that is a different operation from this one.
                    entry.byHand ? toClassify = entry : ()
                }
            }
            Footnote(message: "childLock.ratings.understood.footnote")
        }
    }

    // MARK: - Not sorted yet

    @ViewBuilder
    private var pending: some View {
        if state.mirrored.pending.isEmpty {
            if !isLoading && !state.mirrored.recognized.isEmpty {
                // **An empty sheet is information.** "Everything understood" is something
                // different from "not asked yet", and both would otherwise look the same.
                HintRow(
                    icon: Glyph.done.pair.outlined, color: ColorRole.success.color,
                    title: "childLock.ratings.allUnderstood",
                    message: "childLock.ratings.allUnderstood.text")
            }
        } else {
            SectionHeader(
                wording: SettingsModel.text(
                    "childLock.ratings.open %lld", state.mirrored.openTitles))
            ForEach(state.mirrored.pending) { entry in
                ApprovalRow(entry: entry) { toClassify = entry }
            }
            Footnote(message: "childLock.ratings.open.footnote")
        }
    }

    private func load() async {
        guard let source, state.mirrored.recognized.isEmpty, state.mirrored.pending.isEmpty
        else { return }
        isLoading = true
        state.tally(await source.approvals())
        isLoading = false
    }
}

/// A row: raw text, arrow, interpretation.
///
/// **The number sits below the raw text and not on the right.** It belongs to the left side —
/// "TV-MA (31 titles)" is a statement about the label, not about the interpretation. On the right
/// stands what comes of it, and that is the column you read off.
private struct ApprovalRow: View {

    let entry: ApprovalMirror.ContentEntryRecord
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: MetricsBoard.phone.gutter) {
                VStack(alignment: .leading, spacing: 1) {
                    Group {
                        if entry.rawText.isEmpty {
                            Text(app: "childLock.ratingsNone")
                        } else {
                            Text(verbatim: entry.rawText)
                        }
                    }
                    .font(TypeLevel.text.font)
                    .foregroundStyle(
                        entry.rawText.isEmpty ? ColorRole.textQuiet.color : ColorRole.text.color
                    )
                    .lineLimit(1)

                    Text(verbatim: SettingsModel.text("common.titleCount %lld", entry.count))
                        .font(TypeLevel.label.font)
                        .foregroundStyle(ColorRole.textQuiet.color)
                }

                Spacer(minLength: MetricsBoard.phone.gutter)

                Image(systemName: Glyph.next.name)
                    .font(TypeLevel.label.font)
                    .foregroundStyle(ColorRole.textQuiet.color)

                interpretation
                    .frame(minWidth: 96, alignment: .trailing)
            }
            .padding(.horizontal, MetricsBoard.phone.margin)
            .frame(minHeight: Metrics.choiceRow)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var interpretation: some View {
        VStack(alignment: .trailing, spacing: 1) {
            if let age = entry.alter {
                Text(verbatim: SettingsModel.text("childLock.limit %lld", age))
                    .font(TypeLevel.text.font)
                    .foregroundStyle(ColorRole.text.color)
                if entry.byHand {
                    Text(app: "childLock.ratings.byHand")
                        .font(TypeLevel.lowercased.font)
                        .foregroundStyle(ColorRole.textQuiet.color)
                }
            } else if entry.rawText.isEmpty {
                // **"No rating" passes**, and the row says so. Removing a title without
                // a rating would mean turning a missing label into a
                // warning.
                Text(app: "childLock.ratingsPasses")
                    .font(TypeLevel.footer.font)
                    .foregroundStyle(ColorRole.textMatt.color)
            } else {
                Text(app: "childLock.ratings.blocked")
                    .font(TypeLevel.text.font)
                    .foregroundStyle(ColorRole.progress.color)
                Text(app: "childLock.ratings.tapToSort")
                    .font(TypeLevel.lowercased.font)
                    .foregroundStyle(ColorRole.textQuiet.color)
            }
        }
    }
}

/// Sheet: which level is that?
///
/// **Five levels and a "take back".** A free number would be more precise and useless: no
/// server delivers "from 14", and a limit that exists in no rating separates nothing.
private struct LevelSheet: View {

    let entry: ApprovalMirror.ContentEntryRecord
    /// `nil` takes the assignment back.
    let select: (Int?) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHeader(
                wording: entry.rawText.isEmpty
                    ? SettingsModel.text("childLock.ratingsNone") : entry.rawText)

            Footnote(message: "childLock.ratings.assign.text")

            ForEach(AgeLimit.allCases, id: \.rawValue) { tier in
                ChoiceRow(
                    name: SettingsModel.text("childLock.limit %lld", tier.rawValue),
                    chosen: entry.alter == tier.rawValue
                ) {
                    select(tier.rawValue)
                }
            }

            if entry.byHand {
                Divider().overlay(ColorRole.lineQuiet.color).padding(.vertical, MetricsBoard.phone.gutter)
                ChoiceRow(name: SettingsModel.text("childLock.ratings.unassign")) {
                    select(nil)
                }
            }
        }
        .padding(.vertical, MetricsBoard.phone.gutter)
    }
}
