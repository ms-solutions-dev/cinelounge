import DesignSystemPhone
import SwiftUI

/// A tile without an image.
///
/// **Not an omission but the catalog:** with Jellyfin there is almost always a poster, with
/// the portals never. A grid of gray surfaces would be a wall; that is why the title is set
/// here, on a gradient from the fallback color.
///
/// **Corrected on 2026-09-06** It said here that the text list is the right form for Xtream and
/// that this tile remains "for the portals, where the lists are twenty to fifty entries long
/// and the titles short". Both no longer hold: the text list was dropped on 2026-09-05. (three of
/// its four rationales were measured wrong), and Animehub's entry point "All Series" carries
/// thousands of titles, many of them over forty characters long.
///
/// So it stays at **one** form for every source, and the doubling "title in the surface,
/// title below" is not a weakness of the form but its division: **here the motif, below the
/// information.** That is why the title is shown truncated here and in full in the caption.
struct EmptyTile: View {

    let title: String
    var radius: CGFloat = MetricsBoard.phone.imageRadius

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [ColorRole.deep.color, ColorRole.audio.color],
                startPoint: .topLeading, endPoint: .bottomTrailing)

            // **The header band turns the lack into a form** (2026-09-07). Without a poster the tile was a
            // gray surface with text; with the band it is a cover. Four points tall — the upper limit
            // from the rule at ``StripeBand``.
            StripeBand(opacity: 0.55)
                .frame(height: 4)
                .frame(maxHeight: .infinity, alignment: .top)

            // **At most three lines — the title is a motif here, not information.**
            //
            // Without a limit the surface cut off in the middle of a word ("A Piabriam Brostakuk Bliazilon
            // Weprukror: Raising…" ended as "RAISING" without dots), and that looked like an error and not
            // like a cover. The title is shown in full in the caption below; here it is meant to fill
            // the surface and make it recognizable.
            Text(verbatim: title)
                .font(TypeLevel.lowercased.font)
                .tracking(0.6)
                .textCase(.uppercase)
                .multilineTextAlignment(.center)
                .lineLimit(3)
                .truncationMode(.tail)
                .foregroundStyle(ColorRole.text.color.opacity(0.94))
                .shadow(color: .black.opacity(0.65), radius: 8, y: 1)
                .padding(.horizontal, 8)
                .padding(.bottom, 14)
                .frame(maxHeight: .infinity, alignment: .bottom)
        }
        .clipShape(RoundedRectangle(cornerRadius: radius))
    }
}
