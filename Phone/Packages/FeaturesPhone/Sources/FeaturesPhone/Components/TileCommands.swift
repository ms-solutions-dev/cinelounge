import DesignSystemPhone
import Diagnose
import SwiftUI

/// What the long press on a tile offers.
///
/// **Requirement of 2026-09-07:** on the TV, long-pressing an item in Continue Watching can mark
/// it as watched so that it no longer shows up in Continue Watching; the same is wanted on
/// the phone.
///
/// **The same three commands and the same words as on the TV** (`HomeView.cardMenu`): watched
/// mark, favorite, and in the Continue Watching shelf additionally "Reset progress". An
/// action that carries two names in two places reads as two actions — the keys are therefore
/// called `tile.*` here and carry the same wording.
///
/// **Since 2026-09-09 a fourth: "Download".** Requirement of 2026-09-09: in the library,
/// long-pressing an item should offer options such as "download" or "favorite" or similar
/// (not only in the library but also in portals etc.); that did not seem to be consistent. It
/// was already called "Download" (`action.download`) on the detail page the same day, and
/// `tile.download` therefore carries exactly this word — the rule above holds inside the app
/// just as between the devices. Where it does **not** belong is stated at ``isDownloadable``.
///
/// **The path goes via the ``DetailSource`` and not via a new switch.** It can do
/// ``DetailSource/set(seen:forItem:)`` and ``DetailSource/set(favorite:forItem:)``, and
/// ``AggregateDetailSource`` decides by the identifier who is asked — the same rule as in
/// ``PlaybackJob/origin(zu:)``. A second switch would be a second truth about who owns a
/// title.
///
/// **The TV has no `.contextMenu` with swipe; here there is neither of the two.** A swipe as
/// in ``SwipeCommands`` would not work: a tile sits in a horizontally scrolling row, and there
/// the swipe belongs to scrolling. The long press is the established way on iOS, and for the
/// screen reader the same list is available as ``SwiftUI/View/accessibilityAction(named:_:)``
/// — the same division as with the swipe commands, and for the same reason: maintained
/// separately, the second command at the latest would have been missing in one of the two
/// places.
struct TileCommands: ViewModifier {

    let content: TileContent

    /// Where the tile comes from — for the history, which keeps its entries per origin.
    ///
    /// `nil` means "to be read from the identifier", just as with ``StartModel/origin(zu:)``.
    let origin: Catalog.Origin?

    let source: (any DetailSource)?

    /// Whether this tile sits in the "Continue Watching" shelf.
    ///
    /// **Only there does "Reset progress" exist.** Elsewhere the command answers no question: a
    /// title that is in no Continue Watching shelf disappears from nothing through the reset.
    let inHistory: Bool

    /// How things stand with this title in the downloads — `nil` means "downloads are not kept
    /// here", not "not downloaded".
    ///
    /// Needed only for the switch at ``isDownloadable``; nothing of it is drawn. The state belongs on the
    /// tile itself and not in the menu — that is what ``DownloadButton`` on the detail page is for.
    var downloadState: DownloadState?

    /// Opens the download sheet for this tile — **`nil` means: this screen cannot do it.**
    ///
    /// **A callback and no second path to the downloads.** The sheet makes the choice of version,
    /// host and extent (``DownloadSheet``), and exactly the same choice should come from the long
    /// press; a path of its own from here would be the second answer to the question "what
    /// exactly is downloaded". Only the view that owns the sheet knows how to pull it open — that
    /// is why it passes the callback through instead of this building block looking for a sheet
    /// state.
    var load: ((TileContent) -> Void)?

    /// Opens the detail page — set only where the tap **plays** (Continue Watching, 2026-10-01).
    /// Then the menu is the only way to the page, and "Details" stands at the top.
    var details: (() -> Void)?

    /// Called when something was changed — the view then reloads.
    let following: () -> Void

    /// What was toggled last — **only so that the haptics have a state.**
    ///
    /// **On the state and not in the action**, the same rule as in ``HeaderButtonRow``: a pulse in
    /// the action block would come even if the server rejects right afterwards. Here it comes as
    /// soon as the view has really adopted the change.
    ///
    /// **A counter and not a `Bool`.** Toggling the same thing twice — watched, unwatched,
    /// watched — would otherwise yield the same value the third time as the first, and the
    /// modifier would report nothing. Exactly that case occurs here: the menu is available anew
    /// at every long press.
    @State private var flipped = 0

    /// Whether the last action was a toggle (mark, favorite) or a removal (reset progress).
    @State private var isRemoving = false

    /// A channel has no watched mark and no detail page.
    ///
    /// **It has a history entry anyway**, and that can be removed: exactly for that "Reset
    /// progress" is offered for it too — it is the only way to get an accidentally tapped channel
    /// out of the shelf before the six hours are up (``History/liveValidity``).
    private var isChannel: Bool { origin == .channelList }

    /// Whether "Download" belongs in this menu.
    ///
    /// **The finding of 2026-09-09, a requirement:** in the library, long-pressing an item should
    /// offer options such as "download" or "favorite" or similar … that did not seem to be
    /// consistent. It held twice over: the menu was missing entirely in the library, search and
    /// the shelves of the detail page, and it knew "Download" nowhere.
    ///
    /// **Not on a channel.** A channel has no beginning and no end; what one downloaded from it
    /// would be a recording and not a copy — the same rule and the same wording as at
    /// ``SourceKind/init(_:)``.
    ///
    /// **And not on a title that is already in the downloads — then nothing at all appears.**
    /// "Remove from downloads" would be the only sensible alternative, and it does not belong
    /// here: it deletes data, a long press has no confirmation, and the tile shows nowhere that
    /// there is something to delete. The place for it is the downloads screen, where the row
    /// names its size and the swipe has its red background (``SwipeCommands``). A second
    /// "Download" would also be a second job for the same file.
    private var isDownloadable: Bool {
        guard load != nil, !isChannel else { return false }
        return downloadState == nil || downloadState == .notQueued
    }

    func body(content contentItem: Content) -> some View {
        contentItem
            .contextMenu { menu }
            // **Two occasions, because they are two kinds of response.** A mark tips a small fill — that
            // is ``Haptics/Occasion/switched``. "Reset progress" lets the tile **disappear**, and until
            // then the trip to the server passes; that is ``Haptics/Occasion/succeeded``, the same occasion
            // as with the sync button.
            //
            // **Opening the menu gets none.** iOS brings that itself with the long press; a second one
            // next to it would be a double pulse — the same rationale as with the segment in the "no"
            // list at ``Haptics``.
            .haptics(.switched, at: flipped, when: { old, fresh in fresh > old && !isRemoving })
            .haptics(.succeeded, at: flipped, when: { old, fresh in fresh > old && isRemoving })
            .accessibilityAction(named: Text(appKey: watchedKey)) { set(watched: !content.seen) }
            .accessibilityAction(named: Text(appKey: favoriteKey)) { set(favorite: !content.favorite) }
            // **Maintained separately here too, and yet complete** — the rationale is stated above: a
            // command only the menu knows is missing for the screen reader.
            .accessibilityActions {
                if let details {
                    Button {
                        details()
                    } label: {
                        Text(app: "common.details")
                    }
                }
                if isDownloadable {
                    Button {
                        load?(content)
                    } label: {
                        Text(app: "tile.download")
                    }
                }
            }
    }

    @ViewBuilder
    private var menu: some View {
        if let details {
            Button {
                details()
            } label: {
                Label {
                    Text(app: "common.details")
                } icon: {
                    Image(systemName: "info.circle")
                }
            }
        }
        if !isChannel {
            Button {
                set(watched: !content.seen)
            } label: {
                Label {
                    Text(appKey: watchedKey)
                } icon: {
                    Image(systemName: content.seen ? "checkmark.circle.fill" : "checkmark.circle")
                }
            }
            Button {
                set(favorite: !content.favorite)
            } label: {
                Label {
                    Text(appKey: favoriteKey)
                } icon: {
                    Image(systemName: content.favorite ? "heart.fill" : "heart")
                }
            }
        }
        if isDownloadable {
            Button {
                load?(content)
            } label: {
                Label {
                    Text(app: "tile.download")
                } icon: {
                    Image(systemName: Glyph.downloads.name)
                }
            }
        }
        if inHistory {
            Button {
                reset()
            } label: {
                Label {
                    Text(app: "home.removeFromResume")
                } icon: {
                    Image(systemName: Glyph.remove.name)
                }
            }
        }
    }

    private var watchedKey: String {
        content.seen ? "tile.markUnwatched" : "common.markWatched"
    }

    private var favoriteKey: String {
        content.favorite ? "common.unfavorite" : "live.favoriteAdd"
    }

    /// **The mark at the service, and the entry here.**
    ///
    /// Both belong together: on the TV the server alone fills the shelf, and the mark takes the
    /// title out there. On the phone the own ``History`` stands in front of it — without this
    /// second step the tile would stay although the mark is set, and the command would look as if
    /// it had no effect.
    ///
    /// **Unwatched removes nothing.** Whoever takes back a mark wants the title back and not to
    /// lose its place in the shelf.
    private func set(watched: Bool) {
        Task {
            do {
                try await source?.set(seen: watched, forItem: content.id)
            } catch {
                Diagnose.hint(.network, "Watched mark not set", error)
            }
            if watched { await forgetInHistory() }
            isRemoving = false
            flipped += 1
            following()
        }
    }

    private func set(favorite: Bool) {
        Task {
            do {
                try await source?.set(favorite: favorite, forItem: content.id)
            } catch {
                Diagnose.hint(.network, "Favorite not set", error)
            }
            isRemoving = false
            flipped += 1
            following()
        }
    }

    /// "Reset progress" — **out of the shelf, without a watched mark.**
    ///
    /// **The server path is the same as "unwatched"**, just as on the TV: Jellyfin also resets
    /// the playback position to zero on the unwatched mark, and there is no endpoint of its own
    /// for that. Locally the history entry is dropped — and for a channel and for a portal that
    /// is the only part that takes effect at all.
    private func reset() {
        Task {
            if !isChannel {
                do {
                    // Only the position, as with Apple — the unwatched mark left the position standing on the
                    // CL-Server (2026-10-01).
                    try await source?.removeFromContinueWatching(content.id)
                } catch {
                    Diagnose.hint(.network, "Not removed from Continue Watching", error)
                }
            }
            await forgetInHistory()
            isRemoving = true
            flipped += 1
            following()
        }
    }

    /// **Through the store and not with a separate save.**
    ///
    /// ``HistoryStore/remove(_:origin:)`` exists for this; a `save(…)` from here would
    /// be the second write site in the source, and exactly that is not wanted — the rationale is
    /// stated there.
    private func forgetInHistory() async {
        await HistoryStore.shared.remove(
            content.id, origin: origin ?? PlaybackJob.origin(zu: content.id))
    }
}

extension View {

    /// The long press on a tile — see ``TileCommands``.
    ///
    /// `downloadState` and `load` are optional: a screen that does not keep downloads leaves out
    /// both and gets the three commands as before.
    func tileCommands(
        _ content: TileContent, origin: Catalog.Origin?, source: (any DetailSource)?,
        inHistory: Bool, downloadState: DownloadState? = nil,
        load: ((TileContent) -> Void)? = nil, details: (() -> Void)? = nil,
        following: @escaping () -> Void
    ) -> some View {
        modifier(
            TileCommands(
                content: content, origin: origin, source: source, inHistory: inHistory,
                downloadState: downloadState, load: load, details: details, following: following))
    }
}
