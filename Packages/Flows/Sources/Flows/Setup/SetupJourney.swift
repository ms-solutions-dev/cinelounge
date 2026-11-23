import Core
import Foundation
import Observation
import ProfileKit

/// The thin layer around ``SetupMachine`` — **performs its effects and feeds the answers back**
/// (AP88 §1.1).
///
/// Everything with time lives here: the iCloud question, the deadline after the clip, the
/// search, the renewal of the QR code. The machine stays a value that a check drives without a
/// clock; this layer is checked with ``SetupServices/mock(cloud:search:)`` and a clock of its own.
@Observable
public final class SetupJourney {

    public private(set) var machine: SetupMachine
    /// The code the QR on A2 shows — `nil` while none is valid.
    public private(set) var pairingCode: String?

    public var state: SetupState { machine.state }

    @ObservationIgnored private let services: SetupServices
    /// The sign-in that waits for the machine's word (``SetupEffect/storeJellyfin``) — **never
    /// stored before**, so that another user's Quick Connect cannot slip into the profile
    /// (§2.8 point 4).
    @ObservationIgnored private var pendingCredential: ServerCredentials?
    @ObservationIgnored private var work: [Task<Void, Never>] = []
    @ObservationIgnored private var timers: [Task<Void, Never>] = []
    @ObservationIgnored private var codeRun: Task<Void, Never>?

    public init(_ machine: SetupMachine, services: SetupServices) {
        self.machine = machine
        self.services = services
    }

    /// Starts the iCloud question, the network watch and, without an intro, the deadline.
    public func start() {
        perform(machine.begin())
    }

    public func send(_ input: SetupInput) {
        perform(machine.handle(input))
    }

    /// ``LoginFlow``'s `persist` — **only the user goes to the machine**; the credential waits
    /// here until the machine allows storing it.
    public func signedIn(_ credential: ServerCredentials) {
        pendingCredential = credential
        send(.jellyfinSignedIn(userID: credential.userID, username: credential.username))
    }

    /// Waits until every running answer has come back — **for checks.** Timers do not count;
    /// a check moves its clock itself.
    @_spi(Check) public func settle() async {
        while !work.isEmpty {
            let running = work
            work = []
            for task in running { await task.value }
        }
    }

    /// Stops what still runs — the clock, the code loop and the open code.
    public func stop() {
        for task in work + timers { task.cancel() }
        work = []
        timers = []
        stopCode()
    }

    // MARK: - Effects

    /// **An `activate` that is refused stops the batch** — every effect behind it belongs to
    /// a profile that did not become active.
    private func perform(_ effects: [SetupEffect]) {
        for effect in effects {
            if case .activate(let identifier) = effect, !services.activate(identifier) {
                send(.activationRefused(identifier))
                return
            }
            run(effect)
        }
        followCode()
    }

    private func run(_ effect: SetupEffect) {
        switch effect {
        case .drawReady: services.drawReady()
        case .probeCloud:
            answer {
                await $0.services.probeCloud()
            } then: {
                .cloudAnswered($0)
            }
        case .startCloudDeadline:
            timers.append(
                Task { [weak self, services] in
                    await services.wait(SetupMachine.cloudGrace)
                    guard !Task.isCancelled else { return }
                    self?.send(.cloudDeadlinePassed)
                })
        case .watchNetwork:
            services.watchNetwork { [weak self] online in self?.send(.networkChanged(online: online)) }
        case .adoptCloudProfile(let profile): services.adoptCloudProfile(profile)
        case .activate: break
        case .rememberNotice: services.rememberNotice()
        case .startSearches:
            answer {
                await $0.services.search()
            } then: {
                .searchFound(jellyfin: $0.jellyfin, clServer: $0.clServer)
            }
        case .checkToken(let identifier, let access):
            answer {
                await $0.services.checkToken(access)
            } then: {
                .tokenChecked(identifier, valid: $0)
            }
        case .reloadLists:
            answer {
                $0.services.reloadLists()
            } then: {
                .listsAvailable($0)
            }
        case .enroll(let identifier):
            answer {
                await $0.services.enroll(identifier)
            } then: {
                .enrolled(identifier, success: $0)
            }
        case .requestJoin(let identifier):
            answer {
                await $0.services.requestJoin(identifier)
            } then: {
                .requestState($0)
            }
        case .copyChannelLists(let donor, let target): services.copyChannelLists(donor, target)
        case .storeJellyfin:
            if let pendingCredential { services.storeJellyfin(pendingCredential) }
            pendingCredential = nil
        case .applyStartChoice(let identifier): services.applyStartChoice(identifier)
        }
    }

    /// Runs a service call and sends its answer to the machine — **always after the current
    /// batch**, so that no answer overtakes the effects that caused it.
    private func answer<Value>(
        _ call: @escaping @MainActor (SetupJourney) async -> Value,
        then input: @escaping @MainActor (Value) -> SetupInput
    ) {
        work.append(
            Task { [weak self] in
                await Task.yield()
                guard let self else { return }
                let value = await call(self)
                guard !Task.isCancelled else { return }
                self.send(input(value))
            })
    }

    // MARK: - The code on A2

    /// Keeps a code valid while A2 shows one — **and only one at a time** (§4.2): the old one is
    /// withdrawn before the next is issued.
    private func followCode() {
        guard case .welcome(let offer) = machine.state, offer.showsCode else {
            stopCode()
            return
        }
        guard codeRun == nil else { return }
        codeRun = Task { [weak self, services] in
            while !Task.isCancelled {
                if let old = self?.pairingCode {
                    services.revokeCode(old)
                    self?.pairingCode = nil
                }
                let fresh = await services.issueCode()
                guard !Task.isCancelled else {
                    if let fresh { services.revokeCode(fresh) }
                    return
                }
                self?.pairingCode = fresh
                await services.wait(services.codeValidity)
            }
        }
    }

    private func stopCode() {
        codeRun?.cancel()
        codeRun = nil
        if let pairingCode { services.revokeCode(pairingCode) }
        pairingCode = nil
    }
}
