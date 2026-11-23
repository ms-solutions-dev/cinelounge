import Core
import DesignSystemPhone
import SwiftUI

/// The menu on the title — **one version per source.**
///
/// **On a portal title the downloads row is missing, and the sheet gets shorter instead of
/// full of holes.** Leaving it there dimmed would be an invitation: whoever taps gets
/// an explanation of why they may not tap — and that is an answer to a
/// question they did not ask.
///
/// **The way to the beginning is not a repeat of the play button.** That one continues
/// where you stopped; "from the start" is the other wish, and without this row it
/// cannot be fulfilled at all.
struct TitleMenuSheet: View {

    let seen: Bool
    let favorite: Bool
    /// `nil` means: nothing to continue — the row is omitted.
    let canRestart: Bool
    /// `nil` means: this source knows no downloads (portals, live).
    let addToDownloads: (() -> Void)?

    /// What ends up in the system's share box when sharing — `nil` hides the row.
    ///
    /// **Text and not an address, and that is not frugality.** A title in this app
    /// lives on the viewer's own media server; there is no address that opens anything for
    /// somebody else. An invented `cinelounge://…` would be worse than nothing:
    /// the recipient taps it and lands nowhere — and a registered scheme
    /// without a receiver is an open entrance, which is why E52 removed exactly that
    /// again.
    ///
    /// **What the viewer really wants** when pressing here is "look at this" —
    /// and for that the name with year suffices. Whoever receives the title finds it where they
    /// watch themselves.
    let shareable: String?

    let toggleWatched: () -> Void
    let toggleFavorite: () -> Void
    let fromStart: () -> Void

    var body: some View {
        SheetFrame(title: "detail.titleMenu") {
            if canRestart {
                ChoiceRow(name: text("detail.restart"), icon: Glyph.fromStart.name) {
                    fromStart()
                }
            }
            ChoiceRow(
                name: text(seen ? "action.markUnwatched" : "common.markWatched"),
                icon: Glyph.done.pair.zu(active: seen)
            ) {
                toggleWatched()
            }
            ChoiceRow(
                name: text(favorite ? "action.unfavorite" : "action.favorite"),
                icon: Glyph.favorite.pair.zu(active: favorite)
            ) {
                toggleFavorite()
            }
            if let addToDownloads {
                ChoiceRow(name: text("action.download"), icon: Glyph.downloads.name) {
                    addToDownloads()
                }
            }
            if let shareable {
                // **`ShareLink` and no custom button.** The system's picker
                // knows the services of this phone — Messages, Notes, the
                // Shortcuts menu —, and any rebuilt list would be a different
                // one the next day. The same consideration as with the AirPlay picker in the player.
                ShareLink(item: shareable) {
                    ChoiceRowContent(
                        name: text("action.share"),
                        icon: Glyph.share.name, inset: MetricsBoard.phone.margin)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func text(_ key: String) -> String {
        AppLanguageSetting.text(.init(key))
    }
}
