import CloudKit
import Testing

@testable import CloudSync

/// Which CloudKit errors in the result of a record affect only this record —
/// and which continue to throw the whole batch (product decision 15).
@Suite("CloudKit service: single-record errors")
struct CloudKitServiceTests {

    @Test(
        "Schema, uniqueness, reference and file concern only the record",
        arguments: [
            CKError.Code.invalidArguments, .serverRejectedRequest, .constraintViolation,
            .referenceViolation, .assetFileNotFound, .assetFileModified,
        ])
    func single(_ code: CKError.Code) {
        #expect(CloudKitService.affectsOnlyRecord(CKError(code)))
    }

    @Test(
        "Network, account, quota, permissions and zone stay total errors",
        arguments: [
            CKError.Code.networkFailure, .networkUnavailable, .serviceUnavailable, .requestRateLimited,
            .notAuthenticated, .quotaExceeded, .permissionFailure, .zoneNotFound, .userDeletedZone,
            .limitExceeded, .batchRequestFailed, .zoneBusy,
        ])
    func total(_ code: CKError.Code) {
        #expect(!CloudKitService.affectsOnlyRecord(CKError(code)))
    }
}

/// When `serverRejectedRequest` does affect the whole batch (review evening 2026-09-25).
@Suite("CloudKit service: results of a batch")
struct CloudKitServiceResultTests {

    let zone = CKRecordZone.ID(zoneName: "profil", ownerName: CKCurrentUserDefaultName)

    func identifier(_ name: String) -> CKRecord.ID { CKRecord.ID(recordName: name, zoneID: zone) }

    func dismissed() -> Result<CKRecord, any Error> { .failure(CKError(.serverRejectedRequest)) }

    @Test("All records rejected, none through: the batch throws as a whole")
    func allRejected() {
        let a = identifier("a")
        let b = identifier("b")
        #expect(throws: CloudError.self) {
            try CloudKitService.results([a, b], [a: dismissed(), b: dismissed()])
        }
    }

    @Test("A single rejected record stays its own rejection")
    func singleRejected() throws {
        let a = identifier("a")
        let results = try CloudKitService.results([a], [a: dismissed()])
        guard case .rejected = results.first else {
            Issue.record("\(results)")
            return
        }
    }

    @Test("One through, one rejected: only that one is rejected")
    func mixed() throws {
        let a = identifier("a")
        let b = identifier("b")
        let results = try CloudKitService.results(
            [a, b], [a: .success(CKRecord(recordType: "Newcomer", recordID: a)), b: dismissed()])
        guard case .stored = results[0], case .rejected = results[1] else {
            Issue.record("\(results)")
            return
        }
    }

    @Test("All with a missing schema (invalidArguments): each record rejected individually")
    func allWithoutSchema() throws {
        let a = identifier("a")
        let b = identifier("b")
        let isMissing: Result<CKRecord, any Error> = .failure(CKError(.invalidArguments))
        let results = try CloudKitService.results([a, b], [a: isMissing, b: isMissing])
        #expect(results.allSatisfy { if case .rejected = $0 { true } else { false } })
    }
}
