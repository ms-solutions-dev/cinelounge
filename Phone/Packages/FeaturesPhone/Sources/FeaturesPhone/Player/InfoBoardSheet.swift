import Core
import DesignSystemPhone
import Flows
import SwiftUI

/// The board for the running title — **cast and further episodes, as a sheet on the
/// phone** (AP58 G1, decision 27, A4).
///
/// On the TV it slides out when swiping down; here the button in the player header opens
/// it. **The board itself is the shared one** (``Flows/InfoBoard``): the same titles,
/// the same parental-controls filter, the same rule "forward from the running episode".
///
/// **The cast first, as on the TV** ("Who is in the picture"): The question you open the
/// board with in the middle of a film is usually who that just was.
struct InfoBoardSheet: View {

    let board: InfoBoard
    let matches: (MediaItem) -> Void

    var body: some View {
        SheetFrame(wording: board.title?.title ?? AppLanguageSetting.text("player.aboutTitle")) {
            if !board.loaded && board.cast.isEmpty {
                ProgressView()
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, MetricsBoard.phone.gutter)
            }

            if board.hasNothing {
                Text(app: "player.infoNone")
                    .font(TypeLevel.text.font)
                    .foregroundStyle(ColorRole.textMatt.color)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, MetricsBoard.phone.gutter)
            }

            if !board.cast.isEmpty {
                SectionHeader(title: "player.tabCast")
                ForEach(board.cast) { person in
                    ChoiceRowContent(name: person.name, subRow: person.character)
                        .accessibilityElement(children: .combine)
                }
            }

            if !board.more.isEmpty {
                SectionHeader(title: board.isSeries ? "player.tabEpisodes" : "player.tabSimilar")
                ForEach(board.more) { title in
                    ChoiceRow(
                        name: title.title, icon: Glyph.play.name,
                        subRow: Self.subRow(title)
                    ) {
                        matches(title)
                    }
                }
            }
        }
    }

    /// "S1 E4" for an episode (``EpisodeIdentifier``, the same as on the episode tiles), the year
    /// for a film.
    nonisolated static func subRow(_ title: MediaItem) -> String? {
        if let identifier = title.episodeIdentifier { return identifier }
        return title.year.map(String.init)
    }
}
