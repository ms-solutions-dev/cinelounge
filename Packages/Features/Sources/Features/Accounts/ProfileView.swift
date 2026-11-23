import Core
import DesignSystem
import Flows
import ParentalControls
import ProfileKit
import SwiftUI

/// The profiles of this TV, with switch, create, change and remove.
///
/// **The account list has become a profile list** (AP41, row 5, 2026-09-21).
/// The product decision: only profiles remain; accounts with their
/// progress and accesses live entirely inside the profiles themselves and
/// are then stored in CloudKit. What stood here was a list of **Jellyfin users**;
/// what stands here is a list of **people**. An access is something one of
/// them has — it stands in the second row and is no longer an entry of its own.
///
/// **The reasoning of the old list still applies and therefore stays here:** A
/// single profile still gets a list (otherwise nobody would see that it exists);
/// every action goes through a door of the parental controls; and a second target in the
/// row does not exist — from three meters one hits the wrong one, and the wrong one would be
/// deleting here.
///
/// **The access is still added through the setup** and not through a
/// field of its own: the same path, the same explanations, the same certificate question. It
/// lands with the **active** profile — whoever wants to give something to another one switches there first.
/// That is one place fewer to make a mistake, and it is
/// the same order a person goes through anyway.
struct ProfileView: View {

    @ObservedObject var model: ProfileModel

    /// The parental controls in force — **every action here goes through a door.**
    ///
    /// The names are in ``ParentalControls/LockedDoors`` and are justified there.
    /// **Creating too**, and that is the addition of this row: A new profile would
    /// otherwise be an adult profile that a child gives itself in four taps — the
    /// sentence at the door ("A new account would have no limit") hits it literally.
    @ObservedObject var lock: ParentalControlsState

    /// Called after every switch — with the new session, or with `nil` if the
    /// profile has no Jellyfin (N-1, see ``AccountSwitcher/session(after:load:)``).
    let onSwitched: (ServerCredentials?) -> Void

    /// Leads into the setup to give the active profile an access.
    let onAddAccess: () -> Void

    @FocusState private var focus: String?
    /// The request of the section list to bring focus in — reported by ``ProfileSettings``,
    /// which registers the entry like every settings section (``SettingsFirstEntryKey``).
    var entryRequest = 0

    /// The profile for which the remove confirmation is open.
    @State private var asksFor: Profile?

    /// The sheet for creating or changing — `nil` means: none open.
    @State private var sheet: SheetRequest?

    /// The profile whose server is currently being moved.
    @State private var movesHouse: Account?

    /// The profile whose PIN is currently being requested — on switching or on merging.
    @State private var pinTarget: Profile?

    /// What is currently to be merged, including the PINs already entered.
    @State private var merge: MergeRequest?

    /// Whether the confirmation "which profile should be absorbed?" is open.
    @State private var choosesMerge = false

    /// The pair for which the confirmation "merge?" is open.
    @State private var asksPair: ProfileSync.Pair?

    /// A removal that still needs the profile's PIN (finding 8) — including the choice of how
    /// far it reaches.
    @State private var removal: Profile?
    @State private var removalMode: ProfileManagement.RemovalMode = .everywhere

    /// The profiles from iCloud hidden here — `nil` as long as nobody has asked
    /// ("Add existing profile", 2026-09-27).
    @State private var existing: [Profile]?

    /// The profile whose PIN is currently being set, changed or removed (AP52).
    @State private var pinManagement: Profile?

    /// A merge that still needs a PIN.
    struct MergeRequest: Equatable {
        let leaving: Profile.Identifier
        let remains: Profile.Identifier
        var pins: [Profile.Identifier: String] = [:]
    }

    /// What this device starts with — `nil` means: It asks.
    ///
    /// **Read and held, because the button has two labels.**
    /// ``ProfileKit/StartChoice`` lives in `UserDefaults`; a view that re-reads there on every
    /// redraw is the same computation in the body that E70 abolished.
    @State private var startChoice: Profile.Identifier?

    /// Which sheet is open. **One wish and two flags fewer:** "new" and "changes
    /// this one" are the same sheet with different content; two `@State` above it would drift
    /// apart as soon as both were set.
    enum SheetRequest: Identifiable {
        case fresh
        case changes(Profile)

        var id: String {
            switch self {
            case .fresh: "neu"
            case .changes(let profile): profile.identifier.rawValue
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let movesAccount = movesHouse {
                migration(movesAccount)
            } else {
                // **Running "Forgot PIN" of the profiles, cancelable** (finding 6).
                ProfileEscapeSection()
                asks
                list
                moreButtons
                if !model.canSwitch { singleProfileNotice }
                // **Delete all own iCloud data** (finding 10) — only with the cloud.
                if ProfileCloud.attached != nil {
                    CloudDataSection(lock: lock) { model.load() }
                }
            }
        }
        .onAppear { model.load() }
        // **The entry from the section list lands on the active profile.**
        .onChange(of: entryRequest) { _, _ in
            focus = model.active?.rawValue ?? model.profile.first?.identifier.rawValue
        }
        // **Only on the TV.** `fullScreenCover` does not exist on the Mac, and
        // this package is compiled for the desktop during the check run — the same guard
        // as at the allow-list sheet in ``ParentalControlsView``.
        #if os(tvOS)
            // **The same number pad as in the switcher, including "Forgot PIN"** (AP45,
            // 2026-09-25) — ``ProfilePinSheet``. Until here simply nothing happened when
            // switching to a protected profile from here.
            .fullScreenCover(item: $pinTarget) { target in
                ProfilePinSheet(
                    profile: target, cloud: ProfileCloud.attached,
                    onSubmit: { take($0, forItem: target) },
                    onCancel: {
                        pinTarget = nil
                        merge = nil
                        removal = nil
                    },
                    onUnlocked: {
                        pinTarget = nil
                        merge = nil
                        removal = nil
                        model.load()
                    })
            }
            .fullScreenCover(item: $pinManagement) { profile in
                ProfilePinManagement(
                    profile: profile, model: model, cloud: ProfileCloud.attached
                ) {
                    pinManagement = nil
                    model.load()
                }
            }
            .fullScreenCover(item: $sheet) { request in
                ProfileSheet(
                    existing: request.profile,
                    suggestion: model.nextColor,
                    previousLimit: request.profile.flatMap {
                        lock.ownLimit(forItem: $0.identifier.rawValue)
                    },
                    onSave: { name, color, kind, limit, avatar in
                        save(
                            request, name: name, color: color, kind: kind, limit: limit,
                            avatar: avatar)
                    },
                    onCancel: { sheet = nil },
                    isPinSet: lock.rule.isPinSet
                )
            }
        #endif
        // **Removing is a choice** (product requirement 2026-09-27): only here or everywhere; a
        // borrowed profile knows only "Leave share" (``Flows/ProfileManagement/RemovalMode``).
        .confirmationDialog(
            Text(app: "profiles.removeConfirm"),
            isPresented: Binding(
                get: { asksFor != nil },
                set: { if !$0 { asksFor = nil } }
            ),
            titleVisibility: .visible, presenting: asksFor
        ) { profile in
            if model.isBorrowed(profile.identifier) {
                Button(role: .destructive) {
                    remove(profile, mode: .everywhere)
                } label: {
                    Text(app: "profiles.leaveShare")
                }
            } else {
                Button(role: .destructive) {
                    remove(profile, mode: .hereOnly)
                } label: {
                    Text(app: "profiles.removeHere")
                }
                Button(role: .destructive) {
                    remove(profile, mode: .everywhere)
                } label: {
                    Text(app: "profiles.removeEverywhere")
                }
            }
            Button(role: .cancel) {
            } label: {
                Text(app: "common.cancel")
            }
        } message: { profile in
            Text(app: model.isBorrowed(profile.identifier) ? "profiles.leaveChoice" : "profiles.removeChoice")
        }
        .confirmationDialog(
            Text(app: "profiles.addExisting"),
            isPresented: Binding(
                get: { existing != nil },
                set: { if !$0 { existing = nil } }
            ),
            titleVisibility: .visible, presenting: existing
        ) { list in
            ForEach(list) { profile in
                Button {
                    model.restore([profile])
                    existing = nil
                } label: {
                    Text(verbatim: profile.name)
                }
            }
            Button(role: .cancel) {
            } label: {
                Text(app: "common.cancel")
            }
        } message: { list in
            Text(app: list.isEmpty ? "profiles.addExistingNone" : "profiles.addExistingHint")
        }
    }

    // MARK: - Merging (AP45 ← AP48)

    /// The open questions "same person?" — **here stands the answer**, the question stands
    /// as a marker on the circle in the switcher.
    ///
    /// **Two answers, and both clear the question.** "Keep both" is not a
    /// non-answer (``ProfileKit/ProfileSync/answer(_:in:)``).
    @ViewBuilder
    private var asks: some View {
        let pairs = model.openQuestions
        if !pairs.isEmpty {
            VStack(alignment: .leading, spacing: 14) {
                Label {
                    Text(app: "profiles.mergeQuestion")
                } icon: {
                    Image(systemName: Glyph.toBackfill.name)
                }
                .font(TypeLevel.header.font)
                .foregroundStyle(ColorRole.progress.color)
                ForEach(pairs, id: \.self) { pair in
                    query(pair)
                }
            }
            .padding(.bottom, 30)
            .frame(maxWidth: 1100, alignment: .leading)
        }
    }

    private func query(_ pair: ProfileSync.Pair) -> some View {
        let here = model.profile.first { $0.identifier == pair.device }?.name ?? ""
        let there = model.profile.first { $0.identifier == pair.cloud }?.name ?? ""
        return HStack(alignment: .firstTextBaseline, spacing: 18) {
            Text(app: "profiles.mergePair \(here) \(there)")
                .font(TypeLevel.footer.font)
                .foregroundStyle(ColorRole.text.color)
                .frame(maxWidth: 560, alignment: .leading)
            button("profiles.mergeDo", identifier: "zusammen-\(pair.device.rawValue)") {
                guard lock.isAllowed(finished: "konten") else { return }
                asksPair = pair
            }
            button("profiles.mergeKeepTwo", identifier: "zwei-\(pair.device.rawValue)") {
                model.keepBoth(pair)
            }
        }
        .focusSection()
    }

    /// Attempt a merge — **and show the number pad if a PIN is
    /// missing**, then try again.
    ///
    /// The rule which PINs are needed is in ``ProfileKit/ProfileMerge``;
    /// this view only keeps asking until they are all there.
    private func merge(_ request: MergeRequest) {
        switch model.merge(request.leaving, in: request.remains, pins: request.pins) {
        case .pinRequired(let profile):
            merge = request
            pinTarget = profile
        case .merged(_, let wasActive):
            merge = nil
            pinTarget = nil
            // **If the viewer sat in one of the two, the result applies from now on** — also
            // in the remaining one: If it has become a child profile through a child, the
            // parental controls must know it immediately (``ProfileModel/merge(_:in:pins:)``
            // has already switched again).
            if wasActive || model.active == request.remains {
                lock.load()
                onSwitched(try? SecureStore().loadCredentials())
            }
        case .impossible:
            merge = nil
            pinTarget = nil
        }
    }

    /// The typed PIN — for a switch or for a merge.
    private func take(_ pin: String, forItem target: Profile) -> Bool {
        if let departing = removal {
            let wasActive = departing.identifier == model.active
            guard model.remove(departing.identifier, pin: pin, mode: removalMode) == .removed
            else { return false }
            removal = nil
            pinTarget = nil
            if wasActive { followUpAfterRemoval() }
            return true
        }
        if var request = merge {
            guard model.matchesPin(pin, forItem: target.identifier) else {
                return false
            }
            request.pins[target.identifier] = pin
            pinTarget = nil
            merge(request)
            return true
        }
        guard let result = model.switchTo(zu: target.identifier, pin: pin).result else {
            return false
        }
        pinTarget = nil
        onSwitched(AccountSwitcher.session(after: result))
        return true
    }

    private var list: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(spacing: 14) {
                ForEach(model.profile, id: \.identifier.rawValue) { profile in
                    Button {
                        edit(profile)
                    } label: {
                        ProfileRow(
                            profile: profile,
                            isActive: profile.identifier == model.active,
                            hasFocus: focus == profile.identifier.rawValue
                        )
                    }
                    .bareFocusableButton()
                    .focused($focus, equals: profile.identifier.rawValue)
                    // A long press removes. **No second button in the row:** From three
                    // meters a row with two targets is a row where one hits the
                    // wrong one — and the wrong one would be deleting here.
                    .onLongPressGesture {
                        guard lock.isAllowed(finished: "konten") else { return }
                        guard model.mayRemove(profile.identifier) else { return }
                        asksFor = profile
                    }
                }
            }
            .frame(maxWidth: 1100, alignment: .leading)
            // **What a press does stands below** — also the long one, which one otherwise does not see.
            Text(app: "profiles.editHint")
                .font(TypeLevel.footer.font)
                .foregroundStyle(ColorRole.textQuiet.color)
                .padding(.top, 14)
        }
    }

    /// The handles below the list.
    ///
    /// **Create stands first and acts on nobody**, the three behind it act on the
    /// **active** profile — as already with the account: A button that acted on a different one than the
    /// checked one would be the surprise one can least use with a delete button.
    /// The other rows remain reachable via the long press.
    ///
    /// **Wrapping and not in one row** (on-device test 2026-09-27, T7): Up to nine
    /// pills stood in an `HStack`. It does not wrap but squeezes — every
    /// label ended up vertical, a pair of letters per line.
    private var moreButtons: some View {
        FlowLayout(spacing: 18, lineSpacing: 18) {
            button("profiles.add", identifier: "anlegen") {
                guard lock.isAllowed(finished: "kontoNeu") else { return }
                sheet = .fresh
            }
            // **Deliberately bring back what was removed here** (2026-09-27) —
            // ``ProfileKit/ProfileHiding``. Only with the cloud: Without it nothing lies in iCloud.
            if ProfileCloud.attached != nil {
                button("profiles.addExisting", identifier: "vorhandene") {
                    guard lock.isAllowed(finished: "kontoNeu") else { return }
                    Task { existing = await model.hiddenProfiles() }
                }
            }
            if let active = model.activeProfile {

                // **No profile PIN any more** (AP59 N4, 2026-09-30) — one PIN for the household,
                // asked when leaving the child profile.

                // **Pairing, handoff and remote have been under
                // Settings → Other devices since AP59 N7** (``OtherDevicesSettings``) — they belong to the
                // device, not to a person.

                // **"Start automatically as …" stands behind the account-switch door**
                // (AP45, 2026-09-23), and that is not caution but a hole that
                // would otherwise stand open: ``ProfileKit/StartChoice`` does ask for the
                // **profile** PIN when applied — but an adult profile without its own PIN has
                // none. A child who set the choice to it and restarted would sit
                // in front of it without any limit. The door `accountSwitch` says exactly that: "An
                // account switch lifts every limit."
                button(
                    startChoice == active.identifier
                        ? "profiles.startAsOff" : "profiles.startAs",
                    identifier: "startwahl"
                ) {
                    guard lock.isAllowed(finished: "kontowechsel") else { return }
                    let fresh: Profile.Identifier? =
                        startChoice == active.identifier ? nil : active.identifier
                    StartChoice().set(fresh)
                    startChoice = fresh
                }

                if let account = moveAccount(active) {
                    button("accounts.moveTitle", identifier: "umzug") {
                        guard lock.isAllowed(finished: "umzug") else { return }
                        movesHouse = account
                    }
                }

                // **Merging pulls another profile into the active one** (AP45,
                // 2026-09-25) — the same rule as for the other buttons here: They act
                // on the checked profile. Whoever sits in front of the TV is the one who
                // stays; the other is absorbed into it. Behind the door `accounts`, like
                // removing, because it is one — only with a move.
                if model.canSwitch {
                    button("profiles.merge", identifier: "zusammenlegen") {
                        guard lock.isAllowed(finished: "konten") else { return }
                        choosesMerge = true
                    }
                    .confirmationDialog(
                        Text(app: "profiles.mergeChoose \(active.name)"),
                        isPresented: $choosesMerge, titleVisibility: .visible
                    ) {
                        ForEach(model.profile.filter { $0.identifier != active.identifier }) { other in
                            Button(role: .destructive) {
                                merge(
                                    MergeRequest(
                                        leaving: other.identifier, remains: active.identifier))
                            } label: {
                                Text(verbatim: other.name)
                            }
                        }
                        Button(role: .cancel) {
                        } label: {
                            Text(app: "common.cancel")
                        }
                    } message: {
                        Text(app: "profiles.mergeHint")
                    }
                }

                if model.mayRemove(active.identifier) {
                    button("profiles.remove", identifier: "entfernen") {
                        guard lock.isAllowed(finished: "konten") else { return }
                        asksFor = active
                    }
                }
            }
        }
        .padding(.top, 26)
        .onAppear { startChoice = StartChoice().identifier }
        // **The pair merges into the profile of the cloud** — whose identifier already applies on the other devices;
        // the device's one is the one that came into being only with this TV.
        .confirmationDialog(
            Text(app: "profiles.mergeDo"),
            isPresented: Binding(
                get: { asksPair != nil }, set: { if !$0 { asksPair = nil } }),
            titleVisibility: .visible
        ) {
            Button(role: .destructive) {
                if let pair = asksPair {
                    merge(MergeRequest(leaving: pair.device, remains: pair.cloud))
                }
                asksPair = nil
            } label: {
                Text(app: "profiles.mergeDo")
            }
            Button(role: .cancel) {
            } label: {
                Text(app: "common.cancel")
            }
        } message: {
            Text(app: "profiles.mergeHint")
        }
    }

    /// The move still needs an ``Account`` — **and that is no step backwards.**
    ///
    /// ``Flows/ServerMigrationFlow`` rewrites a **server address**, and that hangs on the access, not
    /// on the person: If Jellyfin moves, it moves for every profile that
    /// has it — since 2026-09-27 really so (setup check, E3; until then
    /// the profiles stayed on the old address).
    private func moveAccount(_ profile: Profile) -> Account? {
        guard case .jellyfin(let server, let user, let name) = profile.jellyfin
        else { return nil }
        return Account(
            server: server, userID: user, name: name,
            kind: profile.kind == .kind)
    }

    private func migration(_ account: Account) -> some View {
        MoveView(
            account: account,
            // **The identifier of the account that moves** (E5) — not that of the running
            // session, which may belong to another profile and server.
            model: ServerMigrationFlow(
                from: account.server,
                serverID: ServerMigrationFlow.serverID(
                    server: account.server, user: account.userID, in: SecureStore())
            ),
            onDone: { model.load() },
            onCancel: { movesHouse = nil }
        )
    }

    /// Saves the sheet — **and the limit only for a child.**
    ///
    /// **To the identifier of the edited profile, not to the active one.** Whoever sets up a
    /// child profile is an adult; the active profile is then themselves.
    /// Exactly this mix-up was the open question in the roadmap ("for whom does one configure?"),
    /// and ``ProfileTarget/limitBelongsTo(_:fresh:)`` answers it as a computation.
    private func save(
        _ request: SheetRequest, name: String, color: Profile.ColorTag, kind: Profile.Kind,
        limit: AgeLimit?, avatar: String?
    ) {
        // **Via the shared path** (``Flows/ProfileManagement/save(_:existing:)``,
        // G3) — the same one through which the phone creates; the limit lands on the edited
        // or the new profile (``ProfileTarget``).
        model.save(
            ProfileDraft(name: name, color: color, kind: kind, limit: limit, avatar: avatar),
            existing: request.profile)
        lock.load()
        sheet = nil
    }

    /// A press on a profile **opens its page** — name, picture, child yes/no, limit.
    ///
    /// **Until 2026-09-30 it switched to the profile** (AP59 N3). Editing worked only for the
    /// active one, via a button of its own in a row of nine; whoever opened "Manage
    /// profiles" and pressed on a profile afterwards sat in that profile. Switching happens in the
    /// sheet "Who is watching?", managing happens here — as on the phone.
    ///
    /// **Behind the door `accounts`**, because unlike before the press can now also change
    /// someone else's profile — for example turn a child profile into an adult one.
    private func edit(_ profile: Profile) {
        guard profile.identifier == model.active || lock.isAllowed(finished: "konten") else { return }
        sheet = .changes(profile)
    }

    /// Removed — **with the profile's PIN, and a borrowed one is left**
    /// (cross-check strand C, finding 8; see ``ProfileModel/remove(_:pin:)``).
    private func remove(_ profile: Profile, mode: ProfileManagement.RemovalMode) {
        asksFor = nil
        let wasActive = profile.identifier == model.active
        switch model.remove(profile.identifier, mode: mode) {
        case .pinRequired(let shielded):
            removal = shielded
            removalMode = mode
            pinTarget = shielded
        case .isBorrowed(let isBorrowed):
            Task {
                try? await model.leave(isBorrowed.identifier)
                if wasActive { followUpAfterRemoval() }
            }
        case .removed:
            if wasActive { followUpAfterRemoval() }
        case .impossible:
            break
        }
    }

    /// If the removed one was in front, **the shell learns who sits in front now — or that it
    /// is nobody** (check 2026-09-25 evening).
    ///
    /// ``ProfileModel/remove(_:pin:)`` has already sent the successor through the bolt
    /// (``ProfileModel/followSuccessor()``); here rule and session follow, on the same
    /// path as after a merge. An empty session means "no library", and the
    /// list above is the choice.
    private func followUpAfterRemoval() {
        lock.load()
        onSwitched(try? SecureStore().loadCredentials())
    }

    /// The sentence below a list with exactly one entry.
    ///
    /// It says that a switch exists and what it hangs on today. Without it a list with one
    /// entry is a list that nobody recognizes as such.
    private var singleProfileNotice: some View {
        Text(app: "profiles.singleHint")
            .font(TypeLevel.lowercased.font)
            .foregroundStyle(ColorRole.textQuiet.color)
            .padding(.top, 22)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: 900, alignment: .leading)
    }

    private func button(
        _ key: String, identifier: String, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(appKey: key)
                .font(TypeLevel.footer.font)
                .lineLimit(1)
                .fixedSize()
                .settingsFont(isFocused: focus == identifier)
                .settingsSurface(.pill, isFocused: focus == identifier)
        }
        .bareFocusableButton()
        .focused($focus, equals: identifier)
    }
}

extension ProfileView.SheetRequest {
    /// The profile being changed — `nil` when creating.
    var profile: Profile? {
        if case .changes(let profile) = self { return profile }
        return nil
    }
}

/// Whom a limit chosen in the sheet belongs to (AP45, Decision 7).
///
/// **A computation, because the mix-up would be silent.** The active profile is, when
/// configuring, always an adult; if the limit were written there, it would stand on the
/// wrong person, and the child would stay without — without any message.
enum ProfileTarget {

    /// The edited profile, or for a new one the freshly assigned identifier.
    /// `nil` if creating failed — then there is nobody it belongs to.
    nonisolated static func limitBelongsTo(
        _ edited: Profile?, fresh: Profile.Identifier?
    ) -> Profile.Identifier? {
        edited?.identifier ?? fresh
    }
}
