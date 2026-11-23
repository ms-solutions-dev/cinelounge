import Core
import DesignSystemPhone
import Diagnose
import Flows
import Household
import Observation
import PortalKit
import ProfileKit
import SwiftUI

/// Area 2 · Portals — **two things, and only one of them is unchangeable.**
///
/// **Until 2026-09-06 the screen said "There is nothing to set here, and that is intended."**
/// The sentence was half right, and the other half was found by a product requirement: the
/// settings need an area somewhere where the portal URL can be maintained. — Yes. The
/// sentence lumped together two things that have nothing to do with each other:
///
/// * **Which portals exist** cannot be changed by the app. That is the answer to an App
///   Store rule and must not be loosened — ``PortalsHint`` stands for that.
/// * **Where the bridge runs** is a computer of the viewer, just like the address of the
///   media server. There is no App Store reason for that.
///
/// **And without the field the address was hard-wired.** `PortalBridge.standard()` knows
/// `portals.example:8099`, and `CINELOUNGE_PORTALE` exists only in the simulator. On a real
/// phone the portals therefore worked **only** where this one name resolves. For this
/// household that went unnoticed; for any other the whole area would have been dead.
///
/// **Three cards instead of four dividers (2026-09-07).** Switch, bridge and the own areas each
/// sit in one card; the unchangeable part at the very bottom carries none — in this area a
/// card means "something can be done here".
///
/// **Checking happens on request and not on opening.** A screen that opens a connection
/// every time it appears costs one even when someone only wanted to look at what is
/// entered.
struct PortalSettingsView: View {
    @Environment(\.horizontalSizeClass) private var widthClass

    @State private var model = PortalSettingsModel()

    var body: some View {
        ZStack {
            ColorRole.reason.color.ignoresSafeArea()

            ScrollSurface {
                VStack(alignment: .leading, spacing: 0) {
                    // **The switch that did not exist here** (2026-09-07): the portals could only be switched on
                    // during setup; whoever had skipped the step there found no way afterwards — and the value
                    // column said "off" while the tab was running in the simulator.
                    SettingsCard {
                        SwitchRow(
                            title: "settings.portals.enabled",
                            message: "settings.portals.enabled.footnote",
                            on: Binding(
                                get: { model.desired },
                                set: { model.set(portals: $0) }))
                    }

                    SettingsCard(header: "settings.portals.bridge") {
                        InputField(
                            text: $model.address,
                            placeholder: "settings.portals.bridgePrompt",
                            kind: .address
                        )
                        .padding(Metrics.cardInset)

                        // **The buttons belong in the card, and so does the message.**
                        // Check and Reset act on the field above; if they stood below
                        // it on the background, they would be two buttons without a
                        // visible subject.
                        buttons

                        if let status = model.status {
                            HintRow(
                                icon: status.good
                                    ? Glyph.done.pair.outlined : Glyph.offline.name,
                                color: status.good ? ColorRole.success.color : ColorRole.progress.color,
                                title: status.good
                                    ? "settings.portals.bridge.ok"
                                    : "settings.portals.bridge.silent",
                                wording: status.message)
                        }
                    }

                    Footnote(message: "settings.portals.bridge.footnote")
                        .padding(.bottom, MetricsBoard.phone.section)

                    login

                    ownAreas

                    // **The part that really is unchangeable.** It stands below the
                    // field and not in its place — otherwise "nothing to
                    // set" reads like a statement about the address above.
                    //
                    // **And it carries no card.** In this area a card is the
                    // sign for "something can be done here"; a sentence together with
                    // ``PortalsHint`` is the opposite of that.
                    SectionHeader(title: "settings.portals.title")
                    Footnote(message: "settings.portals.text")
                    PortalsHint().padding(.horizontal, MetricsBoard.phone.margin)
                }
                .contentColumn(widthClass)
                .padding(.top, MetricsBoard.phone.gutter)
            }
        }
        .task {
            await model.loadState()
            await model.loadPortals()
        }
        .task(id: model.requestState.waiting) { await model.awaitApproval() }
    }

    /// The sign-in — **exactly one shown per situation.**
    ///
    /// **Three situations show no card at all:** with the old bridge there are no people, with an
    /// empty address there is nothing to ask, and with a silent address the information is
    /// already in the notice row above. In this area a card is the sign for "something can be
    /// done here" — without anything to do it would be a call into the void.
    @ViewBuilder
    private var login: some View {
        switch model.state {
        case nil, .unreachable:
            // **The invitation is visible here too, and that is the finding of 2026-09-12**
            // Here stood `EmptyView()`, because without a usable address there was supposedly nothing
            // to do. That was exactly wrong: an invitation BRINGS the address along — it is the way
            // for someone who has not set anything up yet, and it was invisible in exactly the
            // situation in which it is needed. Someone therefore typed the link into the address field;
            // there was no other.
            SettingsCard(header: "settings.portals.account") {
                invitationRow(withProfileHint: false)
            }

        case .bridge:
            // Not an error but information: this service knows no people.
            // **The invitation is shown anyway** — it carries its own address, and
            // whoever redeems it switches from the fallback path to the server.
            Footnote(message: "settings.portals.bridgeService")
            SettingsCard(header: "settings.portals.account") {
                invitationRow(withProfileHint: false)
            }

        case .setupRequired:
            Footnote(message: "settings.portals.setupNeeded")
                .padding(.bottom, MetricsBoard.phone.section)

        case .appZuAlt(let version):
            HintRow(
                icon: Glyph.offline.name, color: ColorRole.progress.color,
                title: "settings.portals.account",
                wording: String(
                    format: LanguageFallback.message("settings.portals.appTooOld %@")
                        ?? "%@", version)
            )
            .padding(.bottom, MetricsBoard.phone.section)

        case .notSignedIn(let people), .profileRequired(let people):
            SettingsCard(header: "settings.portals.account") {
                if let selected = model.selected {
                    pinRow(selected, hasMultiple: people.count > 1)
                } else {
                    // **The invitation sits above the profile choice**, because it is the way
                    // for someone who has not set anything up yet: it brings
                    // the address along and needs no PIN. Whoever is already set up
                    // finds their profile below.
                    invitationRow(withProfileHint: !people.isEmpty)
                    if !people.isEmpty {
                        Separator()
                        profileChoice(people)
                    }
                }
            }
            Footnote(message: "settings.portals.account.footnote")
                .padding(.bottom, MetricsBoard.phone.section)

            if model.canJoin {
                JoinRequest(model: model)
            }

        case .signedIn(let person, _):
            SettingsCard(header: "settings.portals.account") {
                VStack(alignment: .leading, spacing: MetricsBoard.phone.gutter) {
                    HStack(spacing: MetricsBoard.phone.gutter) {
                        Circle()
                            .fill(ProfileColor.from(person.color) ?? ColorRole.textMatt.color)
                            .frame(width: 26, height: 26)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(app: "settings.portals.signedIn")
                                .font(TypeLevel.label.font)
                                .foregroundStyle(ColorRole.textMatt.color)
                            Text(verbatim: person.name)
                                .font(TypeLevel.text.font)
                                .foregroundStyle(ColorRole.text.color)
                        }
                        Spacer(minLength: 0)
                    }

                    Button {
                        Task { await model.signOut() }
                    } label: {
                        Text(appKey: model.isReporting ? "action.wait" : "common.signOut")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.quiet)
                    .disabled(model.isReporting)

                    // A failed sign-out stays visible until it works — see
                    // ``PortalSettingsModel/signOut()``.
                    if model.signOutFailed {
                        Text(app: "settings.portals.signOutFailed")
                            .font(TypeLevel.label.font)
                            .foregroundStyle(ColorRole.live.color)
                    }
                }
                .padding(Metrics.cardInset)
            }
            Footnote(message: "settings.portals.account.footnote")
                .padding(.bottom, MetricsBoard.phone.section)

            if let approval = model.approval {
                JoinApproval(model: approval)
            }
        }
    }

    /// Redeem an invitation or a pairing code.
    ///
    /// **One field for three notations** — link, address with a query part, bare password.
    /// Whoever copies an invitation from a message has a link; whoever types a code has none.
    /// Both mean the same, and two fields would mean letting the viewer decide what the server
    /// recognizes on its own anyway.
    ///
    /// - Parameter mitProfilhinweis: Whether a profile choice follows below. **Without it the
    ///   "or with profile and PIN" is dropped** — a pointer to something that is not there is
    ///   worse than none.
    @ViewBuilder
    private func invitationRow(withProfileHint: Bool) -> some View {
        VStack(alignment: .leading, spacing: MetricsBoard.phone.gutter) {
            Text(app: "settings.portals.invite")
                .font(TypeLevel.label.font)
                .foregroundStyle(ColorRole.textMatt.color)

            InputField(
                text: Binding(get: { model.invitation }, set: { model.invitation = $0 }),
                placeholder: "settings.portals.invitePrompt", kind: .address)

            if let rejection = model.invitationDecline {
                HintRow(
                    icon: Glyph.offline.name, color: ColorRole.progress.color,
                    title: "settings.portals.invite", wording: rejection)
            } else {
                Footnote(message: "settings.portals.inviteHint")
            }

            Button {
                Task { await model.redeem(code: model.invitation) }
            } label: {
                Text(appKey: model.isReporting ? "action.wait" : "settings.portals.redeem")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.loud)
            .disabled(model.isReporting || model.invitation.isEmpty)

            if withProfileHint {
                Text(app: "settings.portals.orPin")
                    .font(TypeLevel.label.font)
                    .foregroundStyle(ColorRole.textMatt.color)
                    .frame(maxWidth: .infinity, alignment: .center)
            }
        }
        .padding(Metrics.cardInset)
    }

    /// The profile choice — **name, color, role, and no PIN hint.**
    ///
    /// The list is deliberately harmless: whoever intercepts it knows who lives here, and
    /// nothing more. No number of attempts, no hint about the PIN.
    private func profileChoice(_ people: [HouseholdPerson]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(app: "settings.portals.whoAreYou")
                .font(TypeLevel.label.font)
                .foregroundStyle(ColorRole.textMatt.color)
                .padding(.horizontal, Metrics.cardInset)
                .padding(.top, Metrics.cardInset)

            ForEach(Array(people.enumerated()), id: \.element.id) { slot, person in
                if slot > 0 { Separator() }
                Button {
                    model.selected = person
                } label: {
                    HStack(spacing: MetricsBoard.phone.gutter) {
                        Circle()
                            .fill(ProfileColor.from(person.color) ?? ColorRole.textMatt.color)
                            .frame(width: 26, height: 26)
                        Text(verbatim: person.name)
                            .font(TypeLevel.text.font)
                            .foregroundStyle(ColorRole.text.color)
                        Spacer(minLength: 0)
                        Image(systemName: Glyph.next.name)
                            .font(TypeLevel.label.font)
                            .foregroundStyle(ColorRole.textMatt.color)
                    }
                    .padding(Metrics.cardInset)
                }
                .buttonStyle(.plain)
            }
        }
    }

    /// The PIN for a chosen person.
    ///
    /// **The rejection does not say what was wrong.** An unknown person and a wrong PIN give the
    /// same answer from the server, and that is intended — revealing through two different texts
    /// here which of the two applied would mean telling a stranger which names to try next.
    private func pinRow(_ person: HouseholdPerson, hasMultiple: Bool) -> some View {
        VStack(alignment: .leading, spacing: MetricsBoard.phone.gutter) {
            HStack(spacing: MetricsBoard.phone.gutter) {
                Circle()
                    .fill(ProfileColor.from(person.color) ?? ColorRole.textMatt.color)
                    .frame(width: 26, height: 26)
                Text(verbatim: person.name)
                    .font(TypeLevel.text.font)
                    .foregroundStyle(ColorRole.text.color)
                Spacer(minLength: 0)
            }

            InputField(
                text: Binding(get: { model.pin }, set: { model.pin = $0 }),
                placeholder: "settings.portals.pinPrompt", kind: .password)

            if let rejection = model.rejection {
                HintRow(
                    icon: Glyph.offline.name, color: ColorRole.progress.color,
                    title: "settings.portals.account", wording: rejection)
            }

            HStack(spacing: MetricsBoard.phone.gutter) {
                Button {
                    Task { await model.notify(on: person) }
                } label: {
                    Text(appKey: model.isReporting ? "action.wait" : "common.signIn")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.loud)
                .disabled(model.isReporting || model.pin.isEmpty)

                // The way back is only shown if there is something to go back to.
                if hasMultiple {
                    Button {
                        model.selected = nil
                        model.pin = ""
                    } label: {
                        Text(app: "common.back").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.quiet)
                    .disabled(model.isReporting)
                }
            }
        }
        .padding(Metrics.cardInset)
    }

    /// One switch per portal: **does it count in Home and favorites?**
    ///
    /// **The finding of 2026-09-07, from a product requirement:** being able to technically exclude
    /// certain portals so that they do not end up in Continue Watching and favorites — Yes, and
    /// the switch belongs here, because what the bridge carries is already listed here.
    ///
    /// **It is phrased the right way round like every other switch in this app: on means
    /// included.** "Own area: off" would be a double negation on a toggle, and nobody reads
    /// those correctly — the footer says where it goes instead.
    ///
    /// **Without a portal list there is no section.** As long as the bridge is silent or the
    /// portals are switched off, there would be switches over nothing.
    @ViewBuilder
    private var ownAreas: some View {
        if !model.portals.isEmpty {
            SettingsCard(header: "settings.portals.shared") {
                ForEach(Array(model.portals.enumerated()), id: \.element.id) { slot, portal in
                    if slot > 0 { Separator() }
                    SwitchRow(
                        wording: portal.name,
                        on: Binding(
                            // **On means own area** (AP59 N7) — as on the TV.
                            get: { !model.preferences.countsTogether(portal.id) },
                            set: { model.set(shared: !$0, forItem: portal.id) }))
                }
            }

            Footnote(message: "settings.portals.shared.footnote")
                .padding(.bottom, MetricsBoard.phone.section)
        }
    }

    @ViewBuilder
    private var buttons: some View {
        HStack(spacing: MetricsBoard.phone.gutter) {
            Button {
                Task { await model.verify() }
            } label: {
                Text(appKey: model.verifies ? "action.wait" : "settings.portals.bridge.check")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.quiet)
            .disabled(model.verifies)

            Button {
                model.reset()
            } label: {
                Text(app: "settings.portals.bridge.reset").frame(maxWidth: .infinity)
            }
            .buttonStyle(.quiet)
            .disabled(model.address.isEmpty)
        }
        // **The number is used here and not the environment, and the difference is a trap.**
        // ``SwiftUI/EnvironmentValues/rowInset`` only reaches whatever has its `body`
        // evaluated **inside** the card. This button row is assembled by the parent view
        // itself; an `@Environment` on it would read the value from **outside** — 20 instead of
        // 14, and the buttons would sit six points off from the field above. Whoever wants to
        // supply a row from the environment makes it a view of its own (as with
        // ``IconRow``).
        .padding(.horizontal, Metrics.cardInset)
        .padding(.bottom, Metrics.cardInset)
    }
}

/// The bridge's address — **saved while typing, checked on request.**
@MainActor
@Observable
public final class PortalSettingsModel {

    /// What the check returned.
    public struct State: Sendable, Equatable {
        public let good: Bool
        public let message: String
    }

    public var address: String {
        didSet {
            guard address != oldValue else { return }
            // **Saved while typing and not on "Done".** Every other setting in this app takes effect
            // on toggle; a field with a save button would be the only one, and whoever overlooks it
            // loses their input. The check is separate from that: it costs a connection.
            status = nil
            let clean = address.trimmingCharacters(in: .whitespaces)
            state2.set(bridge: clean.isEmpty ? nil : URL(string: clean))
        }
    }

    public private(set) var status: State?
    public private(set) var verifies = false
    /// Whether the portals are wanted — the switch at the top.
    public private(set) var desired: Bool

    /// The bridge's portals — for the "own area" switches.
    ///
    /// **Empty means "not yet loaded or none".** The section then does not appear at all: three
    /// switches over a silent bridge would be information about nothing.
    public private(set) var portals: [PortalInfo] = []

    /// Which portals stay on their own — see ``PortalPreferences``.
    public private(set) var preferences: PortalPreferences

    private let state2: SetupState
    private let store: any KeyValueStore

    public init(status: SetupState = SetupState(), store: (any KeyValueStore)? = nil) {
        self.state2 = status
        self.address = status.bridgeURL?.absoluteString ?? ""
        self.desired = status.portalsWanted
        let storage = store ?? SecureStore()
        self.store = storage
        self.preferences = PortalPreferences.load(from: storage)
    }

    /// Fetches the portal list — **once, and only if none is there yet.**
    ///
    /// **The contradiction with the rule "checking happens on request" is none.** What is meant
    /// there is the *check* of the address with its message; here the list is the **content** of
    /// the section. A screen with switches per portal that does not know the portals has nothing
    /// to show.
    public func loadPortals() async {
        guard portals.isEmpty, desired else { return }
        guard let source = SourceAssembly.portalDataSource(width: 1) else { return }
        portals = (try? await source.portals()) ?? []
    }

    /// Toggles the switch "counts in Home and favorites".
    public func set(shared on: Bool, forItem portal: String) {
        preferences.countTogether(portal, on)
        preferences.save(to: store)
    }

    public func set(portals on: Bool) {
        state2.set(portals: on)
        desired = on
    }

    public func reset() {
        address = ""
    }

    // MARK: - Anmeldung

    /// The state of the sign-in. `nil` means "not asked yet".
    public private(set) var state: SignInState?
    /// Whom the profile choice currently shows — the PIN belongs to this person.
    public var selected: HouseholdPerson?
    public var pin = ""
    /// The server's rejection, as a sentence.
    public private(set) var rejection: String?
    public private(set) var isReporting = false
    /// The last sign-out failed (``Household/PortalSignOut/Outcome/failed``) — the
    /// credential therefore deliberately still stands, see ``signOut()``.
    public private(set) var signOutFailed = false

    /// Determine the state.
    ///
    /// **On every appearance and not only once**, unlike the portal list next to it: this state
    /// can change without this screen doing anything — someone removes a device in the console,
    /// and afterwards the app is signed out without anything having happened here. The request is
    /// a single one, and it is small.
    public func loadState() async {
        guard let bridgeAddress = state2.bridgeURL else {
            state = nil
            return
        }
        state = await Household.state(
            basis: bridgeAddress, trait: DeviceTrait.load(from: SecureStore()))
        // If only one person is available, the choice is none — then go straight to the PIN.
        if case .notSignedIn(let people) = state, people.count == 1, selected == nil {
            selected = people.first
        }
        // **Signed in: update the person token** (tvOS roadmap AP47). A phone signed in by PIN is
        // the device that can fetch the new token after a revocation — see ``TokenReconciliation``.
        if case .signedIn(let me, let isBorrowed) = state {
            await TokenReconciliation.onDevice()?.reconcile(me: me, isBorrowed: isBorrowed)
        }
        await loadJoin(bridgeAddress)
    }

    // MARK: - Beitritt (Entscheidung 27, B7)

    /// Whether the server accepts requests — only then is "Ask to join" shown.
    public private(set) var canJoin = false
    /// Where the own request stands — ``Flows/RequestState``.
    public private(set) var requestState: RequestState = .none
    public private(set) var asks = false
    /// The open requests of others — only for administrators (``Flows/ApprovalRule``).
    public private(set) var approval: JoinApprovalModel?

    /// The profile whose name and color are used for the request.
    public var requestingProfile: Profile? { ProfileBook.read(from: FileStore()).activeProfile }

    /// **The same flow as on the TV** (``Flows/JoinRequester``) — only with the device
    /// type of a device of its own.
    private var requester: JoinRequester? {
        guard let bridgeAddress = state2.bridgeURL else { return nil }
        return JoinRequester(
            basis: bridgeAddress, keychain: SecureStore(), ledgerStore: FileStore(),
            deviceName: DeviceName.thisDevice, kind: .thisDevice, lookUp: LanguageFallback.message,
            colorValue: ProfileBrand.value)
    }

    /// As on the TV: requests only where sign-in is required and the server reports `join`; a
    /// request already made is polled, not made again, and after a sign-in the waiting ends
    /// (``Flows/JoinRequester/afterState(_:previous:)``).
    private func loadJoin(_ bridgeAddress: URL) async {
        if case .notSignedIn = state {
            canJoin =
                (try? await ServerVersion.probe(bridgeAddress))?.version?.canJoin ?? false
        } else {
            canJoin = false
        }
        if let requester {
            requestState = await requester.afterState(state, previous: requestState)
        }
        approval =
            ApprovalRule.isVisible(state)
            ? JoinApprovalModel.onDevice(lookUp: LanguageFallback.message) : nil
    }

    public func requestAdmission() async {
        guard let requester, let profile = requestingProfile else { return }
        asks = true
        defer { asks = false }
        requestState = await requester.location(forItem: profile)
    }

    public func withdrawRequest() {
        requester?.forget()
        requestState = .none
    }

    /// Poll **as long as the request is waiting and this screen is open** — the cadence is tied
    /// to the view (`task`), as on the TV.
    public func awaitApproval() async {
        while requestState.waiting {
            do {
                try await Task.sleep(for: .seconds(requestState.spacing))
            } catch {
                // bewusst still: the view is gone — and with it the reason to ask.
                return
            }
            guard let requester else { return }
            let result = await requester.queryPending()
            guard let fresh = RequestState.afterInquiry(current: requestState, result: result)
            else { continue }
            requestState = fresh
            if case .approved = fresh {
                SourceAssembly.forget()
                portals = []
                await loadState()
                await loadPortals()
            }
        }
    }

    /// Sign in — **what is stored on the device afterwards is described at ``Household/DeviceSignIn``**:
    /// credential, no loan head, and the phone now belongs to this person (AP58 R2). **Since R7
    /// the person is also in the active profile** (``Household/PortalAssignment``), as on the
    /// TV — the token sync asks there, and the profile carries it to the other devices via the
    /// cloud.
    public func notify(on person: HouseholdPerson) async {
        guard let bridgeAddress = state2.bridgeURL else { return }
        isReporting = true
        defer { isReporting = false }
        rejection = nil
        do {
            try await DeviceSignIn.notify(
                on: person.id, pin: pin, basis: bridgeAddress, keychain: SecureStore())
            PortalAssignment.assign(person.id, ledgerStore: FileStore())
            pin = ""
            selected = nil
            // The sources carry the old credential — or none.
            SourceAssembly.forget()
            portals = []
            await loadState()
            await loadPortals()
        } catch let caughtError as PortalBridge.TestError {
            // **The code into the ledger, the sentence onto the screen.** What the viewer reads is
            // translated; what stands in Diagnostics has to be the code — that is what one searches for
            // in the server's log, not for "Name or PIN is incorrect".
            Diagnose.hint(.network, "Sign-in rejected: \(caughtError.fallbackText)", caughtError)
            rejection = caughtError.message(lookUp: LanguageFallback.message)
        } catch {
            Diagnose.hint(.network, "Sign-in failed", error)
            rejection = error.localizedDescription
        }
    }

    /// What is in the invitation field — link or code.
    public var invitation = ""
    public private(set) var invitationDecline: String?

    /// Redeem an invitation or a pairing code.
    ///
    /// **The link brings the address along, and that is why it is resolved here before
    /// redeeming.** Whoever receives an invitation has never entered the server — asking first
    /// for the address that is in the link would be a question about something one already has.
    ///
    /// **Without an address and without an entered one only the notice remains.** A pairing code
    /// alone does not say where the server is, and sending it blindly would mean guessing 8100
    /// on some computer.
    public func redeem(code input: String) async {
        invitationDecline = nil
        guard let read = Invitation(input: input) else {
            invitationDecline = SettingsModel.text("setup.badAddress")
            return
        }
        isReporting = true
        // **Three sources for the address, in this order** (2026-09-12):
        //
        // 1. The link itself — it carries it if the console was operated via the plain-text
        //    address.
        // 2. **The network.** Whoever opens the console via `cl.example` gets a link without a usable
        //    device address: that certificate is from mkcert, and its root sits in the browser of
        //    the home setup and not in this phone. But the server announces itself as
        //    `_cinelounge._tcp`, so it is asked instead of guessed.
        // 3. What is already entered.
        //
        // **The network BEFORE the entered address**, and that is the finding of 2026-09-12: the
        // unusable `cl.example` address was entered, and the redeem attempt ran against it — "The
        // portal service does not respond", while the server was answering on 8100 two meters away.
        // `??` with an `await` on the right does not work — the right side is an autoclosure
        // without concurrency. So it is written out, and the search runs only if the link carried
        // no address.
        var found = read.bridgeAddress
        if found == nil { found = await ServerLookup.find() }
        if let found { address = found.absoluteString }
        guard let bridgeAddress = found ?? state2.bridgeURL,
            Self.suitsInvitation(bridgeAddress)
        else {
            isReporting = false
            invitationDecline = SettingsModel.text("settings.portals.inviteNeedsAddress")
            return
        }
        defer { isReporting = false }
        do {
            // The same store as on the TV (``Household/DeviceSignIn``): with a person it is own,
            // without a person a shared device.
            let login = try await DeviceSignIn.redeem(
                read, basis: bridgeAddress, keychain: SecureStore())
            PortalAssignment.afterRedemption(person: login.person?.id, ledgerStore: FileStore())
            invitation = ""
            SourceAssembly.forget()
            portals = []
            await loadState()
            await loadPortals()
        } catch let caughtError as PortalBridge.TestError {
            Diagnose.hint(.network, "Invitation rejected: \(caughtError.fallbackText)", caughtError)
            invitationDecline = caughtError.message(lookUp: LanguageFallback.message)
        } catch {
            Diagnose.hint(.network, "Invitation failed", error)
            invitationDecline = error.localizedDescription
        }
    }

    /// Whether this address can accept an invitation — **`http` or `https`.**
    ///
    /// Until 2026-09-26 only `http` applied (AP58, finding E4): a bridge behind a certificate
    /// the phone trusts was rejected although it answered. Whether a certificate holds is decided
    /// by the connection and not by this rule.
    nonisolated static func suitsInvitation(_ bridgeAddress: URL) -> Bool {
        guard let schema = bridgeAddress.scheme?.lowercased(), bridgeAddress.host() != nil else {
            return false
        }
        return schema == "http" || schema == "https"
    }

    /// Is there an invitation in the address field instead of an address?
    ///
    /// **The finding of 2026-09-12**: someone typed the console's link in here — there was no other
    /// field — and the answer was "The bridge does not respond". Correct and completely useless.
    public var addressIsInvitation: Bool {
        Invitation(input: address)?.bridgeAddress != nil
            || address.contains("invite=")
    }

    /// Sign out — **first at the server, then here**, via the same flow as on the TV
    /// (``Household/PortalSignOut``): it also locks the profile's token against self-sign-in,
    /// which has run along on the phone since AP58 R2.
    ///
    /// **A failure stays visible** (finding 2026-09-27, e1): without a server address or after a
    /// failed sign-out the credential stays there — the view shows that instead of acting as if
    /// signed out.
    public func signOut() async {
        isReporting = true
        defer { isReporting = false }
        signOutFailed = false
        let result = await PortalSignOut.notify(
            from: false, basis: state2.bridgeURL, session: .shared,
            keychain: SecureStore(), ledgerStore: FileStore())
        guard result != .failed else {
            signOutFailed = true
            return
        }
        SourceAssembly.forget()
        portals = []
        selected = nil
        pin = ""
        await loadState()
    }

    /// Asks the bridge whether it is there.
    ///
    /// **Via the portal list and not via `/health`.** Both answer; the list also says **how
    /// many** portals the bridge carries — and that is exactly the question one has at this
    /// point. A bridge that answers and carries nothing is a different case from one that does
    /// not answer.
    public func verify() async {
        verifies = true
        defer { verifies = false }
        let clean = address.trimmingCharacters(in: .whitespaces)
        // **Empty is no longer a case to check (2026-09-12).** Here stood `PortalBridge.standard()`
        // — with an empty field the guessed address was checked, and a green "7 portals found" then
        // said nothing about what is in the field. Without an entry there is nothing to check.
        let bridge = URL(string: clean).map { PortalBridge(basis: $0) }
        guard !clean.isEmpty else {
            status = State(good: false, message: SettingsModel.text("settings.portals.bridge.empty"))
            return
        }
        // **An invitation is not an address**, and "does not respond" would here be the most
        // useless of all true answers.
        guard !addressIsInvitation else {
            status = State(
                good: false, message: SettingsModel.text("settings.portals.bridge.isInvite"))
            return
        }
        guard let bridge else {
            status = State(good: false, message: SettingsModel.text("setup.badAddress"))
            return
        }
        do {
            let found = try await PortalSource(bridge: bridge).availablePortals()
            status = State(
                good: true,
                message: SettingsModel.text("settings.portals.bridge.found %lld", found.count))
        } catch {
            Diagnose.hint(.network, "Portals bridge not responding", error)
            status = State(good: false, message: error.localizedDescription)
        }
    }
}
