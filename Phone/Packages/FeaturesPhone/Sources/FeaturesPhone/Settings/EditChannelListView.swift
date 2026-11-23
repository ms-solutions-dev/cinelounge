import Core
import DesignSystemPhone
import PlaylistKit
import SwiftUI

/// **Change** an access instead of deleting and recreating it.
///
/// **The finding of 2026-09-07, and it came from four research passes:** `ChannelListsView` knew
/// exactly one swipe command — delete. Password, server name and address were unreachable
/// after creation. If a provider password expires — and that is the rule, not the
/// exception —, the only option was to delete and recreate.
///
/// **That costs more than the two minutes of typing.** The group order, the hidden groups and
/// the channel tags hang on a list's identifier. Whoever recreates gets a new identifier —
/// and loses all of it, without anyone having spoken of a deletion. With competitors this is
/// the most frequently named complaint; "remove and add again" is the standard advice there.
///
/// **That is why the identifier stays, and ``PlaylistKit/PlaylistStore/update(_:name:kind:epgURL:password:)``
/// is the path to it.** Until 2026-09-07 the store could rename, toggle, move and delete — just
/// not change.
///
/// **The password field stays empty and does not show the stored one.** Two reasons:
/// fetching a password from the Keychain onto a screen, only to write it back unread, is a
/// way out that nobody needs — and a field with sixteen dots in it does not say whether it is
/// the **right** password. Empty here explicitly means "the stored one stays"; the footer
/// says so.
struct EditChannelListView: View {
    @Environment(\.horizontalSizeClass) private var widthClass

    let list: Playlist
    let storage: PlaylistStore
    let done: () -> Void

    @State private var name = ""
    @State private var address = ""
    @State private var user = ""
    @State private var password = ""
    @State private var epg = ""

    /// Whether it is an Xtream access — **a property of the list and no choice.** Turning an M3U
    /// file into a provider access is not a change but a different list: the identifier would
    /// stand for something other than before.
    private var isXtream: Bool {
        if case .xtream = list.kind { return true }
        return false
    }

    var body: some View {
        ZStack {
            ColorRole.reason.color.ignoresSafeArea()

            ScrollSurface {
                VStack(alignment: .leading, spacing: 0) {
                    SettingsCard(header: "settings.lists.access") {
                        VStack(alignment: .leading, spacing: MetricsBoard.phone.gutter) {
                            InputField(
                                text: $name, placeholder: "setup.playlist.name", kind: .name)
                            InputField(
                                text: $address, placeholder: "setup.playlist.address",
                                kind: .address)
                            if isXtream {
                                InputField(
                                    text: $user, placeholder: "common.username",
                                    kind: .name)
                                InputField(
                                    text: $password, placeholder: "settings.lists.passKeep",
                                    kind: .password)
                            }
                        }
                        .padding(Metrics.cardInset)
                    }

                    Footnote(message: "settings.lists.passKeepText")
                        .padding(.bottom, MetricsBoard.phone.section)

                    // **The guide source separate from the access** — the market finding from four research
                    // passes: only OTT Navigator separates them, and it is the case one really has. A provider
                    // whose channels are fine and whose guide is not is no rarity; today one would have to
                    // swap the whole access for that.
                    SettingsCard(header: "settings.lists.guide") {
                        InputField(
                            text: $epg, placeholder: "settings.lists.guideURL", kind: .address
                        )
                        .padding(Metrics.cardInset)
                    }

                    Footnote(message: "settings.lists.guideText")
                        .padding(.bottom, MetricsBoard.phone.section)

                    Button(action: save) {
                        Text(app: "common.save").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.loud)
                    .disabled(!complete)
                    .padding(.horizontal, MetricsBoard.phone.margin)
                }
                .contentColumn(widthClass)
                .padding(.top, MetricsBoard.phone.gutter)
            }
        }
        .task { load() }
    }

    /// The typed address — **via the shared rule** (``PlaylistKit/ChannelListCheck``,
    /// AP58 R7): scheme added, host required; for Xtream also without a trailing slash.
    private var target: URL? {
        isXtream
            ? ChannelListCheck.serverAddress(address) : ChannelListCheck.address(address)
    }

    private var complete: Bool {
        guard target != nil else { return false }
        return isXtream ? !user.trimmingCharacters(in: .whitespaces).isEmpty : true
    }

    private func load() {
        name = list.name
        epg = list.epgURL?.absoluteString ?? ""
        switch list.kind {
        case .m3u(let place):
            address = place.absoluteString
        case .xtream(let server, let userName):
            address = server.absoluteString
            user = userName
        case .jellyfinLiveTV:
            break
        }
    }

    /// **One operation and not four.** Name, address, user and guide source go into the store
    /// together; four single writes would be four states, three of which nobody should ever see
    /// — and one of them would stay if something goes wrong in between.
    private func save() {
        guard let target else { return }
        let kind: Playlist.Kind? =
            switch list.kind {
            case .m3u: .m3u(target)
            case .xtream:
                .xtream(
                    server: target,
                    username: user.trimmingCharacters(in: .whitespaces))
            case .jellyfinLiveTV: nil
            }

        let source = epg.trimmingCharacters(in: .whitespaces)
        storage.update(
            list.id, name: name, kind: kind,
            // **Doubly wrapped: `.some(nil)` deletes, `nil` leaves it.** An empty field here explicitly
            // means "no own guide source" and not "not touched".
            epgURL: .some(ChannelListCheck.address(source)),
            // Empty means "the stored one stays" — see above.
            password: password.isEmpty ? nil : password)

        // **The catalog has to go, not only the row.** A changed address delivers other channels;
        // the remembered catalog would otherwise point to the old access until the next launch —
        // the same lesson as when deleting a list (roadmap P6).
        SetupState.notify()
        done()
    }
}
