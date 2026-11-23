import Core
import Downloads
import Flows
import Foundation
import NetworkStatus
import ParentalControls
import ProfileKit
import SourceProbe
import Testing

@testable import FeaturesPhone

/// **The findings of the "shell" review of 2026-09-27** (H1–H10) and the addendum F5 from the
/// Home review — each via the path on which it occurred on the device.
@Suite("Wrapper check")
@MainActor
struct WrapperFindingsTests {

    private struct ProbeSource: PlayerSource {
        func target(zu job: PlaybackJob) async throws -> PlaybackRequest {
            PlaybackRequest(
                identifier: job.identifier, title: "Sample",
                address: URL(string: "https://example.invalid/strom")!)
        }
        func notify(
            location: TimeInterval, duration: TimeInterval, zu job: PlaybackJob, isPaused: Bool
        ) async throws {}
    }

    private typealias Household = WhoIsWatchingPhoneTests.Household

    // MARK: - H1 · Offline

    /// Start in airplane mode: the tab is on "Home" (default), the shell shows the
    /// downloads in the Library's stack — and there the tap on a poster must land,
    /// even if the view has not yet switched the tab.
    @Test("H1: Offline, a tap on a downloads poster opens the page in the visible stack")
    func withoutNetworkHintVisible() {
        let wrapper = ShellModel(catalogs: .fromAccesses(jellyfin: true))
        #expect(wrapper.navigator.tabs == .start)
        wrapper.networkMonitor.adopt(.none)
        #expect(wrapper.barState == .downloadsOnly)

        wrapper.navigator.show(.detail, title: "vorrat:abc")

        #expect(wrapper.navigator.tabs == .library)
        #expect(wrapper.navigator[.library].map(\.view) == [.detail])
        #expect(wrapper.navigator[.start].isEmpty)
        #expect(wrapper.navigator.current == .detail)
    }

    @Test("H1: Online, the tap stays in the selected tab")
    func withNetworkInTab() {
        let wrapper = ShellModel(catalogs: .fromAccesses(jellyfin: true))
        wrapper.networkMonitor.adopt(NetworkPath(kind: .wifi))
        wrapper.navigator.show(.detail, title: "abc")
        #expect(wrapper.navigator.tabs == .start)
        #expect(wrapper.navigator[.start].map(\.view) == [.detail])
    }

    @Test("H1: The wrapper switches the tab as soon as only the downloads remain")
    func wrapperSwitches() throws {
        let text = try SourceText.read("ShellView.swift", in: .featuresPhone)
        let location = try #require(text.range(of: ".onChange(of: model.barState, initial: true)"))
        #expect(text[location.upperBound...].prefix(200).contains("model.enterDownloadsAlone()"))
    }

    // MARK: - H2 · One administration, one monitor

    @Test("H2: A second build leaves the administration the started network monitor")
    func networkGuardStays() throws {
        DownloadsHolder.forget()
        defer { DownloadsHolder.forget() }

        let real = NetworkStatus.NetworkWatch()
        real.adopt(NetworkPath(kind: .cellular))
        let administration = DownloadsHolder.ready(
            source: ProbeSource(), start: nil, detail: nil, external: nil, networkMonitor: real)

        let discarded = NetworkStatus.NetworkWatch()
        _ = DownloadsHolder.ready(
            source: ProbeSource(), start: nil, detail: nil, external: nil, networkMonitor: discarded)

        let field = Mirror(reflecting: administration).children.first { $0.label == "_networkMonitor" }
        let held = try #require(field?.value as? NetworkStatus.NetworkWatch?)
        #expect(held === real, "the administration now judges by a monitor that never reports")
        #expect(held?.reported == true)
    }

    /// **The shell does not build its model itself** — the app holds the one, because its `body`
    /// is re-evaluated at every scene and language change.
    @Test("H2: The wrapper model is created once, in the app")
    func oneModel() throws {
        let wrapper = try SourceText.read("ShellView.swift", in: .featuresPhone)
            .split(separator: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
        #expect(!wrapper.contains("ShellModel("))
        #expect(!wrapper.contains("@State private var model"))
        let app = try SourceText.read("CineLoungeApp.swift", in: .phoneApp)
        #expect(app.components(separatedBy: "ShellModel(").count == 2)
        #expect(app.contains("@State private var wrapper: ShellModel?"))
        #expect(app.contains("ShellView(model: wrapper)"))
    }

    // MARK: - H3 · "Who is watching?" once

    @Test("H3: After the choice a rebuilt model does not ask again")
    func curtainOnlyOnce() {
        ProfilePointer.als(nil) {
            let household = Household()
            defer { household.cleanUp() }
            let first = household.wrapper()
            first.showLaunchCurtain()
            #expect(first.sheetState.pending == .accountSwitch)
            first.switchProfile(household.profile(household.parent))
            #expect(first.profile.active == household.parent)

            let fresh = household.wrapper()
            fresh.showLaunchCurtain()
            #expect(fresh.sheetState.pending == nil, "\"Who is watching?\" appears a second time")
        }
    }

    @Test("H3: The same rule on the TV — once per program run")
    func curtainOnTV() throws {
        let tv = try SourceText.read("MainView.swift", in: .features)
        let phone = try SourceText.read("ShellModel.swift", in: .featuresPhone)
        for text in [tv, phone] {
            #expect(text.contains("ProfilePicker.asksNow("))
            #expect(text.contains("ProfilePicker.asksWithoutActive("))
            #expect(!text.contains("ProfilePicker.asksAtStart("))
        }
    }

    /// **Finding 2026-11-09:** without an active profile the question comes again, even when the
    /// curtain of this run was already used — otherwise the shell stands without a person.
    @Test("H3: Without an active profile a rebuilt model asks again")
    func curtainWithoutActive() {
        ProfilePointer.als(nil) {
            let household = Household()
            defer { household.cleanUp() }
            var book = ProfileBook.read(from: household.ledger)
            book.clearActive()
            book.write(in: household.ledger)
            #expect(household.administration.activeAndCount.active == nil)

            let first = household.wrapper()
            first.showLaunchCurtain()
            #expect(first.sheetState.pending == .accountSwitch)

            let fresh = household.wrapper()
            fresh.showLaunchCurtain()
            #expect(fresh.sheetState.pending == .accountSwitch, "nobody chose, so the question stays")
        }
    }

    // MARK: - H4 · Switching to the child discards everything

    @Test("H4: Switching to the child discards the paths as on the TV (Kinderwache.verwerfen)")
    func pathsAfterChildSwitch() {
        ProfilePointer.als(nil) {
            let household = Household()
            defer { household.cleanUp() }
            #expect(household.administration.switchTo(zu: household.parent).result != nil)
            let wrapper = household.wrapper()
            wrapper.navigator.show(.detail, title: "erwachsenenfilm")
            wrapper.navigator.tabs = .library
            wrapper.navigator.show(.downloads)
            wrapper.navigator.show(.settings)
            #expect(wrapper.navigator[.start].map(\.view) == [.detail])
            #expect(wrapper.navigator.overlay == [.settings])

            wrapper.switchProfile(household.profile(household.childProfile))
            #expect(wrapper.surface == .kind)
            #expect(
                wrapper.navigator[.start].isEmpty,
                "the adult's page stays in the stack for the child")
            #expect(wrapper.navigator[.library].isEmpty, "the downloads with the old rule")
            #expect(wrapper.navigator.overlay.isEmpty)
        }
    }

    @Test("H4: If the cloud makes the active profile a child, the player closes")
    func playerAfterCloud() {
        ProfilePointer.als(nil) {
            let household = Household()
            defer { household.cleanUp() }
            #expect(household.administration.switchTo(zu: household.parent).result != nil)
            let wrapper = household.wrapper()
            wrapper.navigator.show(.player, job: PlaybackJob(identifier: "erwachsenenfilm"))
            #expect(wrapper.navigator.current == .player)

            #expect(household.administration.switchTo(zu: household.childProfile).result != nil)
            wrapper.cloudArrived()

            #expect(wrapper.navigator.current != .player)
            #expect(wrapper.navigator[.start].isEmpty)
        }
    }

    /// **One rule alone** — an age limit set in the settings — empties the
    /// stacks of the tabs, but leaves standing the settings sheet in which it was set.
    @Test("H4: A new age limit empties the tabs and leaves the settings in place")
    func ruleAlone() {
        ProfilePointer.als(nil) {
            let household = Household()
            defer { household.cleanUp() }
            #expect(household.administration.switchTo(zu: household.parent).result != nil)
            let wrapper = household.wrapper()
            wrapper.navigator.show(.detail, title: "film")
            wrapper.navigator.show(.settings)

            wrapper.parentalControls.set(limit: .from12)
            wrapper.followRulesState()

            #expect(wrapper.navigator[.start].isEmpty)
            #expect(wrapper.navigator.overlay == [.settings])
        }
    }

    @Test("H4: The same state discards nothing")
    func sameState() {
        ProfilePointer.als(nil) {
            let household = Household()
            defer { household.cleanUp() }
            let wrapper = household.wrapper()
            wrapper.navigator.show(.detail, title: "film")
            wrapper.followRulesState()
            wrapper.cloudArrived()
            #expect(wrapper.navigator[.start].map(\.view) == [.detail])
        }
    }

    // MARK: - F5 · Filtered roots follow the rule

    /// **Home review F5:** Search, Favorites and Library hold their filtered sources in
    /// `@State`; they were rebuilt only with ``ShellModel/setupState``.
    @Test("F5: A changed rule rebuilds the filtered roots")
    func rootFollowsRule() {
        ProfilePointer.als(nil) {
            let household = Household()
            defer { household.cleanUp() }
            let wrapper = household.wrapper()
            let previous = wrapper.rootState
            wrapper.parentalControls.set(limit: .from6)
            #expect(wrapper.rootState != previous)
            #expect(wrapper.rootState.setup == previous.setup)
        }
    }

    @Test("F5: Every root of the wrapper hangs on the root state, including the downloads offline")
    func rootsDependOnState() throws {
        let text = try SourceText.read("ShellView.swift", in: .featuresPhone)
        #expect(text.components(separatedBy: ".id(model.rootState)").count == 3)
        #expect(!text.contains(".id(model.setupState)"))
        #expect(text.contains(".onChange(of: model.ruleState)"))
    }

    /// **Home review, note on part D:** an account switch without a profile of its own only
    /// switched the session — the sources behind it stayed those of the previous account.
    @Test("F5: An account switch without a profile rebuilds the sources")
    func accountSwitchWithoutProfile() throws {
        try ProfilePointer.als(nil) {
            let secure = SecureStore(service: "test.\(UUID().uuidString)")
            defer { try? secure.clearCredentials() }
            let accounts = AccountsModel(
                keychain: secure, childAccounts: ChildAccountList(store: InMemoryStore()))
            let server = try #require(URL(string: "http://" + "a.example"))
            for user in ["alex", "sam"] {
                accounts.accept(
                    ServerCredentials(
                        serverURL: server, userID: user, username: user,
                        accessToken: "token-\(user)"),
                    asChild: false)
            }
            let wrapper = ShellModel(
                accounts: accounts,
                parentalControls: ParentalControlsState(
                    store: UserDefaults(suiteName: UUID().uuidString)!,
                    keychain: InMemoryStore(), ledgerStore: InMemoryStore()),
                ledgerStore: InMemoryStore())
            wrapper.profilePins = {
                ProfilePinManagement(keychain: InMemoryStore(), cloud: nil, device: "test")
            }
            let other = try #require(accounts.accounts.first { $0.id != accounts.signedIn })
            let previous = wrapper.setupState

            wrapper.switchAccount(other)

            #expect(accounts.signedIn == other.id)
            #expect(wrapper.setupState == previous + 1)
        }
    }

    // MARK: - H7 · Only after the intro

    @Test("H7: \"Who is watching?\" waits until the intro cover is open")
    func curtainAfterIntro() {
        ProfilePointer.als(nil) {
            let household = Household()
            defer { household.cleanUp() }
            let cover = IntroCover(deadline: .seconds(60)) { _ in }
            let wrapper = household.wrapper()
            wrapper.afterIntro = { action in cover.afterUncovering(action) }

            wrapper.showLaunchCurtain()
            #expect(wrapper.sheetState.pending == nil, "the sheet would lie over the clip")

            cover.skip()
            #expect(wrapper.sheetState.pending == .accountSwitch)
        }
    }

    // MARK: - H8 · H10 · The downloads follow the profile

    private static let childRule = ProtectionRule(
        deviceLocked: true, accountKind: .kind, isPinSet: true, limit: .from12,
        blocksUnrecognized: true, assignments: [:])

    private static func film(_ identifier: String, size: Int64 = 1_000) -> DownloadJob {
        DownloadJob(
            id: .init(identifier), title: identifier, beside: nil, source: .jellyfin,
            extent: .film, tier: .low, estimatedSize: size)
    }

    private static func populated(_ model: DownloadsModel) {
        model.set(
            downloads: Downloads(
                items: [Self.film("m-18", size: 9_000), Self.film("m-6")],
                isRunning: [
                    Transfer(id: .init("m-18"), state: .isLoading, loaded: 1_000, total: 9_000)
                ]),
            household: StorageBudget(items: [], unrestricted: 1_000_000), durations: [:], seen: [])
        model.set(descriptions: [
            DownloadDescription(id: "m-18", title: "m-18", ageRating: "18"),
            DownloadDescription(id: "m-6", title: "m-6", ageRating: "6"),
        ])
    }

    @Test("H8: The downloads are filtered by the profile that is active now")
    func downloadsFollowProfile() {
        let state = ParentalControlsState(
            store: UserDefaults(suiteName: UUID().uuidString)!, keychain: InMemoryStore(),
            ledgerStore: InMemoryStore())
        let model = DownloadsModel(administration: nil, networkMonitor: nil, parentalControls: state)
        Self.populated(model)
        #expect(model.rows(forItem: .everything).count == 2)

        state.accountKind = .kind
        #expect(state.setPin("1234"))
        state.mode.set(true)
        state.set(limit: .from12)
        #expect(model.rows(forItem: .everything).map(\.title) == ["m-6"])
    }

    @Test("H10: The header counts only what is shown")
    func headerCountsShown() {
        let model = DownloadsModel(networkMonitor: nil, rule: Self.childRule)
        Self.populated(model)
        #expect(model.rows(forItem: .everything).count == 1)
        #expect(model.headerCount.hasPrefix("1 · "))
        #expect(model.downloadLine == nil, "the running download is filtered out")
        #expect(model.shownDownloads.bytes == 1_000)
    }

    // MARK: - H5 · H6 · H9 · Findings read from the source text

    @Test("H5: The straggler writes through the same latch as the session")
    func latecomerLatch() throws {
        let fetcher = try SourceText.read("URLBlockholer.swift", in: .downloads)
        #expect(fetcher.contains("writer.append(data, from: start)"))
        let session = try SourceText.read("BackgroundSession.swift", in: .downloads)
        #expect(session.contains("writer.append(reply.data, from: area.lowerBound)"))
    }

    @Test("H6: A wake call rebuilds the background session of its identifier")
    func wakeCallConnects() throws {
        let text = try SourceText.read("WakeService.swift", in: .phoneApp)
        let arrived = try #require(text.range(of: "WakeNotice.arrived("))
        let connected = try #require(text.range(of: "URLBlockFetcher.reconnect(identifier: identifier)"))
        #expect(arrived.upperBound < connected.lowerBound, "store the completion first")
    }

    @Test("H9: The intro bell mixes in with running music")
    func ringMixes() throws {
        let text = try SourceText.read("IntroStage.swift", in: .featuresPhone)
        #expect(text.contains("setCategory(.ambient, options: [.mixWithOthers])"))
        let shuffle = try #require(text.range(of: "Self.mixWithOthers()"))
        let play = try #require(text.range(of: "controller.bell?.play()"))
        #expect(shuffle.upperBound < play.lowerBound)
    }
}

/// **H11 — Only the most recent question about the location counts.**
@Suite("Wrapper check · location monitor")
@MainActor
struct LocationGuardOrderTests {

    @Test("H11: A superseded reply does not overwrite the newer one")
    func outdatedResponse() async {
        let counter = TallyCounter()
        let watcher = LocationMonitor { _ in
            if await counter.next() == 1 {
                try? await Task.sleep(for: .milliseconds(300))
                return .inFlight
            }
            return .home
        }
        async let first: Void = watcher.verify()
        try? await Task.sleep(for: .milliseconds(50))
        await watcher.verify()
        await first
        #expect(watcher.location == .home)
    }

    @Test("H11: A profile switch determines the location anew")
    func profileSwitchChecks() throws {
        let text = try SourceText.read("ShellModel.swift", in: .featuresPhone)
        let bodyContent = ChildProfilePhoneTests.bodyContent("public func profileSwitched(", in: text)
        #expect(bodyContent.contains("locationMonitor.verify()"))
    }

    private actor TallyCounter {
        private var count = 0
        func next() -> Int {
            count += 1
            return count
        }
    }
}
