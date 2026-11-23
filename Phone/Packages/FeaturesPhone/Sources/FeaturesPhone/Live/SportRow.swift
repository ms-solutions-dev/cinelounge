import Core
import DesignSystemPhone
import SwiftUI

/// Time, pairing, competition, channel.
///
/// **Without remaining time — and that is not an omission but a finding.**
/// `SportEvent.end` is the **broadcast slot**, not the end of the game: A football match
/// stands in the schedule with pre- and post-coverage, a tennis match ends when it ends.
/// "14 min left" would therefore be an invented number on a sport row. For a match what
/// matters anyway is **when it started** — the kick-off time stands on the left and stays.
///
/// **The star is a target of its own.** Two actions in one row need two areas; a star that
/// were part of the play button would open a match when you miss, instead of marking it.
///
/// **A long press follows club and competition** (decision 27, B5, 2026-09-26) — the same
/// menu as on the TV and the same watchlist behind it. **The seal** stands on every row
/// whose kick-off the online source confirms (B6): no repeat possible.
struct SportRow: View {

    let event: SportEvent
    let channelName: String?
    let watchlist: SportReminderList
    let now: Date
    let matches: () -> Void
    let memorize: () -> Void
    let followClub: (String) -> Void
    let followCompetition: (String) -> Void

    /// What the star shows — **only the marking of this match**, since only that is what it
    /// toggles (check Live, finding 2, 2026-09-27). Until then `marks` stood here (marked
    /// **or** followed): With a followed club the star was filled, VoiceOver said "Remove
    /// marking", and two presses changed nothing visible. As on the TV
    /// (`SportView.rememberMenu`).
    var bookmarked: Bool { watchlist.isBookmarked(event) }

    /// Whether the row is remembered via a followed club or competition — a separate,
    /// **non-pressable** symbol next to the pairing; unfollowing goes through the long press.
    var isFollowed: Bool { watchlist.follows(event) }

    private var isRunning: Bool { event.isRunning(at: now) }

    var body: some View {
        HStack(spacing: MetricsBoard.phone.gutter) {
            Button(action: matches) {
                HStack(alignment: .top, spacing: MetricsBoard.phone.gutter) {
                    timeColumn
                    midpoint
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(spokenText)
            .contextMenu { followMenu }

            star
        }
        .padding(.horizontal, MetricsBoard.phone.margin)
        .padding(.vertical, 12)
        .frame(minHeight: Metrics.channelRow)
    }

    /// The start time — **left-aligned at a fixed width**, so that the pairings below stand on
    /// one edge. Without it every row shifts by the width of its time.
    private var timeColumn: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(verbatim: event.start.formatted(date: .omitted, time: .shortened))
                .font(TypeLevel.footer.font.weight(.semibold))
                .foregroundStyle(ColorRole.text.color)
                .monospacedDigit()
            if isRunning { LiveBadge() }
        }
        .frame(width: 58, alignment: .leading)
    }

    private var midpoint: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(verbatim: event.title)
                    .font(TypeLevel.footer.font.weight(.semibold))
                    .foregroundStyle(ColorRole.text.color)
                    .lineLimit(2)
                if event.isVerified {
                    Image(systemName: Glyph.seal.name)
                        .font(TypeLevel.label.font)
                        .foregroundStyle(ColorRole.textQuiet.color)
                        .accessibilityHidden(true)
                }
                if isFollowed {
                    Image(systemName: Glyph.bookmark.pair.zu(active: true))
                        .font(TypeLevel.label.font)
                        .foregroundStyle(ColorRole.progress.color)
                        .accessibilityHidden(true)
                }
            }
            Text(verbatim: whereRow)
                .font(TypeLevel.label.font)
                .foregroundStyle(ColorRole.textQuiet.color)
                .lineLimit(1)
        }
    }

    /// The match, then the two teams, then the competition — **the TV's order.** A star next
    /// to it shows whom you already follow.
    @ViewBuilder
    private var followMenu: some View {
        Button(action: memorize) {
            Label {
                Text(appKey: watchlist.isBookmarked(event) ? "sport.unmark" : "sport.mark")
            } icon: {
                Image(systemName: Glyph.bookmark.pair.zu(active: watchlist.isBookmarked(event)))
            }
        }
        if let pairing = SportPlan.pairing(in: event.title) {
            followButton(pairing.home, isOn: watchlist.hasTeam(pairing.home)) { followClub(pairing.home) }
            followButton(pairing.away, isOn: watchlist.hasTeam(pairing.away)) { followClub(pairing.away) }
        }
        if let competition = event.competition {
            followButton(competition, isOn: watchlist.hasCompetition(competition)) {
                followCompetition(competition)
            }
        }
    }

    private func followButton(_ name: String, isOn: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label {
                Text(verbatim: name)
            } icon: {
                Image(systemName: Glyph.bookmark.pair.zu(active: isOn))
            }
        }
        .accessibilityValue(isOn ? Text(appKey: "a11y.state.remembered") : Text(verbatim: ""))
    }

    private var star: some View {
        Button(action: memorize) {
            Image(systemName: Glyph.bookmark.pair.zu(active: bookmarked))
                .font(TypeLevel.footer.font)
                .foregroundStyle(bookmarked ? ColorRole.progress.color : ColorRole.textQuiet.color)
        }
        .frame(width: Metrics.target, height: Metrics.target)
        .accessibilityLabel(Text(appKey: bookmarked ? "sport.unmark" : "sport.mark"))
    }

    /// "Süper Lig · Arena Spor 1 TR · 2 more variants"
    ///
    /// Assembled and not translated as a sentence: Every part can be missing — an event
    /// without a recognised competition, a broadcast without a channel name. A sentence
    /// pattern with three placeholders would then leave separators without content.
    private var whereRow: String {
        var split: [String] = []
        split.append(
            event.competition
                ?? AppLanguageSetting.text(String.LocalizationValue(event.kind.labelKey)))
        if let channelName { split.append(channelName) }
        let more = SportModel.otherVersions(event)
        if more > 0 {
            split.append(
                String(
                    format: AppLanguageSetting.text("sport.moreVersions %lld"), more)
            )
        }
        return split.joined(separator: " · ")
    }

    private var spokenText: String {
        var split = [event.start.formatted(date: .omitted, time: .shortened)]
        if isRunning { split.append(AppLanguageSetting.text("live.mark")) }
        split.append(event.title)
        split.append(whereRow)
        if event.isVerified { split.append(AppLanguageSetting.text("a11y.state.verified")) }
        if isFollowed { split.append(AppLanguageSetting.text("a11y.state.remembered")) }
        return split.joined(separator: ", ")
    }
}
