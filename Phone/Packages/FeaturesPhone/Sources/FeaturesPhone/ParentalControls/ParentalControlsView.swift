import Core
import DesignSystemPhone
import ParentalControls
import ProfileKit
import SwiftUI

/// Set up the parental controls.
///
/// **Seven blocks, and one of them shows explicitly WHAT the PIN locks** — a
/// lock whose extent you cannot see is believed either wrongly or not at all. The
/// most serious finding of the usability pass was exactly that: the
/// parental controls claimed to lock what they did not lock.
///
/// **The exit is the design task, not the entrance.** From the market it is
/// established that *creating* is trivial and all the work is in *leaving*.
/// That is why this screen sits behind the PIN (``LockedDoors``) and why
/// the PIN is the **first** block: without it nothing takes effect, and a switch "on"
/// without a stored PIN would be the claim once more.
///
/// **Blocks 5 and 6 are information and no switches — a deviation from the draft.** The
/// prototype draws toggles there for "account switch", "Settings", "Live and
/// portals entirely" and for every tab. They would stand for rules that this app does not
/// keep individually: which door is closed is in ``LockedDoors``, which tab stays
/// in the ``TabScope`` — both tables a test suite runs over. Switches on top
/// would be five buttons without effect, and `scripts/buttons.py` looks specifically for
/// those in this app. What is shown is therefore **what applies**, and completely.
public struct ParentalControlsView: View {

    let status: ParentalControlsState
    let state: CatalogState

    /// The signed-in account — for the block "Applies to this account".
    var account: Account?

    /// Asks for the PIN. The request says what for.
    let askPin: (PinTask) -> Void

    /// Leads into the "Age ratings" sheet.
    let approvals: () -> Void

    /// What the media server says. **Injectable, because a test has no server.**
    let accessPolicy: @Sendable () async -> ServerPolicy?

    /// The path to the "Forgot PIN" escape — see ``PinFallbackView``.
    let pinReset: () -> Void

    /// The cloud, solely to see whether a request is open.
    let cloud: ProfileCloud?

    /// The **unfiltered** channel catalog of this phone — the selection for "Live for
    /// children" (AP52). Unfiltered, because you can only choose from what you see; the
    /// view stands behind the door of the parental controls anyway.
    let channelCatalog: @Sendable () async -> [Channel]

    /// The names of the channel lists per identifier — for the headers of the selection.
    let listNames: [String: String]

    @State private var catalog: [Channel] = []

    /// Whose list is currently open.
    @State private var liveFor: Profile?

    /// The value for the row — `nil` means: no request, no row.
    private var reset: String? {
        switch cloud?.pinState(forItem: .parentalControls) {
        case .isRunning, .wartetAufServer: SettingsModel.text("childLock.reset.pending")
        case .due, .confirmed: SettingsModel.text("childLock.reset.ready")
        case .some(.none), nil: nil
        }
    }

    public init(
        status: ParentalControlsState, state: CatalogState, account: Account? = nil,
        askPin: @escaping (PinTask) -> Void = { _ in },
        approvals: @escaping () -> Void = {},
        accessPolicy: @escaping @Sendable () async -> ServerPolicy? = { nil },
        pinReset: @escaping () -> Void = {},
        cloud: ProfileCloud? = ProfileCloud.attached,
        channelCatalog: @escaping @Sendable () async -> [Channel],
        listNames: [String: String]
    ) {
        self.channelCatalog = channelCatalog
        self.listNames = listNames
        self.status = status
        self.state = state
        self.account = account
        self.askPin = askPin
        self.approvals = approvals
        self.accessPolicy = accessPolicy
        self.pinReset = pinReset
        self.cloud = cloud
    }

    public var body: some View {
        ZStack {
            ColorRole.reason.color.ignoresSafeArea()

            ScrollSurface {
                VStack(alignment: .leading, spacing: 0) {
                    pinBlock
                    separator
                    accountBlock
                    separator
                    limitBlock
                    separator
                    approvalsBlock
                    separator
                    lockBlock
                    separator
                    tabBlock
                    separator
                    AdultChannelBlock(state: status)
                    separator
                    if status.isPinSet {
                        liveBlock
                        separator
                    }
                    serverBlock
                }
                .padding(.top, MetricsBoard.phone.gutter)
            }
        }
        // **Once per opening and not on every redraw.** The policy changes
        // on the server and not here; fetching it on every redraw would be a
        // request per scrolled row.
        .task {
            guard status.accessPolicy == nil else { return }
            status.adopt(await accessPolicy())
        }
        .task { catalog = await channelCatalog() }
        .sheet(item: $liveFor) { person in
            LiveForKidsView(
                person: person, choice: ChannelApproval.selectable(catalog),
                listNames: listNames, state: status
            )
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
            .presentationCornerRadius(MetricsBoard.phone.sheetRadius)
            .presentationBackground(ColorRole.surfaceHigh.color)
        }
    }

    // MARK: - Live for children

    /// One row per child profile — **"No Live" or "Groups: 3 · Channels: 42"**
    /// (tvOS roadmap AP52, decision 14).
    ///
    /// **Only with a PIN, just as on the TV.** Without a PIN no lock takes effect
    /// (``ParentalControls/ProtectionRule/applies``), and a list that regulates nothing
    /// would claim a protection that does not exist.
    @ViewBuilder
    private var liveBlock: some View {
        SectionHeader(title: "childLock.live")

        let children = status.childProfiles
        if children.isEmpty {
            Footnote(message: "childLock.liveNoChildren")
        }
        ForEach(children, id: \.identifier) { person in
            DisclosureRow(
                wording: person.name, icon: Glyph.kind.name,
                value: LivePermission.value(
                    status.channelApproval(forItem: person.identifier.rawValue), catalog: catalog)
            ) {
                liveFor = person
            }
        }

        Footnote(message: "childLock.liveHint")
    }

    private var separator: some View {
        Divider().overlay(ColorRole.lineQuiet.color).padding(.vertical, MetricsBoard.phone.gutter)
    }

    // MARK: - 1 · PIN

    /// **Below the switch stands what the lock hides** (decision 23): Live,
    /// portals and sports — age ratings do not apply there; for separate rules
    /// use child profiles with a profile PIN. Same wording on the TV (shared catalog).
    ///
    /// **Without a PIN no parental controls, and the switch says so.**
    ///
    /// Whoever flips it without a stored PIN gets the keypad first. A switch
    /// that jumps to "on" without a PIN claims a lock that anyone lifts with two taps
    /// — exactly the finding for which this package exists.
    @ViewBuilder
    private var pinBlock: some View {
        SectionHeader(title: "childLock.pin")

        // **No device lock any more** (AP59 N4, 2026-09-30): a device for children starts in the
        // child profile, out of it only with this PIN (``Flows/ParentalControlsMigration``).

        DisclosureRow(
            title: status.isPinSet ? "pin.change" : "pin.create",
            value: pinValue, isMissing: !status.isPinSet
        ) {
            askPin(status.isPinSet ? .changePin : .assignPin)
        }

        // **Only if something is really open** (AP43). A row that is always there
        // is an invitation to the child to try it out; one that appears only with a
        // running request is a notification. The request comes from the TV
        // and wakes this device via the silent push.
        if let reset {
            DisclosureRow(
                title: "childLock.reset.title", wording: nil, icon: Glyph.expire.name,
                value: reset, isMissing: true, action: pinReset)
        }

        Footnote(message: "childLock.pin.footnote")
    }

    /// "four digits · last changed on March 12" — or the note that there is none.
    private var pinValue: String {
        guard let changed = status.pinChanged else {
            return SettingsModel.text("childLock.pin.none")
        }
        return SettingsModel.text("childLock.pin.digits %lld", Pin.locations) + " · "
            + changed.formatted(date: .abbreviated, time: .omitted)
    }

    // MARK: - 2 · Applies to this account

    /// **Every account has its own limit, and the device has its own.**
    ///
    /// Decided on 2026-09-06 as question 3, answer (c): a child account says **who owns
    /// the progress**; child mode says **what is locked now**. Only this
    /// version supports both cases — the child on the adult's phone and the
    /// adult on the child account.
    @ViewBuilder
    private var accountBlock: some View {
        SectionHeader(title: "childLock.account")

        if let account {
            HintRow(
                icon: account.kind ? Glyph.kind.name : Glyph.person.name,
                color: account.kind ? ColorRole.brandLight.color : ColorRole.textMatt.color,
                title: "childLock.account.name",
                wording: account.name + " · "
                    + SettingsModel.text(
                        account.kind ? "childLock.account.child" : "childLock.account.adult")
                    + (account.server.host().map { " · " + $0 } ?? ""))
        } else {
            HintRow(
                icon: Glyph.login.name, title: "childLock.account.none",
                message: "childLock.account.none.text")
        }

        Footnote(message: "childLock.account.footnote")
    }

    // MARK: - 3 · Altersgrenze

    /// **Five levels and "no limit".**
    ///
    /// Titles above the limit do not appear in Library, Search and on Home.
    /// They are **not grayed out, they are not there** — a locked title that stays
    /// visible is an invitation.
    @ViewBuilder
    private var limitBlock: some View {
        SectionHeader(title: "childLock.limit")

        ChipRow(
            labels: Self.slots.map {
                $0.map(\.caption) ?? SettingsModel.text("childLock.limitNone")
            },
            chosen: .init(
                get: { Self.slots.firstIndex(of: status.limit) ?? Self.slots.count - 1 },
                set: { status.set(limit: Self.slots[$0]) }))

        Footnote(message: "childLock.limit.footnote")
    }

    /// **"No limit" stands at the end and is `nil`.** It is the absence of a limit and
    /// no sixth level: with "no limit" nothing is filtered at all, not even the
    /// uninterpreted.
    static let slots: [AgeLimit?] = AgeLimit.allCases.map { $0 } + [nil]

    // MARK: - 4 · Altersfreigaben

    /// **The actual finding: the raw text is not standardized.**
    ///
    /// A lock built on it **must** be able to deal with unknown strings
    /// — and it must not guess in doing so.
    @ViewBuilder
    private var approvalsBlock: some View {
        SectionHeader(title: "childLock.ratingsSection")

        DisclosureRow(
            title: "childLock.ratings.row", value: approvalsValue,
            isMissing: status.mirrored.openTitles > 0, action: approvals)

        SwitchRow(
            title: "childLock.ratings.blockUnknown", message: "childLock.ratings.blockUnknown.text",
            on: .init(
                get: { status.blocksUnrecognized },
                set: { status.set(blocksUnrecognized: $0) }))

        Footnote(message: "childLock.ratings.footnote")
    }

    /// "31 titles not classified" — or nothing at all as long as nobody has counted.
    private var approvalsValue: String? {
        guard status.mirrored.openTitles > 0 else { return nil }
        return SettingsModel.text(
            "childLock.ratings.openShort %lld", status.mirrored.openTitles)
    }

    // MARK: - 5 · Was die PIN sperrt

    /// **Complete and read from the table, not copied.**
    ///
    /// A hand-maintained list would be wrong at the next screen — and
    /// unnoticed, because a wrong list looks like a right one. What is shown
    /// is therefore the doors that ``LockedDoors`` keeps, with their own reason.
    @ViewBuilder
    private var lockBlock: some View {
        SectionHeader(title: "childLock.doors")

        ForEach(LockedDoors.info, id: \.self) { door in
            HintRow(
                icon: Glyph.locked.name, title: "childLock.door." + door,
                wording: LockedDoors.reason(door))
        }

        Footnote(message: "childLock.doors.footnote")
    }

    // MARK: - 6 · Tab bar with device lock

    /// **The bar does not look the same for everyone** — and here it says what it looks like.
    ///
    /// A switched-off tab **disappears**, it is not dimmed. The reason
    /// is not strictness but the lack of any basis: 7,746 channels without an
    /// age rating, and a portal catalog is read off, not licensed.
    @ViewBuilder
    private var tabBlock: some View {
        SectionHeader(title: "childLock.tabs")

        let stay = Set(state.tabs(isInChildMode: true))
        ForEach(state.tabs) { tab in
            HintRow(
                icon: stay.contains(tab)
                    ? Glyph.done.pair.outlined : Glyph.hidden.name,
                color: stay.contains(tab) ? ColorRole.success.color : ColorRole.textQuiet.color,
                title: tab.titleKey,
                message: stay.contains(tab) ? nil : "childLock.tabs.gone")
        }

        Footnote(message: "childLock.tabs.footnote")
    }

    // MARK: - 7 · Der Medienserver filtert mit

    /// **The third finding and the decision on it: read, but do not rely.**
    ///
    /// What this account may see on the media server is decided by the server, and it does
    /// so more reliably than any app — it does not even hand out locked titles.
    /// **For three of four sources there is no policy**; that is why the lock
    /// in the app stays in place.
    @ViewBuilder
    private var serverBlock: some View {
        SectionHeader(title: "childLock.serverSection")

        if let accessPolicy = status.accessPolicy, accessPolicy.hasContent {
            HintRow(
                icon: Glyph.done.pair.outlined, color: ColorRole.success.color,
                title: "childLock.server.has", wording: serverSentence(accessPolicy))
        } else {
            // **A server without a policy is the normal case**, and the sheet says so
            // too. An empty row would leave open whether anyone asked at all.
            HintRow(
                icon: Glyph.hidden.name, title: "childLock.server.none",
                message: "childLock.server.none.text")
        }

        HintRow(
            icon: Glyph.hidden.name, title: "childLock.server.others",
            message: "childLock.server.others.text")

        Footnote(message: "childLock.server.footnote")
    }

    /// "Rating up to 12 · two libraries locked" — only what is actually there.
    private func serverSentence(_ accessPolicy: ServerPolicy) -> String {
        var split: [String] = []
        if case .approval(let alter) = accessPolicy.interpreted {
            split.append(SettingsModel.text("childLock.server.upTo %lld", alter))
        } else if let raw = accessPolicy.maximumRating {
            // **The raw text, when it could not be interpreted.** Omitting it would mean
            // withholding from the parent a piece of information from the server because this app does not
            // understand it.
            split.append(raw)
        }
        if !accessPolicy.blockedCatalogs.isEmpty {
            split.append(
                SettingsModel.text(
                    "childLock.server.blocked %lld", accessPolicy.blockedCatalogs.count))
        }
        if accessPolicy.isRestricted {
            split.append(SettingsModel.text("childLock.server.restricted"))
        }
        return split.joined(separator: " · ")
    }
}
