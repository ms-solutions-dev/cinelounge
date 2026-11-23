import Core
import DesignSystem
import Flows
import ProfileKit
import SwiftUI

/// **Who is watching?** — the account switch from the sidebar, as a sheet of its own.
///
/// **Why this sheet exists** (2026-09-13). The profile icon in the sidebar
/// previously opened the settings in the "Account" section — a jump, not a place of its own.
/// The product owner saw two icons that do the same thing: *both feel like they open the
/// same thing … we do not need both, do we?* They were right. The choice was: remove the icon
/// or give it a task of its own. The second was decided — in
/// a living room two accounts are the normal case (E47), and a switch is something one does
/// **in the middle of watching**. For that a list of accounts with remove, move and create
/// is too much screen; here there are only the faces and one press.
///
/// **A profile appears as a circle with an initial**, as in ``ProfileRow`` — the same
/// form, so that it is recognizable. The active one carries a checkmark, a child profile the
/// figure: **shape, not color** (E47, deuteranopia 1.02 : 1 at three meters). The
/// profile color is added and replaces none of it.
///
/// **Since AP41, row 5 this shows profiles and no longer Jellyfin users.** Otherwise
/// this sheet would show a different list of people than the settings next to it — and a
/// freshly created profile without Jellyfin access would not appear here at all. What AP45
/// still brings is the **number pad** for a profile with its own PIN and the
/// child interface behind it.
///
/// **What is missing here, on purpose:** remove, move, merge. They sit behind the
/// last circle, "Manage profiles" — the same path as before, now one press further.
///
/// **Creating has been here since 2026-09-25, and always** (product decision 3):
/// a "+" card "Create profile", even if profiles already exist, with two paths
/// behind it — new or from the iPhone (``ProfileCreation``). Profiles are self-contained; whoever
/// stands in front of "Who is watching?" and does not find themselves should be able to create themselves here and not
/// have to go to the settings first.
struct AccountSwitcher: View {

    /// Where a press on the profile icon leads.
    ///
    /// **Almost always to this sheet — even with a single account.** The first draft
    /// jumped to the settings with one account ("a circle is not a choice"), and the
    /// product owner saw only this: *the profile icon still opens the
    /// settings.* Rightly so — an icon that does something different depending on the number of accounts
    /// cannot be learned. With one account the sheet shows the one circle and next to it
    /// "Another account": That is the choice there then is.
    ///
    /// **The one exception: the parental controls apply.** The switch is there a door
    /// with PIN (`accountSwitch` in ``ParentalControls/LockedDoors``), and the door sits
    /// in the settings. Building it a second time here would be a second place
    /// with the same errors; and a child who saw the circles would see an invitation.
    ///
    /// **Since 2026-09-30 the exception is no longer one** (AP59 N3): The jump into the
    /// settings ended up in the "Jellyfin" section last, and whoever looked for "Who is watching?"
    /// did not find it. If the lock applies, the door now stands in front of the sheet — the same path
    /// as from the child interface.
    nonisolated enum Route: Equatable {
        case sheet
        /// The sheet, but **behind the door `accountSwitch`** — the path out of the
        /// child interface (AP45) when the lock applies.
        case sheetBehindDoor
    }

    nonisolated static func route(parentalControlsApply: Bool) -> Route {
        route(parentalControlsApply: parentalControlsApply, surface: .familiar)
    }

    /// The same path, **out of the child interface** (AP45, 2026-09-25).
    ///
    /// **There are no settings there**, so the door cannot sit in them.
    /// It therefore stands in front of the sheet itself — the same door `accountSwitch`, via
    /// ``ParentalControlsDoor``, which the receiving end of the device handoff also uses. **Without
    /// it, "Switch profile" would be the hole that the start choice already once was:** An
    /// adult profile often has no PIN of its own, and a child would sit after one press
    /// without a limit.
    ///
    /// **If the lock does not apply, the sheet opens without a question** — without a PIN every door
    /// is open, and a question that nobody can answer would be a trap.
    nonisolated static func route(parentalControlsApply: Bool, surface: Surface) -> Route {
        switch (surface, parentalControlsApply) {
        case (_, true): .sheetBehindDoor
        case (_, false): .sheet
        }
    }

    /// What happens after a press on a circle — **the shared rule**
    /// (``Flows/ProfilePicker/Reply``, G3): the same interpretation as on the phone.
    typealias Reply = ProfilePicker.Reply

    /// Whose title image stands behind the circles (AP49, concept addendum N2).
    ///
    /// **That of the focused profile — and while wandering onto "Add access" or
    /// "Manage profiles", the one focused last.** These two are not people; if
    /// the background fell back to the active profile there, the image would jump on the last
    /// step to the right to another face without anyone having chosen a person.
    ///
    /// - Parameters:
    ///   - fokus: the focus identifier, a profile identifier or a handle.
    ///   - profile: the identifiers of all profiles in the switcher.
    ///   - bisher: the previous title-image profile.
    nonisolated static func titleID(
        focus: String?, profile: [String], previous: String?
    ) -> String? {
        guard let focus, profile.contains(focus) else { return previous }
        return focus
    }

    /// Which session applies after a switch — **`nil` means: none**. The rule lives
    /// shared at ``Flows/ProfilePicker/session(after:load:)``.
    nonisolated static func session(
        after result: ProfileSwitch.Outcome?,
        load: () -> ServerCredentials? = { try? SecureStore().loadCredentials() }
    ) -> ServerCredentials? {
        ProfilePicker.session(after: result, load: load)
    }

    nonisolated static func reply(to outcome: ProfileSwitch.SwitchOutcome) -> Reply {
        ProfilePicker.reply(to: outcome)
    }

    @ObservedObject var model: ProfileModel

    /// The cloud — **only to answer "shared by …"** (AP44 → AP45).
    ///
    /// `nil` means: no Apple account, hence no shared profile either. Then the row
    /// is missing instead of claiming "shared by —".
    var cloud: ProfileCloud? = ProfileCloud.attached

    /// After every switch — with `nil` if the new profile has no Jellyfin
    /// (``session(after:load:)``).
    let onSwitched: (ServerCredentials?) -> Void
    /// "Edit profiles" — the management, in which a press on a profile opens its page.
    let onManage: () -> Void
    /// The settings — **the same row as in the sheet on the phone** (AP59 N3).
    let onSettings: () -> Void
    /// **Pressing the own profile: stay and close** (on-device test 2026-09-30). At
    /// startup the own profile is preselected, and the natural press on it means
    /// "yes, I am watching". It did nothing — the sheet closed only with "Back". No switch,
    /// no new session, just close. The phone already closes its sheet before this question.
    var onStay: () -> Void = {}

    /// Whether it only switches — **without "Create profile", "Add access" and "Manage
    /// profiles"** (AP45, 2026-09-25).
    ///
    /// The latter two lead into the settings, and from the child interface there is
    /// no path there. **And a child does not create a profile** — a new profile would be
    /// one without a limit, the same reasoning as at the door `newAccount`. The circles remain:
    /// The sheet is the only exit there. See ``actions(profile:switchOnly:)``.
    var switchOnly = false

    @FocusState private var focus: String?

    /// The profile whose PIN is currently being requested — `nil` means: no number pad.
    @State private var pinTarget: Profile?

    /// Whether "Create profile" is open.
    @State private var isCreating = false

    /// Pairs that look like the same person without proving it (AP45 ← AP48).
    ///
    /// **Read once on appearing and not on every redraw.** They change
    /// only while an iCloud sync is running, and that does not run while this screen
    /// is open.
    @State private var openQuestions: [ProfileSync.Pair] = []

    /// Open "forgot PIN" requests per profile (cross-check strand C, finding 6) — as a
    /// marker on the circle, see ``ProfileEscapes``.
    @State private var escapes = ProfileEscapes.none

    /// Whose motif fills the background — see ``titleID(focus:profile:previous:)``.
    @State private var titleProfile: String?

    /// **With "Reduce Motion" the title image changes without a crossfade.** A whole
    /// image that fades across the surface while wandering is exactly the large-area motion
    /// that this setting is meant to turn off.
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The circles behind the profiles — **shared** (``Flows/ProfilePicker/Action``):
    /// "Create profile" is always there (Decision 3), except when merely switching.
    typealias Action = ProfilePicker.Action

    nonisolated static func actions(profile count: Int, switchOnly: Bool) -> [Action] {
        ProfilePicker.actions(switchOnly: switchOnly)
    }

    var body: some View {
        ZStack {
            ColorRole.reason.color.ignoresSafeArea()
            titleImage
            VStack(spacing: 60) {
                VStack(spacing: 12) {
                    Text(app: "accounts.switcherTitle")
                        .font(TypeLevel.title.font)
                        .foregroundStyle(ColorRole.text.color)
                    Text(app: "accounts.switcherHint")
                        .font(TypeLevel.footer.font)
                        .foregroundStyle(ColorRole.textQuiet.color)
                }
                HStack(alignment: .top, spacing: 70) {
                    ForEach(model.profile, id: \.identifier.rawValue) { profile in
                        circle(profile)
                    }
                    ForEach(
                        Self.actions(profile: model.profile.count, switchOnly: switchOnly),
                        id: \.self
                    ) { mutate in
                        handle(mutate)
                    }
                    if !switchOnly {
                        circleButton(
                            id: "einstellungen", character: Glyph.settings.name,
                            key: "settings.title", action: onSettings)
                    }
                }
            }
            .padding(60)
        }
        // **Focus starts at the signed-in account** — from there every other one is one
        // press away, and whoever only wanted to check who is watching has seen it.
        .onAppear {
            focus = model.active?.rawValue ?? model.profile.first?.identifier.rawValue
            titleProfile = focus
            openQuestions = ProfileSync.openQuestions(from: FileStore())
            escapes = ProfileEscapes.read(cloud: cloud, profile: model.profile)
        }
        .onReceive(NotificationCenter.default.publisher(for: .pinEscape)) { _ in
            escapes = ProfileEscapes.read(cloud: cloud, profile: model.profile)
        }
        .onChange(of: focus) { _, fresh in
            titleProfile = Self.titleID(
                focus: fresh, profile: model.profile.map(\.identifier.rawValue), previous: titleProfile)
        }
        #if os(tvOS)
            // **The number pad including "Forgot PIN" is the same as in the management**
            // (``ProfilePinSheet``) — since 2026-09-24 with the way out per profile
            // (``ProfileKit/PINFallback/Lock``), without the cloud without it.
            .fullScreenCover(item: $pinTarget) { target in
                ProfilePinSheet(
                    profile: target, cloud: cloud,
                    onSubmit: { open(target, using: $0) },
                    onCancel: { pinTarget = nil },
                    onUnlocked: {
                        pinTarget = nil
                        model.load()
                    })
            }
            .fullScreenCover(isPresented: $isCreating) {
                ProfileCreation(model: model, cloud: cloud) {
                    isCreating = false
                    model.load()
                }
            }
        #endif
    }

    /// The motif of the focused profile across the whole surface — **with a soft
    /// crossfade while wandering**, without it under "Reduce Motion".
    ///
    /// **`.id` per profile**, so that SwiftUI sees two images while wandering and fades between them
    /// instead of replacing one.
    private var titleImage: some View {
        let profile = model.profile.first { $0.identifier.rawValue == titleProfile }
        return ZStack {
            if let profile {
                ProfileTitleImage(avatar: profile.avatar, color: profile.color)
                    .id(profile.identifier.rawValue)
                    .transition(.opacity)
            }
        }
        .ignoresSafeArea()
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.45), value: titleProfile)
    }

    /// Checks the typed PIN against the target — **and switches right away on success.**
    ///
    /// **One pass and not two.** ``ProfileKit/ProfileSwitch`` checks the PIN and switches
    /// the session in the same call; a first "is that right?" and a second "then
    /// do it" would be two paths on which the second remained passable without the first.
    ///
    /// **Switched is switched, even without Jellyfin** (2026-09-25). Here
    /// `didSwitchSession == true` was the condition: A protected profile with only one
    /// channel list was switched, but the number pad reported "wrong" and stayed
    /// put — the session is only switched by someone who has a Jellyfin. Now the same rule
    /// as for a press without a PIN (``select(_:)``).
    private func open(_ target: Profile, using pin: String) -> Bool {
        guard let result = model.switchTo(zu: target.identifier, pin: pin).result else { return false }
        pinTarget = nil
        onSwitched(Self.session(after: result))
        return true
    }

    private func circle(_ profile: Profile) -> some View {
        let id = profile.identifier.rawValue
        let hasFocus = focus == id
        let active = profile.identifier == model.active
        return Button {
            select(profile)
        } label: {
            VStack(spacing: 18) {
                ZStack(alignment: .bottomTrailing) {
                    // **In focus the profile color yields to the light surface**, and that is
                    // not an inconsistency: Focus is the strongest statement on the
                    // screen, and two strong colors next to each other leave open which
                    // of the two is meant. The name below stays. **With a picture a
                    // light frame instead of the light surface** — reasoning at
                    // ``ProfileCircle/frame``.
                    ProfileCircle(
                        letter: profile.initial,
                        avatar: profile.avatar,
                        edge: 180,
                        font: TypeLevel.title.font,
                        letterColor: hasFocus ? ColorRole.reason.color : ColorRole.text.color,
                        surface: hasFocus
                            ? ColorRole.text.color : ProfileColor.tag(profile.color.rawValue),
                        frame: hasFocus ? ColorRole.text.color : nil)
                    if active {
                        Image(systemName: Glyph.done.pair.filled)
                            .font(.system(size: 44))
                            .foregroundStyle(ColorRole.brandLight.color)
                            .background(ColorRole.reason.color, in: Circle())
                    }
                }
                .scaleEffect(hasFocus ? 1.08 : 1)
                .animation(.easeOut(duration: 0.18), value: hasFocus)
                Text(profile.name)
                    .font(TypeLevel.footer.font)
                    .foregroundStyle(hasFocus ? ColorRole.text.color : ColorRole.textMatt.color)
                    .lineLimit(1)
                if profile.kind == .kind {
                    Label {
                        Text(app: "profiles.child")
                    } icon: {
                        Image(systemName: Glyph.kind.name)
                    }
                    .font(TypeLevel.lowercased.font)
                    .foregroundStyle(ColorRole.textQuiet.color)
                }
                // **Whose profile this is** (AP44 → AP45). Since AP44 a profile can
                // belong to a foreign Apple account; whoever sits in front then uses the
                // profile of someone else — and everything they do there is recorded with that person
                // on the device. That belongs at the place where one selects it, and not
                // in a sheet two levels deeper.
                if let from = sharedBy(profile) {
                    Text(app: "pairing.sharedBy \(from)")
                        .font(TypeLevel.lowercased.font)
                        .foregroundStyle(ColorRole.textQuiet.color)
                        .lineLimit(1)
                }
                // **"Merge?" — the question belongs on the circle, the answer in the
                // management** (AP45 ← AP48). Two profiles with the same
                // Jellyfin access and different names can be one person or
                // two who share an access; that is not decided by a
                // computation.
                //
                // **Why only the marker stands here:** Whoever just wants to watch should not
                // be held up by a management question — but they should see that
                // there is one. Without the marker they choose for weeks between two profiles
                // of the same name and never learn that this can be tidied up. The same split as
                // with "shared by" above: The information stands where one chooses.
                if mergeable(profile) {
                    Label {
                        Text(app: "profiles.mergeQuestion")
                    } icon: {
                        Image(systemName: Glyph.toBackfill.name)
                    }
                    .font(TypeLevel.lowercased.font)
                    .foregroundStyle(ColorRole.progress.color)
                }
                // **A running "forgot PIN" stands on the circle** (finding 6) — where
                // the one sits whose PIN is about to fall. Cancelling happens in the management.
                if escapes.state(forItem: profile.identifier) != nil {
                    ProfileEscapeMarker()
                }
            }
            .frame(width: 260)
        }
        .bareFocusableButton()
        .focused($focus, equals: id)
        .info(
            Text(verbatim: profile.name),
            [
                .chosen(active),
                .key(profile.kind == .kind ? "profiles.child" : nil),
                // **The question belongs in the spoken description too**, otherwise it is not there at all for
                // someone who has it read aloud — and they are the one to whom two
                // circles of the same name say the least.
                .key(mergeable(profile) ? "profiles.mergeQuestion" : nil),
                .key(
                    escapes.state(forItem: profile.identifier) != nil ? "profiles.pinResetMark" : nil),
            ])
    }

    /// Whether a question is open about this profile.
    private func mergeable(_ profile: Profile) -> Bool {
        ProfileSync.isInQuestion(profile.identifier, under: openQuestions)
    }

    /// Who shared this profile — `nil` if it belongs to this household.
    private func sharedBy(_ profile: Profile) -> String? {
        cloud?.zone(forItem: profile.identifier)?.sharedBy
    }

    /// A circle that is not a profile — "Add profile", "Edit profiles" and the
    /// settings. The same form as the profiles, so that the row remains a row; the
    /// symbol instead of a letter says that no person stands here.
    ///
    /// **The "+" has belonged to creating since 2026-09-25** (Decision 3 speaks of the
    /// "+" card).
    private func handle(_ mutate: Action) -> some View {
        let (character, key): (String, String) =
            switch mutate {
            case .create: (Glyph.add.name, "profiles.add")
            case .manage: (Glyph.manageAccounts.name, "profiles.manage")
            }
        let action: () -> Void =
            switch mutate {
            case .create: { isCreating = true }
            case .manage: onManage
            }
        return circleButton(id: mutate.rawValue, character: character, key: key, action: action)
    }

    private func circleButton(
        id: String, character: String, key: String, action: @escaping () -> Void
    ) -> some View {
        let hasFocus = focus == id
        return Button(action: action) {
            VStack(spacing: 18) {
                Image(systemName: character)
                    .font(.system(size: 64))
                    .foregroundStyle(hasFocus ? ColorRole.reason.color : ColorRole.textMatt.color)
                    .frame(width: 180, height: 180)
                    .background(
                        hasFocus ? ColorRole.text.color : ColorRole.surface.color,
                        in: Circle()
                    )
                    .scaleEffect(hasFocus ? 1.08 : 1)
                    .animation(.easeOut(duration: 0.18), value: hasFocus)
                Text(appKey: key)
                    .font(TypeLevel.footer.font)
                    .foregroundStyle(hasFocus ? ColorRole.text.color : ColorRole.textMatt.color)
            }
            .frame(width: 260)
        }
        .bareFocusableButton()
        .focused($focus, equals: id)
        .info(appKey: key)
    }

    /// **A press on the own profile does not switch but closes** — a switch
    /// to itself would rewrite a session without changing anything (``onStay``).
    ///
    /// **If the target carries a PIN, the number pad comes first** (AP45, 2026-09-23). Until
    /// then simply **nothing** happened here — the bolt in ``ProfileKit/ProfileSwitch``
    /// held, but on screen a silent lock could not be told apart from a
    /// broken button.
    /// What a press on a circle does — testable without a view.
    nonisolated enum Press: Equatable, Sendable { case wechseln, close }

    nonisolated static func press(to target: Profile.Identifier, active: Profile.Identifier?) -> Press {
        ProfilePicker.triggers(target, active: active) ? .wechseln : .close
    }

    private func select(_ profile: Profile) {
        guard Self.press(to: profile.identifier, active: model.active) == .wechseln else {
            onStay()
            return
        }
        let outcome = model.switchTo(zu: profile.identifier)
        switch Self.reply(to: outcome) {
        case .pin:
            pinTarget = profile
        case .switched:
            // **Always called, even without Jellyfin** (N-1): Until then the branch
            // without a session ended here silently — the sheet stayed open, and the parental controls
            // read the rule of the new profile only at the next occasion.
            onSwitched(Self.session(after: outcome.result))
        case .nothing:
            break
        }
    }
}
