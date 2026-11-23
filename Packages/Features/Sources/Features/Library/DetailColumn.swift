import Core
import DesignSystem
import PortalKit
import RatingsKit
import SwiftUI

/// The fixed column on the right in the grid: everything essential about the focused title.
///
/// The purpose is to **spare** going in. Someone browsing a library
/// wants to know what it is about, how long it is and how much is still left — without
/// opening every title and leaving it again. The Apple TV app
/// and Plex do it this way.
///
/// All details come from the list the grid has loaded anyway. **No
/// reloading on focus change** — otherwise every step onward would trigger a request,
/// and scrolling through would cause a flood.
///
/// The one exception is the trailer, and it is narrowly defined: it is only requested
/// when a title has stayed in focus for the dwell time — that is, for the
/// one title someone is actually looking at, and not for every one they
/// move past. See ``TrailerAutostart``.
struct DetailColumn: View {

    let item: MediaItem?
    let posterURL: (MediaItem) -> URL?
    let external: ExternalRatings

    /// Fetches the playback target for a title's trailer.
    ///
    /// Called **only after the dwell time has elapsed** — the reasoning is
    /// above. With a default, so the column also builds where there is no source.
    let trailerTarget: @MainActor (MediaItem) async -> PlaybackTarget?

    /// Fetches the title details of a registered provider for a portal title — likewise only
    /// after a dwell time, see ``ExtrasLookup``. With the default "nothing", like the trailer.
    let extras: @MainActor (MediaItem) async -> TitleExtras?

    /// Width of the column. 500 points leave room next to it for three poster columns plus the
    /// merged filter row and give the description enough lines to
    /// say something. Before that 520 — the filter row needed the twenty points
    /// when the category button moved to it; recalculated in `LayoutBudgetTests`.
    static let width: CGFloat = 500

    /// The poster's space.
    ///
    /// The trailer takes the same place and is flatter. The height therefore stays
    /// fixed: if it followed, half the column would slide upward during the crossfade
    /// while the eye is on the image — and that looks like a bug.
    ///
    /// **Smaller than before (260 × 390), and that is the price for the second
    /// poster row.** The column has a hard height budget — see ``maxHeight`` —,
    /// and with the large poster no room was left below for the
    /// description. The large image is on the left in the grid anyway; here it only carries
    /// recognition, and 300 points are enough for that. It cannot go lower: the
    /// trailer needs its 259 points of height in the same place.
    static let posterSize = CGSize(width: 200, height: 300)

    /// Spacing between the sections of the column. Tighter than the usual 20,
    /// because every point here counts six times — once per gap.
    static let contentSpacing: CGFloat = 16

    /// Lines for the title. Two, not one: the distinguishing part of long
    /// titles comes at the end.
    static let titleLines = 2

    /// Minimum lines of the description in the worst case — **only for the
    /// budget calculation**. Since AP80 (2026-10-12) the description gets the rest of the
    /// column instead of a fixed line count: until then it sat at three lines,
    /// calculated for the worst case (two-line title, ratings, remaining time
    /// with bar), and for an unseen title with a short name 150 to 200 points
    /// below stayed empty. What varies is the content, not the screen —
    /// tvOS always draws 1920 × 1080 points —, so the line count follows the content.
    /// The test suite asserts that even in the worst case these three lines remain.
    static let overviewMinLines = 3

    /// Width of the header data to the right of the poster: column minus poster and gap.
    static let sideWidth: CGFloat = width - posterSize.width - headGap

    /// Gap between poster and header data.
    static let headGap: CGFloat = 20

    /// At most this many names from the cast. Four fit in two lines of 280
    /// points; the lead roles come first, as the server delivers them.
    static let castNames = 4

    /// Allowance for the duration-and-remaining-time group: two text lines, two
    /// gaps and the bar. The bar has no fixed height from the system —
    /// the 20 are a generous estimate, and generous is the safe direction here.
    static var lengthsEstimatedHeight: CGFloat {
        2 * TypeLevel.lineHeight(zu: TypeLevel.lowercased.points) + 2 * 10 + 20
    }

    /// The hard upper limit of the column — **this is the correction at the core.**
    ///
    /// Before, the column had only an ideal height, and it was around 1050
    /// points. The library's `HStack` aligned itself to it: it grew taller than
    /// the screen, the grid's scroll view got a visible area larger than
    /// the image and considered itself not scrollable — the second poster row sat
    /// below the screen edge and was unreachable. The home videos, which have no
    /// column, were fine; that is how the culprit was identified.
    ///
    /// The calculation starts from the screen: 1080 points, minus the overscan inset at the top and bottom, the
    /// pill with its spacing, the column's top inset.
    /// What the sum of the sections — ``estimatedContentHeight`` — wanted beyond that
    /// had to give way; the test suite checks both numbers against each other.
    static var maxHeight: CGFloat {
        1080 - TVMetrics.topMargin - MediaTabBar.reservedTop
            - LibraryView.columnTopPadding
    }

    /// What the sections need together in the worst case — each line
    /// calculated from the tokens, not copied.
    ///
    /// Worst case means: all optional sections are present, each uses
    /// its full line count. The test suite requires that even then everything stays
    /// below ``maxHeight`` — otherwise the upper limit would visibly cut off content
    /// instead of only guarding the emergency.
    static var estimatedContentHeight: CGFloat {
        let caption = TypeLevel.lineHeight(zu: TypeLevel.footer.points)
        let caption2 = TypeLevel.lineHeight(zu: TypeLevel.lowercased.points)
        let title =
            CGFloat(titleLines)
            * TypeLevel.lineHeight(zu: TypeLevel.section.points)
        // The header data to the right of the poster, all present, each at its full line count.
        let sideRows: [CGFloat] = [
            caption2,  // Jahr, Laufzeit, Staffeln, Freigabe
            caption2,  // Genres, one line
            RatingBadges.badgeHeight,
            caption2,  // Regie
            2 * caption2,  // Besetzung, zwei Zeilen
        ]
        let side = sideRows.reduce(0, +) + CGFloat(sideRows.count - 1) * sideSpacing
        // The header block is as tall as the tallest of poster, header data, the
        // trailer variant (``headWide``) and the landscape image with its three lines
        // below (meta line, genres, ratings — director and cast do not exist
        // there, see ``HeaderDataExtent/wide``).
        let wide =
            TrailerSurface.size.height + sideSpacing
            + 2 * caption2 + RatingBadges.badgeHeight + 2 * sideSpacing
        // The extras header: image, people circles with names, label line.
        let extras =
            TrailerSurface.size.height + castCircle + 6 + caption2
            + caption2 + 8 + 2 * sideSpacing
        let head = max(posterSize.height, side, headWide, wide, extras)
        let sections: [CGFloat] = [
            title,  // at the very top, above poster and trailer
            head,
            lengthsEstimatedHeight,
            CGFloat(overviewMinLines) * caption,  // Beschreibung — bekommt den Rest
        ]
        return sections.reduce(0, +) + CGFloat(sections.count - 1) * contentSpacing
    }

    /// Spacing of the header data among themselves — tighter than ``contentSpacing``, because they
    /// belong together and sit next to a poster 300 points tall.
    static let sideSpacing: CGFloat = 10

    /// Height of the header block with the trailer: trailer (259) and below it genres and
    /// ratings — variant G1 of the mockups (product decision, 2026-10-12: choose G1),
    /// the title has sat above the header block since the evening of 2026-10-12 355
    /// points instead of 300 with a poster: remaining time and description move 55 points
    /// down, the description ends two lines earlier with an ellipsis while
    /// the trailer plays, and has them back afterwards. That is intended: rating and
    /// genre stay readable while the image plays.
    static var headWide: CGFloat {
        let genre = TypeLevel.lineHeight(zu: TypeLevel.lowercased.points)
        return TrailerSurface.size.height + genre + RatingBadges.badgeHeight + 2 * sideSpacing
    }

    /// The clock for the automatic start.
    ///
    /// **It hangs on the outer frame and not on the content.** The content is swapped on every
    /// focus change via `.id(item.id)`; a clock inside it would be a new one at every
    /// step onward and would never expire. This is exactly how the switch in the
    /// Home header failed once before.
    @StateObject private var autostart = TrailerAutostart()
    @StateObject private var extrasFetch = ExtrasLookup()

    init(
        item: MediaItem?,
        posterURL: @escaping (MediaItem) -> URL?,
        external: ExternalRatings,
        trailerTarget: @escaping @MainActor (MediaItem) async -> PlaybackTarget? = { _ in nil },
        extras: @escaping @MainActor (MediaItem) async -> TitleExtras? = { _ in nil }
    ) {
        self.item = item
        self.posterURL = posterURL
        self.external = external
        self.trailerTarget = trailerTarget
        self.extras = extras
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let item {
                content(item)
                    // On a switch only the **new** content fades in; the old one
                    // disappears immediately. With a symmetric crossfade, old and new subtree stood
                    // on top of each other for 220 ms during fast stepping — text on text, and with steps shorter than the
                    // duration several semi-transparent versions piled up.
                    // With no transition at all, on the other hand, the content switches so hard
                    // that it flickers.
                    .id(item.id)
                    .transition(.asymmetric(insertion: .opacity, removal: .identity))
            } else {
                placeholder
            }
        }
        .frame(width: Self.width, alignment: .leading)
        // **The upper limit is enforced, not merely claimed.** Only this
        // frame takes the column out of the `HStack`'s height negotiation: whatever
        // the content wants, outwardly it reports at most ``maxHeight`` — and the
        // grid's visible area next to it stays as large as the image. The
        // clipping is the emergency, not the normal case; normally
        // the content fits, and the test suite asserts that.
        .frame(maxHeight: Self.maxHeight, alignment: .top)
        .clipped()
        .animation(.easeInOut(duration: 0.22), value: item?.id)
        .task {
            // First the setting, then the clock. In the reverse order the
            // trailer would start on the first title even when the switch is off.
            autostart.configure(
                preferences: TrailerPreferences.load(from: ProfileStore.playback),
                load: trailerTarget
            )
            autostart.focus(item)
            extrasFetch.configure(load: extras)
            extrasFetch.focus(item)
        }
        // On the outer frame so that the focus change reaches the clock: the content
        // underneath is already a different one by that point.
        .onChange(of: item?.id) { _, _ in
            autostart.focus(item)
            extrasFetch.focus(item)
        }
        .onDisappear {
            // When leaving the library the trailer stops. Sound from a
            // view nobody sees any more is the worst error here — you
            // cannot find the source and quit the app.
            autostart.stop()
            extrasFetch.stop()
        }
    }

    // MARK: - Content

    /// Variant C of the mockups of 2026-10-12 (AP80, product decision: take the
    /// recommended variant): poster on the left, the header data to its right, below them remaining time and
    /// the description, which gets the rest of the column. This makes the column read like
    /// a one-sheet, and the description has ten to twelve lines instead of three.
    ///
    /// Two cases build the header block **wide** (image on top, title below): a
    /// landscape image — flat portals deliver 16:9, and in a 2:3 frame
    /// the image lay as a narrow strip on a plate that was 62 % empty — and the trailer,
    /// which fades in over the header block after the dwell time. With the trailer only the
    /// title line remains; whoever sees the trailer does not read genre and cast, and
    /// everything below the header block stays where it was.
    private func content(_ item: MediaItem) -> some View {
        VStack(alignment: .leading, spacing: Self.contentSpacing) {
            // **The title at the very top**, above poster and trailer (requirement from on-device testing, 2026-10-12:
            // it should look nicer, then: centered and somewhat larger, in a kind of
            // CineLounge branding). It sits in both variants of the header block in
            // the same place and does not move when the trailer starts. The `section` level
            // (48, bold) is the type of the section headings — the same hand as the
            // rest of the app, one level larger than the card titles; there is no separate typeface
            // in CineLounge, the brand is weight and warmth, not a typeface.
            Text(verbatim: item.title)
                .font(TypeLevel.section.font)
                .foregroundStyle(ColorRole.text.color)
                .multilineTextAlignment(.center)
                .lineLimit(Self.titleLines)
                .frame(maxWidth: .infinity)

            head(item)

            if let estimate = WatchEstimate.of(item) {
                lengths(item, estimate)
            }

            if let overview = description(item), !overview.isEmpty {
                Text(verbatim: overview)
                    // `caption`, not `caption2`: the description is reading text,
                    // not an extra — and caption2 at 25 points (18.25
                    // arc minutes at three meters) sits exactly at the strain limit
                    // documented in the tokens.
                    .font(TypeLevel.footer.font)
                    .foregroundStyle(ColorRole.textMatt.color)
                    // No fixed line count: the frame yields the rest of the column,
                    // and `Text` truncates the last line with an ellipsis
                    // instead of cutting off in the middle of a line.
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }

            Spacer(minLength: 0)
        }
        // **The column is always as tall as its budget**, so that the rest the
        // description gets does not depend on the content that happens to sit above it.
        .frame(height: Self.maxHeight, alignment: .top)
    }

    /// The header block: narrow (poster and header data side by side) or wide (image on top).
    @ViewBuilder
    private func head(_ item: MediaItem) -> some View {
        if let running = autostart.running, running.itemID == item.id {
            wideHead(item, extent: .atTrailer) {
                // The trailer is **faded over and not switched**: a hard
                // change in the middle of the column reads as an error, while a transition
                // is read as a response to the focus staying put.
                TrailerSurface(target: running.target)
                    .transition(.opacity)
            }
        } else if let details = details(forItem: item) {
            extrasHeader(item, details)
        } else if item.artwork.isWide == true {
            wideHead(item, extent: .wide) {
                RemoteImage(
                    url: posterURL(item), contentMode: .fit,
                    displaySize: MetricsBoard.tv.episode
                )
                .frame(width: TrailerSurface.size.width, height: TrailerSurface.size.height)
                .background(ColorRole.surfaceHigh.color)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .transition(.opacity)
            }
        } else {
            HStack(alignment: .top, spacing: Self.headGap) {
                poster(item)
                sideData(item, extent: .full)
                    .frame(width: Self.sideWidth, alignment: .leading)
            }
            .animation(.easeInOut(duration: 0.4), value: autostart.running?.itemID)
        }
    }

    /// How much of the header data is shown: everything, or with the trailer only genres and
    /// ratings (G1; the title sits above). Director and cast come back as soon as the trailer is
    /// gone — whoever sees the trailer does not read them, and they cost three lines.
    enum HeaderDataExtent {
        /// Neben dem Plakat: Metazeile, Gattungen, Bewertungen, Regie, Besetzung.
        case full
        /// Below the landscape image: meta line, genres, ratings. Director and cast
        /// are missing because the height would otherwise blow the budget (test suite) — and landscape images
        /// come from flat portals and home videos, which have neither.
        case wide
        /// Below the trailer: genres and ratings; the title sits above.
        case atTrailer
    }

    /// Wide variant: image or trailer at trailer width, the header data below.
    private func wideHead<Bild: View>(
        _ item: MediaItem, extent: HeaderDataExtent, @ViewBuilder image: () -> Bild
    ) -> some View {
        VStack(alignment: .leading, spacing: Self.sideSpacing) {
            image()
            sideData(item, extent: extent)
        }
        .frame(width: Self.width, alignment: .leading)
        .animation(.easeInOut(duration: 0.4), value: autostart.running?.itemID)
    }

    // MARK: - Title extras

    /// The provider's details, when they belong to **this** title.
    private func details(forItem item: MediaItem) -> TitleExtras? {
        guard let fund = extrasFetch.fund, fund.itemID == item.id else { return nil }
        return fund.details
    }

    /// The list's description — otherwise the provider's.
    private func description(_ item: MediaItem) -> String? {
        if let own = item.overview, !own.isEmpty { return own }
        guard let details = details(forItem: item), !details.description.isEmpty else { return nil }
        return details.description
    }

    /// Variant B of the canvas of 2026-10-13 (product decision: take presentation B):
    /// the title image, below it the people as round pictures, then the label as a pill with
    /// date and length. The description follows below as always and gets the rest.
    ///
    /// **The page's image stays** and not the provider's: it is what appears in the
    /// tile next to it, and that is exactly how one should recognize the title.
    private func extrasHeader(_ item: MediaItem, _ details: TitleExtras) -> some View {
        VStack(alignment: .leading, spacing: Self.sideSpacing) {
            RemoteImage(
                url: posterURL(item), contentMode: .fit,
                displaySize: MetricsBoard.tv.episode
            )
            .frame(width: TrailerSurface.size.width, height: TrailerSurface.size.height)
            .background(ColorRole.surfaceHigh.color)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))

            if !details.people.isEmpty {
                peopleRow(details.people)
            }

            labelRow(details)
        }
        .frame(width: Self.width, alignment: .leading)
        .transition(.opacity)
    }

    /// At most three — more do not fit in 500 points without the names breaking.
    static let extrasPeople = 3
    /// A person's circle. Smaller than in the cast row of the detail page
    /// (168): here it sits next to the description, not in its place.
    static let castCircle: CGFloat = 84

    private func peopleRow(_ people: [TitleExtras.Person]) -> some View {
        HStack(alignment: .top, spacing: 18) {
            ForEach(people.prefix(Self.extrasPeople)) { person in
                VStack(spacing: 6) {
                    RemoteImage(
                        url: person.image,
                        displaySize: CGSize(width: Self.castCircle, height: Self.castCircle),
                        placeholderSymbol: "person.fill"
                    )
                    .frame(width: Self.castCircle, height: Self.castCircle)
                    .clipShape(Circle())

                    Text(verbatim: person.name)
                        .font(TypeLevel.lowercased.font)
                        .foregroundStyle(ColorRole.text.color)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
                .frame(width: (Self.width - 2 * 18) / CGFloat(Self.extrasPeople))
            }
        }
    }

    /// The label as a pill, followed by date and length.
    private func labelRow(_ details: TitleExtras) -> some View {
        HStack(spacing: 12) {
            if !details.label.isEmpty {
                Text(verbatim: details.label)
                    .foregroundStyle(ColorRole.text.color)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(ColorRole.surfaceHigh.color))
                    .lineLimit(1)
            }
            if !details.date.isEmpty {
                Text(verbatim: details.readableDate)
            }
            if let minutes = details.minutes {
                if !details.date.isEmpty { dot }
                Text(verbatim: duration(TimeInterval(minutes * 60), rounded: true))
            }
        }
        .font(TypeLevel.lowercased.font)
        .foregroundStyle(ColorRole.textMatt.color)
    }

    /// The poster, 2:3, with `.fit` on a plate as in ``PosterCard``.
    private func poster(_ item: MediaItem) -> some View {
        RemoteImage(
            // Via ``LibraryModel/posterURL(for:)`` with the same width as the
            // tiles next to it: a cache hit, instead of fetching the same poster
            // twice and decoding it twice. The decoded image is
            // thereby slightly larger than the frame, not smaller; so it does
            // not turn blurry.
            url: posterURL(item), contentMode: .fit,
            displaySize: MetricsBoard.tv.poster
        )
        .frame(width: Self.posterSize.width, height: Self.posterSize.height)
        .background(ColorRole.surfaceHigh.color)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .transition(.opacity)
    }

    /// Meta line, genres, ratings, director, cast — in this order, the title
    /// sits above the header block.
    /// Each line only if the source delivers it: Xtream and CL-Server mostly know
    /// neither director nor cast, in which case the description moves up.
    private func sideData(_ item: MediaItem, extent: HeaderDataExtent) -> some View {
        let full = extent == .full
        return VStack(alignment: .leading, spacing: Self.sideSpacing) {
            if extent != .atTrailer {
                metaLine(item)
            }

            if !item.genres.isEmpty {
                genreLine(item)
            }

            if RatingBadges.hasContent(serverRatings: item.ratings, external: external) {
                RatingBadges(serverRatings: item.ratings, external: external)
                    // **One line, hard.** What does not fit in the first drops
                    // out — the ranking in ``RatingBadges`` puts the rarest first,
                    // and the full ratings are on the
                    // detail page.
                    .frame(height: RatingBadges.badgeHeight, alignment: .topLeading)
                    .clipped()
            }

            if full {
                if let directors = item.directors, !directors.isEmpty {
                    labelled("detail.director", directors.joined(separator: ", "), lines: 1)
                }

                if !item.cast.isEmpty {
                    labelled(
                        "detail.cast",
                        item.cast.prefix(Self.castNames).map(\.name).joined(separator: ", "),
                        lines: 2)
                }
            }
        }
    }

    /// One line with a quiet label and a muted value: "Director  Traustus Kredre".
    private func labelled(_ key: LocalizedStringKey, _ value: String, lines: Int) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(app: key)
                .foregroundStyle(ColorRole.textQuiet.color)
            Text(verbatim: value)
                .foregroundStyle(ColorRole.textMatt.color)
                .lineLimit(lines)
        }
        .font(TypeLevel.lowercased.font)
    }

    /// Year, runtime, seasons, episodes, rating — one line, separated by dots.
    /// The runtime only for films: for series the estimated total duration is in
    /// ``lengths(_:_:)``, and the same number twice would be one too many.
    private func metaLine(_ item: MediaItem) -> some View {
        HStack(spacing: 12) {
            if let year = item.year {
                Text(verbatim: String(year))
            }
            if let runtime = item.runtime, runtime > 0, item.kind != .series {
                dot
                Text(verbatim: duration(runtime, rounded: false))
            }
            if let seasons = item.seasonCount, seasons > 0, item.kind == .series {
                dot
                Text(app: "detail.seasonCount \(seasons)")
            }
            if let episodes = item.episodeCount, episodes > 0, item.kind == .series {
                dot
                Text(app: "common.episodeCount \(episodes)")
            }
            if let age = item.ageRating {
                dot
                Text(verbatim: age)
            }
        }
        .font(TypeLevel.lowercased.font)
        .foregroundStyle(ColorRole.textMatt.color)
        .lineLimit(1)
    }

    /// The genres — on a line of their own, not in the header line.
    ///
    /// There is no room there: year, seasons, episodes and age rating already fill it,
    /// and with "Animation · Action & Adventure" the line would be cut off
    /// instead of informative.
    ///
    /// At most three. Some titles list seven, and then none says anything any more —
    /// the first ones are the most fitting anyway.
    ///
    /// **One line, not two.** The column's height budget calculates with one —
    /// see ``estimatedContentHeight`` —, and three genres with dots between them
    /// almost always fit at 500 points of width; what does not fit ends in
    /// an ellipsis instead of displacing the description.
    private func genreLine(_ item: MediaItem) -> some View {
        Text(verbatim: item.genres.prefix(3).joined(separator: " · "))
            .font(TypeLevel.lowercased.font)
            .foregroundStyle(Color(item.artwork.palette ?? .brand, .bright))
            .lineLimit(1)
    }

    /// Total duration, remaining time and a bar for what has been watched.
    private func lengths(_ item: MediaItem, _ estimate: WatchEstimate) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Image(systemName: "clock")
                // "about", because for series the duration is calculated from the episode count times the runtime
                // — the server's figure for it is unusable.
                Text(app: "library.totalLength \(duration(estimate.total, rounded: item.kind == .series))")
            }
            .font(TypeLevel.lowercased.font)
            .foregroundStyle(ColorRole.textMatt.color)

            if estimate.watchedFraction > 0 {
                // The bar shows how far along one is. A number alone could hardly be taken in
                // from three meters away.
                ProgressView(value: estimate.watchedFraction)
                    .tint(Color(paletteOf(item), .bright))
                    .frame(width: 260)

                if estimate.hasRemaining {
                    Text(
                        app:
                            "library.remaining \(duration(estimate.remaining, rounded: item.kind == .series))"
                    )
                    .font(TypeLevel.lowercased.font)
                    .foregroundStyle(Color(paletteOf(item), .bright))
                } else {
                    Text(app: "library.finished")
                        .font(TypeLevel.lowercased.font)
                        .foregroundStyle(ColorRole.textQuiet.color)
                }
            }
        }
    }

    private func paletteOf(_ item: MediaItem) -> AccentPalette {
        item.artwork.palette ?? .brand
    }

    /// Duration as text. For series rounded to half hours — the number is
    /// estimated, and that should be visible.
    ///
    /// **The notation has lived in ``Core/WatchEstimate/durationText(_:roundedValue:)`` since decision 27 (C7)**
    /// — the phone shows the same figure on its detail page.
    private func duration(_ seconds: TimeInterval, rounded: Bool) -> String {
        WatchEstimate.durationText(seconds, roundedValue: rounded)
    }

    private var dot: some View {
        Circle().fill(ColorRole.textQuiet.color).frame(width: 5, height: 5)
    }

    /// As long as nothing is in focus. No empty box, but a hint —
    /// an empty area looks like an error.
    private var placeholder: some View {
        VStack(alignment: .leading, spacing: 16) {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(ColorRole.surface.color)
                .frame(width: Self.posterSize.width, height: Self.posterSize.height)
            Text(app: "library.columnHint")
                .font(TypeLevel.lowercased.font)
                .foregroundStyle(ColorRole.textQuiet.color)
                .frame(width: Self.posterSize.width, alignment: .leading)
            Spacer(minLength: 0)
        }
    }
}
