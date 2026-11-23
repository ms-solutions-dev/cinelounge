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

    // MARK: - Tracks

    /// Whether the tracks of this target are managed by the **server**.
    ///
    /// With chunked delivery the server packs exactly one audio track — the engine sees only
    /// that and could at most offer "Track 1". The real selection is in the metadata
    /// (``PlaybackTarget/media``), and a switch is a new request with
    /// `AudioStreamIndex`/`SubtitleStreamIndex` at a held position. For everything else —
    /// unchanged file, VLC, channels — the engine itself chooses between the tracks it finds in
    /// the stream.
    /// Whether the track list comes from the **server's details** instead of from the engine.
    ///
    /// **Two paths, one reason.** With the chunked path the stream carries only the one track
    /// the server packed; with repacking in the app the same — an fMP4 stream carries exactly the
    /// tracks registered at build time. If one asked the engine in both cases, the menu would
    /// show a single track, and the choice would be gone.
    ///
    /// Switching therefore happens via a rebuild: with the server the number goes into the
    /// address, with the remuxer the **language** into its options.
    var serverManagesTracks: Bool {
        guard target.itemID != nil, target.media != nil else { return false }
        switch target.decision.delivery {
        // The server needs a handle on the file for this — without a start point the title would
        // begin from the start at every track switch.
        case .hls: return source?.canStartAtOffset == true
        case .remuxInApp: return true
        default: return false
        }
    }

    /// A subtitle image together with its position — what the view needs to overlay it.
    public struct SubtitleBitmap: Equatable {
        public let cue: SubtitleImageCue
        public let image: CGImage

        public static func == (lhs: Self, rhs: Self) -> Bool { lhs.cue == rhs.cue }
    }

    // A language filter for the subtitle offer stood here for an evening and was deliberately
    // removed again: the app is meant to become commercial, and which languages a viewer needs
    // is not for the app to decide. Anyone who finds a file with two dozen tracks disturbing
    // cleans up the file — not the display.

    /// Keeps the track lists up to date — depending on the target from the engine or from the
    /// server.
    /// The running remuxer session of a channel — that is where the audio tracks of the
    /// programme table lie, which AVPlayer does not see in the list (AP7 · 4).
    var liveSession: LiveRemuxSession? {
        guard target.kind == .live, target.decision.delivery == .remuxInApp else { return nil }
        return remuxHandle as? LiveRemuxSession
    }

    func refreshTrackLists(from controller: any PlaybackController) {
        if let session = liveSession {
            // **The offer comes from the programme table**, not from AVPlayer's media selection — that
            // sees exactly one track in the list.
            let offer = session.audioOptions.map { option in
                PlaybackTrack(id: Int(option.pid), rawName: option.codec, language: option.language)
            }
            if audioTracks != offer { audioTracks = offer }
            let chosen = session.selectedAudioPID.map(Int.init)
            if selectedAudioTrack != chosen { selectedAudioTrack = chosen }
            if !subtitleTracks.isEmpty { subtitleTracks = [] }
            return
        }
        // **Portals manage their subtitles themselves** (stage 4, 2026-09-12). They come from the
        // same answer as the video address (`/play`) and are in
        // ``PortalKit/PortalSource/lastSubtitles``; the engine sees nothing of them, because
        // they are not in the stream but next to it as separate WebVTT files.
        //
        // **Text only, never images.** The server delivers WebVTT exclusively — AVPlayer does not
        // open EBU-TT-D, and a subtitle that does not open is worse than none. The whole PGS
        // branch below therefore never occurs here.
        if let portals = source as? PortalSource {
            // **Fetched once per target, read afterwards** — the same pattern as ``serverTracksTarget``
            // below, and for the same reason: this place runs on **every** tick, and `lastSubtitles`
            // lives in an actor. An `await` per tick would be an actor hop five times a second for a
            // list that does not change within a target.
            if portalSubtitleTarget != target.itemID {
                let destination = target.itemID
                portalSubtitleTarget = destination
                portalSubtitles = []
                Task { [weak self] in
                    let tracks = await portals.lastSubtitles
                    guard let self, self.portalSubtitleTarget == destination else { return }
                    self.portalSubtitles = tracks
                }
            }
            let offer = portalSubtitles.enumerated().map { slot, track in
                PlaybackTrack(id: slot, rawName: nil, language: track.language)
            }
            if subtitleTracks != offer { subtitleTracks = offer }
            // Audio stays the engine's business: a portal delivers a finished file, and which tracks
            // are in it only the engine knows.
            let newAudio = controller.audioTracks
            if audioTracks != newAudio { audioTracks = newAudio }
            if selectedAudioTrack != controller.selectedAudioTrack {
                selectedAudioTrack = controller.selectedAudioTrack
            }
            if selectedSubtitleTrack != chosenSubtitleIndex {
                selectedSubtitleTrack = chosenSubtitleIndex
            }
            return
        }

        guard serverManagesTracks, let media = target.media else {
            let newAudio = controller.audioTracks
            let newText = controller.subtitleTracks
            if audioTracks != newAudio { audioTracks = newAudio }
            if subtitleTracks != newText { subtitleTracks = newText }
            applyLanguagePreferenceIfPending(to: controller)
            if selectedAudioTrack != controller.selectedAudioTrack {
                selectedAudioTrack = controller.selectedAudioTrack
            }
            if selectedSubtitleTrack != controller.selectedSubtitleTrack {
                selectedSubtitleTrack = controller.selectedSubtitleTrack
            }
            return
        }

        // **The server tracks do not change within a target** (AP7 · L7): they come from
        // ``PlaybackTarget/media``, and that stays fixed as long as the same target runs.
        // ``PlaybackTrack/fromServer(_:)`` nevertheless ran twice per tick — and is quadratic. It is
        // now computed on the target change and read on every tick.
        if serverTracksTarget != target.itemID {
            serverTracksTarget = target.itemID
            audioTracks = PlaybackTrack.fromServer(media.audioTracks)
            subtitleTracks = PlaybackTrack.fromServer(media.subtitleTracks)
        }
        let audio = chosenAudioIndex ?? Self.serverDefaultAudioIndex(in: media)
        if selectedAudioTrack != audio { selectedAudioTrack = audio }
        if selectedSubtitleTrack != chosenSubtitleIndex {
            selectedSubtitleTrack = chosenSubtitleIndex
        }
    }

    /// Takes an embedded text subtitle track directly from the file the app is repacking
    /// anyway — see ``SubtitleCollector``.
    ///
    /// **Why no longer from the server** (F-035, 2026-10-03): for 854 bytes of SRT, Jellyfin
    /// read the whole 11 GB file, 2¼ minutes of "Preparing subtitle", and the disk worked twice
    /// over. Here the lines arrive with the pieces that playback reads ahead anyway.
    ///
    /// - Returns: `false` if the track cannot be found unambiguously in the file — then the
    ///   caller fetches it from the server as before.
    private func loadFromFile(index: Int, generation: Int) -> Bool {
        guard let session = remuxHandle as? MatroskaFileSession,
            let all = target.media?.subtitleTracks,
            let chosen = all.first(where: { Int($0.id) == index }),
            !chosen.isExternal
        else { return false }
        guard
            let track = SubtitleCollector.matroskaTrack(
                forItem: chosen, all: all, file: session.subtitleTracks)
        else {
            Diagnostics.playbackStep(
                "Subtitle track \(index): cannot be matched unambiguously in the file "
                    + "(\(session.subtitleTracks.count) tracks in the file) — from the server",
                since: nil)
            return false
        }
        clearSubtitleState()
        Diagnostics.playbackStep(
            "Subtitle track \(index): from the file (track \(track.number), \(track.codecID)) — without server",
            since: nil)
        let collector = session.subtitles
        let number = track.number
        Task { [weak self] in
            var lastState = -1
            while true {
                guard let self, self.subtitleFetchGeneration == generation else { return }
                let fresh = collector.state(track: number)
                if fresh != lastState {
                    lastState = fresh
                    self.subtitleCues = collector.cues(track: number)
                }
                try? await Task.sleep(for: .seconds(1))
            }
        }
        return true
    }

    /// Fetches the chosen subtitle track and makes it the running one.
    ///
    /// On the first request per file the server extracts the track from the whole container —
    /// that can take a while; after that it comes from its cache. As long as nothing is there,
    /// the picture simply stays without a line: better than a wrong one, and the engine runs on
    /// untouched.
    func loadSubtitle(index: Int) {
        subtitleFetchGeneration += 1
        let generation = subtitleFetchGeneration

        // **With a portal the track is already there as an address** (stage 4, 2026-09-12) — a
        // WebVTT file at the channel, freely retrievable. No waiting, no extraction, no forty
        // attempts: the patience below applies to the media server, which has to pull the track out
        // of the container first (5.5 to 9.5 minutes, documented). Here it would be a loop over a
        // single 404.
        if source is PortalSource {
            guard index >= 0, index < portalSubtitles.count else { return }
            let address = portalSubtitles[index].address
            clearSubtitleState()
            isPreparingSubtitle = true
            Task { [weak self] in
                let raw = try? await URLSession.shared.data(from: address)
                guard let self, self.subtitleFetchGeneration == generation else { return }
                self.isPreparingSubtitle = false
                guard let data = raw?.0,
                    let text = String(data: data, encoding: .utf8)
                else {
                    self.subtitleUnavailable = true
                    Diagnostics.network.error(
                        "Subtitle track \(index) of the portal could not be fetched")
                    return
                }
                self.subtitleCues = WebVTTSubtitles.parse(text)
            }
            return
        }

        guard let jellyfin = source as? JellyfinSource, let itemID = target.itemID else { return }

        // **The app fetches PGS as a raw image track** — the server cannot convert it, the VTT
        // request ends there in a permanent error (documented: Kliasou Magla). The workaround via a
        // VLC restart is deliberately dropped: the engine switch in the middle of playback was the
        // most unstable place in the app. Everything else comes as text — **ASS since 2026-08-10 raw
        // and unconverted**, so that the position is kept: dialogue at the bottom, signs at the
        // top. Exactly that was lost in the conversion to WebVTT, and exactly that is why ASS needed
        // the second engine until now.
        let format = target.media?.subtitleTracks.first { Int($0.id) == index }?.subtitleFormat
        let wantsImages = format == .pgs || format == .vobsub

        if loadFromFile(index: index, generation: generation) { return }

        // **The server does deliver VobSub raw** — as `.sub`, re-measured on 2026-08-10. The old note
        // ("neither convert nor deliver raw") applied to `.vtt` and `.idx`, and the check back then
        // ran via `.vtt`. DVBSUB remains the case without a delivery path: two attempts suffice to
        // rule out a random error, after which the display says so honestly.
        let attempts = format == .dvbsub ? 2 : 40

        clearSubtitleState()
        isPreparingSubtitle = true
        Task { [weak self] in
            // **Patient, not one-shot.** On the first access per file the server first pulls the track
            // from the whole container — documented at 5.5 to 9.5 minutes for large films, while the
            // request times out after 60 seconds. The extraction continues on the server even when the
            // request is long gone — so the app keeps asking until the track is there or another choice
            // replaces it. Forty attempts at a 15-second interval carry even the longest measured
            // preparation; what is still missing after that is really broken.
            for attempt in 1...attempts {
                guard let self, self.subtitleFetchGeneration == generation else { return }
                if wantsImages {
                    if let cues = try? await jellyfin.subtitleImageCues(
                        for: itemID, index: index, format: format ?? .pgs)
                    {
                        guard self.subtitleFetchGeneration == generation else { return }
                        self.subtitleImageCues = cues
                        self.isPreparingSubtitle = false
                        return
                    }
                } else if let cues = try? await jellyfin.subtitleCues(
                    for: itemID, index: index, format: format)
                {
                    guard self.subtitleFetchGeneration == generation else { return }
                    self.subtitleCues = cues
                    self.isPreparingSubtitle = false
                    return
                }
                if attempt == 1 {
                    Diagnostics.verbose(
                        "Subtitle track \(index) not ready yet — the server is preparing it")
                }
                try? await Task.sleep(for: .seconds(15))
            }
            guard let self, self.subtitleFetchGeneration == generation else { return }
            self.isPreparingSubtitle = false
            self.subtitleUnavailable = true
            Diagnostics.network.error("Subtitle track \(index) could not be fetched")
        }
    }

    /// Tears down the remuxer — it holds a server open.
    ///
    /// **And the interpretation starts a new run afterwards** (check 2026-09-25, H1): whether a
    /// new remuxer is there is recognised by ``beobachteUmpacker(at:)`` from
    /// ``stillstandsgriff``, an `ObjectIdentifier`. That is only the address — the new session can
    /// get exactly the memory location of the one just released, and then it would continue with
    /// the sentence and byte base of the old one. Here, where the old one is certainly gone, that
    /// works without comparison.
    func releaseRemux() {
        core.remuxerTornDown()
        stopRemux?()
        stopRemux = nil
        remuxHandle = nil
    }

    /// Clears both track kinds together with the display — on switching off, on title change and
    /// before every new request.
    func clearSubtitleState() {
        subtitleCues = nil
        subtitleImageCues = nil
        subtitleLine = nil
        subtitleTopLine = nil
        subtitleBitmaps = []
        bitmapCache = [:]
        isPreparingSubtitle = false
        subtitleUnavailable = false
    }

    /// Keeps the current subtitle images up to date — only one is built per window, and the
    /// comparison across the windows prevents redrawing on every tick.
    func refreshSubtitleBitmaps() {
        guard let cues = subtitleImageCues else {
            if !subtitleBitmaps.isEmpty { subtitleBitmaps = [] }
            return
        }
        let current = cues.images(at: position)
        guard current != subtitleBitmaps.map(\.cue) else { return }
        subtitleBitmaps = current.compactMap { cue in
            if let cached = bitmapCache[cue.start] {
                return SubtitleBitmap(cue: cue, image: cached)
            }
            guard let image = Self.bitmap(from: cue) else { return nil }
            bitmapCache[cue.start] = image
            return SubtitleBitmap(cue: cue, image: image)
        }
        clearImageCache()
    }

    /// How many subtitle images stay in memory at most.
    ///
    /// **The finding** (AP6 · Q7): ``bitmapCache`` grew over the whole film — 1000 to 1500
    /// image subtitles at around 1.5 MB each — and was only cleared on a track switch. A
    /// two-hour film with PGS subtitles thus accumulates up to two gigabytes, for images that
    /// were each visible once for three seconds.
    ///
    /// Sixty images are around ninety megabytes and cover about three minutes of dialogue —
    /// enough that a jump back of a few seconds does not have to redraw anything.
    static let maximumFrames = 60

    /// Clears the images that are furthest from the position.
    ///
    /// **By distance and not by age:** anyone who jumps back needs the images from just now — a
    /// store that throws out the oldest would have just thrown those away.
    func clearImageCache() {
        guard bitmapCache.count > Self.maximumFrames else { return }
        let here = position
        let tooFar = bitmapCache.keys
            .sorted { abs($0 - here) > abs($1 - here) }
            .prefix(bitmapCache.count - Self.maximumFrames)
        for location in tooFar { bitmapCache.removeValue(forKey: location) }
    }

    /// RGBA pixels into a drawing image — with **non**-premultiplied alpha, because that is how
    /// the PGS reader delivers the colours; if premultiplied beforehand, semi-transparent edges
    /// would be too dark.
    static func bitmap(from cue: SubtitleImageCue) -> CGImage? {
        guard let provider = CGDataProvider(data: cue.rgba as CFData) else { return nil }
        return CGImage(
            width: cue.width,
            height: cue.height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: cue.width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: true,
            intent: .defaultIntent
        )
    }

    /// Which audio track the server packs without a specification: its default track, otherwise
    /// the first. The same rule by which Jellyfin itself chooses — the display should claim what
    /// can really be heard.
    static func serverDefaultAudioIndex(in media: MediaSource) -> Int? {
        let standard = media.audioTracks.first { $0.isDefault } ?? media.audioTracks.first
        return standard.flatMap { Int($0.id) }
    }

    /// Applies the target's language preferences to engine-managed tracks.
    ///
    /// Only for engines that choose in the stream themselves — VLC and the unchanged delivery.
    /// With chunking, the choice is long since in the address as a track number. It waits until
    /// the engine reports tracks; before that there would be nothing to select, and the
    /// preference would be used up.
    func applyLanguagePreferenceIfPending(to controller: any PlaybackController) {
        guard !didApplyLanguagePreference else { return }
        guard target.preferredAudioLanguage != nil || target.preferredSubtitleLanguage != nil
        else {
            didApplyLanguagePreference = true
            return
        }
        guard !controller.audioTracks.isEmpty else { return }
        didApplyLanguagePreference = true

        if let wanted = target.preferredAudioLanguage,
            let match = controller.audioTracks.first(where: {
                LanguageCode.matches($0.language, wanted)
            })
        {
            controller.selectAudioTrack(match.id)
        }
        if let wanted = target.preferredSubtitleLanguage,
            let match = controller.subtitleTracks.first(where: {
                LanguageCode.matches($0.language, wanted)
            })
        {
            controller.selectSubtitleTrack(match.id)
        }
    }

    public func selectAudioTrack(_ id: PlaybackTrack.ID) {
        noteInteraction()
        rememberAudio(id)

        if serverManagesTracks {
            guard id != selectedAudioTrack else { return }
            chosenAudioIndex = id
            selectedAudioTrack = id
            // New request at a held position: the server packs the requested track, the player jumps
            // back to the position after opening.
            Diagnostics.verbose("Audio track \(id) selected — new request to the server")
            scheduleRestart(at: position)
            return
        }

        if let session = liveSession {
            guard id != selectedAudioTrack, id >= 0, id <= Int(UInt16.max) else { return }
            session.selectAudio(pid: UInt16(id))
            selectedAudioTrack = id
            return
        }

        engine.controller.selectAudioTrack(id)
        selectedAudioTrack = id
    }

    public func selectSubtitleTrack(_ id: PlaybackTrack.ID?) {
        noteInteraction()

        if serverManagesTracks {
            guard id != selectedSubtitleTrack else { return }
            chosenSubtitleIndex = id
            selectedSubtitleTrack = id

            // **No rebuild — the app draws by itself.** Switching off means: lines gone, immediately.
            // Switching on means: fetch the track, playback keeps running unperturbed meanwhile. The
            // months-long fight against Jellyfin's main list (burned in, renditions, patched lists)
            // ends here: the stream never carries subtitles, the app overlays them.
            guard let id else {
                subtitleFetchGeneration += 1
                clearSubtitleState()
                Diagnostics.verbose("Subtitles off — local, without rebuild")
                return
            }
            Diagnostics.verbose("Subtitles \(id) selected — track is fetched, no rebuild")
            loadSubtitle(index: id)
            return
        }

        engine.controller.selectSubtitleTrack(id)
        selectedSubtitleTrack = id
    }

    // MARK: - Audio choice per title (AP58 G1, A10)

    /// Remembers the language of the chosen audio track for this title — **new on the TV.**
    ///
    /// Until then the next episode started again in the language of the general rule, even when
    /// one had just deliberately switched to the original audio. It is remembered under the
    /// series, for a film under the title (``Core/AudioMemory``); only for a recording and
    /// only if the track names a language — otherwise there would be nothing by which to find it
    /// again in the next file.
    func rememberAudio(_ id: PlaybackTrack.ID) {
        guard target.kind == .recording, let identifier = target.itemID,
            let language = audioTracks.first(where: { $0.id == id })?.language, !language.isEmpty
        else { return }
        AudioMemory.memorize(language, identifier: identifier, series: target.seriesID, in: audioStore)
    }
}
