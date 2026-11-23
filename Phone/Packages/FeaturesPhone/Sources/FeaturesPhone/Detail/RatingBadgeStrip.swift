import Core
import DesignSystemPhone
import SwiftUI

/// The third-party ratings side by side — and a sentence where there are none.
///
/// **Why not one number but up to four.** For an anime AniList has
/// forty thousand votes and Rotten Tomatoes none at all; for a feature film it is the
/// other way round. Whoever shows one number shows, depending on the title, a different
/// kind of information without saying so — and a viewer who reads "88 %" does not know
/// whether it is an audience verdict or a critics' score.
///
/// **The marks are rebuilt, not the original logos.** Those are protected, and in a
/// 22-point-high capsule nothing of a logo would be recognizable anyway.
///
/// **The whole row is one target, not each badge.** Four targets of 40 points each
/// side by side fall below the target spacing; and there is nothing to choose here —
/// you press to see more.
struct RatingBadgeStrip: View {

    let ratings: [Rating]
    let award: Accolade?

    /// Whether AniList would be responsible but currently delivers nothing.
    ///
    /// **The finding (E38): The information was only in the ratings sheet** — that is, behind
    /// a press nobody makes when the number is missing. And its absence looked like
    /// "this service does not carry the title", which for an anime is exactly not true.
    /// Now it appears where the number is missing: as a pale badge with a dash
    /// instead of a rating.
    var hasMuteMark = false
    /// `nil` means: view only. Otherwise a press opens the sheet.
    var open: (() -> Void)?

    /// This many fit side by side.
    ///
    /// Three and not five: depending on the number a badge is 52 to 66 points wide, and
    /// 353 remain between the margins. The fourth would stand half outside — and what stands
    /// half outside looks like an error and not like "there is more".
    static let sideBySide = 3

    var body: some View {
        if hasContent {
            let content = HStack(spacing: 6) {
                if let award {
                    AwardPlaque(award: award)
                }
                ForEach(shown, id: \.origin) { rating in
                    ScoreBadge(rating: rating)
                }
                if hasMuteMark {
                    MuteBadge()
                }
                if other > 0 {
                    Text(verbatim: "+\(other)")
                        .font(TypeLevel.lowercased.font)
                        .foregroundStyle(ColorRole.textQuiet.color)
                        .monospacedDigit()
                }
            }

            if let open {
                Button(action: open) {
                    content.contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .textHitTarget()
                .accessibilityLabel(Text(app: "common.ratings"))
                .accessibilityHint(Text(app: "detail.ratingsHint"))
            } else {
                content
            }
        }
    }

    private var hasContent: Bool { !ratings.isEmpty || award != nil || hasMuteMark }

    /// How many ratings really fit — the award takes one slot.
    private var shown: [Rating] {
        Array(ratings.prefix(award == nil ? Self.sideBySide : Self.sideBySide - 1))
    }

    private var other: Int { ratings.count - shown.count }
}

/// A rating with the mark of the service it comes from.
///
/// **The mark sits on the left on color, the number on the right on material.** This way
/// the row reads as a row: the colored fields form a line along which you
/// recognize the services without reading each number individually.
/// **Nine points were two below its own lower limit.** ``Styling/TypeLevel/lowercased`` is the
/// smallest step of the design — "nothing goes below it" —, and it grows with Dynamic
/// Type. A fixed `.system(size: 9)` does neither: it is too small already at the base size
/// and stays so at XXL. For the same reason the height is a **lower bound**
/// and not a number: with large type a fixed capsule would cut off its own content.
struct ScoreBadge: View {

    let rating: Rating

    var body: some View {
        HStack(spacing: 0) {
            // **The community rating names no service, because nobody knows which one it
            // is.** Jellyfin passes through whatever is configured at its metadata provider
            // — TMDb or IMDb, and it does not say which. A "TMDB" badge would be
            // a claim; the star says "a rating" and claims nothing. On the
            // TV it says "TMDB" there, and that is the same claim — it just
            // goes unnoticed there because the IMDb number usually stands next to it.
            if let tag = ThirdPartyMark.short(rating.origin) {
                Text(verbatim: tag)
                    .font(TypeLevel.lowercased.font)
                    .foregroundStyle(ThirdPartyMark.font(rating.origin))
                    .lineLimit(1)
                    .fixedSize()
                    .padding(.horizontal, 5)
                    .frame(minHeight: 22)
                    .background(ThirdPartyMark.reason(rating.origin))
            } else {
                Image(systemName: Glyph.rating.name)
                    .font(TypeLevel.lowercased.font)
                    .foregroundStyle(ColorRole.deep.color)
                    .frame(minWidth: 22, minHeight: 22)
                    .background(ColorRole.progress.color)
            }

            Text(verbatim: rating.text)
                .font(TypeLevel.lowercased.font)
                .foregroundStyle(ColorRole.text.color)
                .monospacedDigit()
                .lineLimit(1)
                .fixedSize()
                .padding(.horizontal, 6)
                .frame(minHeight: 22)
                .background(ColorRole.surface.color)
        }
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(ColorRole.outline.color, lineWidth: 0.5)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            Text(
                AppLanguageSetting.text(.init(rating.originKey))
                    + " " + rating.text))
    }
}

/// The award — filled when won, otherwise outlined.
///
/// **Changing only the color was not enough.** With a color deficiency, gold on dark
/// and a gold outline give the same impression; the nomination therefore additionally
/// carries the word. The full reasoning is at ``Accolade/extraKey``.
struct AwardPlaque: View {

    let award: Accolade

    var body: some View {
        HStack(spacing: 4) {
            Text(verbatim: award.badge)
                .font(TypeLevel.lowercased.font)
            Text(verbatim: award.count.formatted(.number))
                .font(TypeLevel.lowercased.font)
                .monospacedDigit()
            if let extras = award.extraKey {
                Text(appKey: extras)
                    .font(TypeLevel.lowercased.font)
            }
        }
        .lineLimit(1)
        .fixedSize()
        .foregroundStyle(award.isWin ? ColorRole.deep.color : ColorRole.progress.color)
        .padding(.horizontal, 7)
        .frame(minHeight: 22)
        .background {
            let form = RoundedRectangle(cornerRadius: 6, style: .continuous)
            if award.isWin {
                form.fill(ColorRole.progress.color)
            } else {
                form.strokeBorder(ColorRole.progress.color, lineWidth: 1)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// The colors of the third-party services.
///
/// **`@MainActor` on the colors, because the board is:** ``Styling/ColorBoard/current`` reads an
/// appearance that can change at runtime, and therefore belongs to the
/// main actor. ``short(_:)`` stays free — an abbreviation never changes.
///
/// **In one place and not scattered across the view.** These are brand colors, not
/// design decisions — so they are not in the ``ColorBoard``, which changes with
/// the appearance. An IMDb yellow that would be a different one in the light appearance
/// would not be recognizable.
enum ThirdPartyMark {

    /// `nil` for the community rating: it has **no** mark, because nobody knows which
    /// service it comes from.
    static func short(_ origin: Rating.Origin) -> String? {
        switch origin {
        case .imdb: "IMDb"
        case .mal: "MAL"
        case .critics: "RT"
        case .metacritic: "MC"
        case .community: nil
        }
    }

    @MainActor static func reason(_ origin: Rating.Origin) -> Color {
        switch origin {
        case .imdb: Color(colorValue: 0xF5_C518)
        case .mal: Color(colorValue: 0x2E_51A2)
        case .critics: Color(colorValue: 0xFA_320A)
        case .metacritic: Color(colorValue: 0x00_CE7A)
        case .community: ColorRole.progress.color
        }
    }

    @MainActor static func font(_ origin: Rating.Origin) -> Color {
        switch origin {
        case .imdb: Color(colorValue: 0x12_100B)
        case .mal: .white
        case .critics: .white
        case .metacritic: Color(colorValue: 0x0B_1A0B)
        case .community: ColorRole.deep.color
        }
    }
}

/// The badge for a rating that should exist and currently does not.
///
/// **A dash and not a zero.** A zero would be a rating — and the worst
/// one there is. The dash says "something is missing here" and claims nothing
/// about the title.
///
/// **Pale and without the service's mark.** Whoever knows AniList recognizes the spot by its place
/// in the row; whoever does not should not learn that this one service is
/// unreliable. The explanation is in the sheet behind it, where this badge leads.
struct MuteBadge: View {

    var body: some View {
        Text(verbatim: "—")
            .font(TypeLevel.lowercased.font)
            .foregroundStyle(ColorRole.textQuiet.color)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 8)
            .frame(minHeight: 22)
            .background(ColorRole.surface.color)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(ColorRole.line.color, lineWidth: 0.5)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(app: "detail.malSilent"))
    }
}
