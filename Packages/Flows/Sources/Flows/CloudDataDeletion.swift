import CloudSync
import Diagnose
import Foundation
import Observation
import ProfileKit

/// **"Delete all my iCloud data"** — for both apps (on-device test build 1332, finding 10,
/// 2026-09-27).
///
/// **Why in the app and not only in the iOS settings:** the app is becoming commercial, and
/// the right to erasure should be exercisable where the data originates. The
/// production environment cannot be reset in the CloudKit console; until now
/// the only option was the detour via Apple Account → iCloud → Manage Storage.
///
/// **What happens is documented at ``ProfileKit/ProfileCloud/deleteAllCloudData()``**; here
/// are only state, log and sentence for the interface — so that TV and phone show the same
/// confirmation prompt with the same consequence.
@Observable
public final class CloudDataDeletion {

    /// Where the operation stands.
    public enum State: Equatable, Sendable {
        case ready
        case isRunning
        /// Done — with the number of deleted zones, for the log.
        case done(zones: Int)
        /// Failed — with the key of the sentence in the `WordingKit` catalog.
        case failed(message: String)
    }

    public private(set) var state: State = .ready

    /// **Asked for and not held onto**, as with ``ProfileManagement``: the cloud may build the
    /// wrapper only after this view.
    private let cloud: @MainActor () -> ProfileCloud?

    public init(cloud: @escaping @MainActor () -> ProfileCloud? = { ProfileCloud.attached }) {
        self.cloud = cloud
    }

    /// Whether there is a cloud at all — without one the interface does not show the row.
    public var available: Bool { cloud() != nil }

    /// Deletes — **only after the interface's confirmation prompt**, which says what happens.
    ///
    /// It is logged as a notice and not as a step: the operation should appear in every
    /// report, even without detailed recording — a profile that is "suddenly gone"
    /// should be explainable without asking. Without names and identifiers.
    public func delete() async {
        guard state != .isRunning else { return }
        guard let cloud = cloud() else {
            state = .failed(message: Self.message(forItem: .noAccount))
            return
        }
        state = .isRunning
        Diagnose.hint(.login, "iCloud: \"Delete all my iCloud data\" confirmed")
        do throws(CloudError) {
            let zones = try await cloud.deleteAllCloudData()
            Diagnose.hint(
                .login, "iCloud: \(zones) zone(s) deleted, profiles on the device cleared")
            state = .done(zones: zones)
        } catch {
            Diagnose.error(.login, "iCloud: deletion failed", error)
            state = .failed(message: Self.message(forItem: error))
        }
    }

    /// The sentence for a failure. **Without an account** there is nothing to delete, **without a network** it works
    /// later — everything else is a failure that the report explains.
    nonisolated static func message(forItem error: CloudError) -> String {
        switch error {
        case .noAccount: "profiles.icloudDelete.noAccount"
        case .unreachable: "profiles.icloudDelete.offline"
        case .zoneMissing, .deletedByUser, .rejected, .other: "profiles.icloudDelete.failed"
        }
    }
}
