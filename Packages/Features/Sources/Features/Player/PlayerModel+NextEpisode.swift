import Core
import DesignSystem
import Flows
import Foundation
import JellyfinKit
import Observation
import Playback
import PortalKit
import SwiftUI

extension PlayerModel {

    // MARK: - Loading extra details

    /// Not `private`, so that the tests can establish the state of the source without calling
    /// ``begin()`` — that starts the tick, and a test with a running timer in the background is
    /// not a test but a race.
    ///
    /// **After every answer it is asked whether the title is still playing** (player check,
    /// finding S8): anyone who, in the first seconds, chose a different episode from the board
    /// would otherwise get the late answer of the previous one — the skip button with its times
    /// and, as "next episode", its successor, possibly the one currently running.
    func loadContext() async {
        guard let source, let itemID = target.itemID else { return }
        let applies = { [weak self] in self?.target.itemID == itemID }

        // A trailer has neither segments nor a next episode, and a channel neither. The requests
        // would come back empty — only after a wait and with load on the server.
        guard target.kind == .recording else { return }

        // If the start selection (for example the anime rule) has already determined a subtitle,
        // it is fetched right away — the display would otherwise stand on the chosen track without
        // ever showing a line.
        if let preset = target.decision.subtitleStreamIndex, subtitleCues == nil {
            loadSubtitle(index: preset)
        }

        let segmentList = (try? await source.segments(for: itemID)) ?? []
        guard applies() else { return }
        core.setSegments(segmentList)
        // **The profile decides whether intro and recap go by themselves** (AP85).
        let binge = BingePreferences.load(from: ProfileStore.playback)
        core.autoSkipKinds = binge.autoSkipKinds
        core.stillWatchingAfter = binge.stillWatchingAfter
        // **So that the question from the roadmap can be answered**: "no longer fetched or just no
        // longer shown?" Without this line a failure looks exactly like a title without marks —
        // both are an empty list, and both explain a missing button.
        Diagnostics.verbose("Segments: \(segments.count) for \(itemID)")
        let frames = try? await source.trickplay(for: itemID)
        guard applies() else { return }
        trickplay = frames
        // **The same filters as on the phone** (AP58 G1, ``Flows/InfoBoard``).
        let episode = await InfoBoard.allowedNext(
            after: itemID, from: source, mayPlay: mayPlay)
        guard applies() else { return }
        nextEpisode = episode

        // Films and home videos have no next episode — there the related title takes the same
        // place: after Jeipik-Bousjinflut, Jeipik-Bousjinflut 2 is on offer, with the same counter and the same
        // dismissability.
        if nextEpisode == nil, target.seriesID == nil {
            let related = await InfoBoard.allowedRelated(
                zu: itemID, from: source, mayPlay: mayPlay)
            guard applies() else { return }
            nextEpisode = related
            nextIsSimilar = related != nil
        }
        core.setNext(
            available: nextEpisode != nil, similar: nextIsSimilar, location: position, duration: duration)
    }

    /// Cast and further episodes for the info area — **via the shared board**
    /// (``Flows/InfoBoard``): only on opening, only once, and only what the filter lets
    /// through.
    public func loadInfoIfNeeded() async {
        guard let source, let itemID = target.itemID else { return }
        await board.load(
            source: source, identifier: itemID, series: target.seriesID, next: nextEpisode,
            mayPlay: mayPlay, applies: { [weak self] in self?.target.itemID == itemID })
    }

    // MARK: - Skipping

    /// The segment for which a button is currently offered.
    ///
    /// Only within the reported window — after that it disappears by itself. A permanent button
    /// in the picture would be easier to build and would stand there pointlessly for every film
    /// that has no intro.
    public var skipOffer: MediaSegment? {
        core.skipOffer(at: position)
    }

    public func skipCurrentSegment() {
        guard let end = core.skip(at: position) else { return }
        seek(to: end)
    }

    // MARK: - Sleep timer (AP85)

    public var sleepChoice: PlaybackCore.SleepChoice { core.sleepChoice }

    public func setSleep(_ choice: PlaybackCore.SleepChoice) {
        core.setSleep(choice)
        noteViewer()
    }

    /// Minutes left on a running sleep timer.
    public var sleepMinutesLeft: Int? { core.sleepMinutesLeft() }

    // MARK: - Still watching? (AP85)

    /// Whether the player stands and asks.
    public var asksStillWatching: Bool { core.asksStillWatching }

    /// A press of the viewer — resets the "Still watching?" count and shows the bar.
    /// **Only for the views**; the model's own paths call ``noteInteraction()``.
    ///
    /// **Back passes `showsBar: false`** (finding 2026-11-09): with the bar shown on every
    /// press, Back always found it up, hid it — and never got to leaving the player.
    public func noteViewer(showsBar: Bool = true) {
        core.noteViewerPresent()
        if showsBar { noteInteraction() }
    }

    /// "Keep watching".
    public func keepWatching() {
        core.confirmStillWatching()
        engine.controller.play()
        noteInteraction()
    }

    /// The section just skipped by itself — for the hint with "Back" (AP85 binge package).
    public var autoSkipHint: MediaSegment? { core.autoSkipHint() }

    /// "Back": to the start of the section skipped by itself; it then runs.
    public func undoAutoSkip() {
        guard let start = core.undoAutoSkip() else { return }
        seek(to: start)
        noteInteraction()
    }

    // MARK: - Next episode

    /// Dismisses the offer.
    ///
    /// Must exist: anyone who wants to watch the credits — in anime the song is there, in series
    /// the preview — must not be dragged along.
    public func dismissNextUp() {
        core.dismissNext()
        noteInteraction()
    }

    /// Switches to the next episode.
    public func advance() async {
        guard let episode = nextEpisode else { return }
        await play(episode)
    }

    /// Switches to any episode — for the card "More episodes".
    ///
    /// **``mayPlay`` is asked here too** — not only when filling the lists: between filling
    /// and press the offer can come from another path, and the switch is the last place before
    /// the engine.
    public func play(_ episode: MediaItem) async {
        guard !isAdvancing, mayPlay(episode) else { return }
        isAdvancing = true
        defer { isAdvancing = false }

        // First sign off the running title. Otherwise the server has two sessions of the same
        // device, and the old one stays visible as "playing" until its deadline.
        if let report = core.finish(at: position) {
            await send(report)
        }

        guard let next = await makeTarget(for: episode) else {
            // Without an address there is nothing to start. The offer disappears anyway — offering it a
            // second time would only fail again.
            core.dismissNext()
            return
        }

        adopt(next)
        await loadContext()
    }

    /// Builds the target for an episode.
    ///
    /// The engine choice is made anew here and not taken from the running episode: within a
    /// series, container and tracks do change — an episode delivered later as MKV would run
    /// black in the system player.
    func makeTarget(for episode: MediaItem) async -> PlaybackTarget? {
        guard let source else { return nil }

        // The next episode comes from a list query and therefore carries no technical details.
        // Without them the engine choice is blind.
        guard let full = try? await source.item(id: episode.id), let media = full.source else {
            return nil
        }

        // **The same details as for the first start — all of them** (``Core/PlaybackPlan``).
        // `sourceCanStartAtOffset`, the viewer's preference and the ASS choice were once missing
        // here, and the episode meant an engine switch in the middle of the series. The same start
        // rule as for the first title: anyone who watches anime in the original audio should not
        // suddenly get the next episode in German — and anyone who watches with subtitles wants
        // them in the next episode too.
        //
        // **Since AP58 R4 the episode starts where the server says** (until then always at zero) —
        // the same rule as on the phone and on the first start. And a media server is no longer
        // assumed but asked at the source: a series from the provider otherwise ran differently
        // from the second episode on than the first.
        let plan = PlaybackPlan.build(
            title: full, media: media, source: PlaybackPlan.Source(source), preference: preference,
            device: .thisDevice, reason: .nextEpisode(withSubtitles: selectedSubtitleTrack != nil))
        let decision = plan.decision

        let url: URL
        do {
            url = try await source.streamURL(for: full.id, decision: decision)
        } catch {
            // The same place, the same reasoning: without this entry, "the next episode does not
            // start" would end in the diagnostics as silence.
            Diagnostics.playbackProblem(
                "No address for the next episode “\(full.title)”: "
                    + "\(Diagnostics.explain(error)) — identifier \(full.id), "
                    + "delivery path \(decision.delivery)",
                since: nil
            )
            return nil
        }

        return PlaybackTarget(
            itemID: full.id,
            title: full.title,
            subtitle: Self.episodeSubtitle(for: full),
            url: url,
            decision: decision,
            startAt: plan.startAt,
            duration: full.runtime,
            seriesID: full.seriesID,
            media: media,
            chapters: full.chapters ?? [],
            preferredAudioLanguage: plan.audioLanguage,
            preferredSubtitleLanguage: plan.subtitleLanguage,
            kind: .recording
        )
    }

    /// The second line of an episode.
    ///
    /// The designation comes from ``EpisodeIdentifier`` — the same as on the episode tiles, in the
    /// app's language (finding B3 of 2026-09-27: until then a fixed "F" stood here).
    static func episodeSubtitle(for episode: MediaItem) -> String? {
        var parts: [String] = []
        if let series = episode.parentTitle, !series.isEmpty { parts.append(series) }
        if let identifier = episode.episodeIdentifier { parts.append(identifier) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// Takes over a new target.
    /// Reports the running target to Now Playing — at start and at every title change (F-029:
    /// after the next episode the old title was still shown on the phone).
    func announceNowPlaying() {
        let poster = target.itemID.flatMap { id in
            target.kind == .live ? nil : source?.imageURL(itemID: id, kind: .primary, width: 600, tag: nil)
        }
        NowPlayingBridge.shared.begin(
            title: target.title, subtitle: target.subtitle, isLive: target.kind == .live,
            artworkURL: poster,
            commands: NowPlayingBridge.Commands(
                play: { [weak self] in self?.engine.controller.play() },
                pause: { [weak self] in self?.engine.controller.pause() },
                toggle: { [weak self] in self?.togglePause() },
                skip: target.isSeekable ? { [weak self] seconds in self?.skip(by: seconds) } : nil))
    }

    func adopt(_ next: PlaybackTarget) {
        // Another title, other tracks: the choice applies per file — the numbers of the old one
        // fit entirely different tracks in the next. What the new target's decision has already
        // chosen (for example the preferred audio track) is taken over. With the same title (jump,
        // track switch) the choice explicitly stays.
        // **Asked once, needed twice** — and here at the top, because from `target = next` on the
        // question can no longer be asked.
        let isSameTitle = Self.keepsContext(from: target, to: next)

        if !isSameTitle {
            chosenAudioIndex = next.decision.audioStreamIndex
            chosenSubtitleIndex = next.decision.subtitleStreamIndex
            didApplyLanguagePreference = false
            // Lines and images also have to go — they belonged to the old film. With the same title
            // (jump, audio switch) they explicitly stay: they hang on the position, not on the stream.
            subtitleFetchGeneration += 1
            clearSubtitleState()
        }

        target = next

        // **A new counter.** The old one has signed off and stays silent for good; if it were
        // reused, not a single report would come for the new episode, and it would never appear
        // under "Continue Watching".
        // **What hangs on the title goes away only on a title change** — segments, what was swiped
        // away and the offer in the ``core``; the counter of the reports always starts anew.
        core.newTarget(
            reportsProgress: next.tracksProgress, isRecording: next.kind == .recording,
            sameTitle: isSameTitle)

        // **What belongs to the title goes away only on a title change** (roadmap AP4: "Skip intro
        // and credits no longer appear").
        //
        // All of it stood here unconditionally — and `restart(at:)` rebuilds the engine on every
        // far jump without fetching the context again afterwards. After the first jump via the
        // server, the list of segments was empty for the rest of the film: no intro, no credits,
        // and no trigger point for the next episode either.
        //
        // Segments, cast and preview images hang on the **title**, not on the stream. With a jump
        // within the same title they therefore stay; what was swiped away also stays swiped away —
        // anyone who has skipped the intro does not want it offered again after jumping back.
        // **The speed applies to the title** (``Flows/SpeedChoice/afterSwitch(_:sameTitle:)``,
        // player check, finding S6) — on every path and not only via the remuxer: until then
        // `rate = 1` stood in the remuxer branch of ``startEngine(_:)``. As a result the next
        // episode inherited the previous one's speed on the direct path, and a far jump in a
        // Matroska silently set a chosen speed to 1. On the same title the tick puts it back on
        // after the rebuild (``applySpeed()``).
        rate = SpeedChoice.afterSwitch(rate, sameTitle: isSameTitle)

        if !isSameTitle {
            liveStalls = 0
            announceNowPlaying()
            // **The package belongs to the TITLE, not to the view** (user question 2026-08-15: whether we
            // record how long a channel is streamed). The measurement used to close only with the view
            // and attributed the whole zapping session to the FIRST channel — "Telve 1 HEVC watched 518 s"
            // in truth covered four channels. Every title change now closes its package and starts a
            // new one under the new name.
            reportTrack()
            playbackTrace.begin(
                "\(next.decision.engine.rawValue)/\(next.decision.delivery.rawValue): "
                    + next.title,
                at: Date(),
                isLive: next.kind == .live
            )
            trickplay = nil
            nextEpisode = nil
            nextIsSimilar = false
            board.clear()
            sourceChoice.isRunning(nil)
        }
        scrubPosition = nil

        // The position where the viewer is. **Without offset** (AP8): the server-side start point
        // was dropped with the VLC removal — the player jumps by itself, and the local start point
        // has carried everything since.
        position = next.startAt
        duration = next.duration ?? 0
        status = .opening

        // The info area belongs to the previous title. If it stayed open, the cast of the episode
        // just left would stand there above the new picture.
        isInfoVisible = false

        // **The channel switch is measured too**, and it especially: when flipping through
        // channels, a long startup time is most noticeable, and the switch is the most frequent way
        // into a channel.
        // A new startup, so also a new interim result — see ``reportedSlowStart``.
        reportedSlowStart = false
        startupTiming = StartupTiming(
            opening: "\(next.decision.engine.rawValue)/\(next.decision.delivery.rawValue)",
            startedAt: Date()
        )

        // **Via ``startEngine(_:)`` and not directly** — otherwise the engine gets the raw address
        // on the switch instead of the repacked one. The full reasoning is there.
        startEngine(next)
        startStartupProbe()
        // The switch also opens a picture again — the same reasoning as in ``begin()``.
        updateIdleGuard()
        noteInteraction()
    }

    // MARK: - Images

    /// Image address for the cards in the info area and in the next-episode offer.
    ///
    /// ``ContentSource`` deliberately delivers no image addresses — the contract describes
    /// content, not its presentation. The query on ``JellyfinSource`` is therefore the smaller
    /// intervention: extending the contract by images would affect every source, including the
    /// channel list, which has none. If `nil` comes out here, ``RemoteImage`` sets its designed
    /// placeholder — no empty surface.
    public nonisolated func imageURL(
        for itemID: String,
        kind: JellyfinSource.ImageKind = .primary,
        width: Int
    ) -> URL? {
        (source as? JellyfinSource)?.imageURL(itemID: itemID, kind: kind, width: width)
    }

    /// The image of a chapter marker of the running title — only for Jellyfin and only if the
    /// server has extracted it (tag). Otherwise `nil`, and the chapters tab takes the trickplay
    /// image at the same position (AP79, 2026-10-12).
    func chapterImageURL(index: Int, tag: String?, width: Int) -> URL? {
        guard let itemID = target.itemID else { return nil }
        return (source as? JellyfinSource)?.chapterImageURL(
            itemID: itemID, index: index, tag: tag, width: width)
    }
}
