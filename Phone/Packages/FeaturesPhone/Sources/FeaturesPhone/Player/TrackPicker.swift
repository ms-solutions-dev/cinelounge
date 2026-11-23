import Core
import DesignSystemPhone
import Flows
import SwiftUI

/// Audio and subtitles — **two segments, one list.**
///
/// **Two sheets would be two ways for the same decision.** Anyone who changes the audio
/// track checks the subtitles in the same breath; separating them would mean coming up
/// from below twice.
///
/// **"Off" is part of the list**, not a switch next to it. It is one of the choices, not
/// an exception to them — and as a switch it would be a second control for the same
/// thing.
struct TrackPicker: View {

    let audioTracks: [PlaybackTrack]
    let subtitles: [PlaybackTrack]
    let selectedAudio: PlaybackTrack.ID?
    let selectedSubtitle: PlaybackTrack.ID?
    let selectAudio: (PlaybackTrack.ID) -> Void
    let selectSubtitle: (PlaybackTrack.ID?) -> Void
    /// The chosen speed and the way to change it — `nil` where there are no tiers
    /// (AP58 G1, A6: the same tiers as in the track board of the TV).
    var rate: Double = 1
    var selectSpeed: ((Double) -> Void)?
    /// The sleep timer (AP85) — `nil` hides the row.
    var sleep: PlaybackCore.SleepChoice = .off
    var sleepMinutesLeft: Int?
    var selectSleep: ((PlaybackCore.SleepChoice) -> Void)?

    @State private var onSubtitles = false

    var body: some View {
        SheetFrame(title: "player.tracks") {
            // **The segment is only there if there are two sides.** A title without a subtitle
            // track has nothing to switch — and a switch with one side is no switch.
            if !subtitles.isEmpty {
                SegmentPicker(
                    links: AppLanguageSetting.text("player.audio"),
                    right: AppLanguageSetting.text("player.subtitles"),
                    isRightSelected: $onSubtitles)
            }

            if onSubtitles, !subtitles.isEmpty {
                ChoiceRow(
                    name: AppLanguageSetting.text("player.subtitlesOff"),
                    chosen: selectedSubtitle == nil
                ) {
                    selectSubtitle(nil)
                }
                ForEach(subtitles) { track in
                    ChoiceRow(
                        name: track.displayName(),
                        icon: Glyph.subtitles.name,
                        chosen: track.id == selectedSubtitle
                    ) {
                        selectSubtitle(track.id)
                    }
                }
            } else {
                ForEach(audioTracks) { track in
                    ChoiceRow(
                        name: track.displayName(),
                        icon: Glyph.audio.name,
                        chosen: track.id == selectedAudio
                    ) {
                        selectAudio(track.id)
                    }
                }
                if audioTracks.isEmpty {
                    Footnote(message: "player.noTracks")
                }
            }

            // **The tiers stand under the tracks and not as a third side.** Anyone who changes the
            // speed does so rarely and then deliberately; a third tab would put the frequent choice
            // — the audio track — one step further away. The hold gesture for double speed remains
            // in addition.
            if let selectSpeed {
                SectionHeader(title: "player.speed")
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: Metrics.targetSpacing) {
                        ForEach(SpeedChoice.slots, id: \.self) { tier in
                            Chip(wording: SpeedChoice.caption(tier), on: tier == rate) {
                                selectSpeed(tier)
                            }
                        }
                    }
                    .padding(.horizontal, MetricsBoard.phone.margin)
                }
            }

            if let selectSleep {
                SectionHeader(title: "player.sleepTimer")
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: Metrics.targetSpacing) {
                        ForEach(PlaybackCore.sleepChoices, id: \.self) { choice in
                            Chip(
                                wording: PlaybackWording.sleep(
                                    choice, minutesLeft: choice == sleep ? sleepMinutesLeft : nil),
                                on: choice == sleep
                            ) {
                                selectSleep(choice)
                            }
                        }
                    }
                    .padding(.horizontal, MetricsBoard.phone.margin)
                }
            }
        }
    }
}
