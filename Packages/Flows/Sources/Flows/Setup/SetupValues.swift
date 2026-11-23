import Foundation
import JellyfinKit
import PortalKit
import ProfileKit

/// What the first setup does differently on the two devices — **the deliberate differences as
/// values** (AP88 §1.1), the same form as ``ProfileStartup/Steps``.
nonisolated public struct SetupSteps: Sendable, Equatable {

    /// How a profile comes over from the phone — the split of ``SharingFlow/PullMode``.
    public enum FetchFromPhone: Sendable, Equatable {
        /// The TV has no camera and shows a code.
        case showCode
        /// The phone scans the other device's code.
        case scan
    }

    /// Whether the intro clip covers the start (AP51). Without it the iCloud deadline runs
    /// from the start and not from the end of the clip.
    public var coversIntro: Bool
    public var fetchFromPhone: FetchFromPhone
    /// Whether the local-network notice stands before the first search (break point 8).
    public var networkNoticeBeforeSearch: Bool
    /// What the device names itself to the CL-Server and to `SelfSignIn`.
    public var deviceKind: DeviceKind

    public init(
        coversIntro: Bool, fetchFromPhone: FetchFromPhone, networkNoticeBeforeSearch: Bool,
        deviceKind: DeviceKind
    ) {
        self.coversIntro = coversIntro
        self.fetchFromPhone = fetchFromPhone
        self.networkNoticeBeforeSearch = networkNoticeBeforeSearch
        self.deviceKind = deviceKind
    }

    public static let tv = SetupSteps(
        coversIntro: true, fetchFromPhone: .showCode, networkNoticeBeforeSearch: true, deviceKind: .tv)
    public static let phone = SetupSteps(
        coversIntro: false, fetchFromPhone: .scan, networkNoticeBeforeSearch: true, deviceKind: .phone)
}

/// What iCloud answered at the first start — **the account apart from the profiles** (AP88 §2.6).
///
/// `CloudHub.start()` returns silently without an account, and ``ProfileKit/ProfileCloud/find(now:)``
/// folds a read failure into `[]`. Both would look like "no profiles", and an unread iCloud
/// would offer "New profile" to someone who has three.
nonisolated public enum CloudAnswer: Sendable, Equatable {
    /// Read, at least one profile that is not yet on this device.
    case profiles([SetupProfile])
    /// Read, none.
    case noProfiles
    case noAccount
    case restricted
    /// The deadline passed, or a read failed.
    case noAnswer

    /// The setup's reading of ``ProfileKit/ProfileCloud/findReporting(now:)``.
    ///
    /// - Parameter describe: adds what only this device knows — the person token arrives with
    ///   the profile (`attachKeychain`), the limit does not.
    public init(
        _ reading: ProfileCloud.Reading, describe: (Profile) -> SetupProfile = { SetupProfile($0) }
    ) {
        switch reading {
        case .found(let profiles): self = profiles.isEmpty ? .noProfiles : .profiles(profiles.map(describe))
        case .noAccount: self = .noAccount
        case .restricted: self = .restricted
        case .unread: self = .noAnswer
        }
    }

    /// The profiles in the answer — empty for every other case.
    public var profiles: [SetupProfile] {
        if case .profiles(let profiles) = self { return profiles }
        return []
    }

    /// Whether the household zone can be used for the code (``SetupPullMode/cloud``).
    public var reachesCloud: Bool {
        switch self {
        case .profiles, .noProfiles: true
        case .noAccount, .restricted, .noAnswer: false
        }
    }
}

/// How "Fetch a profile from the iPhone" travels — **iCloud and the pairing code, or the home
/// network** (`ProfileCreation.PullMode` in `Features`).
nonisolated public enum SetupPullMode: Sendable, Equatable {
    case cloud
    case wire
}

/// A profile as the setup sees it — **the profile plus what only this device knows about it.**
///
/// The person token and the age limit lie in this device's Keychain and never in the book;
/// the core needs both and must not read a Keychain itself.
nonisolated public struct SetupProfile: Sendable, Equatable, Identifiable {
    public var profile: Profile
    /// Whether a CL-Server person token for this profile lies on the device (`PortalMarkerSlot`).
    public var hasPersonTag: Bool
    /// Whether this profile has its own age limit on this device (``ParentalControls/AgeLimit``).
    /// **The limit does not travel through iCloud** (AP88 §10.1).
    public var hasOwnLimit: Bool

    public var id: Profile.Identifier { profile.identifier }

    public init(_ profile: Profile, hasPersonTag: Bool = false, hasOwnLimit: Bool = false) {
        self.profile = profile
        self.hasPersonTag = hasPersonTag
        self.hasOwnLimit = hasOwnLimit
    }

    var isChild: Bool { profile.kind == .kind }
}

/// What A2 offers.
nonisolated public struct WelcomeOffer: Sendable, Equatable {

    /// One profile card.
    public struct Card: Sendable, Equatable {
        public let profile: SetupProfile
        /// **`false` for a child as long as this device has no household PIN** (AP88 §2.3,
        /// question 2). The PIN does not travel through iCloud; a child who picks itself on a
        /// fresh TV would sit in a child profile without a door.
        public let selectable: Bool
    }

    /// Where the focus stands — **owned by the offer so that a late iCloud answer keeps it**
    /// (§2.6): cards that jump under the thumb make someone pick the wrong profile.
    public enum Focus: Sendable, Equatable {
        case newProfile
        case profile(Profile.Identifier)
    }

    public var cards: [Card]
    public var cloud: CloudAnswer
    public var pullMode: SetupPullMode
    /// Whether the QR code stands next to "Fetch from the iPhone" — both ways need a network, and
    /// only a device that shows a code has one (``SetupSteps/FetchFromPhone/showCode``).
    public var showsCode: Bool
    /// Whether "Fetch a profile" leads anywhere. **A device that scans can only fetch through the
    /// household zone** (``SetupPullMode/cloud``): the handoff through the home network goes out
    /// from the phone and never into it.
    public var canFetch: Bool
    public var focus: Focus

    /// Whether the quiet sentence "Choose an adult profile first" appears.
    public var asksForAdultFirst: Bool { cards.contains { !$0.selectable } }
}

/// Why a source row cannot be opened.
nonisolated public enum SourceUnavailability: Sendable, Equatable {
    /// No network — "No network" and not "Not reachable" (§2.4).
    case noNetwork
    /// A child's device is paired by the administrator with a code (§1.4 point 4).
    case notForChildren
}

/// The state of one row in A4 — **a value and not a text.**
nonisolated public enum SourceRowState: Sendable, Equatable {
    /// "Add".
    case empty
    /// "Found" in gold — the home-network search hit something.
    case found(detail: String)
    /// "From your profile · just confirm".
    case fromProfile(Access)
    /// "Take over the lists from Lea" — one press (decision of 2026-11-15 on question 4).
    case suggested(from: String)
    /// ✓.
    case done(detail: String)
    /// CL-Server: request open.
    case waiting
    case unavailable(SourceUnavailability)
}

nonisolated public struct SourceRow: Sendable, Equatable {
    public let kind: Access.Kind
    public let state: SourceRowState

    public init(kind: Access.Kind, state: SourceRowState) {
        self.kind = kind
        self.state = state
    }
}

/// A4: the three rows of one profile.
nonisolated public struct SourcesPage: Sendable, Equatable {
    public let profile: Profile.Identifier
    public let rows: [SourceRow]
    /// The first row that is still open — where the focus goes after a sheet.
    public let focus: Access.Kind?

    public init(profile: Profile.Identifier, rows: [SourceRow], focus: Access.Kind?) {
        self.profile = profile
        self.rows = rows
        self.focus = focus
    }

    /// **"Done" without a source does not go** (§1.4 point 5) — an empty home looks like a
    /// failure.
    public var canFinish: Bool {
        rows.contains { row in
            switch row.state {
            case .done, .waiting: true
            default: false
            }
        }
    }

    public func row(_ kind: Access.Kind) -> SourceRowState? {
        rows.first { $0.kind == kind }?.state
    }
}

/// A5: how the Jellyfin sign-in starts.
nonisolated public enum JellyfinMode: Sendable, Equatable {
    /// Choose a server as today, without the path choice before it.
    case fresh
    /// The address comes from the profile; Quick Connect starts at once.
    case confirm(Access)
    /// **Quick Connect signed in someone else** (§2.8 point 4) — nothing is stored until the
    /// question is answered.
    case otherUser(signedIn: String, expected: String, access: Access)
}

/// A6.
nonisolated public enum ClServerStep: Sendable, Equatable {
    case searching
    case notFound
    case request(RequestState)
    /// A child's device is paired with a code — never a request.
    case childPairing
}

/// How a sheet ended.
nonisolated public enum SourceOutcome: Sendable, Equatable {
    case done(detail: String)
    case waiting
}

/// A7.
nonisolated public struct SetupSummary: Sendable, Equatable {
    public let profile: Profile.Identifier
    public let name: String
    public let rows: [SourceRow]
    /// "Start automatically as Lea".
    public var startChoice: Bool
    /// The row "Parental controls: limit for Mia" — for every child without its own limit on
    /// this device, **including one from iCloud** (§10.1).
    public let offersChildLimit: Bool
}

/// Where the setup stands.
nonisolated public enum SetupState: Sendable, Equatable {
    /// A1 — waiting for iCloud. `introOver` says whether the clip is gone.
    case probing(introOver: Bool)
    /// A2.
    case welcome(WelcomeOffer)
    /// The fetching path (`CloudSheet` or `HandoffReceiveView`), embedded.
    case fetchingFromPhone(SetupPullMode)
    /// A3. `isFirst` decides whether "Back" leads to A2 or to A7.
    case creating(isFirst: Bool, lateCloudHint: Bool)
    /// A3K — a child profile and no household PIN on this device.
    case householdPin(for: Profile.Identifier)
    /// The local-network notice, once per installation, before the first search. `open` is the
    /// row that was pressed, `nil` when the notice follows choosing a profile.
    case networkNotice(then: Profile.Identifier, open: Access.Kind?)
    /// A4.
    case sources(SourcesPage)
    /// A5.
    case jellyfin(Profile.Identifier, JellyfinMode)
    /// The channel-list form.
    case channelList(Profile.Identifier)
    /// A6.
    case clServer(Profile.Identifier, ClServerStep)
    /// A7.
    case done(SetupSummary)
    /// The main screen follows.
    case finished(Profile.Identifier)
}

/// What reaches the machine — from the screens and as answers of the services.
nonisolated public enum SetupInput: Sendable, Equatable {
    case cloudAnswered(CloudAnswer)
    case cloudDeadlinePassed
    case introEnded
    case focusMoved(WelcomeOffer.Focus)
    case chose(Profile.Identifier)
    case choseNew
    case choseFetchFromPhone
    case profileFetched(SetupProfile)
    /// **Several profiles from the phone at once** — the handoff carries the phone's whole book
    /// (`SetupBundle.profile`), and none of them is the one this TV is for. They stand in A2 as
    /// cards; whoever sits in front of the TV picks.
    case profilesArrived([SetupProfile])
    /// A3 saved this profile (``ProfileManagement/save(_:existing:)``).
    case draftSaved(SetupProfile)
    case householdPinSet
    /// ``ProfileKit/ProfileSwitch`` refused the switch (a profile PIN).
    case activationRefused(Profile.Identifier)
    case noticeAcknowledged
    case searchFound(jellyfin: [ServerDiscovery.Found], clServer: URL?)
    case tokenChecked(Profile.Identifier, valid: Bool)
    /// The IDs of the channel lists that are usable on this device.
    case listsAvailable(Set<String>)
    case networkChanged(online: Bool)
    case openSource(Access.Kind)
    /// The own form instead of the suggestion.
    case addOwnChannelList
    case sourceFinished(Access.Kind, SourceOutcome)
    /// A sign-in came back from ``LoginFlow`` — only the user, the credential stays in the
    /// journey.
    case jellyfinSignedIn(userID: String, username: String)
    case acceptOtherUser
    /// A5 "Choose another server" — from the profile's address to the server choice. **The
    /// access in the profile stays** until a sign-in there replaces it (§2.8 point 3).
    case chooseOtherServer
    case sendJoinRequest
    case requestState(RequestState)
    case enrolled(Profile.Identifier, success: Bool)
    case finishSources
    case setStartChoice(Bool)
    case addAnotherProfile
    case start
    case back
    case abort
}

/// What the machine asks the journey to do.
nonisolated public enum SetupEffect: Sendable, Equatable {
    /// Leaving A1 — `DrawReadiness` may draw.
    case drawReady
    case probeCloud
    case startCloudDeadline
    /// `NetworkWatch` before `MainView` (§2.4).
    case watchNetwork
    /// ``ProfileKit/ProfileCloud/adopt(_:now:)`` for the one chosen profile.
    case adoptCloudProfile(Profile)
    /// ``ProfileManagement/switchTo(zu:pin:)`` — **before the first source** (§1.4 point 1).
    case activate(Profile.Identifier)
    case rememberNotice
    case startSearches
    /// Check a token still in the Keychain with one call (§2.1).
    case checkToken(Profile.Identifier, Access)
    case reloadLists
    /// `SelfSignIn` with the person token.
    case enroll(Profile.Identifier)
    case requestJoin(Profile.Identifier)
    case copyChannelLists(from: Profile.Identifier, to: Profile.Identifier)
    /// `SessionStore.signIn` with the credential the journey holds.
    case storeJellyfin
    case applyStartChoice(Profile.Identifier)
}
