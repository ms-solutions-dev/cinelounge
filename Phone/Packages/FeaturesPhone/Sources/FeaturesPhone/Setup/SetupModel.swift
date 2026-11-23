import Core
import Flows
import Foundation
import Observation
import ParentalControls
import ProfileKit

/// The phone's first setup — **the same ``Flows/SetupJourney`` as on the TV** (AP88 wave 6).
///
/// **Person first, then their sources**, in the same order and through the same machine: A1 a
/// short wait for iCloud (skippable, there is no intro to cover it), A2 "Who's watching here?",
/// A3 the profile, the notice before the first search, A4 Jellyfin, IPTV and CL-Server with the
/// same row states, A5 and A6 as sheets, A7 the summary. What differs is a value
/// (``Flows/SetupSteps/phone``): no intro, the camera scans instead of a code being shown.
///
/// **Until wave 6 this was the path choice** with three cards (`PathChoiceView`), and every
/// source landed in a profile that did not exist yet: `SetupState.create` wrote with
/// ``ProfileKit/ProfileAccesses/create(_:in:)`` into the active profile, and a fresh phone had
/// none (finding 1). The machine now makes the profile active before the first source.
///
/// **What lives here and not in the views:** the sheets that outlive a redraw (A5's sign-in, the
/// IPTV form), and the end of the run.
@MainActor
@Observable
public final class SetupModel {

    public let journey: SetupJourney

    @ObservationIgnored let stores: SetupHub.Stores
    @ObservationIgnored let deviceID: String
    /// The profiles in the book when a code from the system camera opened — **to tell which one
    /// it brought** (``Flows/SetupWorld/arrivals(before:in:named:carried:)``).
    @ObservationIgnored private var beforeLink: Set<Profile.Identifier>?

    init(_ journey: SetupJourney, stores: SetupHub.Stores, deviceID: String) {
        self.journey = journey
        self.stores = stores
        self.deviceID = deviceID
    }

    public var state: Flows.SetupState { journey.state }

    public func send(_ input: SetupInput) {
        journey.send(input)
    }

    /// Whether the run is over and the shell may show the tabs.
    public var isFinished: Bool {
        if case .finished = state { return true }
        return false
    }

    /// The setup's profile for a sheet's head ("Lea · Jellyfin").
    func profile(_ identifier: Profile.Identifier) -> SetupProfile? {
        journey.machine.setupProfile(identifier)
    }

    /// A profile from the book as the machine wants it — with what only the Keychain knows.
    func describe(_ profile: Profile) -> SetupProfile {
        SetupHub.describe(profile, stores: stores)
    }

    // MARK: - The sheets

    /// A5 — **a fresh sign-in for every time the sheet opens**, over the shared
    /// ``Flows/SetupJellyfinSheet`` and with the phone's search (both at once).
    func jellyfinSheet() -> SetupJellyfinSheet {
        SetupJellyfinSheet(
            journey: journey, deviceID: deviceID, deviceName: DeviceName.thisDevice,
            isChildAccount: { ChildAccountList().isChild($0) }, searchMode: .bothAtOnce)
    }

    /// The IPTV form of A4 — **the settings' form** (``SourceFormModel``), writing into the
    /// active profile, which the machine made the setup's profile.
    func channelListForm() -> SourceFormModel {
        SourceFormModel(entry: .channelList, state: stores.setupState, deviceID: deviceID)
    }

    /// The CL-Server calls of A6.
    var clServerCalls: SetupClServerCalls { SetupClServerCalls(stores: stores) }

    // MARK: - A code from the system camera

    /// A profile code opened while the setup runs — **the book before it**, so that its arrival
    /// can be named afterwards.
    public func linkOpened() {
        beforeLink = Set(ProfileBook.read(from: stores.ledger).profile.map(\.identifier))
    }

    /// The code's sheet closed — **a profile it brought leads into its A4** (§4.1), as through
    /// "Get a profile with a code".
    public func linkClosed() {
        guard let before = beforeLink else { return }
        beforeLink = nil
        let arrival = SetupWorld.arrivals(before: before, in: ProfileBook.read(from: stores.ledger))
        if let input = arrival.input(describe: describe) { journey.send(input) }
    }

    // MARK: - The end

    /// The machine reached `finished` — **the profiles nobody chose come into the book**.
    public func finish() {
        SetupHub.finish(self)
    }
}
