import Core
import Foundation
import JellyfinKit
import PlaylistKit
import Testing

@testable import FeaturesPhone

/// The forms behind "Add account" and "New channel list", and what is stored afterwards.
///
/// **Since AP88 wave 6 there is no path choice before them** — the first setup runs on the shared
/// journey (``SetupJourneyPhoneTests``), and a form begins at its path.
@Suite("Setup")
struct SetupTests {

    /// Every check gets its own store — otherwise it sees the set-up of the
    /// previous one. **The Keychain stays out:** it is shared and real, and a
    /// check that writes to it reaches into a running device.
    @MainActor
    private static func state() -> SetupState {
        let name = "probe.\(UUID().uuidString)"
        return SetupState(
            keychain: SecureStore(service: name),
            listen: PlaylistStore(store: InMemoryStore(), secrets: InMemoryStore(), ledger: InMemoryStore()),
            store: UserDefaults(suiteName: name) ?? .standard,
            ledgerStore: InMemoryStore())
    }

    @MainActor
    private static func model() -> SourceFormModel {
        SourceFormModel(state: state(), deviceID: "probe")
    }

    // MARK: - The three routes

    /// **The explanation comes before the system prompt.** Whoever asks without explanation gets
    /// a no that cannot be taken back without a trip to the system settings.
    /// **The explanation appears only when there is something to allow.**
    ///
    /// It announces a broadcast call into the local network and the system prompt for it. As long as
    /// the search is not built, neither of the two happens — the button "Search the
    /// home network" led to an input field, and the announced prompt never came. The
    /// test suite therefore hangs on the switch and not on a fixed step: whoever builds the search
    /// gets the screen back and this check along with it.
    @Test("The server route shows the network explanation only when there is a search")
    @MainActor
    func serverRouteExplainsOnlyWithSearch() {
        let model = Self.model()
        model.chooseJellyfin()
        #expect(model.step == (SourceFormModel.searchBuilt ? .networkPermission : .server))
    }

    /// **Both answers lead on.** Allowing and typing it in yourself land on the same
    /// screen — one with a list of finds, the other with a field.
    @Test("Both answers to the network explanation lead to the server")
    @MainActor
    func bothAnswersContinue() {
        let model = Self.model()
        model.chooseJellyfin()
        model.continueToServer()
        #expect(model.step == .server)
    }

    /// **A form begins at its path** — the navigation that opened it leads out, there is no
    /// path choice behind its first step any more (AP88 wave 6).
    @Test("The first step of a form is its start and has no way back inside it")
    @MainActor
    func formStartsAtItsPath() {
        let state = Self.state()
        let account = SourceFormModel(entry: .jellyfin, state: state, deviceID: "probe")
        #expect(account.step == (SourceFormModel.searchBuilt ? .networkPermission : .server))
        #expect(account.isAtStart)
        account.back()
        #expect(account.isAtStart)

        let list = SourceFormModel(entry: .channelList, state: state, deviceID: "probe")
        #expect(list.step == .channelList)
        list.back()
        #expect(list.step == .channelList)
        #expect(list.isAtStart)
    }

    /// **The way back goes one step and not to the beginning.**
    ///
    /// Until 2026-09-06 it always led to the path choice. But it is taken mostly
    /// to switch the **sign-in path** — and then one stood three screens further back
    /// and had to have the server searched again, with the same address in the field.
    @Test("The way back leads one step back, not to the start")
    @MainActor
    func backOneStep() {
        let model = Self.model()
        model.chooseJellyfin()
        model.continueToServer()
        model.setStepForCheck(.loginRoute)

        model.back()
        #expect(model.step == .server, "from the sign-in route back to the address")

        model.setStepForCheck(.password)
        model.back()
        #expect(model.step == .loginRoute, "from the password back to the sign-in route choice")

        model.setStepForCheck(.code)
        model.back()
        #expect(model.step == .loginRoute, "and from the code likewise")
    }

    /// **The sign-in leads back to its explanation and not out of the form.**
    @Test("From the server the way back leads to the network explanation")
    @MainActor
    func serverLeadsBackToExplanation() {
        let model = Self.model()
        model.continueToServer()
        model.back()
        #expect(model.step == .networkPermission)
        #expect(model.isAtStart)
    }

    /// **No step is a dead end.** From each either a way back leads out or it is an end point
    /// (the first step of a form, where the navigation leads out, and Done) — what is checked is
    /// the property and not an enumeration, so that a new step inherits it.
    @Test("From every step a path leads out")
    @MainActor
    func noDeadEnd() {
        let all: [SourceFormModel.Step] = [
            .networkPermission, .server, .connect, .loginRoute, .password, .code, .channelList, .done,
        ]
        for step in all {
            let model = Self.model()
            model.setStepForCheck(step)
            model.back()
            if [.networkPermission, .channelList, .done].contains(step) {
                #expect(model.step == step, "\(step) is an endpoint")
            } else {
                #expect(model.step != step, "\(step) is a dead end")
            }
        }
    }

    // MARK: - What is stored

    @Test("A provider access ends up in the list store")
    @MainActor
    func channelListIsStored() throws {
        let state = Self.state()
        let model = SourceFormModel(
            state: state, deviceID: "probe", accessInfo: { _, _ in nil })
        let address = try #require(URL(string: "http://anbieter.example:8080"))

        model.addChannelList(
            name: "My provider", address: address, user: "abc", password: "secret")

        #expect(state.channelLists.count == 1)
        #expect(state.channelLists.first?.name == "My provider")
        #expect(state.hasContent)
        #expect(model.step == .done)
    }

    /// **An access that only provides `ts` says so when it is entered** (E34) — as a hint
    /// on the Done screen, not at the first black picture. And one that provides HLS
    /// or does not answer says nothing: a hint without a finding would be noise.
    @Test("Only a pure ts access gets the hint")
    @MainActor
    func rawStreamAccessIsNamed() async throws {
        let address = try #require(URL(string: "http://anbieter.example:8080"))
        for (reply, expected) in [(false, true), (true, false), (nil, false)] as [(Bool?, Bool)] {
            let model = SourceFormModel(
                state: Self.state(), deviceID: "probe",
                accessInfo: { _, _ in reply })
            model.addChannelList(name: "A", address: address, user: "abc", password: "x")
            await model.lookupTask?.value
            #expect((model.accessHint != nil) == expected, "Reply \(String(describing: reply))")
        }
    }

    /// **"Set up" and "something is there" are two questions.** Whoever removes everything
    /// again has seen the set-up anyway.
    @Test("Done and hasContent are independent")
    @MainActor
    func doneIsNotCatalog() {
        let state = Self.state()
        #expect(!state.done)
        #expect(!state.hasContent)

        state.markDone()
        #expect(state.done)
        #expect(!state.hasContent, "done does not mean something is left")
    }

    @Test("Clearing removes everything")
    @MainActor
    func clearingCleansUp() throws {
        let state = Self.state()
        let address = try #require(URL(string: "http://anbieter.example"))
        state.create(
            channelList: Playlist(id: "a", name: "A", kind: .m3u(address)), password: nil)
        state.set(portals: true)
        state.markDone()

        state.clear()

        #expect(state.channelLists.isEmpty)
        #expect(!state.portalsWanted)
        #expect(!state.done)
    }

    // MARK: - The summary

    /// A "Done" without a list leaves open whether the access has arrived.
    @Test("The done page lists what was set up")
    @MainActor
    func summaryListsItems() throws {
        let state = Self.state()
        let model = SourceFormModel(
            state: state, deviceID: "probe", accessInfo: { _, _ in nil })
        let address = try #require(URL(string: "http://anbieter.example"))

        model.addChannelList(
            name: "My provider", address: address, user: "abc", password: "x")

        #expect(model.summary == ["My provider"])
        #expect(model.storedAddress == address, "the first setup's row names the provider's host")
    }

    // MARK: - What is really there after storing

    /// **The most expensive ten-minute job of the walkthrough from 2026-09-06**
    ///
    /// ``SecureStore`` keeps two things separate: the **signed-in** session
    /// (`saveCredentials`) and the **list** of all accesses (`memorize`). The shared
    /// test suite says it literally — "Saving alone does not fill the list". The
    /// set-up called only the first until 2026-09-06; on the shipping path the
    /// account list was thus **always empty**, and the account switch had nothing to switch.
    ///
    /// This check exceptionally touches the real Keychain — under a
    /// service name of its own, and it cleans up after itself. The spot cannot be proven
    /// otherwise: ``SetupState`` takes a ``SecureStore`` and no interface.
    @Test("A stored media server also appears in the account list")
    @MainActor
    func jellyfinFillsTheAccountList() throws {
        let name = "probe.\(UUID().uuidString)"
        let keychain = SecureStore(service: name)
        let state = SetupState(
            keychain: keychain,
            listen: PlaylistStore(store: InMemoryStore(), secrets: InMemoryStore(), ledger: InMemoryStore()),
            store: UserDefaults(suiteName: name) ?? .standard,
            ledgerStore: InMemoryStore())
        let credential = ServerCredentials(
            serverURL: try #require(URL(string: "http://vault.example")),
            userID: "user", username: "user", accessToken: "token")

        state.create(jellyfin: credential)

        #expect(state.jellyfin == credential, "the signed-in session")
        #expect(keychain.allAccounts() == [credential], "and the list that AP3 depends on")

        try? keychain.remove("server.accounts")
        try? keychain.clearCredentials()
    }

    // MARK: - The certificate

    /// **The path was built and ended in nothing.**
    ///
    /// `CertificateTrustStore.evaluate` answers with `.askUser`, the connection delegate
    /// puts the question into the mailbox — and on the phone nobody took it out. The
    /// viewer received "Server not reachable": a message that points in the wrong
    /// direction, because the server is reachable and answers.
    @Test("An open certificate question is asked instead of reported as a network error")
    @MainActor
    func certificatePromptIsAsked() {
        let model = Self.model()
        let query = CertificatePrompt.Pending(
            host: "medienserver.example",
            fingerprint: CertificateFingerprint(certificateData: Data("A".utf8)))
        CertificatePrompt.shared.location(query)
        defer { CertificatePrompt.shared.clear() }

        model.takeCertificatePrompt(fallback: "error.unreachable")

        #expect(model.certificatePrompt == query)
        #expect(model.error == nil, "the question is not a disruption")
    }

    /// **Without an open question it stays with the message.** A mailbox into which nobody
    /// has put anything must not open a screen.
    @Test("Without a certificate question the ordinary message appears")
    @MainActor
    func withoutCertificatePrompt() {
        CertificatePrompt.shared.clear()
        let model = Self.model()
        model.takeCertificatePrompt(fallback: "error.unreachable")
        #expect(model.certificatePrompt == nil)
        #expect(model.error == "error.unreachable")
    }

    /// **Rejected also means: the mailbox is emptied.** A left-over question
    /// would be opened again at the next failure — even if that has nothing to do with a
    /// certificate.
    @Test("Rejecting clears the question")
    @MainActor
    func certificateRejected() {
        let model = Self.model()
        let query = CertificatePrompt.Pending(
            host: "medienserver.example",
            fingerprint: CertificateFingerprint(certificateData: Data("B".utf8)))
        CertificatePrompt.shared.location(query)
        model.takeCertificatePrompt(fallback: "error.unreachable")

        model.rejectCertificate()

        #expect(model.certificatePrompt == nil)
        #expect(CertificatePrompt.shared.current == nil)
        #expect(model.error == "cert.rejected")
        #expect(model.step == .server)
    }

    /// **An unknown and a changed digest are two screens.**
    ///
    /// In the home network an unknown certificate is the normal case; a changed one is the
    /// warning for which the whole procedure was built. What the view uses to tell them
    /// apart is ``CertificatePrompt/Pending/known`` — and nothing else.
    @Test("The question carries whether a digest is new or changed")
    @MainActor
    func newOrChanged() {
        let old = CertificateFingerprint(certificateData: Data("old".utf8))
        let fresh = CertificateFingerprint(certificateData: Data("new".utf8))

        let firstEncounter = CertificatePrompt.Pending(host: "medienserver.example", fingerprint: fresh)
        #expect(firstEncounter.known == nil)

        let switched = CertificatePrompt.Pending(
            host: "medienserver.example", fingerprint: fresh, known: old)
        #expect(switched.known == old)
        // **The same machine with a different digest is a different question.** Otherwise the
        // sheet would stay put on the switch and show the old digest.
        #expect(firstEncounter.id == switched.id, "the identifier depends on the shown digest")
        #expect(
            CertificatePrompt.Pending(host: "medienserver.example", fingerprint: old).id
                != firstEncounter.id)
    }
}

/// The bridge's address — **the finding from 2026-09-06, and it came from the product owner.**
///
/// Requirement: Settings must have an area somewhere where the URL for
/// portals can be maintained. — Yes. The screen said "There is nothing to set here",
/// and that sentence lumped together two things that have nothing to do with each other: which
/// portals exist (App Store rule, unchangeable) and **where the bridge stands** (a
/// machine of the viewer, like the media server).
@MainActor
@Suite("Portals bridge")
struct BridgeAddressTests {

    static func state() -> SetupState {
        let name = "probe.\(UUID().uuidString)"
        return SetupState(
            keychain: SecureStore(service: name),
            listen: PlaylistStore(store: InMemoryStore(), secrets: InMemoryStore(), ledger: InMemoryStore()),
            store: UserDefaults(suiteName: name) ?? .standard,
            ledgerStore: InMemoryStore())
    }

    /// **It lies where the TV stores it** — AP40, 2026-09-20.
    ///
    /// The name `setup.portalBridge` stood here and there, but meant two stores:
    /// `UserDefaults` versus Keychain. And ``SecondScreen/Takeover`` writes a
    /// **handed-over** bridge into the Keychain — so it never arrived here, just like
    /// the age limit before the same correction. The check is therefore done with the
    /// writer of the other side and the reader from here.
    @Test("What a handoff writes to the Keychain, the setup reads")
    func readsWhatTheHandoffWrites() {
        let name = "probe.\(UUID().uuidString)"
        let keychainStore = SecureStore(service: name)
        let state = SetupState(
            keychain: keychainStore,
            listen: PlaylistStore(store: InMemoryStore(), secrets: InMemoryStore(), ledger: InMemoryStore()),
            store: UserDefaults(suiteName: name) ?? .standard,
            ledgerStore: InMemoryStore())
        defer { BridgeAddress.save("", to: keychainStore) }

        // Exactly the path that `Takeover.matches(code:)` takes.
        BridgeAddress.save("http://portals.example:8099", to: keychainStore)

        #expect(state.bridgeURL?.absoluteString.contains("8099") == true)
    }

    /// **An address entered before 2026-09-20 comes over.**
    @Test("The old store is adopted once")
    func adoptsOldAddress() {
        let name = "probe.\(UUID().uuidString)"
        let keychainStore = SecureStore(service: name)
        let store = UserDefaults(suiteName: name) ?? .standard
        store.set("http://bridge.example:9000", forKey: "setup.portalBridge")
        let state = SetupState(
            keychain: keychainStore,
            listen: PlaylistStore(store: InMemoryStore(), secrets: InMemoryStore(), ledger: InMemoryStore()),
            store: store,
            ledgerStore: InMemoryStore())
        defer { BridgeAddress.save("", to: keychainStore) }

        state.adoptBridgeAddress()

        #expect(state.bridgeURL?.absoluteString.contains("9000") == true)
    }

    /// **Without an entry the name from the agreement applies.** `nil` and no prefilled
    /// address: one that stands in the field looks like one that somebody has checked.
    @Test("Without an entry there is no address")
    func withoutEntry() {
        #expect(Self.state().bridgeURL == nil)
    }

    /// **Entered, read, withdrawn.**
    @Test("The address survives and can be taken back")
    func entered() {
        let state = Self.state()
        let address = URL(string: "http://bridge.example:9000")!

        state.set(bridge: address)
        #expect(state.bridgeURL == address)

        // **Empty means back to the name and not "no portals".** There is
        // the switch next to it for that.
        state.set(bridge: nil)
        #expect(state.bridgeURL == nil)
        #expect(!state.portalsWanted, "the switch is unaffected by this")
    }

    /// **And clearing removes both.** A left-over address would, after
    /// removal, point to a machine that nobody has chosen any more.
    @Test("Clearing takes the address along")
    func clearingTakesThemAlong() {
        let state = Self.state()
        state.set(bridge: URL(string: "http://bridge.example:9000"))
        state.set(portals: true)

        state.clear()

        #expect(state.bridgeURL == nil)
        #expect(!state.portalsWanted)
    }
}

/// The search in the home network — what can be checked without a network.
///
/// **Whether a request arrives is told only by a real network** (measured on 2026-09-10: 253
/// addresses in 4.3 s, the home server found). What stands here are the two
/// places where an error would stay silent: a search that runs although it was refused,
/// and a server that appears twice in the list.
@Suite("Search on the home network")
@MainActor
struct ServerDiscoveryTests {

    private func model() -> SourceFormModel {
        let name = "probe.\(UUID().uuidString)"
        return SourceFormModel(
            state: SetupState(
                keychain: SecureStore(service: name),
                listen: PlaylistStore(
                    store: InMemoryStore(), secrets: InMemoryStore(), ledger: InMemoryStore()),
                store: UserDefaults(suiteName: name) ?? .standard,
                ledgerStore: InMemoryStore()),
            deviceID: "probe")
    }

    @Test("Typing by hand triggers no search")
    func manualDoesNotSearch() {
        // **The case that breaks the promise of the screen before it.** ``NetworkLawView``
        // expressly offers the path that does **not** trigger the system prompt; if
        // the search started anyway, the prompt would appear precisely for the one who refused
        // it.
        let model = model()
        model.chooseJellyfin()
        model.continueToServer()

        #expect(model.step == .server)
        #expect(!model.isSearching)
        #expect(model.found.isEmpty)
    }

    @Test("The same server appears only once in the list")
    func noServerTwice() {
        // Measured on 2026-09-10: the home server answers under both of its addresses with
        // the same identifier.
        let model = model()
        let a = ServerDiscovery.Found(
            id: "3c37", name: "test-server", address: URL(string: "http://192.168.1.13:8096")!)
        let b = ServerDiscovery.Found(
            id: "3c37", name: "test-server", address: URL(string: "http://192.168.1.14:8096")!)

        model.takeDiscoveryForTesting(a)
        model.takeDiscoveryForTesting(b)

        #expect(model.found.count == 1)
        #expect(model.found.first?.address.absoluteString == "http://192.168.1.13:8096")
    }
}
