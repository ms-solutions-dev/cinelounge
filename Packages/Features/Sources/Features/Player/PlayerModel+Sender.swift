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

    // MARK: - Switching channels

    /// How many ticks a live channel may stay without a single picture before the raw stream is
    /// tried: eight seconds.
    ///
    /// **The failure alone is not enough** (device finding 2026-08-08: "the 4K RAW channels are not
    /// played at all"). With a codec it cannot open in MPEG-TS, the system player often reports
    /// nothing at all — it stays in buffering, and the viewer sits in front of black. That is why
    /// the standstill also triggers the fallback, and clearly earlier than the twelve seconds of
    /// the standstill report: anyone who zaps does not wait.
    static let liveFallbackTicks = 16

    /// How many ticks of audio without a picture count as "blind": two and a half seconds.
    ///
    /// **This is the case that neither state nor progress reveals** (viewer finding 2026-08-08:
    /// "picture is always black, sound comes", on the device as in the simulator). Apple's
    /// player accepts a playlist with HEVC in MPEG-TS — that pairing it cannot decode, yet it
    /// reports no error: it plays the sound and lets the clock run. To the app that looked like
    /// a successful playback.
    ///
    /// Two and a half seconds, because the picture size is there after about a second with a
    /// sound stream. On the **second** visit the wait is dropped entirely — the channel is then
    /// in ``RawStreamMemory``.
    static let blindTicks = 5

    /// How many ticks of audio without a **drawn** picture count as blind: eight seconds.
    ///
    /// **The second way to be blind — and it was invisible until 2026-08-15** A repacked stream
    /// carries its format descriptions in the header; the picture size is thus there at once,
    /// and the question "is the picture size zero?" never becomes true — even if the decoder
    /// never fulfils the track (device finding: Mercan TV UHD and Lodos TV UHD, audio only, no
    /// fallback). Whether anything was really drawn is known only to the video layer
    /// (``PlaybackController/firstFrameVisible``).
    ///
    /// The deadline is wider than for the missing picture size, because a working stream
    /// sometimes draws its first picture only after seconds (measured 2026-08-15: up to 3 s in the
    /// normal case) — and it only counts while the engine **plays**: buffering resets the
    /// counter, so a sluggish startup is not punished as blindness.
    static let blindDrawTicks = 16

    /// Detects audio without picture and fetches the raw stream.
    ///
    /// Two kinds of blindness, two deadlines: if even the **picture size** is missing, the
    /// decoder cannot handle the track — two and a half seconds suffice. If the size is there
    /// but the layer **never draws**, it is eight — see ``blindDrawTicks``. `nil` answers do not
    /// count as blind: without a drawing surface (tests, AirPlay) that would be a guessed
    /// fallback.
    func noteBlindPlayback() {
        let controller = engine.controller
        let sizeMissing = controller.hasVideoOutput == false
        let neverDrawn = controller.firstFrameVisible == false
        guard target.kind == .live, status == .playing, sizeMissing || neverDrawn
        else {
            blindTicks = 0
            return
        }

        blindTicks += 1
        guard blindTicks == (sizeMissing ? Self.blindTicks : Self.blindDrawTicks) else { return }
        fallBackToRawStream()
    }

    /// How many ticks a live start via the playlist may hang in "becoming ready" before the raw
    /// stream takes over: 16 ticks = 8 s.
    ///
    /// **The third kind of blindness — invisible without a deadline until 2026-08-16** (device
    /// finding: b**N SP*RTS 2 HD took 22.6 s to "ready", the viewer gave up after 25 s; "did not
    /// open at all"). The blind guard only counts WHILE playing — anything that never becomes
    /// ready to play fell through every grid. Eight seconds, as with the never-drawn picture: a
    /// working channel is ready in one to three seconds.
    static let sluggishStartTicks = 16

    /// Detects the hanging startup and fetches the raw stream.
    func noteSluggishStart() {
        guard target.kind == .live, !hasPlayedSinceLoad,
            target.sourceURL.pathExtension.lowercased() == "m3u8"
        else {
            startTicks = 0
            return
        }
        startTicks += 1
        guard startTicks == Self.sluggishStartTicks else { return }
        Diagnostics.playbackProblem(
            "Live startup stuck: not ready to play after 8 s — falling back to the raw stream",
            since: startupTiming?.startedAt)
        fallBackToRawStream()
    }

    /// Draws the consequences of a reported failure of the engine.
    ///
    /// Three cases, three answers (roadmap AP1, the standstill; device finding 2026-08-15, the dead
    /// channel):
    ///
    /// - **Played and broke off** → the same path is set up anew once. The silent rebuild of the
    ///   connection alone does not save the `-12888` case — AVFoundation has discarded the
    ///   playback target, the engine has to reload. No counter needed: the rebuild resets "has
    ///   played", so a second teardown without a picture goes into the other cases.
    /// - **Raw stream, never played** → the memo is healed
    ///   (``RawStreamMemory/forget(_:)``): the channel stays honestly failed for this visit, but
    ///   the next one tries the playlist again. No automatic counter-attempt — together with the
    ///   fallback that would be a roundabout.
    /// - **Playlist, never played** → the known fallback to the raw stream, once per address.
    func noteEngineFailure() {
        stallReport("dropout")
        // **A film that fails has so far triggered nothing at all** — no fallback, no notice, no
        // line (device finding 2026-08-23: "Piotfrodaus 8" stood black for fourteen seconds, then the viewer
        // pressed Menu, and the diagnostics contained nothing about it).
        //
        // A fallback does not help here either: the path via the media server is rightly blocked for
        // provider titles, and the remaining one — Apple's engine on the raw Matroska — is a sham
        // fallback that AVFoundation cannot open. What was missing was the **information**.
        guard target.kind == .live else {
            Diagnostics.playbackProblem(
                "Engine reports failure on a film: delivery path "
                    + "\(target.decision.delivery), reason \(target.decision.reason), "
                    + "remote host \(target.url.host ?? "?"), played since load: "
                    + "\(hasPlayedSinceLoad ? "yes" : "no")",
                since: nil
            )
            return
        }

        if hasPlayedSinceLoad {
            // A teardown remains a defect even if the answer to it is the silent rebuild.
            Diagnostics.playbackProblem(
                "Live dropout after running picture — the same path is set up again",
                since: nil)
            // **The partial path that AVPlayer rejects is switched off for this channel** (F-019) —
            // the rebuild gets the playlist without parts, see ``LowLatencyMemory``. The mark from the
            // error log arrives a moment after the state change — the rebuild waits for it.
            let reconnectCount = target.rerouted(to: target.sourceURL)
            // **Remembered and checked against the generation** (remuxer check, finding 7, 2026-09-27):
            // this task hung on nobody — if the viewer closed the view or switched the channel within
            // the 400 ms, it reconnected anyway and occupied the only provider connection for a screen
            // nobody saw any more. `finish()` now cancels ``dropRestartTask``; the generation check
            // also catches the channel switch, which does not call `finish()` but triggers a new
            // ``startEngine(_:)`` itself.
            let generation = engineStartGeneration
            dropRestartTask?.cancel()
            dropRestartTask = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(400))
                guard let self, !Task.isCancelled, generation == self.engineStartGeneration else { return }
                if self.engine.controller.rejectedLowLatency {
                    LowLatencyMemory.shared.reject(reconnectCount.sourceURL)
                    Diagnostics.playbackStep(
                        "Partial-commitment turned off for this channel — AVPlayer rejected the partial path (-15410)",
                        since: nil)
                }
                self.startEngine(reconnectCount)
            }
            return
        }

        if target.url.pathExtension.lowercased() == "ts" {
            // **The rule learns from this too, and first** (AP3 · V5). It may have predicted the raw
            // stream without this channel ever being on the memo — then the memo heals nothing, and
            // without this line a rule that has become wrong would stay forever.
            learnRawStream(.list)

            var memory = RawStreamMemory.load(from: rawStreamStore)
            guard memory.needsRawStream(target.sourceURL) else { return }
            memory.forget(target.sourceURL)
            memory.save(to: rawStreamStore)
            // The dead stream is the defect; healing the memo is only the consequence.
            Diagnostics.playbackProblem(
                "Raw stream dead without ever playing — memory healed, "
                    + "the next visit tries the playlist again",
                since: nil)
            return
        }

        fallBackToRawStream()
    }

    /// What an observation says about the **kind** of a channel.
    enum RawStreamUsage { case raw, list }

    /// Counts a success of the playlist for the ``RawStreamRule`` — only once a picture has
    /// really been drawn.
    ///
    /// **The success counts just like the failure** (AP3 · V5): a rule that collects only
    /// failures says "always raw" after the first one and would be permanently wrong for the
    /// provider's H.264 channels.
    ///
    /// **But only a real success** (F-033, 2026-10-03, Apple TV 4K from 2017): "playing" used
    /// to count here — and an HEVC channel via the playlist plays sound without picture there.
    /// Every visit thus produced "playlist" at startup and "raw" at the fallback 2.5 s later,
    /// plus another "playlist" once the raw stream ran. The rule never got above half, and every
    /// new HEVC channel failed individually: black, then restart. Now only the playlist itself
    /// counts, and only with a drawn picture.
    func noteListUsed() {
        guard !isListInUse, target.kind == .live, status == .playing,
            target.sourceURL.pathExtension.lowercased() == "m3u8",
            engine.controller.firstFrameVisible == true
        else { return }
        isListInUse = true
        learnRawStream(.list)
    }

    /// Writes an observation into the ``RawStreamRule``.
    ///
    /// **From the playback target and not from the channel**, because the player knows none: the
    /// remote end is in the address, the feature in the title — and that is
    /// ``Channel/cleanName``, that is, the name with its version label. A passed-through state
    /// would be a second truth that eventually drifts apart.
    func learnRawStream(_ evidence: RawStreamUsage) {
        guard target.kind == .live else { return }
        let pair = RawStreamRule.pair(counterpart: target.sourceURL.host, name: target.title)
        var rule = RawStreamRule.load(from: rawStreamStore)
        switch evidence {
        case .raw: rule.rememberRaw(pair)
        case .list: rule.rememberList(pair)
        }
        rule.save(to: rawStreamStore)
        let ruleState = rule.state(pair)
        Diagnostics.verbose(
            "Raw-stream rule: \(pair) now \(ruleState.raw) raw / \(ruleState.list) list"
                + (rule.saysRaw(pair) ? " — says raw" : ""))
    }

    /// Triggers the fallback to the raw stream — once per address.
    ///
    /// The path via the playlist is the better one (system bar, no second engine), but not every
    /// provider delivers every channel that way: with the one tested, the H.264 channels play as
    /// `.m3u8`, the 4K and HEVC versions do not. For them the raw stream remains.
    func fallBackToRawStream() {
        // **Via ``PlaybackTarget/sourceURL``, throughout.** When the remuxer is running, `url`
        // points to `127.0.0.1` — the fallback built an address on the device itself instead of at
        // the provider from it, and would have remembered a channel that never exists again under
        // that address.
        let source = target.sourceURL
        guard target.kind == .live,
            source.pathExtension.lowercased() == "m3u8",
            liveFallbackAttempted != source
        else { return }

        let fallbackURL = ChannelAddressChoice.rawAddress(source)
        let fallbackDecision = LiveModel.decision(forURL: fallbackURL)

        // The engine forcing together with its fallback lock disappeared with the VLC removal (user
        // decision 2026-08-16) — on 2026-08-15 it had done more damage than measured: "unterdrueckt" lines
        // while the UHD channels stayed mute-black.
        liveFallbackAttempted = source
        blindTicks = 0
        // **So that it works at once next time.** Without this memory the detour would cost a few
        // seconds of black again on every visit to the same channel — so again and again when
        // zapping.
        var memory = RawStreamMemory.load(from: rawStreamStore)
        memory.remember(source)
        memory.save(to: rawStreamStore)
        // **And the kind learns along** (AP3 · V5): the next channel of the same provider with the
        // same feature goes raw at once, instead of using up the same eight seconds again.
        learnRawStream(.raw)

        // **The most frequent place of this bundle — and so far a hook every time.** In the session
        // of 2026-08-23 there are 54 such fallbacks in the recording, and every single one means that a
        // channel carried no picture via the playlist. A session with dropouts that produces zero
        // error lines is a defect of the measurement, not an acquittal.
        Diagnostics.playbackProblem(
            "Live fallback: the channel carried no picture as a playlist, "
                + "raw stream from now on. \(memory.count) channels remembered.",
            since: nil
        )
        play(
            PlaybackTarget(
                itemID: target.itemID,
                title: target.title,
                subtitle: target.subtitle,
                url: fallbackURL,
                // The decision from above: from ``LiveModel`` and not from the picker directly — that is
                // where the forcing is also applied, and two separate paths to the same decision sooner or
                // later drift apart.
                decision: fallbackDecision,
                kind: .live
            )
        )
    }

    /// **It is asked with ``PlaybackTarget/sourceURL``, not with `url`.** Since the remuxer is
    /// running, `url` points to `127.0.0.1` — that address appears nowhere in the channel list,
    /// the starting point was unknown, and up and down did nothing at all (viewer finding
    /// 2026-08-11). The history is at ``ChannelSource/plays(_:)``: the same error, another
    /// intermediate station.
    public func switchChannel(by offset: Int) {
        guard canSwitchChannel, let next = neighbourChannel?(target.sourceURL, offset)
        else { return }
        play(next)
    }

    /// Takes over a finished target — for the switch from the overlaid list.
    ///
    /// The same path as with the arrow keys, so that there is only one place where a channel
    /// switch happens: two paths there would drift apart as soon as one of them is touched.
    public func play(_ next: PlaybackTarget) {
        // **Only take over — ``adopt(_:)`` starts the engine itself.**
        //
        // A second `engine.start(next)` stood here, and it cost an evening: every switch loaded the
        // same stream twice, two milliseconds apart. In the log it was visible as a double start
        // line. With a provider that allows a single connection, that is not just double work: the
        // second engine gets nothing any more, and both stand in black.
        adopt(next)
        // The switch is an input: the bar stays up so that the new name can be read. Without that,
        // one would keep switching blind.
        noteInteraction()
    }
}
