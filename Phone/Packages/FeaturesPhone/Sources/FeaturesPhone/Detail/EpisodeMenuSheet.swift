import Core
import DesignSystemPhone
import SwiftUI

/// The menu on an episode.
///
/// **It carries the episode title as a heading.** A sheet that slides up from below over the
/// list covers exactly the row that was pressed; without the name in it, by the third sheet
/// it is no longer certain which episode is meant.
///
/// **"The episodes before it too?" only when setting, never when undoing.** Whoever marks an
/// episode as unwatched means that one — asking them the follow-up question would mean imputing
/// a wish to them that almost nobody has.
struct EpisodeMenuSheet: View {

    let episode: EpisodeInfo
    /// How many episodes before it are still open — decides the follow-up question.
    let openPrior: Int

    let play: () -> Void
    let toggleWatched: () -> Void
    let toggleFavorite: () -> Void
    let askForPrior: () -> Void

    var body: some View {
        SheetFrame(wording: headline) {
            ChoiceRow(name: text("common.play"), icon: Glyph.play.name) {
                play()
            }
            ChoiceRow(
                name: text(episode.seen ? "action.markUnwatched" : "common.markWatched"),
                icon: Glyph.done.pair.zu(active: episode.seen)
            ) {
                // The follow-up question arises only when there is really something to ask: when
                // **setting** and only as long as something before it is still open.
                if !episode.seen && openPrior > 0 {
                    askForPrior()
                } else {
                    toggleWatched()
                }
            }
            ChoiceRow(
                name: text(episode.favorite ? "action.unfavorite" : "action.favorite"),
                icon: Glyph.favorite.pair.zu(active: episode.favorite)
            ) {
                toggleFavorite()
            }
        }
    }

    private var headline: String {
        guard let number = episode.number else { return episode.title }
        return "\(number). \(episode.title)"
    }

    private func text(_ key: String) -> String {
        AppLanguageSetting.text(.init(key))
    }
}
