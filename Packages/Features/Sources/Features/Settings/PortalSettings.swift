import Core
import DesignSystem
import Flows
import Household
import PortalKit
import ProfileKit
import SwiftUI

/// What concerns the portals — and that is deliberately little.
///
/// **The most conspicuous trait of this area is what is NOT here.** The
/// portal's script carries its own cache time, request timeout, a button
/// to clear its page cache, an image switch and a folder path. Five controls that
/// disappear — not because they were unimportant, but because they have become a
/// server matter and thus no longer the viewer's problem.
///
/// **The state sits at the very top, and that of the bridge.** Not the portals:
/// if it fails, everything below it is meaningless — and you should see that in the
/// first row and not after the third toggle.
///
/// **A defective portal is shown, not left out.** With the reason
/// next to it. If it were simply missing, you would search the app for something the server
/// has long recognised as broken.
struct PortalSettings: View {

    /// The source. `nil` means: no bridge is set up — then
    /// the address is shown here and nothing else.
    let source: PortalSource?
    /// The address as it is tried. Shown even when nothing
    /// answers: without it nobody knows where to look.
    let address: String
    /// After a changed address — the source is rebuilt above.
    let onBridgeChanged: () -> Void

    /// What is **entered**, not what applies.
    ///
    /// **Empty has meant "no portals" since 2026-09-12** and no longer "the default".
    /// Nothing is prefilled anyway: a written-out address looks like
    /// one that somebody has checked.
    @State private var input: String =
        BridgeAddress.load(from: SecureStore())?
        .absoluteString ?? ""
    @State private var stored = false
    /// The search on the home network is running.
    @State private var isSearching = false
    /// Searched and found nothing — **something other than "not yet searched".**
    @State private var notFound = false
    /// The input yielded no address — the old one stays.
    @State private var isUnusable = false
    @FocusState private var focus: String?
    @Environment(\.settingsEntryRequest) private var entryRequest

    /// What the bridge reported. `nil` means "not yet asked", an empty
    /// field means "asked and got nothing" — two different things, and the difference
    /// decides whether a loading hint or an error is shown here.
    @State private var portals: [ContentEntryRecord]?

    /// Portals on or off (``Core/PortalSwitch``) and which of them count towards Home and
    /// favourites (``Core/PortalPreferences``) — the same switches as on the phone
    /// (decision 27, C12).
    @State private var portalsEnabled = PortalSwitch.on(in: SecureStore())
    @State private var preferences = PortalPreferences.load(from: SecureStore())
    @State private var error: String?

    /// The state of the sign-in. `nil` means "not yet asked".
    ///
    /// **Everything below depends on it** — with the old bridge there is nothing to
    /// see here, with a server without a token there is only one thing to do.
    @State private var state: SignInState?
    /// The pairing code as typed.
    @State private var pairingCode = ""
    /// The server's refusal of a redemption attempt, as a sentence.
    @State private var pairingRefusal: String?
    @State private var isWorking = false
    /// The last sign-out failed (``PortalSignOut/Outcome/failed``) —
    /// the token therefore deliberately remains, see ``notify(from:)``.
    @State private var signOutFailed = false

    /// Whether the server accepts requests (`join` in `capabilities`). **Only then** is there the
    /// "request" path — an older server does not know it, and there it stays with the code.
    @State private var canJoin = false
    /// The state of the own request (AP47).
    @State private var requestState: RequestState = .none
    /// The approval page — `nil` if this sign-in carries no right to it.
    @State private var approval: JoinApprovalModel?

    struct ContentEntryRecord: Identifiable, Equatable {
        let id: String
        let name: String
        let ready: Bool
        let reason: String?
        /// What the portal is, in one sentence. Empty with the old bridge.
        let description: String
        /// What it **cannot** do, e.g. `drm_partial`.
        let limits: [String]
        /// Whether it carries adult content — **a label and not a lock.** The server does the hiding:
        /// to a child device it does not deliver such portals at all.
        let adult: Bool
    }

    private var reachable: Bool { error == nil && portals != nil }

    /// Whether the profile already has the CL-Server. Without profiles (before setup) the answer is yes.
    nonisolated static func isLinked(_ profile: Profile?) -> Bool {
        profile?.wantsPortals ?? true
    }

    /// What the "Portal service" row says about the server.
    ///
    /// **"Not reachable" only if it does not answer** (on-device test 2026-09-27). Until
    /// then every missing portal list was called that — even a server that had
    /// answered very clearly with `401
    /// auth.profile_required`: device known, person
    /// missing. You then searched the network for an error that lay in the sign-in.
    static func state(reachable: Bool, state: SignInState?) -> String {
        if reachable { return "settings.portals.reachable" }
        switch state {
        case .setupRequired, .notSignedIn, .profileRequired:
            return "settings.portals.signInMissing"
        default:
            return "settings.portals.unreachable"
        }
    }

    var body: some View {
        // **No second scroll area** (AP22, 2026-09-11). Another
        // unbounded `ScrollView(.vertical)` hung here inside content that is already in one
        // (``SettingsView`` builds one around every area). Two nested
        // scroll areas without a height limit share the scrolling on tvOS according to the
        // focus: the inner one takes it, the outer one does not move, and the content
        // below the edge stayed put. The eight remaining areas therefore deliver
        // only a `VStack` — the only deliberately nested one is the log list
        // in ``DiagnosticsSettings``, and it is limited to 620 pt and justified.
        VStack(alignment: .leading, spacing: 0) {
            SettingsHeader("tab.portals", hint: "settings.portals.hint")

            // **Link first, then switch** (owner, 2026-09-28): a new profile saw
            // "Show CL-Server ✓" and took the CL-Server to be set up. The switch
            // belongs to a profile that already has it; before that, choosing the person is the way.
            if Self.isLinked(ProfileBook.read(from: FileStore()).activeProfile) {
                SwitchRow(
                    title: "settings.portals.enabled",
                    message: "settings.portals.enabledHint",
                    on: Binding(
                        get: { portalsEnabled },
                        set: { fresh in
                            portalsEnabled = fresh
                            PortalSwitch.set(fresh, in: SecureStore())
                            onBridgeChanged()
                        }),
                    card: .toggle(
                        header: "settings.portals.enabled", on: portalsEnabled,
                        explanation: "settings.portals.enabledHint", validity: .profile),
                    identifier: "portals-enabled",
                    focus: $focus)
            }

            row(
                titleKey: "settings.portals.bridge",
                value: address,
                stateKey: Self.state(reachable: reachable, state: state),
                good: reachable
            )

            addressField

            signInArea

            if let error {
                Text(verbatim: error)
                    .font(TypeLevel.text.font)
                    .foregroundStyle(ColorRole.textQuiet.color)
                    .frame(maxWidth: 900, alignment: .leading)
                    .padding(.top, 14)
            }

            if let portals, !portals.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    // **The portal rows are at the same time the "In Home and
                    // favourites" switch** (decision 27, C12) — a press toggles, the checkmark
                    // on the right tells the state. Separate switch rows below would have cost one
                    // more focus target per portal (``FocusPlanTests``).
                    SettingsHeader("settings.portals.shared", hint: "settings.portals.sharedHint")
                    ForEach(portals) { portal in
                        portalRow(portal)
                    }
                }
                .padding(.top, 30)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.trailing, 40)
        // **The first target of this area** (AP23, 2026-09-11) — it was missing, and with it
        // there was no catcher at the content edge at all: the right press from the area list
        // assigned by geometry.
        //
        // **There are exactly two focus targets here**, the address field and the button
        // next to it; the portal rows are pure text. The save button as a landing spot
        // would be absurd — what is in the field is saved —, so the field. That
        // reaches the same target as before, only **chosen** instead of guessed.
        .preference(key: SettingsFirstEntryKey.self, value: "bridge")
        .onChange(of: entryRequest) { _, _ in focus = "bridge" }
        // **Ask again at every new address** (2026-09-12).
        //
        // Here used to be `.task { await load() }` — once on appearing. The address
        // can be **changed** on this screen, however, and afterwards it kept its
        // old verdict: the client pressed "Search the network", the field showed
        // the home server address with port 8100 and "Saved", and next to it still "not
        // reachable" together with "The portal service does not answer" — above a server that
        // answered perfectly well. The sign-in area stayed away as well, because it
        // deliberately does not exist for an unreachable address.
        //
        // **An old finding above a new address is worse than none:** it
        // looks like a statement about what you just entered.
        // **The focus trace here too** (2026-09-28): the page keeps a focus of its own, and
        // the settings' trace ended at its boundary with "content-entry → —". Whether a
        // press hit the person button could not be seen that way.
        .onChange(of: focus) { previous, now in
            Diagnostics.cursorMoved("CL-Server", from: previous, to: now)
        }
        .task(id: address) { await load() }
        // **Poll every 15 seconds, and only while this area is visible**
        // (AP47). That hangs on `.task` and not on a timer: SwiftUI cancels the
        // task as soon as the view disappears, and then nobody asks any more. A
        // waiting screen that nobody looks at does not need to know anything.
        .task(id: requestState.waiting) { await wait() }
    }

    // MARK: - Sign-in

    /// What there is to see and do for the sign-in — **exactly one thing per state.**
    ///
    /// **No branch says "something is wrong".** Every state carries its own sentence,
    /// and three of them carry none at all: with the old bridge there are no persons, with
    /// an empty address there is nothing to ask, and with a silent address the
    /// information is already in the row at the very top. A fourth "else" branch would be the
    /// place where something unexplained lands later.
    @ViewBuilder
    private var signInArea: some View {
        switch state {
        case nil, .bridge, .unreachable:
            // The bridge knows no persons; a silent address is explained above.
            EmptyView()

        case .setupRequired:
            hint("settings.portals.setupNeeded")

        case .appZuAlt(let version):
            Text(app: "settings.portals.appTooOld \(version)")
                .font(TypeLevel.text.font)
                .foregroundStyle(ColorRole.live.color)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 900, alignment: .leading)
                .padding(.top, 24)

        case .notSignedIn:
            // **Nobody types a PIN on the TV.** The console in the browser shows
            // a six-character code, and the TV redeems it — that is the whole
            // way in, and that is why there is no profile choice here.
            pairing
            // **And since AP47 the second way: request.** Only on a server that
            // knows it; the code stays next to it, because an administrator with a console is
            // faster than an approval.
            // **Not for child profiles** (counter-check of 2026-09-24): they get no
            // token, and their role is set by the administrator, not by a request.
            if canJoin, requestingProfile?.kind != .kind { requestArea }

        case .profileRequired(let people):
            profileChoice(people)

        case .signedIn(let person, let isBorrowed):
            if case .approved = requestState { requestOutcome.padding(.top, 24) }
            signedInRow(person, isBorrowed: isBorrowed)
            // **On the right and never on the role**, and never with a borrowed profile
            // — ``ApprovalRule/isVisible(_:)``.
            if ApprovalRule.isVisible(state), let approval {
                ApprovalList(model: approval, focus: $focus)
            }
        }
    }

    /// Whether the typed address insists on TLS.
    ///
    /// **On what is typed and not on what is stored.** The sentence should appear while
    /// someone is looking at the field — not only after they have saved and waited
    /// for the failure.
    private var isHttps: Bool {
        input.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased().hasPrefix("https://")
    }

    /// Whether the typed code can be redeemed.
    ///
    /// **As a question of its own, because it is asked twice** — once to grey out
    /// the button, and once to discard the press. Two expressions would drift
    /// apart, and the case then would be a button that looks grey and still
    /// works.
    private var isPairingReady: Bool {
        !isWorking && !pairingCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Type in and redeem the pairing code.
    private var pairing: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(app: "settings.portals.pairing")
                .font(TypeLevel.header.font)
                .foregroundStyle(ColorRole.text.color)

            HStack(spacing: 20) {
                // Visible and no password field — like the address above: on the
                // TV keyboard a typo is the rule, and behind dots it
                // cannot be found.
                // **``InputKind/identifier`` and not ``InputKind/address``.** A
                // six-character code is not an address; issued as one, the field
                // would get a `.URL` content type and thus completions that can only
                // get in the way here. What counts is common to both: nothing capitalised, nothing
                // corrected.
                //
                // **320 pt and not 620 like the address next to it:** a field that is as
                // wide as its longest content says without a word how much
                // belongs in it.
                InputRow(
                    title: "settings.portals.pairingPrompt", text: $pairingCode,
                    state: .alone, kind: .identifier, width: 320, identifier: "pairing",
                    focus: $focus)

                // **The house pattern now lives in the building block** (``ActionState/locked``):
                // stay focusable, look greyed out, discard the press in the
                // body. This place had first done it wrong and then right
                // by hand — the fourth version was read off from here.
                FormButton(
                    title: "settings.portals.redeem",
                    state: isPairingReady ? .ready : .locked,
                    rank: .main,
                    identifier: "redeem",
                    focus: $focus
                ) {
                    Task { await redeem(input: pairingCode) }
                }
            }

            // The refusal replaces the hint instead of standing below it: two sentences
            // on top of each other, one of which no longer applies, are harder to read
            // than one.
            if let pairingRefusal {
                Text(verbatim: pairingRefusal)
                    .font(TypeLevel.lowercased.font)
                    .foregroundStyle(ColorRole.live.color)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 900, alignment: .leading)
            } else {
                Text(app: "settings.portals.pairingHint")
                    .font(TypeLevel.lowercased.font)
                    .foregroundStyle(ColorRole.textQuiet.color)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 900, alignment: .leading)
            }
        }
        .padding(.top, 24)
        .onChange(of: pairingCode) { _, _ in pairingRefusal = nil }
    }

    // MARK: - Requests (AP47)

    /// The profile that requests — **the active one**, with its name and its colour.
    private var requestingProfile: Profile? {
        ProfileBook.read(from: FileStore()).activeProfile
    }

    private var requester: JoinRequester? {
        let keychain = SecureStore()
        guard let bridgeAddress = BridgeAddress.effective(from: keychain) else { return nil }
        return JoinRequester(
            basis: bridgeAddress, session: .shared, keychain: keychain,
            ledgerStore: FileStore(), deviceName: DeviceName.thisDevice, kind: .tv,
            lookUp: LanguageFallback.message, colorValue: ProfileBrand.value)
    }

    /// Request instead of pairing — **one button, one sentence, and while waiting a way
    /// back.**
    private var requestArea: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(app: "settings.portals.joinAsk")
                .font(TypeLevel.header.font)
                .foregroundStyle(ColorRole.text.color)

            if requestState.waiting {
                FormButton(
                    title: "settings.portals.joinCancel",
                    rank: .beside,
                    identifier: "join-cancel",
                    focus: $focus
                ) {
                    requester?.forget()
                    requestState = .none
                }
            } else {
                FormButton(
                    title: "settings.portals.joinRequest",
                    statusTitle: "settings.portals.joinRequesting",
                    state: isWorking ? .isRunning : (requestingProfile == nil ? .locked : .ready),
                    rank: .main,
                    identifier: "join-request",
                    focus: $focus
                ) {
                    Task { await query() }
                }
            }

            // **Locked says why** (finding 2026-11-09): without an active profile the press
            // did nothing, and nobody could see that.
            if requestingProfile == nil, !isWorking {
                Text(app: "settings.portals.joinNeedsProfile")
                    .font(TypeLevel.lowercased.font)
                    .foregroundStyle(ColorRole.textMatt.color)
            }

            requestOutcome
        }
        .padding(.top, 30)
    }

    /// The sentence for the state of the request — **honest per outcome.**
    private var requestOutcome: some View {
        Group {
            switch requestState {
            case .none:
                if let profile = requestingProfile {
                    Text(app: "settings.portals.joinHint \(profile.name)")
                        .foregroundStyle(ColorRole.textQuiet.color)
                } else {
                    Text(app: "settings.portals.joinNoProfile")
                        .foregroundStyle(ColorRole.textQuiet.color)
                }
            case .waiting:
                Text(app: "settings.portals.joinWaiting")
                    .foregroundStyle(ColorRole.textMatt.color)
            case .throttled(let seconds):
                // In minutes, rounded up: "57 minutes left" reads well, "3412 seconds"
                // does not.
                if let seconds {
                    Text(app: "settings.portals.joinThrottled \((seconds + 59) / 60)")
                        .foregroundStyle(ColorRole.live.color)
                } else {
                    Text(app: "settings.portals.joinThrottledSoon")
                        .foregroundStyle(ColorRole.live.color)
                }
            case .approved(let name, let withTag):
                if withTag {
                    Text(app: "settings.portals.joinApproved \(name)")
                        .foregroundStyle(ColorRole.success.color)
                } else {
                    Text(app: "settings.portals.joinApprovedNoMark \(name)")
                        .foregroundStyle(ColorRole.success.color)
                }
            case .rejected:
                Text(app: "settings.portals.joinDeclined")
                    .foregroundStyle(ColorRole.live.color)
            case .expired:
                Text(app: "settings.portals.joinExpired")
                    .foregroundStyle(ColorRole.live.color)
            case .failed(let message):
                Text(verbatim: message)
                    .foregroundStyle(ColorRole.live.color)
            case .notForChildren:
                Text(app: "settings.portals.joinNotForChildren")
                    .foregroundStyle(ColorRole.live.color)
            }
        }
        .font(TypeLevel.lowercased.font)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: 900, alignment: .leading)
    }

    private func query() async {
        guard let requester, let profile = requestingProfile else { return }
        isWorking = true
        defer { isWorking = false }
        requestState = await requester.location(forItem: profile)
    }

    /// The beat of the waiting — **once every 15 seconds, and only while waiting.**
    ///
    /// With "throttled" it waits as long as the server names, but at most a minute
    /// (``RequestState/spacing``). What a poll brings is decided by
    /// ``RequestState/afterInquiry(current:result:)`` — a request that has since been
    /// withdrawn does not come back that way.
    private func wait() async {
        while requestState.waiting {
            do {
                try await Task.sleep(for: .seconds(requestState.spacing))
            } catch {
                // bewusst still: `Task.sleep` throws only on cancellation. The view is gone —
                // and with it the reason to ask.
                return
            }
            guard let requester else { return }
            let result = await requester.queryPending()
            guard let fresh = RequestState.afterInquiry(current: requestState, result: result)
            else { continue }
            requestState = fresh
            if case .approved = fresh {
                onBridgeChanged()
                await load()
            }
        }
    }

    /// Who the **active profile** is on the portals server — **an assignment and not a
    /// switcher** (AP45, "One switcher", 2026-09-25).
    ///
    /// **Until here there was a second "Who is watching?" at this place**: a person choice
    /// that set only the device's header and not the profile — next to the switcher that
    /// chooses profiles. Two switchers for one question. It could not simply be dropped
    /// without replacement, though (finding of 2026-09-23): it was the **only** way to give a profile a server person
    /// that it had not received through an approval (AP47) — a household whose
    /// server holds more persons than there are profiles with portals access would otherwise no longer reach the
    /// rest.
    ///
    /// **Now the person belongs to the profile** (``Household/PortalAssignment``): the choice writes
    /// ``ProfileKit/Access/portals(person:)`` into the active profile, and from then on every switch
    /// in "Who is watching?" sets the header by itself (``ProfileKit/ProfileSwitch``). Switching
    /// happens only there. Whoever needs another person creates a profile and assigns
    /// them to it.
    ///
    /// **Still without a PIN** — on the household TV the age approval is an agreement
    /// within the household and not a lock (decision 2026-09-11).
    private func profileChoice(_ people: [HouseholdPerson]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(app: "settings.portals.assignTitle \(requestingProfile?.name ?? "")")
                .font(TypeLevel.header.font)
                .foregroundStyle(ColorRole.text.color)

            HStack(spacing: 20) {
                ForEach(people) { person in
                    Button {
                        guard !isWorking else {
                            Diagnostics.network.info(
                                "CL-Server: person choice dropped, something is still running")
                            return
                        }
                        Task { await select(person) }
                    } label: {
                        HStack(spacing: 12) {
                            Circle()
                                .fill(ProfileColor.from(person.color) ?? ColorRole.textMatt.color)
                                .frame(width: 22, height: 22)
                            Text(verbatim: person.name)
                                .font(TypeLevel.text.font)
                                .settingsFont(
                                    isFocused: focus == "person-" + person.id, muted: isWorking)
                        }
                        .settingsSurface(
                            .pill, isFocused: focus == "person-" + person.id)
                    }
                    .bareFocusableButton()
                    .focused($focus, equals: "person-" + person.id)
                }
            }

            Text(app: "settings.portals.assignHint")
                .font(TypeLevel.lowercased.font)
                .foregroundStyle(ColorRole.textQuiet.color)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 900, alignment: .leading)
        }
        .padding(.top, 24)
    }

    /// Who is signed in — and the way out.
    private func signedInRow(_ person: HouseholdPerson, isBorrowed: Bool) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 18) {
                Text(app: "settings.portals.signedIn")
                    .font(TypeLevel.text.font)
                    .foregroundStyle(ColorRole.text.color)
                    .frame(width: 220, alignment: .leading)

                HStack(spacing: 12) {
                    Circle()
                        .fill(ProfileColor.from(person.color) ?? ColorRole.textMatt.color)
                        .frame(width: 14, height: 14)
                    Text(verbatim: person.name)
                        .font(TypeLevel.text.font)
                        .foregroundStyle(ColorRole.textMatt.color)
                    // **Borrowing is named.** A profile that may watch and not
                    // manage otherwise looks like a full sign-in — and
                    // the difference is noticed only when a button has no effect.
                    if isBorrowed {
                        Text(app: "settings.portals.borrowed")
                            .font(TypeLevel.lowercased.font)
                            .foregroundStyle(ColorRole.textQuiet.color)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Button {
                    guard !isWorking else { return }
                    Task { await notify(from: isBorrowed) }
                } label: {
                    Text(app: isBorrowed ? "settings.portals.switchProfile" : "common.signOut")
                        .font(TypeLevel.footer.font)
                        .settingsFont(isFocused: focus == "signout", muted: true)
                        .settingsSurface(.pill, isFocused: focus == "signout")
                }
                .bareFocusableButton()
                .focused($focus, equals: "signout")
            }
            .frame(maxWidth: 900, alignment: .leading)

            // A failed sign-out stays until it works — see
            // ``notify(from:)`` and ``PortalSignOut/Outcome/failed``.
            if signOutFailed {
                Text(app: "settings.portals.signOutFailed")
                    .font(TypeLevel.lowercased.font)
                    .foregroundStyle(ColorRole.live.color)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 900, alignment: .leading)
            }
        }
        .padding(.top, 24)
    }

    private func hint(_ key: String) -> some View {
        Text(appKey: key)
            .font(TypeLevel.text.font)
            .foregroundStyle(ColorRole.textQuiet.color)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: 900, alignment: .leading)
            .padding(.top, 24)
    }

    // MARK: - Actions

    /// Redeem a pairing code.
    ///
    /// **Typed in lowercase it is the same code.** The server writes six-character codes in capitals; whoever
    /// types it in lowercase from the remote means the same one, and rejecting it for that
    /// would be harassment. Nothing is transformed here — the server accepts both.
    private func redeem(input code: String) async {
        // **The same redemption as the setup's child pairing** (AP88 wave 4) — reader, sign-in
        // and profile entry live in ``ClServerCalls/redeem(_:at:keychain:ledgerStore:)``.
        guard let bridgeAddress = BridgeAddress.effective(from: SecureStore()) else { return }
        isWorking = true
        defer { isWorking = false }
        switch await ClServerCalls.redeem(code, at: bridgeAddress) {
        case .paired:
            pairingCode = ""
            onBridgeChanged()
            await load()
        case .refused(let sentence):
            pairingRefusal = sentence
        }
    }

    /// Assign the person to the active profile — without a PIN, see ``profileChoice(_:)``.
    private func select(_ person: HouseholdPerson) async {
        isWorking = true
        defer { isWorking = false }
        let assigned = PortalAssignment.borrow(
            person.id, ledgerStore: FileStore(), keychain: SecureStore())
        // Without a name — the person's identifier is enough for looking it up on the server.
        Diagnostics.network.info(
            "CL-Server: person chosen, \(assigned ? "entered" : "NOT entered (no active profile)") on the profile"
        )
        onBridgeChanged()
        await load()
    }

    /// Sign out — or, with a borrowed profile, only return the loan.
    ///
    /// **Two different things behind one button, and the button is labelled differently.**
    /// Signing out a borrowed profile would mean unpairing the TV because someone
    /// else wants to watch — the token stays, only the loan ends.
    ///
    /// **The procedure lives in ``PortalSignOut``**, so it can be checked without a view: there,
    /// signing out also locks the profile's token against self-sign-in.
    ///
    /// **A failure stays visible** (finding 2026-09-27, e1): without a server address
    /// or with a failed sign-out the token stays there — the view
    /// shows that instead of pretending to be signed out, and the button stays there for
    /// another attempt.
    private func notify(from isBorrowed: Bool) async {
        isWorking = true
        defer { isWorking = false }
        signOutFailed = false
        let keychain = SecureStore()
        let result = await PortalSignOut.notify(
            from: isBorrowed, basis: BridgeAddress.effective(from: keychain),
            session: .shared, keychain: keychain, ledgerStore: FileStore())
        signOutFailed = result == .failed
        onBridgeChanged()
        await load()
    }

    // MARK: - Rows

    @ViewBuilder
    /// The input field for the address of the bridge.
    ///
    /// **What is NOT here remains the most conspicuous trait of this area:** which
    /// portals exist, the app cannot change — App Store rules 5.2.1 and 5.2.2.
    /// **Where the bridge runs is something else:** that is a machine of the viewer,
    /// just like the address of the media server, and there is no
    /// App Store reason for it. Without this field the address was hard-wired, and the
    /// portals worked only where the home server's portal host name resolves.
    private var addressField: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 20) {
                // Visible and no password field — like with the access keys
                // next door: on the TV keyboard a typo is the rule, and
                // behind dots it cannot be found.
                InputRow(
                    title: "settings.portals.bridgePrompt", text: $input, state: .alone,
                    kind: .address, width: 620, identifier: "bridge", focus: $focus)

                FormButton(
                    title: "settings.saveKey",
                    statusTitle: "settings.keySaved",
                    state: stored ? .done : .ready,
                    rank: .main,
                    identifier: "save-bridge",
                    focus: $focus
                ) {
                    // **A mistyped entry must not switch the portals off.**
                    // That is why only what yields an address is accepted; otherwise
                    // the old one stays and the row below says so.
                    isUnusable = !BridgeAddress.save(input, to: SecureStore())
                    stored = !isUnusable
                    if stored { onBridgeChanged() }
                }

                // **The button that saves the typing** (2026-09-12).
                //
                // **Typing in is the most expensive operation this app knows on a
                // TV** — `AccountState` says so, and an IP with dots
                // and a colon on a letter keyboard is the worst
                // case of it. On the home network the server announces itself
                // (``PortalKit/ServerLookup``, `_cinelounge._tcp`, long since registered in the TV's
                // Info entry), and the phone has been asking it when redeeming an
                // invitation since 2026-09-12. The TV lacked it — where it
                // is worth the most.
                //
                // **What is found is entered and saved, not merely suggested.**
                // A suggestion that you then still have to confirm is, on this
                // keyboard, a second way to the same goal.
                // No `.disabled` during the search — that now lives in
                // ``ActionState/isRunning``, together with the hourglass and the busy information.
                FormButton(
                    title: "settings.portals.findServer",
                    statusTitle: "settings.portals.searching",
                    state: isSearching ? .isRunning : .ready,
                    rank: .beside,
                    identifier: "find-bridge",
                    focus: $focus
                ) {
                    isSearching = true
                    notFound = false
                    Task {
                        let found = await ServerLookup.find()
                        isSearching = false
                        guard let found else {
                            notFound = true
                            return
                        }
                        input = found.absoluteString
                        isUnusable = !BridgeAddress.save(input, to: SecureStore())
                        stored = !isUnusable
                        if stored { onBridgeChanged() }
                    }
                }
            }
            // A word that emptying does not mean switching off.
            Text(app: isUnusable ? "settings.portals.bridgeBad" : "settings.portals.bridgeHint")
                .font(TypeLevel.lowercased.font)
                .foregroundStyle(isUnusable ? ColorRole.live.color : ColorRole.textQuiet.color)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 900, alignment: .leading)

            // **The one typo that cost an evening** (2026-09-12): in the
            // simulator the address was `https://<portal-host>:8099`. Both services listen on the
            // home network in plain text — for the server that is intentional, so a TV
            // does not fail on a certificate chain that protects nothing there. The
            // request thus went nowhere, and the screen said "not reachable"
            // and "The portal service does not answer": both true, both useless.
            // After that the whole sign-in area was missing too, because it deliberately does not exist
            // for a silent address — a pair of characters became a screen
            // that looked like before the changeover.
            if isHttps {
                Text(app: "settings.portals.plainOnly")
                    .font(TypeLevel.lowercased.font)
                    .foregroundStyle(ColorRole.live.color)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 900, alignment: .leading)
            }

            // **"Searched and found nothing" is information, not an error.** The sentence
            // names the two conditions under which the search finds something — the
            // server is running, and this TV is on the same network.
            if notFound {
                Text(app: "settings.portals.notFound")
                    .font(TypeLevel.lowercased.font)
                    .foregroundStyle(ColorRole.textQuiet.color)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 900, alignment: .leading)
            }
        }
        .padding(.top, 20)
        .onChange(of: input) { _, _ in
            stored = false
            isUnusable = false
        }
    }

    /// **This row may stay mute, the portal rows may not** (AP26, row building blocks).
    ///
    /// The axis is not "focusable yes/no" but: **is there another focus target
    /// below this row in the same scroll frame?** Here yes — address field and
    /// save button are below, the focus passes them and brings the
    /// row into view.
    private func row(titleKey: String, value: String, stateKey: String, good: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 18) {
            Text(appKey: titleKey)
                .font(TypeLevel.text.font)
                .foregroundStyle(ColorRole.text.color)
                .frame(width: 220, alignment: .leading)

            Text(verbatim: value)
                .font(TypeLevel.text.font)
                .foregroundStyle(ColorRole.textMatt.color)
                .frame(maxWidth: .infinity, alignment: .leading)

            // The green dot is no decoration: if the bridge fails, the
            // areas stay empty, and without this row that would look like a
            // broken portal.
            HStack(spacing: 10) {
                Circle()
                    // `ColorRole.success` and not a raw `Color.green`: a
                    // signal green glows out of the picture on the dark surface of this app
                    // and draws the eye away from what matters — the full
                    // reasoning is at
                    // ``Styling/ColorRole/success``.
                    .fill(good ? ColorRole.success.color : ColorRole.textQuiet.color)
                    .frame(width: 12, height: 12)
                Text(appKey: stateKey)
                    .font(TypeLevel.text.font)
                    .foregroundStyle(ColorRole.textMatt.color)
            }
        }
        .frame(maxWidth: 900, alignment: .leading)
        .padding(.vertical, 12)
    }

    /// **And these rows may not** — they come last in the area.
    ///
    /// They were pure text, and with that the portal list on tvOS was **unreachable
    /// as soon as it extends past the screen edge**: below the save button there is then
    /// no focus target any more, so nothing scrolls any more, so everything below it does not
    /// exist. The area even says so itself — "the portal rows are pure
    /// text" stood there as the reason for the choice of the first target, without anyone having
    /// thought the consequence through.
    ///
    /// Now a ``RowKind/readingRow``: selectable, but without effect and with the
    /// quieter highlight — it is no invitation to press.
    private func portalRow(_ portal: ContentEntryRecord) -> some View {
        Button {
            preferences.countTogether(portal.id, !preferences.countsTogether(portal.id))
            preferences.save(to: SecureStore())
        } label: {
            portalRowContent(portal)
        }
        .bareFocusableButton()
        .focused($focus, equals: "portal-" + portal.id)
        .info(Text(verbatim: portal.name), .on(!preferences.countsTogether(portal.id)))
    }

    @ViewBuilder
    private func portalRowContent(_ portal: ContentEntryRecord) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 18) {
            // The same glyph as in the sidebar — a portal looks the same
            // everywhere. And not that of the Live providers: see ``AppSidebar``.
            Image(systemName: portal.ready ? "network" : "exclamationmark.triangle.fill")
                .font(.system(size: 22))
                // `ColorRole.live` is the in-house colour for "something is wrong
                // here" (``HomeView``, ``LibraryView``, ``PlaylistSettings``). A
                // raw `Color.orange` was a fourth warning colour next to three identical ones.
                .foregroundStyle(portal.ready ? ColorRole.textMatt.color : ColorRole.live.color)
                .frame(width: 34, alignment: .leading)

            Text(verbatim: portal.name)
                .font(TypeLevel.text.font)
                .foregroundStyle(ColorRole.text.color)
                .frame(width: 220, alignment: .leading)

            // **The reason displaces the description instead of standing below it.**
            // Whoever comes here because something is missing should read it without another press —
            // and what the portal would be if it worked is then the less important half.
            // Both side by side would be too much in one row.
            Text(verbatim: portal.reason ?? secondaryLine(portal))
                .font(TypeLevel.text.font)
                .foregroundStyle(ColorRole.textQuiet.color)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)

            // **The "18+" label labels and does not lock.** The server locked
            // long ago: to a child device it does not deliver such portals at all,
            // and a direct call of their addresses gives 403. If the portal is listed here,
            // this person may see it — the label only says what is inside.
            if portal.adult {
                Text(app: "settings.portals.adult")
                    .font(TypeLevel.lowercased.font)
                    .foregroundStyle(ColorRole.textQuiet.color)
            }

            if !portal.ready {
                Text(appKey: "settings.portals.broken")
                    .font(TypeLevel.text.font)
                    .foregroundStyle(ColorRole.live.color)
            }

            // **The checkmark is called "own area"** (AP59 N7, 2026-09-30) — before it was called
            // "in the shared shelves", and whoever looked for their own Continue Watching found
            // it behind a checkmark that had to be deselected for it.
            let own = !preferences.countsTogether(portal.id)
            Image(
                systemName: own
                    ? Glyph.done.pair.filled : Glyph.done.pair.outlined
            )
            .font(TypeLevel.footer.font)
            .settingsFont(isFocused: focus == "portal-" + portal.id, muted: !own)
        }
        .frame(maxWidth: 900, alignment: .leading)
        .settingsSurface(
            .readingRow, isFocused: focus == "portal-" + portal.id, reason: .clear)
    }

    /// What stands next to the name as long as the portal is fine.
    ///
    /// **Limits take precedence over the description.** A description says what a portal
    /// is; a limit says what it cannot do — and the second is needed before
    /// starting anything. `drm_partial` means: it looks complete and is not.
    ///
    /// **An unknown limit is shown as a code, not concealed.** That way
    /// a gap in the catalog is noticed instead of silently disappearing — the same rule as with
    /// the server's refusals.
    private func secondaryLine(_ portal: ContentEntryRecord) -> String {
        let wordings = portal.limits.map { LanguageFallback.message("limit." + $0) ?? $0 }
        guard wordings.isEmpty else { return wordings.joined(separator: " · ") }
        return portal.description
    }

    // MARK: - Loading

    /// The state — **with the self-sign-in before it and, if needed, after it** (AP47).
    ///
    /// On opening: a device without a token whose profile carries a person token signs
    /// in by itself. Afterwards: if a token is there and the state still says "not
    /// signed in", the server has rejected it (`auth.required`) — after a revocation
    /// the device quietly signs in again with the new token. **At most one attempt
    /// per occasion**, and for a token that has already failed none at all.
    ///
    /// **And when signed in: carry the token forward** (``TokenReconciliation``). Here, after a
    /// revocation, the new token goes into the profile, from where the fallen devices read it.
    private func determineState(_ bridgeAddress: URL, _ keychain: SecureStore) async -> SignInState {
        func queryState() async -> SignInState {
            await Household.state(
                basis: bridgeAddress,
                trait: DeviceTrait.load(from: keychain),
                profile: DeviceTrait.profile(from: keychain))
        }
        if await SelfSignIn.onDevice()?.attempts(.open) == .signedIn {
            onBridgeChanged()
        }
        var fresh = await queryState()
        if case .notSignedIn = fresh, DeviceTrait.signedIn(in: keychain),
            await SelfSignIn.onDevice()?.attempts(.dismissed) == .signedIn
        {
            onBridgeChanged()
            fresh = await queryState()
        }
        if case .signedIn(let me, let isBorrowed) = fresh,
            await TokenReconciliation.onDevice()?.reconcile(me: me, isBorrowed: isBorrowed) == .fresh
        {
            onBridgeChanged()
            fresh = await queryState()
        }

        // **Requests exist only where signing in is required** — and only on a server
        // that reports `join`. The second question to the server costs only whoever needs it.
        if case .notSignedIn = fresh {
            canJoin =
                (try? await ServerVersion.probe(bridgeAddress))?.version?.canJoin ?? false
        } else {
            canJoin = false
        }
        if let requester {
            requestState = await requester.afterState(fresh, previous: requestState)
        }
        approval =
            ApprovalRule.isVisible(fresh)
            ? JoinApprovalModel.onDevice(lookUp: LanguageFallback.message) : nil
        return fresh
    }

    private func load() async {
        let keychain = SecureStore()
        // **The state first and independent of the source.** Without a token there is no
        // portal list, but very much something to do — and exactly that would not be visible
        // if this screen aborted at `source == nil`.
        if let bridgeAddress = BridgeAddress.effective(from: keychain) {
            state = await determineState(bridgeAddress, keychain)
        } else {
            state = nil
            canJoin = false
            approval = nil
        }

        guard let source else {
            error = nil
            portals = []
            return
        }
        do {
            // **One request and not two** (2026-09-12): ``PortalRow`` brings
            // capabilities, description and limits along instead of fetching them afterwards.
            let found = try await source.portalRows()
            portals = found.map {
                ContentEntryRecord(
                    id: $0.id, name: $0.name, ready: $0.ready, reason: $0.reason,
                    description: $0.description, limits: $0.limits, adult: $0.adult)
            }
            error = nil
        } catch let rejection as PortalBridge.TestError {
            Diagnostics.defect(
                "Portal list rejected: \(Diagnostics.explain(rejection))", since: nil, area: "Oberfläche")
            // **The reason in plain text, not "does not work".** The bridge sends it
            // verbatim; the server sends a code, and the app translates it —
            // if the translation is missing, the code is shown and not an empty field.
            error = rejection.message(lookUp: LanguageFallback.message)
            portals = nil
        } catch let thrownError {
            Diagnostics.defect(
                "Portal list not loaded: \(Diagnostics.explain(thrownError))", since: nil,
                area: "Oberfläche")
            error = thrownError.localizedDescription
            portals = nil
        }
    }
}
