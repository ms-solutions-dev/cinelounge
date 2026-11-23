import Core
import DesignSystem
import Flows
import JellyfinKit
import ParentalControls
import ProfileKit
import SwiftUI

/// The settings section of the parental controls — **and the only place where they can
/// be changed.**
///
/// **Without this screen the lock was ineffective, and completely so.** On the TV there was
/// no way to set a PIN; ``ProtectionRule/applies`` however requires
/// a PIN to be set, because a lock without a way back would not be a lock but a
/// trap. The four locked doors from stage 1 and the filter from stage 2 therefore
/// stood there and did nothing.
///
/// **The adult switch lives here and nowhere else.** This is the most serious
/// finding of the phone review, carried over: There, **four taps** led from the child account
/// to the "Adult channels" switch, without a PIN. Under Settings → Live there has since been only the row
/// that leads here — and one gets here only through the "kindersicherung" door.
///
/// **The section protects itself.** It sits behind the same door it configures;
/// otherwise switching off the lock would be the one way that is not locked.
struct ParentalControlsView: View {

    @ObservedObject var lock: ParentalControlsState
    /// Jellyfin — only to **show** its policy, not to follow it.
    let source: JellyfinSource?
    /// The Live settings — the adult switch now lives here.
    ///
    /// As state and not as a passed-in value: ``LivePreferences`` is a value with
    /// mutating access, and a `let` could not be toggled. It is read
    /// at construction, written directly to the store.
    @State private var live: LivePreferences

    /// "Hide unlabeled adult channels" (G3, finding C8) — **the same store
    /// as on the phone** (``ParentalControls/ChannelLock/stored(store:keychain:)``).
    @State private var hidesUnlabeled = ChannelLock.hidesUnlabeled()

    /// Whether the device-lock sheet or the adult-channels sheet is open (G3).
    @State private var showsDeviceLock = false
    @State private var showsAdult = false

    @FocusState private var focus: String?
    @Environment(\.settingsEntryRequest) private var entryRequest

    /// The flow that is currently running: set, change or forget the PIN.
    @State private var job: Job?

    /// The mirror of the catalog — `nil` as long as nobody has reviewed it.
    ///
    /// **The difference from "empty" is half the information:** An empty list claims that
    /// every rating is understood; `nil` says that nobody has looked yet.
    @State private var mirror: ApprovalMirror?
    @State private var sees = false
    @State private var showsApprovals = false

    /// The channel catalog — **the same one "Live" receives** (``SettingsView/liveStock``),
    /// for the selection and the counters of the allow list (AP52).
    let channelCatalog: @Sendable () async -> [Channel]

    /// The names of the channel lists per identifier — for the headers of the allow list.
    let listNames: [String: String]

    /// The loaded catalog. Empty until ``channelCatalog`` has answered.
    @State private var catalog: [Channel] = []

    /// The child profiles of this household — each one has its own allow list.
    @State private var children: [Profile] = []

    /// Whose allow list is currently open — the second level. `nil` means none.
    @State private var liveFor: Profile?

    /// By hand, because ``live`` is a `@State`: The derived initializer would
    /// not be accessible with it, and the initial value would come from the view instead of from the caller.
    init(
        lock: ParentalControlsState, source: JellyfinSource?, live: LivePreferences,
        channelCatalog: @escaping @Sendable () async -> [Channel], listNames: [String: String]
    ) {
        self.lock = lock
        self.source = source
        self.channelCatalog = channelCatalog
        self.listNames = listNames
        _live = State(initialValue: live)
    }

    enum Job: Equatable {
        case set
        case change
        case forgotten
    }

    @ViewBuilder
    var body: some View {
        // **The own guard — depth protection, not a replacement** (AP23, 2026-09-11). The
        // comment above has always claimed "The section protects itself"; until
        // now it did not: The five ``ParentalControlsState/isAllowed(finished:)`` call sites
        // were in ``AccountsView`` and ``SettingsView``, none in this file.
        //
        // The door in front of the section stays where it is — at the section selection. Here
        // the same curtain stands once more, in case someone shows this view without the
        // path through the section list. A second holder would be wrong: It is
        // **the same** ``ParentalControlsState`` that the settings keep, and
        // thus also the same pass — whoever has just passed the door does not
        // face a second one here.
        if lock.isHidden("kindersicherung") {
            Curtain(
                door: "kindersicherung",
                reason: lock.reason(forItem: "kindersicherung"),
                asks: { lock.queryPending("kindersicherung") }
            )
        } else if let person = liveFor {
            // **The second level: the allow list of a child** (AP52). Behind
            // the same curtain as the whole section, because it sits inside it.
            let choice = ChannelApproval.selectable(catalog)
            LiveAllowList(
                person: person, choice: choice, listNames: listNames,
                approval: lock.channelApproval(forItem: person.identifier.rawValue),
                update: { lock.set(channelApproval: $0, forItem: person.identifier.rawValue) },
                focus: $focus
            )
            .onAppear {
                focus =
                    choice.isEmpty
                    ? "live-leer" : "live-leeren"
            }
            .backWithMenu {
                liveFor = nil
                focus = "live-" + person.identifier.rawValue
            }
        } else {
            openContent
        }
    }

    @ViewBuilder
    private var openContent: some View {
        // **No second scroll area** (AP22, 2026-09-11). Here another
        // unbounded `ScrollView(.vertical)` hung in a content that already sits
        // in one (``SettingsView`` builds one around every section). Two nested
        // scroll areas without a height limit share the scrolling on tvOS by
        // focus: The inner one takes it, the outer one does not move, and the content
        // below the edge stayed put. The eight other sections therefore deliver
        // only a `VStack` — the only deliberately nested one is the log list
        // in ``DiagnosticsSettings``, and that one is limited to 620 pt and justified.
        VStack(alignment: .leading, spacing: 0) {
            SettingsHeader("childLock.title", hint: "childLock.hint")
                // **The first target of this section** (AP23, 2026-09-11). `SettingsFirstEntryKey`
                // stood in seven places in five files — and of all places here, behind
                // the door, in none. Without the message no catcher is created at the
                // content edge (``SettingsView/showsContentCatcher(focus:firstEntry:)``),
                // and the right press from the section list assigns focus by geometry.
                .preference(key: SettingsFirstEntryKey.self, value: "pin")
                .onChange(of: entryRequest) { _, _ in focus = "pin" }

            pinBlock
            // **Open "forgot PIN" requests of the profiles, cancelable** (cross-check strand C,
            // finding 6). Here the parent who manages the locks sees them — even
            // if the request was made on another TV.
            ProfileEscapeSection()
            if lock.rule.isPinSet {
                kidsModeBlock
                limitsBlock
                liveBlock
                notUnderstoodBlock
                adultBlock
            }
            serverBlock
        }
        .padding(.bottom, 60)
        // **Without Jellyfin there is no server policy to show** — the device lock
        // still applies, and so does the whole rest of the section.
        .task { if let source { await lock.loadPolicy(from: source) } }
        .task {
            children = ProfileBook.read(from: FileStore()).profile.filter { $0.kind == .kind }
            catalog = await channelCatalog()
        }
        .sheet(item: Binding(get: { job.map(SheetID.init) }, set: { _ in job = nil })) {
            identifier in
            sheet(identifier.job)
        }
    }

    /// `sheet(item:)` requires `Identifiable` — ``Job`` is a value without an identifier.
    private struct SheetID: Identifiable {
        let job: Job
        var id: String { String(describing: job) }
        init(_ job: Job) { self.job = job }
    }

    // MARK: - The PIN

    private var pinBlock: some View {
        VStack(alignment: .leading, spacing: 14) {
            row(
                catalogTitleKey: lock.rule.isPinSet ? "childLock.pinSet" : "childLock.pinUnset",
                sentenceKey: lock.rule.isPinSet ? "childLock.pinSetHint" : "childLock.pinUnsetHint"
            )

            HStack(spacing: 18) {
                button(
                    lock.rule.isPinSet ? "pin.change" : "pin.create",
                    identifier: "pin"
                ) {
                    job = lock.rule.isPinSet ? .change : .set
                }
                if lock.rule.isPinSet {
                    // **The way out, and it is the task.** A lock without a way out
                    // is not a lock but a defect: Whoever has forgotten the PIN
                    // would otherwise never get back to their own device.
                    button("pin.forgot", identifier: "vergessen") { job = .forgotten }
                }
            }
        }
        .padding(.bottom, 40)
    }

    // MARK: - Device lock

    /// **Below the switch stands what the lock hides** (Decision 23, 2026-09-26):
    /// Live, portals and sports carry no age ratings and therefore drop out entirely. Whoever
    /// wants separate rules takes child profiles with a profile PIN. The sentence is in the
    /// shared catalog because the phone shows it word for word.
    ///
    /// **Since G3 a row with a sheet** (``DeviceLockSheet``): the switch, this sentence and
    /// the explanations "What the PIN locks" and "Sidebar under device lock" sit there
    /// together — the section stays under fifteen focus targets (`FocusPlanTests`).
    private var kidsModeBlock: some View {
        VStack(alignment: .leading, spacing: 14) {
            // **Only the explanation now** (AP59 N4) — the device-lock switch is gone.
            DisclosureRow(
                title: "childLock.doors",
                value: "\(LockedDoors.info.count)",
                identifier: "geraet", focus: $focus
            ) {
                showsDeviceLock = true
            }
            .frame(maxWidth: 900, alignment: .leading)
        }
        .padding(.bottom, 40)
        #if os(tvOS)
            .fullScreenCover(isPresented: $showsDeviceLock) {
                DeviceLockSheet(lock: lock) { showsDeviceLock = false }
            }
        #endif
    }

    // MARK: - Age limit

    /// The levels as a series — **and "no limit" as one of them.**
    ///
    /// **Without this choice the filter filtered nothing.** ``ApprovalInterpretation/shows(_:at:…)``
    /// begins with `guard let limit else { return true }`: As long as no level
    /// is set, **everything** gets through. The filter from stage 2 thus stood there and
    /// had nothing to filter against.
    ///
    /// **"No limit" is not an absence but a level in the series.** It is the
    /// default and must remain selectable — whoever has set a limit and wants to
    /// get rid of it again otherwise finds no way back except resetting the whole
    /// lock.
    ///
    /// **And it is not the same as "from 0".** That is the difference between "not
    /// locked at all" and "everything locked except FSK 0" — two ends of the same series.
    private var limitsBlock: some View {
        VStack(alignment: .leading, spacing: 14) {
            row(catalogTitleKey: "childLock.limit", sentenceKey: "childLock.limitHint")

            HStack(spacing: 14) {
                tier(nil)
                ForEach(AgeLimit.allCases, id: \.rawValue) { tier($0) }
            }
        }
        .padding(.bottom, 40)
    }

    private func tier(_ value: AgeLimit?) -> some View {
        let identifier = "grenze-" + (value.map { String($0.rawValue) } ?? "keine")
        let chosen = lock.limit == value
        return Button {
            lock.set(limit: value)
        } label: {
            // **Symbol and number, not just color.** The selected level carries a
            // checkmark; a marker conveyed by the fill alone is missing for one in ten.
            HStack(spacing: 8) {
                if chosen { Image(systemName: "checkmark") }
                Text(
                    value.map(\.caption)
                        ?? AppLanguageSetting.text("childLock.limitNone"))
            }
            .font(TypeLevel.footer.font)
            .settingsFont(isFocused: focus == identifier)
            .settingsSurface(
                .pill, isFocused: focus == identifier,
                reason: chosen ? ColorRole.surfaceHigh.color : ColorRole.surface.color)
        }
        .bareFocusableButton()
        .focused($focus, equals: identifier)
        .info(
            Text(
                verbatim: value.map(\.caption)
                    ?? AppLanguageSetting.text("childLock.limitNone")),
            .chosen(chosen))
    }

    // MARK: - Live for children

    /// **One row per child, and its value is the answer** (AP52, Decision 14):
    /// "No Live" or "3 groups · 42 channels". The same pattern as the group row under
    /// "Live" (AP46) — whoever only wants to know whether a child has Live does not have to go in.
    ///
    /// **Child profiles only.** An adult has no list; for them the
    /// device lock decides, and it removes Live entirely as before.
    private var liveBlock: some View {
        VStack(alignment: .leading, spacing: 14) {
            row(catalogTitleKey: "childLock.live", sentenceKey: "childLock.liveHint")

            if children.isEmpty {
                Text(app: "childLock.liveNoChildren")
                    .font(TypeLevel.footer.font)
                    .foregroundStyle(ColorRole.textMatt.color)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 900, alignment: .leading)
            }
            ForEach(children, id: \.identifier) { person in
                let approval = lock.channelApproval(forItem: person.identifier.rawValue)
                let value = LivePermission.value(approval, catalog: catalog)
                DisclosureRow(
                    wording: person.name,
                    value: value,
                    card: CardSpec(
                        header: "childLock.live",
                        headerWording: person.name,
                        statementWording: value,
                        explanation: "childLock.liveHint",
                        pills: approval.groups.sorted().prefix(4).map {
                            CardPill(ChannelName.display($0.name), chosen: true)
                        },
                        optionCount: ChannelApproval.selectable(catalog).count),
                    identifier: "live-" + person.identifier.rawValue,
                    focus: $focus
                ) {
                    liveFor = person
                }
                .frame(maxWidth: 900, alignment: .leading)
            }
        }
        .padding(.bottom, 40)
    }

    // MARK: - Unrecognised entries

    /// **A missing rating and a not-understood rating are two different things**, and only the second
    /// is offered for choice here.
    ///
    /// A title **without** a rating always gets through — locking all of them would mean giving a
    /// child account an almost empty library, because on Jellyfin by no means every
    /// title carries a rating. A title with a rating that this app
    /// does not classify is a different case: There **is** something there, it is just not
    /// understood.
    private var notUnderstoodBlock: some View {
        VStack(alignment: .leading, spacing: 14) {
            row(catalogTitleKey: "childLock.unknown", sentenceKey: "childLock.unknownHint")

            toggle(
                catalogTitleKey: "childLock.unknownToggle", identifier: "unverstanden",
                on: lock.rule.blocksUnrecognized
            ) {
                lock.set(blocksUnrecognized: !lock.rule.blocksUnrecognized)
            }

            // **The way to the list, and it sits below the switch.** First
            // one decides whether the not-understood locks; then one looks at what that costs. The
            // reverse order would be busywork before the question of what for.
            button(
                sees ? "childLock.ratingsScanning" : "childLock.ratings",
                identifier: "freigaben"
            ) {
                // **The press is discarded in the body and not at the button** (AP22): A
                // disabled button drops out of the focus tree on tvOS, and the
                // review takes time.
                guard !sees else { return }
                Task { await screen() }
            }
        }
        .padding(.bottom, 40)
        #if os(tvOS)
            .fullScreenCover(isPresented: $showsApprovals) {
                ApprovalSheet(
                    mirror: mirror ?? ApprovalMirror(),
                    blocksUnrecognized: lock.rule.blocksUnrecognized,
                    arrange: { rawText, alter in arrange(rawText, to: alter) },
                    redeem: { redeem($0) },
                    onClose: { showsApprovals = false }
                )
            }
        #endif
    }

    /// Reviews the catalog — **once, and afterwards from what was remembered.**
    ///
    /// The pass belongs to ``Flows/CatalogIndex``, which does it anyway for the filmography:
    /// **two answers from one pass.** Whoever has already opened a filmography
    /// does not wait here at all.
    private func screen() async {
        sees = true
        defer { sees = false }
        // **Ratings are written by Jellyfin alone** — without it there is nothing
        // to review, and the list would stay empty. See ``ApprovalSheet``.
        guard let source else { return }
        let counted = await CatalogIndex.shared.survey(from: source).approvals
        mirror = ApprovalMirror.about(
            counted: counted,
            assignments: UnrecognizedRatings.load(from: SecureStore()).assignments)
        showsApprovals = true
    }

    /// **Assigning means storing and re-reading the rule** — in this order.
    ///
    /// ``ParentalControlsState/load()`` fetches the assignments from the same store; whoever
    /// reads them earlier gets the state from just before. And the mirror is reinterpreted without a new
    /// pass: The count belongs to the catalog and has not
    /// changed, only its interpretation.
    private func arrange(_ rawText: String, to alter: Int) {
        var board = UnrecognizedRatings.load(from: SecureStore())
        board.arrange(rawText, to: alter)
        board.save(to: SecureStore())
        lock.load()
        reinterpret(using: board.assignments)
    }

    private func redeem(_ rawText: String) {
        var board = UnrecognizedRatings.load(from: SecureStore())
        board.redeem(rawText)
        board.save(to: SecureStore())
        lock.load()
        reinterpret(using: board.assignments)
    }

    private func reinterpret(using assignments: [String: Int]) {
        Task {
            guard let counted = await CatalogIndex.shared.countedRatings() else {
                return
            }
            mirror = ApprovalMirror.about(counted: counted, assignments: assignments)
        }
    }

    // MARK: - Adult channels

    /// **Since G3 a row with a sheet** (``AdultSheet``) — with the second switch
    /// "hide without labeling", which until then only the phone carried (finding C8).
    private var adultBlock: some View {
        VStack(alignment: .leading, spacing: 14) {
            row(catalogTitleKey: "childLock.adult", sentenceKey: "childLock.adultHint")

            DisclosureRow(
                title: "childLock.adult.show",
                value: AppLanguageSetting.text(
                    String.LocalizationValue(live.showsAdultChannels ? "common.on" : "common.off")),
                identifier: "erwachsen", focus: $focus
            ) {
                showsAdult = true
            }
            .frame(maxWidth: 900, alignment: .leading)
        }
        .padding(.bottom, 40)
        #if os(tvOS)
            .fullScreenCover(isPresented: $showsAdult) {
                AdultSheet(
                    live: $live, hidesUnlabeled: $hidesUnlabeled
                ) { showsAdult = false }
            }
        #endif
    }

    // MARK: - What the server says

    /// The policy of Jellyfin — **an explanation and not a setting.**
    ///
    /// There is nothing to press here, and that is the point: The server filters anyway, and
    /// more reliably than this app — it does not hand out locked titles in the first place.
    /// Wanting to switch it off here would be a button that does nothing.
    ///
    /// **It is shown anyway, because it explains.** Whoever is missing titles on the TV that
    /// appear in the web interface otherwise looks in the wrong program: The limit can
    /// come from the server.
    private var serverBlock: some View {
        VStack(alignment: .leading, spacing: 14) {
            row(catalogTitleKey: "childLock.server", sentenceKey: "childLock.serverHint")

            Group {
                if let accessPolicy = lock.serverPolicy {
                    if accessPolicy.hasContent {
                        serverRows(accessPolicy)
                    } else {
                        // **A server without a policy is the normal case**, and the sentence
                        // says so. An empty row would leave open whether anyone asked at all.
                        Text(app: "childLock.serverNone")
                    }
                } else {
                    Text(app: "childLock.serverAsking")
                }
            }
            .font(TypeLevel.footer.font)
            .foregroundStyle(ColorRole.textMatt.color)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: 900, alignment: .leading)
        }
    }

    @ViewBuilder
    private func serverRows(_ accessPolicy: ServerPolicy) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if let approval = accessPolicy.maximumRating {
                Text(app: "childLock.serverLimit \(approval)")
            }
            if accessPolicy.isRestricted {
                Text(app: "childLock.serverDisabled")
            }
            if !accessPolicy.blockedCatalogs.isEmpty {
                Text(app: "childLock.serverBlocked \(accessPolicy.blockedCatalogs.count)")
            }
        }
    }

    // MARK: - The sheets

    @ViewBuilder
    private func sheet(_ job: Job) -> some View {
        switch job {
        case .set:
            PinSetSheet(
                catalogTitleKey: "pin.create",
                onDone: { digits in
                    lock.setPin(digits)
                    self.job = nil
                },
                onCancel: { self.job = nil })
        case .change:
            // **First the old one, then the new one** — otherwise an unattended
            // device would suffice to take over the lock instead of bypassing it.
            PinChangeSheet(
                checkOld: { lock.matchesPin($0) },
                onDone: { digits in
                    lock.setPin(digits)
                    self.job = nil
                },
                onCancel: { self.job = nil })
        case .forgotten:
            PinForgottenSheet(
                onReset: {
                    lock.clearPin()
                    self.job = nil
                },
                onCancel: { self.job = nil })
        }
    }

    // MARK: - Building blocks

    private func row(catalogTitleKey: String, sentenceKey: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(appKey: catalogTitleKey)
                .font(TypeLevel.header.font)
                .foregroundStyle(ColorRole.text.color)
            Text(appKey: sentenceKey)
                .font(TypeLevel.lowercased.font)
                .foregroundStyle(ColorRole.textQuiet.color)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 900, alignment: .leading)
        }
    }

    private func button(
        _ key: String, identifier: String, action: @escaping () -> Void
    )
        -> some View
    {
        Button(action: action) {
            Text(appKey: key)
                .font(TypeLevel.footer.font)
                .settingsFont(isFocused: focus == identifier)
                .settingsSurface(.pill, isFocused: focus == identifier)
        }
        .bareFocusableButton()
        .focused($focus, equals: identifier)
        .info(appKey: key)
    }

    /// **Color AND symbol**, as with every note in this app: A marker
    /// that carries only color is missing for one in ten.
    private func toggle(
        catalogTitleKey: String, identifier: String, on: Bool, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 18) {
                Image(systemName: on ? "checkmark.square.fill" : "square")
                Text(appKey: catalogTitleKey)
                Spacer(minLength: 0)
                Text(appKey: on ? "common.on" : "common.off")
                    .foregroundStyle(ColorRole.textMatt.color)
            }
            .font(TypeLevel.footer.font)
            .settingsFont(isFocused: focus == identifier)
            .frame(maxWidth: 900, alignment: .leading)
            .settingsSurface(.row, isFocused: focus == identifier)
        }
        .bareFocusableButton()
        .focused($focus, equals: identifier)
        .info(appKey: catalogTitleKey, .on(on))
    }
}
