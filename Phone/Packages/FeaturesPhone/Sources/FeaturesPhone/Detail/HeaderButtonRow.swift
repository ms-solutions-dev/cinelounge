import Core
import DesignSystemPhone
import Downloads
import SwiftUI

/// The button row under the title: Watched, Favorite, Trailer, Sources, More.
///
/// **Five round buttons and no play button below.** That belongs in the floating bar
/// — it is the one main thing of this page, and it lies under the thumb. What stands
/// here is everything you can **also** do; it is rarely pressed and may therefore
/// stand at the top.
///
/// **What does not work is not there.** The trailer button appears only when there is a
/// trailer, and the sources button only with more than one version. A dimmed
/// button is an invitation, and the answer to it would be the same every time — the same
/// rule as for the tabs and for the filter chips.
///
/// **The two toggles report, the three paths do not.** Watched and favorite flip
/// a state, and what becomes visible of that is a 44-point circle that fills — at the
/// top of the screen, where the thumb currently is and the gaze rests on the poster.
/// Trailer, sources and More, on the other hand, open something you see; a tap for those would be the
/// accompaniment of an ordinary button press. The rule is in ``Haptics``.
struct HeaderButtonRow: View {

    let seen: Bool
    let favorite: Bool
    /// The trailer including language (AP78) — `nil`: no button. The badge shows what was
    /// found.
    let trailer: TrailerChoice?
    let hasSourceChoice: Bool

    /// How the title stands in the downloads — **`nil` where nothing can be loaded.**
    ///
    /// Today that is only the channel: it has no beginning and no end, and what you would download
    /// from it would be a recording and not a copy. Jellyfin, the provider catalog
    /// **and the portals** have the button — the latter since 2026-09-08.
    var downloadState: DownloadState?

    let toggleWatched: () -> Void
    let toggleFavorite: () -> Void
    var onDownloadsTap: () -> Void = {}
    let showTrailer: () -> Void
    let showSources: () -> Void
    let showMenu: () -> Void

    var body: some View {
        HStack(spacing: Metrics.targetSpacing) {
            RoundButton(
                icon: Glyph.done.pair, label: "action.watched", on: seen,
                action: toggleWatched)
            RoundButton(
                icon: Glyph.favorite.pair, label: "action.favorite", on: favorite,
                action: toggleFavorite)
            // **The downloads button stands here and not in the ⋯ next to it.** A feature in the
            // overflow menu does not exist for most users — and it stands
            // third and not last, because it is pressed more often than trailer
            // and sources.
            if let downloadState {
                DownloadButton(state: downloadState, action: onDownloadsTap)
            }
            if let trailer {
                RoundButton(
                    icon: Glyph.broadcast.name, label: "detail.trailer",
                    tag: trailer.badge, action: showTrailer)
            }
            if hasSourceChoice {
                RoundButton(
                    icon: Glyph.sources.name, label: "common.sources",
                    action: showSources)
            }
            RoundButton(
                icon: Glyph.more.name, label: "action.more.menu",
                action: showMenu)
            Spacer(minLength: 0)
        }
        // **On the state and not in the action.** ``DetailModel/setEnabled(seen:)``
        // sets the value immediately and undoes it if the server does not cooperate.
        // A tap in the action block would then come once for a mark that never existed; this way
        // it follows the state — and also reports the undoing, which you would
        // otherwise miss because you have long since scrolled on.
        .haptics(.switched, at: seen)
        .haptics(.switched, at: favorite)
    }
}
