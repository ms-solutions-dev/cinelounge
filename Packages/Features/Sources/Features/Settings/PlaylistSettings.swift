import Core
import DesignSystem
import PlaylistKit
import ProfileKit
import SwiftUI

/// Enter, rename, switch on and off, and delete channel lists.
///
/// **Text input is tedious on tvOS** — there is no system-wide clipboard,
/// and you type an address character by character on an on-screen keyboard.
/// That is why only the bare minimum is asked for here: an address for an M3U, or
/// server, user name and password for an Xtream access. Everything else —
/// name, programme guide — is either derived or can be changed afterwards.
///
/// Whoever wants to avoid typing entirely can use the keyboard of a paired
/// iPhone; the system offers it by itself.
struct PlaylistSettings: View {

    let store: PlaylistStore

    /// Discards the loaded channel catalog — called after "Refresh".
    ///
    /// **Without a default value**, for the same reason as ``SettingsView/liveGroups``:
    /// a caller that forgets the wiring would get a button that only
    /// refreshes the status line and keeps the catalog — from the outside indistinguishable from
    /// "works".
    let onRefresh: () async -> Void

    @State private var entries: [Playlist] = []
    @State private var isAdding = false
    @State private var draft = Draft()
    @State private var message: String?

    /// What the provider answered when checked — in plain text for display.
    ///
    /// **Success must be visible, not only failure.** Before, this view
    /// reported only when something went wrong; a silent success, however, is
    /// indistinguishable from "nothing happened". You then enter an access, see no reaction
    /// and do not know whether it works.
    @State private var confirmation: String?

    /// Is a check at the provider currently running?
    @State private var checking = false

    /// What each stored list last answered, by identifier.
    ///
    /// **A list that once worked does not work forever.** An access
    /// expires, a password is changed at the provider, a server moves. Without
    /// a line on the entry you only notice when the Live area stays empty —
    /// and then you do not know which of the lists it is.
    @State private var status: [String: Reachability] = [:]

    /// What came out of the query.
    enum Reachability: Equatable {
        case checking
        /// Reachable, together with what the provider says about the access.
        case reachable(String)
        /// Not reachable or rejected — with the key for the reason.
        case failed(String)
    }
    @FocusState private var focus: String?
    @Environment(\.settingsEntryRequest) private var entryRequest

    /// What is in the form while entering.
    struct Draft {
        var kind: Kind = .m3u
        var name = ""
        var address = ""
        var username = ""
        var password = ""
        var epgAddress = ""

        enum Kind: String, CaseIterable, Identifiable {
            case m3u, xtream
            var id: String { rawValue }

            var titleKey: String {
                switch self {
                case .m3u: "settings.playlistKindM3U"
                case .xtream: "settings.playlistKindXtream"
                }
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {

            if entries.isEmpty && !isAdding {
                emptyState
            } else {
                ForEach(entries) { entry in
                    row(entry)
                }
            }

            if isAdding {
                form
            } else {
                addButton
            }

            if checking {
                // Without this line, a request that takes several seconds over a thin
                // connection looks like a dead button — and you press
                // a second time.
                HStack(spacing: 14) {
                    ProgressView()
                    Text(app: "settings.playlistChecking")
                }
                .font(TypeLevel.footer.font)
                .foregroundStyle(ColorRole.textMatt.color)
                .padding(.top, 18)
            }

            if let message {
                Text(appKey: message)
                    // **What to act on is not in the fine print**
                    // (AP5 · B7): `caption2` is, by its own definition, "for accessories
                    // only" and sits at 18.2 arcminutes — our own
                    // lower limit. An error message is not an accessory.
                    .font(TypeLevel.footer.font)
                    .foregroundStyle(ColorRole.live.color)
                    .padding(.top, 18)
            }

            if let confirmation {
                VStack(alignment: .leading, spacing: 6) {
                    Label {
                        Text(app: "settings.playlistConnected")
                    } icon: {
                        Image(systemName: "checkmark.circle.fill")
                    }
                    .font(TypeLevel.footer.font)
                    .foregroundStyle(ColorRole.text.color)

                    // The provider's statements verbatim, not translated: they are
                    // its values, and a localised status could no longer be compared with
                    // what is in its message.
                    Text(verbatim: confirmation)
                        .font(TypeLevel.footer.font)
                        .foregroundStyle(ColorRole.textMatt.color)
                }
                .padding(.top, 18)
            }
        }
        // **The note stood at the area header and now hangs on the block** (AP46,
        // 2026-09-24). Not on an element as in the other areas: which
        // target applies is decided here by the state — the first channel list, otherwise
        // the form, otherwise the add button.
        .preference(
            key: SettingsFirstEntryKey.self,
            value: entries.first.map { "refresh-" + $0.id } ?? (isAdding ? "name" : "add")
        )
        .onChange(of: entryRequest) { _, _ in
            focus = entries.first.map { "refresh-" + $0.id } ?? (isAdding ? "name" : "add")
        }
        .task {
            reload()
            await refreshStatus()
        }
        // **The confirmation prompt before deleting** (AP5 · B8). It is the only
        // irrevocable action in the settings, and it hung on a
        // single press.
        .confirmationDialog(
            Text(app: "settings.deleteConfirm"),
            isPresented: Binding(
                get: { deletePrompt != nil },
                set: { if !$0 { deletePrompt = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button(role: .destructive) {
                if let id = deletePrompt { delete(id) }
                deletePrompt = nil
            } label: {
                Text(app: "common.delete")
            }
            Button(role: .cancel) {
                deletePrompt = nil
            } label: {
                Text(app: "common.cancel")
            }
        } message: {
            Text(app: "settings.deleteConfirmHint")
        }
    }

    /// Asks each stored list whether it still works.
    ///
    /// **One after another and not side by side.** An Xtream access often allows only
    /// a single connection — on the checked provider exactly one. Querying four lists
    /// at once would mean locking yourself out, and the answer would be
    /// "rejected" for accesses that are fine.
    ///
    /// The request hits only `player_api.php` without an action. That is the cheapest
    /// information there is, and it occupies no playback stream.
    private func refreshStatus() async {
        for entry in entries {
            await check(entry)
        }
    }

    /// Asks a single list whether it still works — **via the shared check**
    /// (``PlaylistKit/ChannelListCheck``, AP58 R7). With an M3U list there is nothing
    /// to ask: it has no way to provide information.
    private func check(_ entry: Playlist) async {
        guard case .xtream = entry.kind else { return }
        status[entry.id] = .checking
        guard
            let finding = await ChannelListCheck.verify(
                entry, password: store.password(for: entry.id))
        else {
            status[entry.id] = nil
            return
        }
        status[entry.id] = Self.row(finding)
    }

    /// The finding as a row of this screen.
    ///
    /// **Since R7, "rejected" and "expired" actually arrive.** `verify()` throws in
    /// both cases, and until then the `catch` caught them as "not reachable".
    static func row(_ finding: ChannelListCheck.Finding) -> Reachability {
        switch finding {
        case .withoutPassword: .failed("settings.playlistNoPassword")
        case .rejected: .failed("settings.playlistRejected")
        case .expired: .failed("settings.playlistExpired")
        case .muted: .failed("settings.playlistUnreachable")
        case .isValid(let info): .reachable(summary(of: info))
        }
    }

    // MARK: - Catalog

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 12) {
            Image(systemName: "dot.radiowaves.left.and.right")
                .font(.system(size: 44))
                .foregroundStyle(ColorRole.textQuiet.color)
            Text(app: "settings.noPlaylists")
                .font(TypeLevel.text.font)
                .foregroundStyle(ColorRole.textMatt.color)
        }
        .padding(.bottom, 30)
    }

    private func row(_ entry: Playlist) -> some View {
        HStack(spacing: 22) {
            Image(systemName: entry.isEnabled ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 26))
                .foregroundStyle(
                    entry.isEnabled ? ColorRole.brandLight.color : ColorRole.textQuiet.color
                )

            VStack(alignment: .leading, spacing: 4) {
                Text(verbatim: entry.name)
                    .font(TypeLevel.header.font)
                    .foregroundStyle(ColorRole.text.color)
                Text(verbatim: Self.describe(entry.kind))
                    .font(TypeLevel.lowercased.font)
                    .foregroundStyle(ColorRole.textMatt.color)
                    .lineLimit(1)

                // The third row: is it being received, or is the connection down?
                //
                // Colour AND glyph, not colour alone: on a TV with
                // strong picture enhancement hues shift, and whoever is
                // red-green colour blind sees two rows of equal brightness. The glyph in front
                // carries the statement even without colour.
                //
                // **The height is reserved in advance** (roadmap P6): the information
                // arrives only when the provider has answered — without fixed
                // space its appearance pushed every row below it down, and whoever
                // was just aiming at "Delete" hit the neighbour. The `ZStack`
                // is there even in the empty case; `minHeight` instead of a fixed height, because
                // an error message may run to two lines.
                ZStack(alignment: .topLeading) {
                    switch status[entry.id] {
                    case .checking:
                        Label {
                            Text(app: "settings.playlistChecking")
                        } icon: {
                            ProgressView().controlSize(.small)
                        }
                        // See AP5 · B7 — and at least `textDim`.
                        .font(TypeLevel.footer.font)
                        .foregroundStyle(ColorRole.textMatt.color)

                    case .reachable(let detail):
                        Label {
                            Text(verbatim: detail)
                        } icon: {
                            Image(systemName: "checkmark.circle.fill")
                        }
                        .font(TypeLevel.footer.font)
                        .foregroundStyle(ColorRole.success.color)
                        .lineLimit(1)

                    case .failed(let key):
                        Label {
                            Text(appKey: key)
                        } icon: {
                            Image(systemName: "exclamationmark.triangle.fill")
                        }
                        .font(TypeLevel.footer.font)
                        .foregroundStyle(ColorRole.live.color)
                        .lineLimit(2)

                    case nil:
                        EmptyView()
                    }
                }
                .frame(minHeight: 30, alignment: .topLeading)
            }

            Spacer(minLength: 20)

            // Refresh fetches the catalog of the list anew: the provider status
            // is queried afresh AND the loaded channel catalog is discarded —
            // only both together are what "refresh" promises. Refreshing only
            // the status line would leave yesterday's channels in place.
            // Fetching the whole programme guide takes time; without an indicator the
            // button would look dead, and you press a second time. The hourglass and the
            // busy information come with ``ActionState/isRunning``.
            FormButton(
                title: "settings.refresh",
                state: status[entry.id] == .checking ? .isRunning : .ready,
                rank: .beside,
                identifier: "refresh-" + entry.id,
                focus: $focus
            ) {
                status[entry.id] = .checking
                Task {
                    await onRefresh()
                    await check(entry)
                }
            }

            // Switching on and off instead of only deleting: whoever does not need a friend's
            // access for a while does not want to retype it
            // — and typing is the most expensive operation here.
            FormButton(
                title: entry.isEnabled ? "settings.disable" : "settings.enable",
                rank: .beside,
                identifier: "toggle-" + entry.id,
                focus: $focus
            ) {
                store.setEnabled(!entry.isEnabled, for: entry.id)
                reload()
            }

            FormButton(
                title: "common.delete",
                rank: .beside,
                warning: true,
                identifier: "delete-" + entry.id,
                focus: $focus
            ) {
                // **Ask first** (AP5 · B8): deleting a channel list takes
                // Live, Sport and the favourites their channels away and demands
                // the credentials again — and one mis-press was enough for that.
                // It is the only irrevocable action in the
                // settings.
                deletePrompt = entry.id
            }
        }
        .padding(.vertical, 20)
        // **The whole row is a focus section.** Its buttons sit far
        // right, and tvOS searches in a cone around the direction of movement: whoever
        // pressed right from the area list or up from the add button
        // had the buttons outside every cone — they were simply
        // unreachable with the remote (on-device finding 2026-08-07, "cannot get
        // to Switch off or Delete"). As a section the full
        // row width counts as a target, and the focus lands on the nearest button.
        .focusSection()
        .overlay(alignment: .bottom) {
            Rectangle().fill(ColorRole.lineQuiet.color).frame(height: 1)
                // Decoration takes part in determining the focus target and thus lies
                // between this row and the one below. In the channel list exactly
                // this one divider has already been noticed; the rows here carry
                // buttons for switching on and off and for deleting, and the way
                // down passes over the line at every row.
                .allowsHitTesting(false)
        }
    }

    /// Describes a list in one row — **without credentials.**
    ///
    /// The user name would be helpful here, but it would stand next to the server name
    /// and thus on a screen that is occasionally photographed. The
    /// server alone is enough to tell them apart.
    static func describe(_ kind: Playlist.Kind) -> String {
        switch kind {
        case .m3u(let url): url.host() ?? url.absoluteString
        case .xtream(let server, _): server.host() ?? server.absoluteString
        case .jellyfinLiveTV: "Jellyfin"
        }
    }

    // MARK: - Entering

    private var addButton: some View {
        ActionRow(
            title: "settings.addPlaylist",
            icon: "plus",
            identifier: "add",
            focus: $focus
        ) {
            draft = Draft()
            isAdding = true
            // The pressed button disappears when the form opens —
            // without a handoff the focus would fall into the sidebar, and the
            // form could not be filled in (on-device finding 2026-08-07).
            handOffFocus(to: "kind-m3u")
        }
        .padding(.top, 28)
        // Full width as a section, like the rows above: from their
        // buttons far right the search cone leads down into nothing otherwise,
        // and the button here on the left is unreachable from there.
        .frame(maxWidth: .infinity, alignment: .leading)
        .focusSection()
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: 22) {
            // The kind first: it decides which fields appear at all, and
            // saves three inputs with an M3U.
            HStack(spacing: 14) {
                ForEach(Draft.Kind.allCases) { kind in
                    // **The building block brings the information that was missing here.** The
                    // earlier `kindButton` carried none — "M3U" and "Xtream" were
                    // read aloud without saying which of the two is selected.
                    ChoiceRow(
                        title: kind.titleKey,
                        chosen: draft.kind == kind,
                        identifier: "kind-" + kind.id,
                        focus: $focus
                    ) {
                        draft.kind = kind
                    }
                }
            }

            InputRow(
                title: "settings.playlistName", text: $draft.name, state: .inRow, kind: .prose,
                identifier: "name", focus: $focus)
            InputRow(
                title: "settings.playlistAddress", text: $draft.address, state: .inRow, kind: .address,
                identifier: "address", focus: $focus)

            if draft.kind == .xtream {
                InputRow(
                    title: "common.username", text: $draft.username, state: .inRow, kind: .identifier,
                    identifier: "user", focus: $focus)
                InputRow(
                    title: "common.password", text: $draft.password, state: .inRow, kind: .identifier,
                    isHidden: true, identifier: "pass", focus: $focus)
            } else {
                // Only for M3U: Xtream brings the broadcast times itself.
                InputRow(
                    title: "settings.playlistEPG", text: $draft.epgAddress, state: .inRow, kind: .address,
                    identifier: "epg", focus: $focus)
            }

            HStack(spacing: 18) {
                FormButton(
                    title: "settings.save", rank: .main, identifier: "save", focus: $focus
                ) {
                    save()
                }
                FormButton(
                    title: "common.cancel", rank: .beside, identifier: "cancel", focus: $focus
                ) {
                    isAdding = false
                    message = nil
                    handOffFocus(to: "add")
                }
            }
        }
        .padding(.top, 30)
        // The same reasoning as at the add button: the fields are narrower
        // than the rows above; as a full-width section the
        // form stays reachable downward from the row buttons.
        .frame(maxWidth: .infinity, alignment: .leading)
        .focusSection()
    }

    // MARK: - Saving

    private func save() {
        message = nil
        confirmation = nil

        switch draft.kind {
        case .m3u:
            guard let url = ChannelListCheck.address(draft.address) else {
                message = "settings.playlistBadAddress"
                return
            }
            save(
                Playlist(
                    name: displayName(fallback: url.host() ?? "M3U"),
                    kind: .m3u(url),
                    epgURL: ChannelListCheck.address(draft.epgAddress)
                )
            )

        case .xtream:
            // Checked via `XtreamEndpoint` and not assembled by hand: the
            // normalisation lives there — missing scheme, trailing
            // slash. Having it twice would mean maintaining it twice.
            guard
                let endpoint = XtreamEndpoint(
                    server: draft.address,
                    username: draft.username,
                    password: draft.password
                )
            else {
                message = "settings.playlistBadXtream"
                return
            }
            let playlist = Playlist(
                name: displayName(fallback: endpoint.server.host() ?? "Xtream"),
                kind: .xtream(server: endpoint.server, username: endpoint.username)
            )

            // **Ask first, then save.** Before, things were stored here unchecked.
            // A mistyped server or a wrong password thus counted as
            // set up, the Live area stayed empty — and that cannot be told apart from a
            // provider without channels. The provider answers
            // with status 200 even for a wrong password; only the `auth` field
            // tells the truth.
            checking = true
            Task {
                await verifyAndStore(playlist, endpoint: endpoint)
            }
            return
        }

        isAdding = false
        reload()
        handOffFocus(to: "add")
    }

    /// Wait first, then assign — the pattern of the return from search
    /// (``MainView``): an immediate assignment is overwritten by the system's
    /// ongoing focus assignment. The 120 milliseconds let tvOS
    /// finish its own assignment before ours applies.
    /// Which list is up for deletion — see the button.
    @State private var deletePrompt: String?

    /// Really deletes.
    ///
    /// Where the focus should go afterwards is decided **before** deleting: the
    /// row that moves up — or the add button if none remains.
    /// Without the handoff the pressed button would die under the focus, and tvOS
    /// would throw it into the sidebar (the teardown trap, on-device finding 2026-08-07).
    private func delete(_ id: String) {
        let index = entries.firstIndex { $0.id == id } ?? 0
        let remaining = entries.filter { $0.id != id }
        store.remove(id)
        // **And for every profile that held it** (AP41) — as on the phone.
        ProfileAccesses.removeEverywhere(.channelList(identifier: id), in: FileStore())
        reload()
        if remaining.isEmpty {
            handOffFocus(to: "add")
        } else {
            handOffFocus(to: "delete-" + remaining[min(index, remaining.count - 1)].id)
        }
    }

    private func handOffFocus(to id: String) {
        Task {
            try? await Task.sleep(for: .milliseconds(120))
            focus = id
        }
    }

    /// Asks the provider and stores the access only on success — **the same check as
    /// the status line** (``PlaylistKit/ChannelListCheck``). A mistyped password
    /// and an expired access get separate messages; since R7 they also
    /// arrive, instead of ending up in the `catch` as "not reachable".
    private func verifyAndStore(_ playlist: Playlist, endpoint: XtreamEndpoint) async {
        defer { checking = false }
        let finding = await ChannelListCheck.verify(playlist, password: endpoint.password)
        switch finding.map(Self.row) {
        case .reachable(let summary):
            save(playlist, password: endpoint.password)
            confirmation = summary
            isAdding = false
            reload()
            handOffFocus(to: "add")
        case .failed(let key):
            message = key
        case .checking, nil:
            message = "settings.playlistUnreachable"
        }
    }

    /// The provider's answer in one row.
    ///
    /// Deliberately with **numbers** and not only a checkmark: "Connected" alone
    /// reassures but says nothing. The allowed connections are the piece of information that
    /// counts in daily use — with a single one no second device can
    /// watch at the same time, and that later explains a behaviour that
    /// otherwise looks like an error.
    static func summary(of info: ChannelListCheck.StateInfo) -> String {
        var split: [String] = []
        if let status = info.status, !status.isEmpty { split.append(status) }
        if let max = info.atMost {
            split.append("\(info.taken)/\(max)")
        }
        if let flow = info.until {
            split.append(flow.formatted(date: .abbreviated, time: .shortened))
        }
        return split.joined(separator: "  ·  ")
    }

    /// The entered name, or the host name as a fallback.
    ///
    /// Making it a required field would be one more input for something that can be derived
    /// from the address. Renaming is possible at any time later.
    private func displayName(fallback: String) -> String {
        let trimmed = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? fallback : trimmed
    }

    /// **Through the profile's window** (on-device test build 1332, 2026-09-27, finding 3) — the
    /// device catalog used to be here, and a new profile saw the access of the deleted one.
    private func reload() {
        entries = store.visiblePlaylists
    }

    /// A list created here **belongs to the profile sitting in front of it** (AP41) — until
    /// 2026-09-27 this view stored it only on the device. With the window
    /// (``Flows/ChannelListView``) it would otherwise have stayed invisible.
    private func save(_ playlist: Playlist, password: String? = nil) {
        store.add(playlist, password: password)
        ProfileAccesses.create(.channelList(identifier: playlist.id), in: FileStore())
    }
}
