import CloudSync
import Core
import Diagnose
import Foundation
import Household
import Observation
import ProfileKit

/// "Devices & Sharing" — **give a profile, fetch one, and see who is reading along**
/// (AP44; merged in AP58 R2, finding P4).
///
/// **The finding:** The same calls (read the share, remove a participant, end
/// sharing, leave, including revoking the person token), the same page state machine and the same
/// rendering of the code in readable form each lived in the view — on the TV in the `CloudSheet`, on the
/// phone in the `CloudView`. Identical today; the flow lives here so that it stays that way.
///
/// **What stays per device is the way to fetch** (``PullMode``): The TV has no
/// camera and shows a code under which it expects a profile; the phone scans the
/// code of the other device. What happens after that is in the code itself
/// (``ProfileKit/Pairing/Role``).
///
/// **Ending and removing revoke the person token** (decision 8.4, AP47): Whoever
/// stops sharing the profile should no longer be able to sign a device in with the token
/// (``Household/TokenReconciliation/revoke(forItem:)``, including a note for the retry).
@Observable
public final class SharingFlow {

    /// Which of the three states is currently shown.
    public enum Page: Sendable, Equatable {
        case overview
        /// This device shows a code and gives its profile away.
        case gives
        /// This device fetches a profile — with a code or camera, depending on ``PullMode``.
        case isFetching
    }

    /// How this device fetches a profile.
    public enum PullMode: Sendable, Equatable {
        /// Show a code under which a profile is expected (TV, without camera).
        case code
        /// Scan the other device's code (phone).
        case camera
    }

    /// `nil` means: Only fetching happens here — the path behind the "+" card in "Who's watching?".
    public let profile: Profile?
    public let pullMode: PullMode
    public private(set) var page: Page = .overview
    public private(set) var pairing: PairingModel?
    public private(set) var approval: AccessGrant?
    /// The language key of the last failure (``ProfileKit/PairingModel/reason(_:)``).
    public var error: String?

    private let cloud: ProfileCloud
    private let device: String
    private let revoke: @MainActor (Profile.Identifier) async -> Void

    /// - Parameter widerrufe: the revocation of the person token — in the app
    ///   ``Household/TokenReconciliation/onDevice()``, in the checks a recording.
    public init(
        profile: Profile?, cloud: ProfileCloud, pullMode: PullMode,
        device: String = DeviceName.thisDevice,
        revoke: @escaping @MainActor (Profile.Identifier) async -> Void = { identifier in
            await TokenReconciliation.onDevice()?.revoke(forItem: identifier)
        }
    ) {
        self.profile = profile
        self.cloud = cloud
        self.pullMode = pullMode
        self.device = device
        self.revoke = revoke
    }

    /// Whether only fetching happens — then there is no overview.
    public var isPullOnly: Bool { profile == nil }

    /// Whether this profile belongs to another account and is only lent to us.
    public var isBorrowed: Bool {
        profile.flatMap { cloud.zone(forItem: $0.identifier)?.zone?.shared } == true
    }

    /// Who lends it to us — `nil` for an own one.
    public var sharedBy: String? { profile.flatMap { cloud.zone(forItem: $0.identifier)?.sharedBy } }

    // MARK: - Devices

    /// The devices on which this profile runs — **newest first**, from the zone
    /// (2026-10-01, after StoryShelf's "iCloud & Devices").
    ///
    /// Also for a lent profile: The owner's zone lists all devices, and whoever
    /// reads along should see where the profile still runs.
    public private(set) var devices: [DeviceEntry] = []

    /// The ID of this device — for the "this device" mark in the list.
    public var thisDevice: String { cloud.hub.device.identifier }

    /// Re-reads the devices from the zone. Without a profile or zone: none.
    public func loadDevices() {
        guard let profile, let zone = cloud.zone(forItem: profile.identifier) else {
            devices = []
            return
        }
        devices = CloudHub.devices(in: zone)
    }

    /// The names of the devices that a participant has entered — so that "joined via link"
    /// is not the only information left about them.
    public func deviceNames(from participant: Participant) -> [String] {
        devices.filter { $0.creator == participant.identifier }.map(\.name)
    }

    /// Rename a device — **any, not only this one**: Whoever manages the profile should be able to call
    /// the TV in a second household "Living room second household". The name stays, even if
    /// the device later registers itself again (`named`).
    public func rename(device identifier: String, name: String) async {
        guard let profile, let zone = cloud.zone(forItem: profile.identifier) else { return }
        cloud.hub.nameDevice(identifier, name: name, in: zone)
        loadDevices()
        await zone.reconcile()
        loadDevices()
    }

    // MARK: - Give and fetch

    /// Begins an operation — **a fresh pairing model per operation.**
    public func start(_ incoming: Page) {
        guard incoming != .overview else { return }
        let model = PairingModel(cloud: cloud, device: device)
        pairing = model
        page = incoming
        switch incoming {
        case .gives:
            guard let profile else { return }
            Task { await model.give(profile.identifier, title: profile.name) }
        case .isFetching:
            if pullMode == .code { model.search() }
        case .overview:
            break
        }
    }

    /// A profile link opened by the **system camera** (``ProfileKit/ProfileLink``) — the same
    /// flow as with the reader in the app, just without it.
    public func accept(_ link: ProfileLink) async {
        start(.isFetching)
        await pairing?.accept(link)
    }

    /// The camera has read a code — **whether to fetch or give is stated by the code.**
    public func scanned(_ text: String) async {
        guard let model = pairing else { return }
        let offering = profile.map { (identifier: $0.identifier, title: $0.name) }
        await model.scanned(text, offering: offering)
    }

    /// Back — **and the mailbox is emptied in the process** (``ProfileKit/PairingModel/close()``):
    /// A leftover entry would be a valid key in a public
    /// database.
    ///
    /// - Returns: whether the sheet closes now — from the overview and when only fetching.
    @discardableResult
    public func back() async -> Bool {
        guard page != .overview else { return true }
        let model = pairing
        pairing = nil
        page = .overview
        await model?.close()
        guard !isPullOnly else { return true }
        await loadSharing()
        return false
    }

    // MARK: - Who reads along

    /// Reads who is reading along on this profile — for a lent one nothing.
    public func loadSharing() async {
        loadDevices()
        guard let profile, !isBorrowed else { return }
        approval = try? await cloud.approval(profile.identifier)
    }

    public func remove(_ participant: Participant) async {
        guard let profile else { return }
        do throws(CloudError) {
            try await cloud.remove(participant: participant.identifier, from: profile.identifier)
            await revoke(profile.identifier)
            await loadSharing()
        } catch let thrownError {
            Diagnose.hint(.login, "Participant not removed: \(thrownError)")
            error = PairingModel.reason(thrownError)
        }
    }

    public func finish() async {
        guard let profile else { return }
        do throws(CloudError) {
            try await cloud.endSharing(profile.identifier)
            await revoke(profile.identifier)
            approval = nil
        } catch let thrownError {
            Diagnose.hint(.login, "Sharing not ended: \(thrownError)")
            error = PairingModel.reason(thrownError)
        }
    }

    /// Leaves a lent profile.
    ///
    /// - Returns: whether it succeeded — then the profile is no longer on this device.
    @discardableResult
    public func leave() async -> Bool {
        guard let profile else { return false }
        do throws(CloudError) {
            try await cloud.leave(profile.identifier)
            page = .overview
            return true
        } catch let thrownError {
            Diagnose.hint(.login, "Sharing not left: \(thrownError)")
            error = PairingModel.reason(thrownError)
            return false
        }
    }

    // MARK: - Der Code

    /// Sechzehn Zeichen in Vierergruppen — ohne sie liest sie niemand vor.
    public nonisolated static func readable(_ code: String) -> String {
        stride(from: 0, to: code.count, by: 4)
            .map { String(code.dropFirst($0).prefix(4)) }
            .joined(separator: " ")
    }
}
