import Core
import Foundation
import JellyfinKit
import ProfileKit

/// What the first setup needs from the outside — **injected, as with ``LoginServices``.**
///
/// The holders behind it (`CloudStartup`, `SessionStore`, `NetworkWatch`, the list store, the
/// pairing) live in the app shell; the core knows them only as these calls. The shell builds
/// the real set in wave 2; the checks pass ``mock(cloud:search:)``.
public struct SetupServices {

    /// What the home-network search found.
    public struct SearchReport: Sendable, Equatable {
        public var jellyfin: [ServerDiscovery.Found]
        public var clServer: URL?

        public init(jellyfin: [ServerDiscovery.Found] = [], clServer: URL? = nil) {
            self.jellyfin = jellyfin
            self.clServer = clServer
        }
    }

    /// ``ProfileKit/ProfileCloud/findReporting(now:)``, read as a ``CloudAnswer``.
    public var probeCloud: @MainActor () async -> CloudAnswer
    /// Waits — `Task.sleep` in the program, a hand-driven clock in the checks.
    public var wait: @MainActor (Duration) async -> Void
    /// `DrawReadiness.notify()`.
    public var drawReady: @MainActor () -> Void
    /// Reports the network state now and on every change.
    public var watchNetwork: @MainActor (@escaping @MainActor (Bool) -> Void) -> Void
    public var adoptCloudProfile: @MainActor (Profile) -> Void
    /// ``ProfileManagement/switchTo(zu:pin:)`` — `false` if the switch was refused.
    public var activate: @MainActor (Profile.Identifier) -> Bool
    public var rememberNotice: @MainActor () -> Void
    public var search: @MainActor () async -> SearchReport
    /// Whether a token still in the Keychain is valid for this access (`/Users/Me`).
    public var checkToken: @MainActor (Access) async -> Bool
    /// Re-reads the list store and returns the IDs of the usable lists.
    public var reloadLists: @MainActor () -> Set<String>
    /// `SelfSignIn` with the occasion of the setup.
    public var enroll: @MainActor (Profile.Identifier) async -> Bool
    /// ``JoinRequester/location(forItem:)`` for the setup's profile — not the active one.
    public var requestJoin: @MainActor (Profile.Identifier) async -> RequestState
    public var copyChannelLists: @MainActor (_ from: Profile.Identifier, _ to: Profile.Identifier) -> Void
    /// `SessionStore.signIn`.
    public var storeJellyfin: @MainActor (ServerCredentials) -> Void
    /// `StartChoice.set`.
    public var applyStartChoice: @MainActor (Profile.Identifier) -> Void
    /// A fresh code for the QR on A2 — `nil` if none can be issued.
    public var issueCode: @MainActor () async -> String?
    /// Withdraws a code — **before the next one is valid** (§4.2).
    public var revokeCode: @MainActor (String) -> Void
    /// How long a code is valid.
    public var codeValidity: Duration

    public init(
        probeCloud: @escaping @MainActor () async -> CloudAnswer,
        wait: @escaping @MainActor (Duration) async -> Void,
        drawReady: @escaping @MainActor () -> Void,
        watchNetwork: @escaping @MainActor (@escaping @MainActor (Bool) -> Void) -> Void,
        adoptCloudProfile: @escaping @MainActor (Profile) -> Void,
        activate: @escaping @MainActor (Profile.Identifier) -> Bool,
        rememberNotice: @escaping @MainActor () -> Void,
        search: @escaping @MainActor () async -> SearchReport,
        checkToken: @escaping @MainActor (Access) async -> Bool,
        reloadLists: @escaping @MainActor () -> Set<String>,
        enroll: @escaping @MainActor (Profile.Identifier) async -> Bool,
        requestJoin: @escaping @MainActor (Profile.Identifier) async -> RequestState,
        copyChannelLists: @escaping @MainActor (Profile.Identifier, Profile.Identifier) -> Void,
        storeJellyfin: @escaping @MainActor (ServerCredentials) -> Void,
        applyStartChoice: @escaping @MainActor (Profile.Identifier) -> Void,
        issueCode: @escaping @MainActor () async -> String?,
        revokeCode: @escaping @MainActor (String) -> Void,
        codeValidity: Duration
    ) {
        self.probeCloud = probeCloud
        self.wait = wait
        self.drawReady = drawReady
        self.watchNetwork = watchNetwork
        self.adoptCloudProfile = adoptCloudProfile
        self.activate = activate
        self.rememberNotice = rememberNotice
        self.search = search
        self.checkToken = checkToken
        self.reloadLists = reloadLists
        self.enroll = enroll
        self.requestJoin = requestJoin
        self.copyChannelLists = copyChannelLists
        self.storeJellyfin = storeJellyfin
        self.applyStartChoice = applyStartChoice
        self.issueCode = issueCode
        self.revokeCode = revokeCode
        self.codeValidity = codeValidity
    }

    /// A setup without a world — **only for checks.** Everything that a check does not name
    /// answers like an empty household: no token, no enrollment, no code, a clock that never
    /// runs out.
    @_spi(Check) public static func mock(
        cloud: CloudAnswer = .noProfiles, search: SearchReport = SearchReport()
    ) -> SetupServices {
        SetupServices(
            probeCloud: { cloud },
            wait: { try? await Task.sleep(for: $0 * 3600) },
            drawReady: {},
            watchNetwork: { $0(true) },
            adoptCloudProfile: { _ in },
            activate: { _ in true },
            rememberNotice: {},
            search: { search },
            checkToken: { _ in false },
            reloadLists: { [] },
            enroll: { _ in false },
            requestJoin: { _ in .none },
            copyChannelLists: { _, _ in },
            storeJellyfin: { _ in },
            applyStartChoice: { _ in },
            issueCode: { nil },
            revokeCode: { _ in },
            codeValidity: .seconds(180))
    }
}
