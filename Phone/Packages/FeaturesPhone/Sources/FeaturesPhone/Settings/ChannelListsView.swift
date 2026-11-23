import Core
import DesignSystemPhone
import Diagnose
import PlaylistKit
import SwiftUI

/// Area 1 · Channel lists.
///
/// **The switch sits in the row, the commands lie behind the swipe.** Switching a list off is
/// something one does often and undoes — deleting it one does once. What is frequent belongs
/// visibly in the row; what is rare and final belongs behind a gesture that one does not make
/// by accident.
///
/// **One card per list (2026-09-07).** The lists stood as flat rows on the background, and with
/// two providers it was not visible which check message belongs to which access — name,
/// switch, check button and message ran into each other without an edge.
///
/// **Switching off is not deleting, and that is the whole difference.** A switched-off list
/// keeps credentials, groups and visibilities; a deleted one takes them along. Whoever puts
/// both into one button loses a half-hour setup while trying things out.
struct ChannelListsView: View {
    @Environment(\.horizontalSizeClass) private var widthClass

    @State private var listen: [Playlist] = []
    @State private var deleting: Playlist?
    /// Which row has its commands open — at most one.
    @State private var openSwipe: String?
    /// What the check returned per list — only where someone pressed.
    @State private var checks: [String: AccessStatus] = [:]
    @State private var running: Set<String> = []

    private let storage: PlaylistStore
    private let newList: () -> Void

    /// The way to edit — **`nil` in the checks**, which have no wrapper.
    private let editList: ((Playlist) -> Void)?

    init(
        storage: PlaylistStore, newList: @escaping () -> Void = {},
        editList: ((Playlist) -> Void)? = nil
    ) {
        self.storage = storage
        self.newList = newList
        self.editList = editList
    }

    /// **The swipe is closed before the screen changes.** An open row that is still open when
    /// one comes back looks as if the command had not arrived — the same consideration as with
    /// the delete sheet.
    private func change(_ list: Playlist) {
        openSwipe = nil
        editList?(list)
    }

    /// What lies behind a row — **the one list that all four read from.**
    ///
    /// Buttons, context menu, screen reader **and** the visible tag. The comment at
    /// ``SwipeCommands`` has predicted it literally since 2026-09-06: "Maintained separately, the
    /// second command would at the latest have been missing in one of the three places — and
    /// nobody would have noticed." On 2026-09-07 the second command came, and the tag did not name
    /// it.
    ///
    /// **"Edit" comes before "Delete", and that is the order of frequency:** an expired password
    /// is the rule, a deleted access the exception.
    private func commands(for list: Playlist) -> [SwipeCommand] {
        [
            SwipeCommand(
                id: "edit", title: "settings.lists.edit",
                icon: Glyph.edit.name, action: { change(list) }),
            SwipeCommand(
                id: "delete", title: "common.delete",
                icon: Glyph.remove.name, kind: .route,
                action: { deleting = list }),
        ]
    }

    var body: some View {
        ZStack {
            ColorRole.reason.color.ignoresSafeArea()

            ScrollSurface {
                VStack(alignment: .leading, spacing: 0) {
                    if listen.isEmpty {
                        Footnote(message: "settings.lists.empty")
                    }

                    // **One card of its own per list and not all in one.** A channel list is an object in its
                    // own right — it has a switch, a check, a message and two swipe commands. Stacked in a
                    // shared card it would not be visible where one ends and the next begins; here the card
                    // spacing separates them.
                    //
                    // **And the card clips the swipe.** The commands slide out from under their own edge
                    // instead of across the full screen width — that is exactly the association the swipe needs.
                    ForEach(listen) { list in
                        SettingsCard {
                            // The same story as in ``AccountsView``: `.swipeActions` stood here and did nothing in a
                            // `ScrollView` — and `deleting` was set without anyone ever reading it. The command was
                            // dead twice over.
                            SwipeCommands(
                                pending: $openSwipe, identifier: list.id,
                                commands: commands(for: list)
                            ) {
                                row(list)
                            }
                        }
                    }

                    SettingsCard {
                        DisclosureRow(
                            title: "settings.addPlaylist", icon: Glyph.login.name,
                            isContained: true, action: newList)
                    }
                }
                .contentColumn(widthClass)
                .padding(.top, MetricsBoard.phone.gutter)
            }
        }
        .task { load() }
        // **It asks, and then it really deletes.** Until 2026-09-06 the (ineffective) swipe set
        // `deleting` — and nobody ever read the property. Even if the gesture had taken hold,
        // nothing would have happened.
        .sheet(item: $deleting) { list in
            DeleteListSheet(
                list: list,
                delete: {
                    storage.remove(list.id)
                    // **And for every profile that carried it** (AP41). Otherwise the switcher would count a
                    // list that nobody can open anymore.
                    SetupState(listen: storage).remove(channelList: list.id)
                    deleting = nil
                    load()
                },
                cancel: { deleting = nil }
            )
            .presentationDetents([.fraction(SheetID.deleteList.portion), .large])
            .presentationDragIndicator(.visible)
            .presentationCornerRadius(MetricsBoard.phone.sheetRadius)
            .presentationBackground(ColorRole.surfaceHigh.color)
        }
    }

    private func row(_ list: Playlist) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            toggle(list)
            checkRow(list)
        }
        // **Air above, and it is needed (2026-09-07, seen in the simulator).** The overlay of name,
        // kind and ``SwipeMark`` is three lines high and thus taller than the 59-point row that
        // carries it; it sits centered on it and stuck out over the card edge at the top. The name
        // touched the card edge.
        .padding(.top, MetricsBoard.phone.gutter)
    }

    private func toggle(_ list: Playlist) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            SwitchRow(
                title: "", message: nil,
                on: Binding(
                    get: { list.isEnabled },
                    set: { on in
                        storage.setEnabled(on, for: list.id)
                        load()
                        SetupState.notify()
                    })
            )
            .overlay(alignment: .leading) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: list.name)
                        .font(TypeLevel.text.font)
                        .foregroundStyle(ColorRole.text.color)
                    // **The status line per list states the kind, not the state.** Whether an access is still
                    // valid only a query would know — and on an account with one permitted connection it costs
                    // more than it is worth here. What is known without a query is the method.
                    Text(verbatim: Self.kind(list))
                        .font(TypeLevel.label.font)
                        .foregroundStyle(ColorRole.textQuiet.color)
                    // **From the same list as the buttons** (2026-09-07). Here stood `[`common.delete`]` by hand —
                    // and when the second command was added, the tag did not name it. That is exactly what the
                    // comment at ``SwipeCommands`` warns about, and it happened on the same day.
                    SwipeMark(commands: commands(for: list).map(\.title))
                }
                .padding(.leading, Metrics.cardInset)
                .allowsHitTesting(false)
            }
        }
    }

    /// What a check of the access returned.
    struct AccessStatus: Equatable {
        let isGood: Bool
        /// Key in the catalog.
        let title: String
        let wording: String?
    }

    /// **Check access — on request, never on its own.** Finding of 2026-09-07, on screen: the row
    /// said "Provider access · iptvhost.example · username", and whether the access is valid was nowhere
    /// to be seen. The rule "no query on its own" stays — the account allows one connection, and
    /// a connection storm throttles the interface. One press is no storm: one request to
    /// `player_api.php`, the same one setup has made since E34, and it does not count as a stream
    /// connection.
    @ViewBuilder
    private func checkRow(_ list: Playlist) -> some View {
        if case .xtream = list.kind {
            VStack(alignment: .leading, spacing: MetricsBoard.phone.gutter) {
                Button {
                    Task { await verify(list) }
                } label: {
                    Text(appKey: running.contains(list.id) ? "action.wait" : "settings.lists.check")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.quiet)
                .disabled(running.contains(list.id))
                if let state = checks[list.id] {
                    HintRow(
                        icon: state.isGood ? Glyph.done.pair.outlined : Glyph.offline.name,
                        color: state.isGood ? ColorRole.success.color : ColorRole.progress.color,
                        title: state.title, wording: state.wording)
                }
            }
            // **The number and not the environment** — the same trap as in
            // ``PortalSettingsView``: this row is assembled by the parent view, and that stands
            // outside the card.
            .padding(.horizontal, Metrics.cardInset)
            // **Air above, and it is needed.** Above the row sits the three-line overlay of name, kind
            // and ``SwipeMark``; it is taller than the 59-point row that carries it, and would
            // otherwise bump into the button at the bottom.
            .padding(.top, MetricsBoard.phone.gutter)
            .padding(.bottom, Metrics.cardInset)
        }
    }

    private func verify(_ list: Playlist) async {
        guard case .xtream = list.kind else { return }
        running.insert(list.id)
        defer { running.remove(list.id) }
        let password = storage.credentials(for: list.id)?.password
        guard let finding = await ChannelListCheck.verify(list, password: password) else { return }
        Diagnose.step(.network, "Access checked: \(finding)")
        checks[list.id] = Self.interpret(finding)
    }

    /// The finding of the shared check (``PlaylistKit/ChannelListCheck``, AP58 R7) as a row
    /// — **three causes, three sentences:** rejected (wrong password), expired (the account was
    /// once correct) and valid. For "valid" the numbers that decide something are shown: until
    /// when, how many connections are in use, and whether the access only provides raw streams.
    /// **Since R7 "rejected" and "expired" arrive** — `verify()` throws in both cases, and until
    /// then they ended up as "does not respond".
    nonisolated static func interpret(_ finding: ChannelListCheck.Finding) -> AccessStatus {
        switch finding {
        case .withoutPassword, .muted:
            return AccessStatus(isGood: false, title: "settings.lists.check.silent", wording: nil)
        case .rejected:
            return AccessStatus(isGood: false, title: "settings.lists.check.rejected", wording: nil)
        case .expired:
            return AccessStatus(isGood: false, title: "settings.lists.check.expired", wording: nil)
        case .isValid(let info):
            var split: [String] = []
            if let until = info.until {
                split.append(
                    SettingsModel.text("settings.lists.check.until") + " "
                        + until.formatted(date: .numeric, time: .omitted))
            }
            if let atMost = info.atMost {
                split.append(
                    SettingsModel.text(
                        "settings.lists.check.connections %lld %lld", info.taken, atMost))
            }
            if info.rawOnly {
                split.append(SettingsModel.text("settings.lists.check.rawOnly"))
            }
            return AccessStatus(
                isGood: true, title: "settings.lists.check.ok",
                wording: split.isEmpty ? nil : split.joined(separator: " · "))
        }
    }

    /// Xtream or M3U — **what is known without a query.**
    static func kind(_ list: Playlist) -> String {
        switch list.kind {
        case .xtream(let server, let user):
            "\(SettingsModel.text("setup.playlist.xtream")) · \(server.host() ?? "") · \(user)"
        case .m3u(let address):
            "\(SettingsModel.text("setup.playlist.m3u")) · \(address.host() ?? "")"
        case .jellyfinLiveTV:
            SettingsModel.text("settings.lists.jellyfin")
        }
    }

    /// **Through the profile's window** (on-device test build 1332, 2026-09-27, finding 3): here
    /// stood `storage.playlists`, the device inventory — the list showed `Y-IPTV` while the
    /// overview one level up said "nothing". See ``PlaylistKit/PlaylistStore/viewport``.
    private func load() {
        listen = storage.visiblePlaylists
    }
}
