import Core
import DesignSystemPhone
import NetworkStatus
import SwiftUI

/// Quality and audio — **two-stage, with the bitrate on every row.**
///
/// **Six steps from 0.5 to 20 Mbit/s**, and the number is on the row instead of in a
/// help text. "1080p" alone does not say whether it fits through the connection, and that is
/// the question you ask yourself on the road.
///
/// **Two segments and not two sheets.** Quality and audio are the same decision
/// in two parts — "how should this play". Spreading them over two sheets would demand
/// a second path from the start for the second part.
///
/// **For the file itself there is only its information, no choice.** `Core.MediaSource` carries
/// container, encoding, color range, bitrate, interlacing and bit depth — **no
/// frame size**. That belongs to the tracks, not the source; an invented "1080p" would be
/// a claim about something nobody here knows. What the viewer really chooses
/// is the **upper limit** with which the server delivers.
///
/// **The location line below says how much of that gets through.** Over this household's tunnel
/// that is 0.3 Mbit/s — picking a version with 8 is then not a mistake, but you
/// should know it while picking and not after two minutes of stuttering.
struct SourcesSheet: View {

    let sources: [SourceInfo]
    let audioTracks: [AudioTrackInfo]
    let quality: StreamQuality
    let audioTrack: String?

    /// At home or on the road.
    ///
    /// **Until AP2 · M1 this says `home`**, and that is not a stopgap but the
    /// honest state: whether the home network is directly reachable cannot be said today —
    /// the measurement needs a trip with hotspot and WireGuard. A guessed
    /// warning would be worse than none: whoever sees it at home does not believe it
    /// on the road anymore.
    var location: LocationStatement.Location = .home

    let selectQuality: (StreamQuality) -> Void
    let selectAudioTrack: (AudioTrackInfo) -> Void

    @State private var audio = false

    var body: some View {
        SheetFrame(title: "sources.title") {
            if let file = sources.first {
                // The information about the file, not the choice: it stands at the top as a row
                // and not as a button, because there is nothing to decide about it.
                Footnote(
                    wording: [file.name, file.bitrateText].compactMap { $0 }
                        .joined(separator: DelimiterChars.point))
            }

            // **The segment only appears when there are two sides.** If the file carries a
            // single audio track, the audio choice is no choice — and a switch with one
            // side is not a switch.
            if audioTracks.count > 1 {
                SegmentPicker(
                    links: AppLanguageSetting.text("sources.quality"),
                    right: AppLanguageSetting.text("player.audio"),
                    isRightSelected: $audio)
            }

            if audio && audioTracks.count > 1 {
                ForEach(audioTracks) { track in
                    ChoiceRow(
                        name: track.name,
                        icon: Glyph.subtitles.name,
                        number: track.attributes,
                        chosen: track.id == (audioTrack ?? defaultTrack?.id)
                    ) {
                        selectAudioTrack(track)
                    }
                }
            } else {
                ForEach(StreamQuality.allCases) { tier in
                    ChoiceRow(
                        name: AppLanguageSetting.text(.init(Self.name(tier))),
                        icon: Glyph.sources.name,
                        number: Self.bitrateText(tier),
                        chosen: tier == quality
                    ) {
                        selectQuality(tier)
                    }
                }
            }

            if sources.isEmpty {
                Footnote(message: "sources.none")
            }

            LocationRow(statement: LocationStatement.forItem(.sourceSheet, location: location))
        }
    }

    private var defaultTrack: AudioTrackInfo? {
        audioTracks.first { $0.isDefault } ?? audioTracks.first
    }

    /// **The steps are named after what they do, not after their number.**
    ///
    /// `nonisolated`, so that the check can call them without the main actor. The
    /// release build reported this on 2026-09-05 and the debug build did not — the reason
    /// this step is in `check.sh`. "Unlimited"
    /// and "Make it play" are decisions; "500000" is a figure. The number
    /// stands next to it.
    nonisolated static func name(_ tier: StreamQuality) -> String {
        switch tier {
        case .unlimited: "quality.unlimited"
        case .veryHigh: "quality.veryHigh"
        case .high: "quality.high"
        case .medium: "quality.medium"
        case .low: "quality.low"
        case .minimal: "quality.minimal"
        }
    }

    /// "8.0 Mbit/s" — and for "unlimited" nothing, because there is no limit there.
    nonisolated static func bitrateText(_ tier: StreamQuality) -> String? {
        guard let bitrate = tier.bitrate else { return nil }
        let mbit = Double(bitrate) / 1_000_000
        return AppLanguageSetting.text(
            "source.bitrate \(mbit.formatted(.number.precision(.fractionLength(1))))")
    }
}
