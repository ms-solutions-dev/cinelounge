import Core
import DesignSystem
import Flows
import SwiftUI

/// The area that slides into the picture on swiping down.
///
/// The cards follow what the source provides (AP79, 2026-10-12, ``Flows/InfoBar``):
/// Info and Audio & Subtitles always, Cast, Episodes or Similar, and Chapters only if they
/// exist — nobody shows an empty tab. **Playback keeps running** — that is the whole
/// purpose: one wants to know who is speaking just now without pausing the film. That is
/// why this view nowhere stops the sound either.
///
/// The cards already switch when the focus lands on their name, instead of only on
/// pressing. On tvOS that is the familiar movement, and a second key press for something
/// one has already looked at is noticed as a delay.
struct PlayerInfoPanel: View {

    let model: PlayerModel
    @FocusState.Binding var focus: String?

    /// What a press on a cast member triggers. `nil` means: the row is for looking at — the
    /// reasoning is at ``PersonTap``.
    var onSelectPerson: ((Person) -> Void)?

    @Environment(\.accentPalette) private var palette

    /// Height from the template. It leaves a third of the picture free at the top — just
    /// enough to see that the film keeps running.
    static let height: CGFloat = 796

    /// The cards in display order — computed from the situation, not enumerated.
    ///
    /// While the board loads, cast and episodes are still missing; they are added as soon as
    /// the answer is there. The series counts even if only the whole title knows it
    /// (``InfoBoard`` resolves it the same way).
    var tabItems: [InfoTab] {
        InfoBar.tabs(
            .init(
                kind: model.target.kind,
                series: model.target.seriesID != nil || model.info?.seriesID != nil,
                cast: model.cast.count,
                more: model.siblingEpisodes.count,
                chapters: ChapterJump.hasChapters(
                    kind: model.target.kind, chapters: model.target.chapters)))
    }

    /// The language key for a tab.
    static func key(_ tabItems: InfoTab) -> String {
        switch tabItems {
        case .info: "player.tabInfo"
        case .cast: "player.tabCast"
        case .episodes: "player.tabEpisodes"
        case .similarTitles: "player.tabSimilar"
        case .chapters: "player.tabChapters"
        case .tracks: "player.tabTracks"
        }
    }

    /// Width of a chapter card: four next to each other fit into the overscan area.
    static let chapterWidth: CGFloat = 400

    /// Width of a track column and the gap between the two.
    ///
    /// As values and not as numbers in the build, because both together must fit into the
    /// overscan area — content that is too wide is centred by SwiftUI and runs out on both
    /// sides, without a warning. Recomputed in `PlayerModelTests`.
    static let columnWidth: CGFloat = 620
    static let columnGap: CGFloat = 60

    @State private var tab: InfoTab = .info
    /// Spoiler protection of the profile (AP85).
    @State private var guardsSpoilers = BingePreferences.load(from: ProfileStore.playback).hidesSpoilers

    var body: some View {
        VStack {
            Spacer(minLength: 0)

            VStack(alignment: .leading, spacing: 34) {
                tabs
                content
                Spacer(minLength: 0)
            }
            .padding(.top, 44)
            .padding(.horizontal, MetricsBoard.tv.margin)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: Self.height)
            .background(background)
        }
        .ignoresSafeArea()
        .onChange(of: focus) { _, current in
            // The focus determines the card. Without this line the content would stay while another
            // name is already highlighted above — that looks like a bug.
            guard let current, let chosen = Self.tabItems(forFocus: current) else { return }
            tab = chosen
        }
        .onChange(of: tabItems) { _, now in
            // If the board arrives and the tab under the content is gone (or not there yet), it goes
            // to Info — never to a content without a tab.
            tab = InfoBar.remains(tab, in: now)
        }
    }

    private var background: some View {
        LinearGradient(
            stops: [
                .init(color: ColorRole.reason.color, location: 0),
                .init(color: ColorRole.reason.color.opacity(0.97), location: 0.62),
                .init(color: ColorRole.reason.color.opacity(0.86), location: 1),
            ],
            startPoint: .bottom,
            endPoint: .top
        )
        .overlay(alignment: .top) {
            Rectangle()
                .fill(ColorRole.line.color)
                .frame(height: 2)
        }
    }

    /// Which card a focus identifier belongs to.
    ///
    /// The identifier carries the **name** of the tab, not its position: the bar grows when the
    /// board answers, and a position would suddenly mean something else while the focus is on
    /// it.
    static func tabItems(forFocus id: String) -> InfoTab? {
        guard id.hasPrefix("info-tab-") else { return nil }
        return InfoTab(rawValue: String(id.dropFirst("info-tab-".count)))
    }

    static func focusID(_ tabItems: InfoTab) -> String { "info-tab-" + tabItems.rawValue }

    // MARK: - Cards

    private var tabs: some View {
        HStack(spacing: 34) {
            ForEach(tabItems, id: \.self) { entry in
                let id = Self.focusID(entry)
                let isFocused = focus == id
                let isActive = tab == entry

                Button {
                    tab = entry
                } label: {
                    Text(appKey: Self.key(entry))
                        .font(TypeLevel.header.font)
                        .foregroundStyle(
                            isFocused || isActive ? ColorRole.text.color : ColorRole.textQuiet.color
                        )
                        .padding(.bottom, 12)
                        .overlay(alignment: .bottom) {
                            Rectangle()
                                .fill(isActive ? Color(palette) : .clear)
                                .frame(height: 4)
                        }
                }
                .bareFocusableButton()
                .focused($focus, equals: id)
            }
        }
        .focusSection()
    }

    @ViewBuilder
    private var content: some View {
        switch tab {
        case .info: info
        case .cast: castRow
        case .episodes, .similarTitles: episodes
        case .chapters: chapters
        case .tracks: tracks
        }
    }

    // MARK: - Info

    /// Year, director, runtime, rating, genres and the description — the questions one asks
    /// oneself in the middle of a film. Previously the details row stood above the cast; now it
    /// has its own tab, which exists for every title.
    @ViewBuilder
    private var info: some View {
        if let info = model.info {
            VStack(alignment: .leading, spacing: 22) {
                metaLine(for: info)
                if !info.genres.isEmpty {
                    Text(verbatim: info.genres.prefix(4).joined(separator: " · "))
                        .font(TypeLevel.footer.font)
                        .foregroundStyle(Color(palette, .bright))
                        .lineLimit(1)
                }
                if let overview = info.overview, !overview.isEmpty {
                    Text(verbatim: overview)
                        .font(TypeLevel.text.font)
                        .foregroundStyle(ColorRole.textMatt.color)
                        // Six lines at 1,300 points: the core of the plot, and below it the film stays visible.
                        .lineLimit(6)
                        .frame(maxWidth: 1300, alignment: .leading)
                }
            }
        } else if model.isInfoLoaded {
            nothingThere
        } else {
            placeholder
        }
    }

    private func metaLine(for info: MediaItem) -> some View {
        HStack(spacing: 16) {
            if let year = info.year {
                Text(verbatim: String(year))
            }
            if let directors = info.directors, !directors.isEmpty {
                Circle().fill(ColorRole.textQuiet.color).frame(width: 6, height: 6)
                Text(app: "detail.director")
                Text(verbatim: directors.joined(separator: ", "))
            }
            if let runtime = info.runtime, runtime > 0 {
                Circle().fill(ColorRole.textQuiet.color).frame(width: 6, height: 6)
                Text(Duration.seconds(runtime), format: .units(allowed: [.hours, .minutes]))
            }
            if let age = info.ageRating {
                Circle().fill(ColorRole.textQuiet.color).frame(width: 6, height: 6)
                Text(verbatim: age)
            }
        }
        .font(TypeLevel.footer.font)
        .foregroundStyle(ColorRole.textMatt.color)
        .lineLimit(2)
    }

    // MARK: - Cast

    /// The leads as a row — leads first, as the source delivers them.
    @ViewBuilder
    private var castRow: some View {
        if !model.cast.isEmpty {
            ScrollView(.horizontal) {
                HStack(alignment: .top, spacing: 34) {
                    ForEach(model.cast) { person in
                        let id = "info-cast-\(person.id)"

                        VStack(spacing: 14) {
                            RemoteImage(
                                url: model.imageURL(
                                    for: person.id,
                                    width: ImageSizing.requestWidth(
                                        points: MetricsBoard.tv.person
                                    )
                                ),
                                displaySize: CGSize(
                                    width: MetricsBoard.tv.person,
                                    height: MetricsBoard.tv.person
                                )
                            )
                            .frame(
                                width: MetricsBoard.tv.person,
                                height: MetricsBoard.tv.person
                            )
                            .clipShape(Circle())
                            .focusHighlight(focus == id, accent: Color(palette, .bright))

                            VStack(spacing: 4) {
                                Text(verbatim: person.name)
                                    .font(TypeLevel.footer.font)
                                    .fontWeight(.semibold)
                                    .foregroundStyle(ColorRole.text.color)
                                if let character = person.character, !character.isEmpty {
                                    Text(verbatim: character)
                                        .font(TypeLevel.lowercased.font)
                                        .foregroundStyle(ColorRole.textMatt.color)
                                }
                            }
                            .multilineTextAlignment(.center)
                            .lineLimit(2)
                            .frame(width: MetricsBoard.tv.person + 30)
                        }
                        .modifier(
                            PersonTap(
                                action: onSelectPerson.map { action in { action(person) } })
                        )
                        .focused($focus, equals: id)
                    }
                }
                .padding(.vertical, 20)
            }
            .scrollClipDisabled()
            .focusSection()
        }
    }

    // MARK: - More episodes / Similar

    @ViewBuilder
    private var episodes: some View {
        if model.siblingEpisodes.isEmpty {
            if model.isInfoLoaded { nothingThere } else { placeholder }
        } else {
            ScrollView(.horizontal) {
                HStack(alignment: .top, spacing: MetricsBoard.tv.gutter) {
                    ForEach(model.siblingEpisodes) { episode in
                        let id = "info-ep-\(episode.id)"

                        Button {
                            // The switch runs through the model, not through a new screen: a second player over the
                            // first would mean two engines and two audio tracks at the same time.
                            Task { await model.play(episode) }
                        } label: {
                            EpisodeCard(
                                item: episode,
                                imageURL: model.imageURL(
                                    for: episode.id,
                                    // Films have no episode still frame — there the landscape image carries the card; for
                                    // episodes everything stays as before.
                                    kind: episode.kind == .episode ? .primary : .backdrop,
                                    width: ImageSizing.requestWidth(
                                        points: MetricsBoard.tv.episode.width)),
                                isFocused: focus == id,
                                guardsSpoilers: guardsSpoilers
                            )
                        }
                        .bareFocusableButton()
                        .focused($focus, equals: id)
                    }
                }
                .padding(.vertical, 20)
            }
            .scrollClipDisabled()
            .focusSection()
        }
    }

    // MARK: - Chapters

    /// Image size of a chapter card, 16:9 at card width minus the inner margin (20 per side).
    static let chapterImage = CGSize(width: chapterWidth - 40, height: (chapterWidth - 40) * 9 / 16)

    /// The image for a chapter marker: Jellyfin's chapter image, otherwise the trickplay image
    /// at the start position, otherwise an empty surface of the same size (requirement,
    /// 2026-10-12: with images it would be easier to recognise roughly where the section lies).
    @ViewBuilder
    private func chapterImage(_ tag: Chapter, index: Int) -> some View {
        let size = Self.chapterImage
        if let url = model.chapterImageURL(
            index: index, tag: tag.imageTag,
            width: ImageSizing.requestWidth(points: size.width))
        {
            RemoteImage(url: url, displaySize: size)
                .frame(width: size.width, height: size.height)
        } else if let trickplay = model.trickplay {
            ScrubPreview(trickplay: trickplay, time: tag.start)
                .scaleEffect(size.width / ScrubPreview.size.width)
                .frame(width: size.width, height: size.height)
        } else {
            ColorRole.surfaceHigh.color
                .frame(width: size.width, height: size.height)
        }
    }

    /// The chapter markers as cards with an image; a press jumps there. The running one is
    /// marked — from the position the bar shows (``PlayerModel/displayPosition``), not from the
    /// engine, so that the marking follows along while seeking.
    private var chapters: some View {
        let marks = model.target.chapters
        return ScrollView(.horizontal) {
            HStack(alignment: .top, spacing: MetricsBoard.tv.gutter) {
                ForEach(Array(marks.enumerated()), id: \.offset) { index, tag in
                    let id = "info-chapter-\(index)"
                    let end = index + 1 < marks.count ? marks[index + 1].start : .infinity
                    let isRunning = model.displayPosition >= tag.start && model.displayPosition < end

                    Button {
                        model.seek(to: tag.start)
                    } label: {
                        VStack(alignment: .leading, spacing: 8) {
                            chapterImage(tag, index: index)
                                .clipShape(
                                    RoundedRectangle(cornerRadius: MetricsBoard.tv.imageRadius)
                                )
                                .padding(.bottom, 4)
                            if let title = tag.title, !title.isEmpty {
                                Text(verbatim: title)
                            } else {
                                Text(app: "player.chapter \(index + 1)")
                            }
                            Text(
                                Duration.seconds(tag.start),
                                format: .time(
                                    pattern: tag.start >= 3600 ? .hourMinuteSecond : .minuteSecond)
                            )
                            .font(TypeLevel.lowercased.font)
                            .foregroundStyle(isRunning ? Color(palette, .bright) : ColorRole.textMatt.color)
                        }
                        .font(TypeLevel.footer.font)
                        .foregroundStyle(ColorRole.text.color)
                        .lineLimit(2)
                        .padding(20)
                        .frame(width: Self.chapterWidth, alignment: .leading)
                        .background(
                            RoundedRectangle(cornerRadius: MetricsBoard.tv.cardRadius)
                                .fill(isRunning ? ColorRole.surfaceHigh.color : ColorRole.surface.color)
                        )
                        .focusHighlight(focus == id, accent: Color(palette, .bright))
                    }
                    .bareFocusableButton()
                    .focused($focus, equals: id)
                }
            }
            .padding(.vertical, 20)
        }
        .scrollClipDisabled()
        .focusSection()
    }

    // MARK: - Audio & subtitles

    /// Two columns instead of one list: the area is wide and limited in height — one below the
    /// other, both lists would be cut off after three entries.
    @ViewBuilder
    private var tracks: some View {
        if model.audioTracks.isEmpty && model.subtitleTracks.isEmpty {
            placeholder
        } else {
            HStack(alignment: .top, spacing: Self.columnGap) {
                column(key: "player.audio") {
                    ForEach(model.audioTracks) { track in
                        TrackRow(
                            id: "info-audio-\(track.id)",
                            label: track.displayName(),
                            isOn: model.selectedAudioTrack == track.id,
                            focus: $focus
                        ) {
                            model.selectAudioTrack(track.id)
                        }
                    }
                }

                column(key: "player.subtitles") {
                    TrackRow(
                        id: "info-sub-off",
                        labelKey: "player.subtitlesOff",
                        isOn: model.selectedSubtitleTrack == nil,
                        focus: $focus
                    ) {
                        model.selectSubtitleTrack(nil)
                    }
                    ForEach(model.subtitleTracks) { track in
                        TrackRow(
                            id: "info-sub-\(track.id)",
                            label: track.displayName(),
                            isOn: model.selectedSubtitleTrack == track.id,
                            focus: $focus
                        ) {
                            model.selectSubtitleTrack(track.id)
                        }
                    }
                }
            }
            .focusSection()
        }
    }

    private func column<Content: View>(
        key: LocalizedStringKey,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(app: key)
                .font(TypeLevel.footer.font)
                .kerning(3)
                .foregroundStyle(ColorRole.textQuiet.color)
            content()
        }
        .frame(width: Self.columnWidth, alignment: .leading)
    }

    /// When the board has answered and nothing is there — **instead of a spinner without end**
    /// (player check, finding S7: for a provider episode the title can never be looked up, and
    /// the spinner spun forever).
    private var nothingThere: some View {
        Text(app: "player.infoNone")
            .font(TypeLevel.text.font)
            .foregroundStyle(ColorRole.textMatt.color)
            .frame(height: 200)
    }

    /// As long as nothing is available.
    ///
    /// A spinner and not a "nothing available": cast and episodes are only fetched on opening,
    /// and with VLC the tracks are only ready after startup. A statement about the catalog
    /// would be too early in both cases.
    private var placeholder: some View {
        HStack(spacing: 18) {
            ProgressView()
            Text(app: "player.loading")
                .font(TypeLevel.text.font)
                .foregroundStyle(ColorRole.textMatt.color)
        }
        .frame(height: 200)
    }
}
