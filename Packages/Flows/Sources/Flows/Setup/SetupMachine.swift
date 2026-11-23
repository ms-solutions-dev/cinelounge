import Foundation
import JellyfinKit
import ProfileKit

/// The first setup as a pure calculation — **person first, then their sources** (AP88).
///
/// **Why a value without time and stores:** a check that waits for a deadline checks the clock
/// in the end (rule from AP44). Everything that takes time or touches a store comes out as a
/// ``SetupEffect``; ``SetupJourney`` performs it and feeds the answer back as a ``SetupInput``.
///
/// **The one order that carries AP88:** a profile becomes active (``SetupEffect/activate(_:)``)
/// before the machine reaches A4. Every source then writes into an active profile, and
/// finding 1 — `ProfileAccesses.update` without `ledger.active` — has no ground.
nonisolated public struct SetupMachine: Sendable, Equatable {

    /// Where the machine begins — computed by ``SetupGate``.
    public enum Start: Sendable, Equatable {
        /// No profile here can play anything: A1, with the profiles already in the book.
        case fresh(known: [SetupProfile])
        /// An active profile and nothing usable anywhere: back into A4.
        case resume(SetupProfile)
        /// **A source added later from the settings** (wave 5): the sheet of this kind for the
        /// active profile, and every way out of it ends the journey — the same sheets as in the
        /// first setup instead of a second sign-in.
        case retrofit(SetupProfile, Access.Kind)
    }

    /// How long the TV waits for iCloud after the clip — **4 s** (decision of 2026-11-15 on
    /// question 3, about 9 s from a cold start).
    public static let cloudGrace = Duration.seconds(4)

    public private(set) var state: SetupState

    let steps: SetupSteps
    private let entry: Start
    private var cloud: CloudAnswer?
    private var profiles: [SetupProfile]
    private var bookProfiles: Set<Profile.Identifier>
    private var isPinSet: Bool
    private var noticeSeen: Bool
    private var online: Bool
    private var searched = false
    private var searchDone = false
    private var foundJellyfin: ServerDiscovery.Found?
    /// The CL-Server the home-network search found — **what A6 asks, enrolls and pairs at.** A
    /// fresh TV has no stored bridge address yet (§10.1), so the sheet takes it from here.
    public private(set) var clServerAddress: URL?
    private var availableLists: Set<String> = []
    private var copiedFrom: [Profile.Identifier: String] = [:]
    private var completed: [Profile.Identifier: [Access.Kind: SourceOutcome]] = [:]
    private var lastSummary: Profile.Identifier?
    /// The kind a retrofit opened — `nil` in the first setup.
    private var retrofitting: Access.Kind?

    /// - Parameters:
    ///   - isPinSet: whether this device has a household PIN (``ParentalControls/Pin``).
    ///   - noticeSeen: whether the local-network notice ran on this installation.
    public init(
        steps: SetupSteps, start: Start, isPinSet: Bool, noticeSeen: Bool, online: Bool = true
    ) {
        self.steps = steps
        self.entry = start
        self.isPinSet = isPinSet
        self.noticeSeen = noticeSeen
        self.online = online
        switch start {
        case .fresh(let known):
            profiles = known
            state = .probing(introOver: false)
        case .resume(let profile), .retrofit(let profile, _):
            profiles = [profile]
            state = .probing(introOver: true)
        }
        if case .retrofit(_, let kind) = start { retrofitting = kind }
        bookProfiles = Set(profiles.map(\.id))
    }

    /// The effects of the start.
    ///
    /// **The iCloud question runs from the cold start**, not under the intro — the setup only
    /// waits for its answer now (§2.6). Without an intro the deadline runs at once.
    public mutating func begin() -> [SetupEffect] {
        switch entry {
        case .fresh:
            return [.probeCloud, .watchNetwork] + (steps.coversIntro ? [] : [.startCloudDeadline])
        case .resume(let profile):
            var effects: [SetupEffect] = [.drawReady, .watchNetwork, .reloadLists]
            enterSources(profile.id, effects: &effects)
            return effects
        case .retrofit(let profile, let kind):
            var effects: [SetupEffect] = [.watchNetwork, .reloadLists]
            enterSources(profile.id, effects: &effects)
            if kind == .channelList {
                state = .channelList(profile.id)
            } else {
                openSource(kind, effects: &effects)
            }
            return effects
        }
    }

    /// Takes one input — **the only place where the state changes.**
    public mutating func handle(_ input: SetupInput) -> [SetupEffect] {
        var effects: [SetupEffect] = []
        switch input {
        case .cloudAnswered(let answer): cloudAnswered(answer, effects: &effects)
        case .cloudDeadlinePassed: deadlinePassed(effects: &effects)
        case .introEnded:
            if state == .probing(introOver: false) {
                state = .probing(introOver: true)
                effects.append(.startCloudDeadline)
            }
        case .focusMoved(let focus):
            if case .welcome(var offer) = state {
                offer.focus = focus
                state = .welcome(offer)
            }
        case .chose(let identifier): chose(identifier, effects: &effects)
        case .choseNew:
            if case .welcome = state { state = .creating(isFirst: true, lateCloudHint: false) }
        case .choseFetchFromPhone:
            if case .welcome(let offer) = state, offer.canFetch { state = .fetchingFromPhone(offer.pullMode) }
        case .profileFetched(let profile): profileFetched(profile, effects: &effects)
        case .profilesArrived(let arrivals): profilesArrived(arrivals)
        case .draftSaved(let profile):
            if case .creating = state { arrived(profile, effects: &effects) }
        case .householdPinSet: householdPinSet(effects: &effects)
        case .activationRefused: state = .welcome(welcomeOffer(keeping: nil))
        case .noticeAcknowledged: noticeAcknowledged(effects: &effects)
        case .searchFound(let jellyfin, let clServer): searchFound(jellyfin, clServer, effects: &effects)
        case .tokenChecked(let identifier, let valid): tokenChecked(identifier, valid)
        case .listsAvailable(let lists):
            availableLists = lists
            refresh()
        case .networkChanged(let isOnline): networkChanged(isOnline, effects: &effects)
        case .openSource(let kind): openSource(kind, effects: &effects)
        case .addOwnChannelList:
            if case .sources(let page) = state { state = .channelList(page.profile) }
        case .chooseOtherServer:
            switch state {
            case .jellyfin(let identifier, .confirm), .jellyfin(let identifier, .otherUser):
                state = .jellyfin(identifier, .fresh)
            default: break
            }
        case .sourceFinished(let kind, let outcome): sourceFinished(kind, outcome)
        case .jellyfinSignedIn(let userID, let username):
            jellyfinSignedIn(userID, username, effects: &effects)
        case .acceptOtherUser:
            if case .jellyfin(let identifier, .otherUser(let signedIn, _, _)) = state {
                effects.append(.storeJellyfin)
                complete(.jellyfin, .done(detail: signedIn), of: identifier)
            }
        case .sendJoinRequest:
            if case .clServer(let identifier, .request(let request)) = state, !request.waiting,
                profile(identifier)?.isChild == false
            {
                effects.append(.requestJoin(identifier))
            }
        case .requestState(let request): requestState(request)
        case .enrolled(let identifier, let success):
            if success { record(.done(detail: clServerAddress?.host() ?? ""), for: .portals, of: identifier) }
        case .finishSources: finishSources()
        case .setStartChoice(let choice):
            if case .done(var summary) = state {
                summary.startChoice = choice
                state = .done(summary)
            }
        case .addAnotherProfile:
            if case .done = state { state = .creating(isFirst: false, lateCloudHint: false) }
        case .start:
            if case .done(let summary) = state {
                state = .finished(summary.profile)
                if summary.startChoice { effects.append(.applyStartChoice(summary.profile)) }
            }
        case .back, .abort: back()
        }
        return effects
    }

    // MARK: - A1 and A2

    private mutating func cloudAnswered(_ answer: CloudAnswer, effects: inout [SetupEffect]) {
        cloud = answer
        let known = Set(profiles.map(\.id))
        let arrived = answer.profiles.filter { !known.contains($0.id) }
        profiles += arrived
        if !arrived.isEmpty { effects.append(.reloadLists) }
        switch state {
        case .probing:
            leaveProbing(effects: &effects)
        case .welcome(let offer):
            state = .welcome(welcomeOffer(keeping: offer.focus))
        case .creating(let isFirst, let hint):
            state = .creating(isFirst: isFirst, lateCloudHint: hint || !arrived.isEmpty)
        default:
            break
        }
    }

    private mutating func deadlinePassed(effects: inout [SetupEffect]) {
        guard case .probing = state else { return }
        if cloud == nil { cloud = .noAnswer }
        leaveProbing(effects: &effects)
    }

    private mutating func leaveProbing(effects: inout [SetupEffect]) {
        effects.append(.drawReady)
        state = .welcome(welcomeOffer(keeping: nil))
    }

    private func welcomeOffer(keeping focus: WelcomeOffer.Focus?) -> WelcomeOffer {
        let cards = profiles.map { WelcomeOffer.Card(profile: $0, selectable: !$0.isChild || isPinSet) }
        let answer = cloud ?? .noAnswer
        let first = cards.first(where: \.selectable).map { WelcomeOffer.Focus.profile($0.profile.id) }
        let pullMode: SetupPullMode = answer.reachesCloud ? .cloud : .wire
        let showsCode = steps.fetchFromPhone == .showCode
        return WelcomeOffer(
            cards: cards, cloud: answer, pullMode: pullMode, showsCode: online && showsCode,
            canFetch: online && (showsCode || pullMode == .cloud), focus: focus ?? first ?? .newProfile)
    }

    private mutating func chose(_ identifier: Profile.Identifier, effects: inout [SetupEffect]) {
        guard case .welcome(let offer) = state,
            let card = offer.cards.first(where: { $0.profile.id == identifier }), card.selectable
        else { return }
        if !bookProfiles.contains(identifier) {
            effects.append(.adoptCloudProfile(card.profile.profile))
            bookProfiles.insert(identifier)
        }
        activate(card.profile, effects: &effects)
    }

    /// A profile from the phone — **through the embedded fetching path or through the QR that A2
    /// shows without a press** (§4.1): the camera on the code, and the TV jumps into A4 for that
    /// profile. Anywhere else a late arrival changes nothing; the profile is in the book and
    /// stands in "Who is watching?" afterwards.
    private mutating func profileFetched(_ profile: SetupProfile, effects: inout [SetupEffect]) {
        switch state {
        case .fetchingFromPhone, .welcome: arrived(profile, effects: &effects)
        default: break
        }
    }

    /// Several profiles from the phone — **cards in A2, and no profile becomes active** until
    /// someone picks one. A card that already stands keeps its place, so that nothing jumps under
    /// the thumb (§2.6).
    private mutating func profilesArrived(_ arrivals: [SetupProfile]) {
        let focus: WelcomeOffer.Focus?
        switch state {
        case .welcome(let offer): focus = offer.focus
        case .fetchingFromPhone: focus = nil
        default: return
        }
        for arrival in arrivals {
            if let slot = profiles.firstIndex(where: { $0.id == arrival.id }) {
                profiles[slot] = arrival
            } else {
                profiles.append(arrival)
            }
            bookProfiles.insert(arrival.id)
        }
        state = .welcome(welcomeOffer(keeping: focus))
    }

    /// A profile from A3 or from the phone.
    private mutating func arrived(_ profile: SetupProfile, effects: inout [SetupEffect]) {
        profiles.removeAll { $0.id == profile.id }
        profiles.append(profile)
        bookProfiles.insert(profile.id)
        guard !profile.isChild || isPinSet else {
            state = .householdPin(for: profile.id)
            return
        }
        activate(profile, effects: &effects)
    }

    private mutating func householdPinSet(effects: inout [SetupEffect]) {
        isPinSet = true
        guard case .householdPin(let identifier) = state, let profile = profile(identifier) else { return }
        activate(profile, effects: &effects)
    }

    /// **The heart of AP88:** `activate` before anything that writes an access.
    ///
    /// The notice comes right after choosing only for a profile that brings an access needing
    /// the home network at once — a token to check or a person token to enroll. Everyone else
    /// meets it before the first search (§2.5).
    private mutating func activate(_ profile: SetupProfile, effects: inout [SetupEffect]) {
        effects.append(.activate(profile.id))
        let reachesNetwork = profile.profile.jellyfin != nil || profile.hasPersonTag
        if reachesNetwork, needsNotice {
            state = .networkNotice(then: profile.id, open: nil)
        } else {
            enterSources(profile.id, effects: &effects)
        }
    }

    // MARK: - The notice and the search

    private var needsNotice: Bool { steps.networkNoticeBeforeSearch && !noticeSeen }

    private mutating func noticeAcknowledged(effects: inout [SetupEffect]) {
        guard case .networkNotice(let identifier, let kind) = state else { return }
        noticeSeen = true
        effects.append(.rememberNotice)
        enterSources(identifier, effects: &effects)
        if let kind { openSource(kind, effects: &effects) }
    }

    /// The network work of a profile — **only once the notice ran.**
    private mutating func reachOut(for identifier: Profile.Identifier, effects: inout [SetupEffect]) {
        guard !needsNotice, online else { return }
        if !searched {
            searched = true
            effects.append(.startSearches)
        }
        if let access = profile(identifier)?.profile.jellyfin, completed[identifier]?[.jellyfin] == nil,
            retrofitting ?? .jellyfin == .jellyfin
        {
            effects.append(.checkToken(identifier, access))
        }
        enrollIfPossible(identifier, effects: &effects)
    }

    /// `SelfSignIn` needs the CL-Server's address, and a fresh TV only knows it after the
    /// search (§10.1).
    private func enrollIfPossible(_ identifier: Profile.Identifier, effects: inout [SetupEffect]) {
        guard clServerAddress != nil, let profile = profile(identifier), profile.hasPersonTag,
            !profile.isChild, completed[identifier]?[.portals] == nil, retrofitting ?? .portals == .portals
        else { return }
        effects.append(.enroll(identifier))
    }

    private mutating func searchFound(
        _ jellyfin: [ServerDiscovery.Found], _ clServer: URL?, effects: inout [SetupEffect]
    ) {
        searchDone = true
        foundJellyfin = jellyfin.first
        clServerAddress = clServer
        if case .clServer(let identifier, .searching) = state {
            state = .clServer(identifier, clServer == nil ? .notFound : .request(.none))
        }
        if let identifier = currentProfile { enrollIfPossible(identifier, effects: &effects) }
        refresh()
    }

    /// **The network back while A4 or one of its sheets stands: the search catches up** — a
    /// device that started offline would otherwise never look for Jellyfin or the CL-Server, and
    /// the rows would stay on "Add" although both answer now.
    private mutating func networkChanged(_ isOnline: Bool, effects: inout [SetupEffect]) {
        let cameBack = isOnline && !online
        online = isOnline
        if cameBack, let identifier = currentProfile { reachOut(for: identifier, effects: &effects) }
        refresh()
    }

    // MARK: - A4

    private mutating func enterSources(_ identifier: Profile.Identifier, effects: inout [SetupEffect]) {
        state = .sources(page(identifier))
        reachOut(for: identifier, effects: &effects)
    }

    private func page(_ identifier: Profile.Identifier) -> SourcesPage {
        let rows = Access.Kind.allCases.map { SourceRow(kind: $0, state: rowState($0, of: identifier)) }
        let open = rows.first { row in
            switch row.state {
            case .done, .waiting, .unavailable: false
            default: true
            }
        }
        return SourcesPage(profile: identifier, rows: rows, focus: open?.kind)
    }

    private func rowState(_ kind: Access.Kind, of identifier: Profile.Identifier) -> SourceRowState {
        let profile = profile(identifier)
        switch completed[identifier]?[kind] {
        case .done(let detail): return .done(detail: detail)
        case .waiting: return .waiting
        case nil: break
        }
        switch kind {
        case .jellyfin:
            guard online else { return .unavailable(.noNetwork) }
            if let access = profile?.profile.jellyfin { return .fromProfile(access) }
            if let foundJellyfin { return .found(detail: foundJellyfin.name) }
            return .empty
        case .channelList:
            if let profile, hasUsableLists(profile) { return .done(detail: "") }
            if let donor = listDonor(for: identifier) { return .suggested(from: donor.profile.name) }
            return .empty
        case .portals:
            if profile?.isChild == true { return .unavailable(.notForChildren) }
            guard online else { return .unavailable(.noNetwork) }
            if let clServerAddress { return .found(detail: clServerAddress.host() ?? "") }
            return .empty
        }
    }

    private func hasUsableLists(_ profile: SetupProfile) -> Bool {
        profile.profile.channelLists.contains { $0.channelListID.map(availableLists.contains) ?? false }
    }

    /// The profile whose lists a second profile can take over with one press — **never a silent
    /// copy** (decision of 2026-11-15 on question 4).
    private func listDonor(for identifier: Profile.Identifier) -> SetupProfile? {
        profiles.first { other in
            guard other.id != identifier else { return false }
            if case .done = completed[other.id]?[.channelList] { return true }
            return hasUsableLists(other)
        }
    }

    private mutating func openSource(_ kind: Access.Kind, effects: inout [SetupEffect]) {
        guard case .sources(let page) = state, let row = page.row(kind), let profile = profile(page.profile)
        else { return }
        switch row {
        case .unavailable(.noNetwork), .done: return
        default: break
        }
        if kind == .channelList {
            guard case .suggested = row, let donor = listDonor(for: profile.id) else {
                state = .channelList(profile.id)
                return
            }
            effects.append(.copyChannelLists(from: donor.id, to: profile.id))
            copiedFrom[profile.id] = donor.profile.name
            record(.done(detail: donor.profile.name), for: .channelList, of: profile.id)
            return
        }
        guard !needsNotice else {
            state = .networkNotice(then: profile.id, open: kind)
            return
        }
        switch kind {
        case .jellyfin:
            state = .jellyfin(profile.id, profile.profile.jellyfin.map(JellyfinMode.confirm) ?? .fresh)
        case .portals where profile.isChild:
            state = .clServer(profile.id, .childPairing)
        case .portals:
            let step: ClServerStep =
                clServerAddress != nil ? .request(.none) : searchDone ? .notFound : .searching
            state = .clServer(profile.id, step)
        case .channelList:
            break
        }
    }

    private mutating func sourceFinished(_ kind: Access.Kind, _ outcome: SourceOutcome) {
        guard let identifier = sheetProfile else { return }
        complete(kind, outcome, of: identifier)
    }

    private mutating func jellyfinSignedIn(_ userID: String, _ username: String, effects: inout [SetupEffect])
    {
        guard case .jellyfin(let identifier, let mode) = state else { return }
        if case .confirm(let access) = mode, case .jellyfin(_, let expected, let expectedName) = access,
            expected != userID
        {
            state = .jellyfin(
                identifier, .otherUser(signedIn: username, expected: expectedName, access: access))
            return
        }
        effects.append(.storeJellyfin)
        complete(.jellyfin, .done(detail: username), of: identifier)
    }

    /// - Note: **A withdrawn, rejected or expired request takes its "waiting" mark along** — A7
    ///   would otherwise promise a CL-Server that nobody is deciding about any more.
    private mutating func requestState(_ request: RequestState) {
        guard case .clServer(let identifier, .request) = state else { return }
        state = .clServer(identifier, .request(request))
        switch request {
        case .approved(let name, _): completed[identifier, default: [:]][.portals] = .done(detail: name)
        case .waiting, .throttled: completed[identifier, default: [:]][.portals] = .waiting
        case .none, .rejected, .expired:
            if completed[identifier]?[.portals] == .waiting { completed[identifier]?[.portals] = nil }
        case .failed, .notForChildren: break
        }
    }

    /// A valid token from the Keychain is the sign-in itself — **also when A5 is already open**:
    /// the sheet closes instead of asking for a Quick Connect that nobody needs any more (§2.1).
    private mutating func tokenChecked(_ identifier: Profile.Identifier, _ valid: Bool) {
        guard valid, let access = profile(identifier)?.profile.jellyfin else { return }
        let outcome = SourceOutcome.done(detail: access.displayName ?? "")
        if case .jellyfin(identifier, .confirm) = state {
            complete(.jellyfin, outcome, of: identifier)
        } else {
            record(outcome, for: .jellyfin, of: identifier)
        }
    }

    private mutating func finishSources() {
        if retrofitting != nil, case .sources(let page) = state {
            state = .finished(page.profile)
            return
        }
        guard case .sources(let page) = state, page.canFinish, let profile = profile(page.profile) else {
            return
        }
        lastSummary = profile.id
        state = .done(
            SetupSummary(
                profile: profile.id, name: profile.profile.name, rows: page.rows, startChoice: false,
                offersChildLimit: profile.isChild && !profile.hasOwnLimit))
    }

    // MARK: - Back

    /// **"Back" never removes a profile** (§1.4 points 2 and 3) — that would be a silent
    /// deletion. From A2 it does nothing; the system then sends the app to the background.
    private mutating func back() {
        if retrofitting != nil {
            retrofitBack()
            return
        }
        switch state {
        case .probing, .welcome, .finished:
            break
        case .fetchingFromPhone:
            state = .welcome(welcomeOffer(keeping: nil))
        case .creating(let isFirst, _):
            state = isFirst ? .welcome(welcomeOffer(keeping: nil)) : summaryAgain()
        case .householdPin:
            state = lastSummary == nil ? .welcome(welcomeOffer(keeping: nil)) : summaryAgain()
        case .networkNotice(let identifier, let kind):
            state = kind == nil ? .welcome(welcomeOffer(keeping: nil)) : .sources(page(identifier))
        case .sources:
            state = .welcome(welcomeOffer(keeping: nil))
        case .jellyfin(let identifier, .otherUser(_, _, let access)):
            state = .jellyfin(identifier, .confirm(access))
        case .jellyfin(let identifier, _), .channelList(let identifier), .clServer(let identifier, _):
            state = .sources(page(identifier))
        case .done(let summary):
            state = .sources(page(summary.profile))
        }
    }

    /// **A retrofit has no A2 and no A4 to go back to** — "Back" from its sheet, from the notice
    /// or from the fallback page ends it; inside A5 it stays the sheet's own step back.
    private mutating func retrofitBack() {
        switch state {
        case .jellyfin(let identifier, .otherUser(_, _, let access)):
            state = .jellyfin(identifier, .confirm(access))
        case .networkNotice(let identifier, _):
            state = .finished(identifier)
        case .sources(let page):
            state = .finished(page.profile)
        case .jellyfin(let identifier, _), .channelList(let identifier), .clServer(let identifier, _):
            state = .finished(identifier)
        default:
            break
        }
    }

    private func summaryAgain() -> SetupState {
        guard let lastSummary, let profile = profile(lastSummary) else {
            return .welcome(welcomeOffer(keeping: nil))
        }
        let page = page(lastSummary)
        return .done(
            SetupSummary(
                profile: lastSummary, name: profile.profile.name, rows: page.rows, startChoice: false,
                offersChildLimit: profile.isChild && !profile.hasOwnLimit))
    }

    // MARK: - Helpers

    /// Whether the device has a network now — **the IPTV sheet offers only M3U without one**
    /// (§2.4): Xtream checks the account at the provider's server before it is stored.
    public var isOnline: Bool { online }

    /// The profile whose IPTV lists this one took over with one press — for the row's sentence
    /// "Taken over from Lea", which the bare detail cannot tell from a provider's host.
    public func listsCopied(for identifier: Profile.Identifier) -> String? {
        copiedFrom[identifier]
    }

    /// A profile the setup knows — for the sheets' heads ("Lea · Jellyfin") and their avatar.
    public func setupProfile(_ identifier: Profile.Identifier) -> SetupProfile? {
        profile(identifier)
    }

    private func profile(_ identifier: Profile.Identifier) -> SetupProfile? {
        profiles.first { $0.id == identifier }
    }

    /// The profile of the open sheet.
    private var sheetProfile: Profile.Identifier? {
        switch state {
        case .jellyfin(let identifier, _), .channelList(let identifier), .clServer(let identifier, _):
            identifier
        default: nil
        }
    }

    /// The profile A4 or one of its sheets is about.
    private var currentProfile: Profile.Identifier? {
        if case .sources(let page) = state { return page.profile }
        return sheetProfile
    }

    private mutating func complete(
        _ kind: Access.Kind, _ outcome: SourceOutcome, of identifier: Profile.Identifier
    ) {
        completed[identifier, default: [:]][kind] = outcome
        state = retrofitting == nil ? .sources(page(identifier)) : .finished(identifier)
    }

    private mutating func record(
        _ outcome: SourceOutcome, for kind: Access.Kind, of identifier: Profile.Identifier
    ) {
        completed[identifier, default: [:]][kind] = outcome
        refresh()
    }

    /// Redraws A2 or A4 after a fact changed — sheets keep their own state.
    private mutating func refresh() {
        switch state {
        case .welcome(let offer): state = .welcome(welcomeOffer(keeping: offer.focus))
        case .sources(let page): state = .sources(self.page(page.profile))
        default: break
        }
    }
}
