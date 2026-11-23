import CloudKit
import Foundation

/// The ``CloudService`` against the real CloudKit — the container
/// `iCloud.dev.ms-solutions.storyshelf`, private and shared database.
///
/// Everything CloudKit brings in types (`CKRecord`, `CKShare`, tokens) stays in
/// this file: outward go ``CloudRecord``, ``ZoneID`` and `Data`
/// as token or seal. The system fields of a `CKRecord` (with the
/// change tag) are archived as a seal and become the record again on the next save
/// — this way `ifServerRecordUnchanged` stays effective across a restart.
///
/// **Fields:** text → `String`, number → `Int64`, decimal → `Double`, time → `Date`,
/// truth → `Int64` (CloudKit has none), bytes → `Data` (under 1 MB — our
/// records are bytes to kilobytes). Plus `changed` as a field of its own, the
/// clock of the ``MergeRule``.
///
/// **Errors** are mapped to ``CloudError``: network and rate → unreachable
/// (the zone waits), zone missing or deleted by the user → zone missing, account → no
/// account, rights/quota/unknown field → rejected with reason (then appears in the
/// diagnostic line — "Feld unbekannt" means: schema not in production). **On
/// save** a schema error affects only its record: it comes back as
/// ``SaveResult/rejected(_:)``, see ``affectsOnlyRecord(_:)``.
public struct CloudKitService: CloudService {

    static let changedField = "geaendert"

    private let container: CKContainer
    /// Siehe ``CloudService/environment``.
    public let environment: String?
    private let privateSubscription: String
    private let sharedSubscription: String

    /// - Parameters:
    ///   - container: The container ID of this app, for example
    ///     `iCloud.dev.ms-solutions.storyshelf`. **No default, and that is deliberate:**
    ///     Since this package lives in `grundstock`, several apps use it. A
    ///     default would mean that the app that forgets it silently writes into another
    ///     app's container — no error, no message, foreign data. The same rule
    ///     as for `ContentSource.listChanges()` and `tracksStateItself`.
    ///   - subscriptionPrefix: The name prefix of the two database subscriptions
    ///     (`<prefix>-privat`, `<prefix>-shared`). **It must never change**: A
    ///     new name creates a second subscription instead of replacing the existing one,
    ///     and then every silent push arrives twice.
    ///   - environment: The CloudKit environment of this build (`"Production"`, `"Development"`),
    ///     as it appears in the entitlements — or `nil` if the app does not fix it;
    ///     then the environment guard of the ``ProfileZone`` stays off. **No default**, for
    ///     the same reason as with the container: an app should make a decision.
    public init(container: String, subscriptionPrefix: String, environment: String?) {
        self.container = CKContainer(identifier: container)
        self.environment = environment
        self.privateSubscription = "\(subscriptionPrefix)-privat"
        self.sharedSubscription = "\(subscriptionPrefix)-geteilt"
    }

    private func database(_ zone: ZoneID) -> CKDatabase {
        zone.shared ? container.sharedCloudDatabase : container.privateCloudDatabase
    }

    private func database(shared: Bool) -> CKDatabase {
        shared ? container.sharedCloudDatabase : container.privateCloudDatabase
    }

    private func zoneID(_ zone: ZoneID) -> CKRecordZone.ID {
        CKRecordZone.ID(zoneName: zone.name, ownerName: zone.owner ?? CKCurrentUserDefaultName)
    }

    private func identifier(_ id: CKRecordZone.ID, shared: Bool) -> ZoneID {
        ZoneID(name: id.zoneName, owner: shared ? id.ownerName : nil)
    }

    // MARK: - Konto

    public func accountStatus() async -> AccountStatus {
        switch try? await container.accountStatus() {
        case .available: .available
        case .noAccount: .noAccount
        case .restricted, .temporarilyUnavailable: .restricted
        default: .unknown
        }
    }

    public func accountChanges() -> AsyncStream<Void> {
        AsyncStream { continuation in
            let task = Task {
                for await _ in NotificationCenter.default.notifications(named: .CKAccountChanged).map({ _ in
                    ()
                }) {
                    continuation.yield()
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - Zonen

    /// The new API reports the failure of a zone **in the result**, not as a throw —
    /// whoever merely writes `try` takes a zone that was never created for created (build 225:
    /// "Freigabe nicht gespeichert" without a reason).
    public func create(_ zone: ZoneID) async throws(CloudError) {
        do {
            let (results, _) = try await database(zone).modifyRecordZones(
                saving: [CKRecordZone(zoneID: zoneID(zone))], deleting: [])
            if case .failure(let error)? = results[zoneID(zone)] { throw CloudError(error) }
        } catch let caughtError as CloudError {
            throw caughtError
        } catch { throw CloudError(error) }
    }

    public func delete(_ zone: ZoneID) async throws(CloudError) {
        do {
            _ = try await database(zone).modifyRecordZones(saving: [], deleting: [zoneID(zone)])
        } catch {
            let caughtError = CloudError(error)
            if caughtError != .zoneMissing, caughtError != .deletedByUser { throw caughtError }
        }
    }

    public func zones(shared: Bool) async throws(CloudError) -> [ZoneID] {
        do {
            return try await database(shared: shared).allRecordZones().map {
                identifier($0.zoneID, shared: shared)
            }
        } catch { throw CloudError(error) }
    }

    public func databaseChanges(
        shared: Bool, since tag: Data?
    ) async throws(CloudError)
        -> DatabaseChanges
    {
        let db = database(shared: shared)
        let start = CloudKitService.token(tag)
        do {
            return try await withCheckedThrowingContinuation { continuation in
                let op = CKFetchDatabaseChangesOperation(previousServerChangeToken: start)
                let collector = Collector()
                op.recordZoneWithIDChangedBlock = { id in
                    collector.changed.append(identifier(id, shared: shared))
                }
                op.recordZoneWithIDWasDeletedBlock = { id in
                    collector.deleted.append(identifier(id, shared: shared))
                }
                // **Deleted and deleted by the user kept apart** (2026-09-27): "purged" is
                // deletion in the iOS settings, and the loss of the encrypted data is
                // likewise a step taken by the person — see ``CloudError/deletedByUser``.
                op.recordZoneWithIDWasPurgedBlock = { id in
                    collector.deleted.append(identifier(id, shared: shared))
                    collector.byUser.append(identifier(id, shared: shared))
                }
                op.recordZoneWithIDWasDeletedDueToUserEncryptedDataResetBlock = { id in
                    collector.deleted.append(identifier(id, shared: shared))
                    collector.byUser.append(identifier(id, shared: shared))
                }
                op.fetchDatabaseChangesResultBlock = { result in
                    switch result {
                    case .success(let (token, _)):
                        continuation.resume(
                            returning: DatabaseChanges(
                                changed: collector.changed, deleted: collector.deleted,
                                deletedByUser: collector.byUser,
                                tag: CloudKitService.tokenData(token)))
                    case .failure(let error): continuation.resume(throwing: error)
                    }
                }
                op.qualityOfService = .userInitiated
                db.add(op)
            }
        } catch {
            let caughtError = CloudError(error)
            if case CKError.changeTokenExpired = error, tag != nil {
                return try await databaseChanges(shared: shared, since: nil)
            }
            throw caughtError
        }
    }

    // MARK: - Records

    public func changes(_ zone: ZoneID, since tag: Data?) async throws(CloudError) -> Changes {
        let db = database(zone)
        let id = zoneID(zone)
        let configuration = CKFetchRecordZoneChangesOperation.ZoneConfiguration()
        configuration.previousServerChangeToken = CloudKitService.token(tag)
        do {
            return try await withCheckedThrowingContinuation { continuation in
                let op = CKFetchRecordZoneChangesOperation(
                    recordZoneIDs: [id], configurationsByRecordZoneID: [id: configuration])
                let collector = Collector()
                op.recordWasChangedBlock = { _, result in
                    if case .success(let record) = result, record.recordType != CKRecord.SystemType.share {
                        collector.wordings.append(CloudKitService.record(record))
                    }
                }
                op.recordWithIDWasDeletedBlock = { recordID, contentType in
                    collector.names.append(RecordName(contentType: contentType, name: recordID.recordName))
                }
                op.recordZoneFetchResultBlock = { _, result in
                    switch result {
                    case .success(let (token, _, _)): collector.tag = CloudKitService.tokenData(token)
                    case .failure(let error): collector.error = error
                    }
                }
                op.fetchRecordZoneChangesResultBlock = { result in
                    if let error = collector.error {
                        continuation.resume(throwing: error)
                        return
                    }
                    switch result {
                    case .success:
                        continuation.resume(
                            returning: Changes(
                                changed: collector.wordings, deleted: collector.names, tag: collector.tag))
                    case .failure(let error): continuation.resume(throwing: error)
                    }
                }
                op.qualityOfService = .userInitiated
                db.add(op)
            }
        } catch {
            if case CKError.changeTokenExpired = error, tag != nil {
                return try await changes(zone, since: nil)
            }
            throw CloudError(error)
        }
    }

    public func read(
        _ names: [RecordName], in zone: ZoneID
    ) async throws(CloudError)
        -> [CloudRecord]
    {
        let id = zoneID(zone)
        do {
            let results = try await database(zone).records(
                for: names.map { CKRecord.ID(recordName: $0.name, zoneID: id) })
            return results.values.compactMap { result in
                if case .success(let record) = result { return CloudKitService.record(record) }
                return nil
            }
        } catch { throw CloudError(error) }
    }

    public func save(
        _ wordings: [CloudRecord], in zone: ZoneID
    ) async throws(CloudError)
        -> [SaveResult]
    {
        let id = zoneID(zone)
        let records = wordings.map { CloudKitService.record($0, zone: id) }
        do {
            let (stored, _) = try await database(zone).modifyRecords(
                saving: records, deleting: [], savePolicy: .ifServerRecordUnchanged, atomically: false)
            return try CloudKitService.results(records.map(\.recordID), stored)
        } catch let caughtError as CloudError {
            throw caughtError
        } catch { throw CloudError(error) }
    }

    /// The response of `modifyRecords` per record sent, in the order of the
    /// IDs.
    ///
    /// **All rejected, none through — then it was the request.**
    /// `serverRejectedRequest` is in ``affectsOnlyRecord(_:)`` because older systems
    /// report the missing schema of *one* type that way. The same code also comes, however, when
    /// the server rejects the whole request and puts it into every individual result; then
    /// the whole batch would drop out of the queue record by record as rejected. If
    /// therefore at least two records carry this code and not a single one got through, the
    /// batch as a whole throws, and the queue stays in place.
    static func results(
        _ identifiers: [CKRecord.ID], _ stored: [CKRecord.ID: Result<CKRecord, any Error>]
    ) throws(CloudError) -> [SaveResult] {
        let dismissed = identifiers.compactMap { identifier -> (any Error)? in
            guard case .failure(let error) = stored[identifier],
                (error as? CKError)?.code == .serverRejectedRequest
            else { return nil }
            return error
        }
        if identifiers.count >= 2, dismissed.count == identifiers.count, let first = dismissed.first {
            throw CloudError(first)
        }
        return try identifiers.map { identifier throws(CloudError) -> SaveResult in
            switch stored[identifier] {
            case .success(let fresh): return .stored(CloudKitService.record(fresh))
            case .failure(let error):
                if let ck = error as? CKError {
                    if ck.code == .serverRecordChanged, let server = ck.serverRecord {
                        return .conflict(server: CloudKitService.record(server))
                    }
                    if ck.code == .unknownItem { return .vanished }
                    if CloudKitService.affectsOnlyRecord(ck) {
                        return .rejected("\(ck.localizedDescription) (CKError \(ck.code.rawValue))")
                    }
                }
                throw CloudError(error)
            case nil: return .vanished
            }
        }
    }

    /// Whether an error **from the result of a single record** affects only that record
    /// — then it goes back as ``SaveResult/rejected(_:)``, and the
    /// remaining records of the batch stay saved (product decision 15).
    ///
    /// **The list is narrow, and that is deliberate.** CloudKit puts errors of the whole
    /// request or of the zone (network, account, quota, rights, zone missing) *also* per
    /// record into the result; treating such an error as an individual error would mean throwing the whole batch
    /// out of the queue. Only the codes that depend on the content
    /// of a record are therefore listed here:
    /// - `invalidArguments` (12): "Cannot create new type … in production schema",
    ///   "Cannot create or modify field" — the record type or a field is missing in the
    ///   production schema, or a field has a different type there.
    /// - `serverRejectedRequest` (15): older systems report the missing schema
    ///   of a type that way; in the result of *one record* it is its error. If all
    ///   records of a batch carry it, ``results(_:_:)`` throws for the whole one after all.
    /// - `constraintViolation` (19), `referenceViolation` (31): uniqueness or
    ///   reference of this record.
    /// - `assetFileNotFound` (16), `assetFileModified` (17): the file of a field.
    static func affectsOnlyRecord(_ error: CKError) -> Bool {
        switch error.code {
        case .invalidArguments, .serverRejectedRequest, .constraintViolation, .referenceViolation,
            .assetFileNotFound, .assetFileModified:
            true
        default: false
        }
    }

    public func delete(_ names: [RecordName], in zone: ZoneID) async throws(CloudError) {
        let id = zoneID(zone)
        do {
            let (_, deleted) = try await database(zone).modifyRecords(
                saving: [], deleting: names.map { CKRecord.ID(recordName: $0.name, zoneID: id) },
                savePolicy: .ifServerRecordUnchanged, atomically: false)
            for (_, result) in deleted {
                if case .failure(let error) = result, (error as? CKError)?.code != .unknownItem {
                    throw CloudError(error)
                }
            }
        } catch let caughtError as CloudError {
            throw caughtError
        } catch { throw CloudError(error) }
    }

    // MARK: - Pushes

    public func subscribe() async throws(CloudError) {
        do {
            for (db, identifier) in [
                (container.privateCloudDatabase, privateSubscription),
                (container.sharedCloudDatabase, sharedSubscription),
            ] {
                let subscription = CKDatabaseSubscription(subscriptionID: identifier)
                let info = CKSubscription.NotificationInfo()
                info.shouldSendContentAvailable = true
                subscription.notificationInfo = info
                _ = try await db.modifySubscriptions(saving: [subscription], deleting: [])
            }
        } catch { throw CloudError(error) }
    }

    public func interpret(push: [AnyHashable: Any]) -> PushInterpretation? {
        guard let report = CKNotification(fromRemoteNotificationDictionary: push),
            let db = report as? CKDatabaseNotification
        else { return nil }
        return .database(shared: db.databaseScope == .shared)
    }

    // MARK: - The public database

    /// **Without a zone.** The public database knows only `CKRecordZone.default()`.
    private var mailbox: CKDatabase { container.publicCloudDatabase }

    public func putPublic(_ message: CloudRecord) async throws(CloudError) {
        do {
            let record = Self.record(message, zone: CKRecordZone.default().zoneID)
            _ = try await mailbox.modifyRecords(saving: [record], deleting: [])
        } catch { throw CloudError(error) }
    }

    public func readPublic(
        _ name: RecordName
    ) async throws(CloudError)
        -> CloudRecord?
    {
        do {
            let identifier = CKRecord.ID(
                recordName: name.name, zoneID: CKRecordZone.default().zoneID)
            let record = try await mailbox.record(for: identifier)
            guard record.recordType == name.contentType else { return nil }
            return Self.record(record)
        } catch let caughtError as CKError where caughtError.code == .unknownItem {
            // bewusst still: **A mailbox that was picked up or has expired is the normal
            // case.** Whoever makes an error of it has the UI report "Störung" where in
            // truth nobody has merely answered yet.
            return nil
        } catch { throw CloudError(error) }
    }

    public func deletePublic(_ name: RecordName) async throws(CloudError) {
        do {
            let identifier = CKRecord.ID(
                recordName: name.name, zoneID: CKRecordZone.default().zoneID)
            _ = try await mailbox.modifyRecords(saving: [], deleting: [identifier])
        } catch let caughtError as CKError where caughtError.code == .unknownItem {
            // bewusst still: The target of this call is already gone.
            return
        } catch { throw CloudError(error) }
    }

    // MARK: - Freigabe

    /// **Anyone with the link, read and write** — not "only invited people": With the
    /// QR route the link is the invitation, nobody is looked up by Apple ID.
    /// With `.none` the share was invisible to the family Apple ID ("share not
    /// found", build 230 on the iPad). Anyone who has the link can read along and write along —
    /// that is why only the owner shows it, and "Freigabe beenden" invalidates it.
    /// An existing share with narrower permission is brought up to date.
    public func split(_ zone: ZoneID, title: String) async throws(CloudError) -> AccessGrant {
        if let existing = try await share(zone) {
            if existing.publicPermission == .readWrite { return CloudKitService.approval(existing) }
            existing.publicPermission = .readWrite
            return try await saveShare(existing)
        }
        let share = CKShare(recordZoneID: zoneID(zone))
        share.publicPermission = .readWrite
        share[CKShare.SystemFieldKey.title] = title as CKRecordValue
        return try await saveShare(share)
    }

    private func saveShare(_ share: CKShare) async throws(CloudError) -> AccessGrant {
        do {
            let (results, _) = try await container.privateCloudDatabase.modifyRecords(
                saving: [share], deleting: [], savePolicy: .ifServerRecordUnchanged, atomically: true)
            switch results[share.recordID] {
            case .success(let stored)?:
                guard let fresh = stored as? CKShare else {
                    throw CloudError.other("Share came back as \(type(of: stored))")
                }
                return CloudKitService.approval(fresh)
            case .failure(let error)?:
                // If a share already exists (another device was faster), the
                // conflict brings it along — then it is the result, not an error.
                if let ck = error as? CKError, ck.code == .serverRecordChanged,
                    let there = ck.serverRecord as? CKShare
                {
                    return CloudKitService.approval(there)
                }
                throw CloudError(error)
            case nil:
                throw CloudError.other("Share returned no result")
            }
        } catch let caughtError as CloudError {
            throw caughtError
        } catch { throw CloudError(error) }
    }

    public func approval(_ zone: ZoneID) async throws(CloudError) -> AccessGrant? {
        guard let share = try await share(zone) else { return nil }
        return CloudKitService.approval(share)
    }

    private func share(_ zone: ZoneID) async throws(CloudError) -> CKShare? {
        let id = CKRecord.ID(recordName: CKRecordNameZoneWideShare, zoneID: zoneID(zone))
        do {
            return try await database(zone).record(for: id) as? CKShare
        } catch {
            if case CKError.unknownItem = error { return nil }
            throw CloudError(error)
        }
    }

    public func remove(participant: String, from zone: ZoneID) async throws(CloudError) {
        guard let share = try await share(zone) else { return }
        guard let p = share.participants.first(where: { CloudKitService.identifier($0) == participant })
        else {
            return
        }
        share.removeParticipant(p)
        do {
            _ = try await container.privateCloudDatabase.modifyRecords(
                saving: [share], deleting: [], savePolicy: .ifServerRecordUnchanged, atomically: true)
        } catch { throw CloudError(error) }
    }

    public func endSharing(_ zone: ZoneID) async throws(CloudError) {
        guard let share = try await share(zone) else { return }
        do {
            _ = try await container.privateCloudDatabase.modifyRecords(
                saving: [], deleting: [share.recordID], savePolicy: .ifServerRecordUnchanged, atomically: true
            )
        } catch { throw CloudError(error) }
    }

    public func sharingMetadata(_ url: URL) async throws(CloudError) -> ShareMetadata {
        do {
            let meta = try await container.shareMetadata(for: url)
            let zoneID = meta.share.recordID.zoneID
            return ShareMetadata(
                url: url, zone: ZoneID(name: zoneID.zoneName, owner: zoneID.ownerName),
                ownerName: CloudKitService.name(meta.ownerIdentity),
                title: meta.share[CKShare.SystemFieldKey.title] as? String,
                accepted: meta.participantStatus == .accepted)
        } catch { throw CloudError(error) }
    }

    public func accept(_ metadata: ShareMetadata) async throws(CloudError) -> ZoneID {
        do {
            let meta = try await container.shareMetadata(for: metadata.url)
            if meta.participantStatus != .accepted {
                _ = try await container.accept(meta)
            }
            let zoneID = meta.share.recordID.zoneID
            return ZoneID(name: zoneID.zoneName, owner: zoneID.ownerName)
        } catch { throw CloudError(error) }
    }

    public func leave(_ zone: ZoneID) async throws(CloudError) {
        let id = CKRecord.ID(recordName: CKRecordNameZoneWideShare, zoneID: zoneID(zone))
        do {
            _ = try await container.sharedCloudDatabase.modifyRecords(
                saving: [], deleting: [id], savePolicy: .ifServerRecordUnchanged, atomically: true)
        } catch {
            let caughtError = CloudError(error)
            if caughtError != .zoneMissing, caughtError != .deletedByUser { throw caughtError }
        }
    }

    // MARK: - Translation

    /// Collects the callbacks of an operation — the blocks run one after another on the
    /// operation's queue, the lock is for the translator.
    private final class Collector: @unchecked Sendable {
        var wordings: [CloudRecord] = []
        var names: [RecordName] = []
        var changed: [ZoneID] = []
        var deleted: [ZoneID] = []
        var byUser: [ZoneID] = []
        var tag: Data?
        var error: (any Error)?
    }

    static func record(_ message: CloudRecord, zone: CKRecordZone.ID) -> CKRecord {
        let record: CKRecord
        if let seal = message.seal, let decoder = try? NSKeyedUnarchiver(forReadingFrom: seal),
            let from = CKRecord(coder: decoder)
        {
            record = from
        } else {
            record = CKRecord(
                recordType: message.contentType, recordID: CKRecord.ID(recordName: message.name, zoneID: zone)
            )
        }
        for (name, value) in message.fields {
            let raw: CKRecordValue =
                switch value {
                case .text(let t): t as CKRecordValue
                case .integer(let z): NSNumber(value: Int64(z))
                case .double(let k): NSNumber(value: k)
                case .date(let z): z as CKRecordValue
                case .bool(let w): NSNumber(value: Int64(w ? 1 : 0))
                case .data(let d): d as CKRecordValue
                }
            // **A field is either encrypted or not, and that forever** —
            // see ``CloudRecord/encrypted``. The server rejects a field
            // that was once created in plain text and would now arrive encrypted; that is
            // exactly why the decision sits on the record and not on a switch.
            if message.encrypted.contains(name) {
                record.encryptedValues[name] = raw
            } else {
                record[name] = raw
            }
        }
        // **The clock stays in plain text.** An encrypted field carries no index, and
        // `changed` is the first thing you look at in the dashboard.
        record[changedField] = message.changed as CKRecordValue
        return record
    }

    static func record(_ record: CKRecord) -> CloudRecord {
        var fields: [String: FieldValue] = [:]
        var encrypted: Set<String> = []
        for name in record.allKeys() where name != changedField {
            // **Look in the secret compartment first, then in plain text.** An encrypted
            // field read via `record[name]` does not yield its value; conversely,
            // `encryptedValues` yields nothing for an open field. This order is
            // the safe one: it cannot accidentally pass a secret through as
            // plain text.
            let fromEncryptedValues = record.encryptedValues[name]
            if fromEncryptedValues != nil { encrypted.insert(name) }
            switch fromEncryptedValues ?? record[name] {
            case let t as String: fields[name] = .text(t)
            case let z as Date: fields[name] = .date(z)
            case let d as Data: fields[name] = .data(d)
            case let n as NSNumber:
                fields[name] =
                    String(cString: n.objCType) == "d" || String(cString: n.objCType) == "f"
                    ? .double(n.doubleValue) : .integer(n.intValue)
            default: break
            }
        }
        let encoder = NSKeyedArchiver(requiringSecureCoding: true)
        record.encodeSystemFields(with: encoder)
        return CloudRecord(
            contentType: record.recordType, name: record.recordID.recordName, fields: fields,
            changed: record[changedField] as? Date ?? record.modificationDate ?? Date(),
            seal: encoder.encodedData, creator: record.creatorUserRecordID?.recordName,
            encrypted: encrypted,
            // **The server's clock, and only from here.** It never goes out — see
            // ``CloudRecord/serverTime``.
            serverTime: record.modificationDate)
    }

    static func token(_ tag: Data?) -> CKServerChangeToken? {
        guard let tag else { return nil }
        return try? NSKeyedUnarchiver.unarchivedObject(ofClass: CKServerChangeToken.self, from: tag)
    }

    static func tokenData(_ token: CKServerChangeToken?) -> Data? {
        guard let token else { return nil }
        return try? NSKeyedArchiver.archivedData(withRootObject: token, requiringSecureCoding: true)
    }

    static func identifier(_ p: CKShare.Participant) -> String {
        p.userIdentity.userRecordID?.recordName ?? p.userIdentity.lookupInfo?.emailAddress
            ?? p.userIdentity.lookupInfo?.phoneNumber ?? UUID().uuidString
    }

    static func name(_ identity: CKUserIdentity) -> String? {
        if let split = identity.nameComponents {
            let name = PersonNameComponentsFormatter.localizedString(from: split, style: .default)
            if !name.isEmpty { return name }
        }
        return identity.lookupInfo?.emailAddress ?? identity.lookupInfo?.phoneNumber
    }

    static func approval(_ share: CKShare) -> AccessGrant {
        AccessGrant(
            url: share.url,
            participant: share.participants.map { p in
                Participant(
                    identifier: identifier(p), name: name(p.userIdentity), owner: p.role == .owner,
                    accepted: p.acceptanceStatus == .accepted, writable: p.permission == .readWrite)
            })
    }
}

extension CloudError {

    /// An error from CloudKit mapped to the six classes.
    init(_ error: any Error) {
        if let own = error as? CloudError {
            self = own
            return
        }
        guard let ck = error as? CKError else {
            self = .other(error.localizedDescription)
            return
        }
        switch ck.code {
        case .notAuthenticated, .accountTemporarilyUnavailable: self = .noAccount
        case .networkUnavailable, .networkFailure, .serviceUnavailable, .requestRateLimited, .zoneBusy:
            self = .unreachable
        case .zoneNotFound: self = .zoneMissing
        // **Getrennt von `zoneNotFound`** — siehe ``CloudError/deletedByUser``.
        case .userDeletedZone: self = .deletedByUser
        case .permissionFailure, .quotaExceeded, .invalidArguments, .badContainer, .missingEntitlement:
            self = .rejected("\(ck.localizedDescription) (CKError \(ck.code.rawValue))")
        case .partialFailure:
            let inside = (ck.partialErrorsByItemID ?? [:]).values.compactMap { $0 as? CKError }
            if let first = inside.first(where: { $0.code != .batchRequestFailed }) {
                self = CloudError(first)
            } else {
                self = .other(ck.localizedDescription)
            }
        default: self = .other("\(ck.localizedDescription) (CKError \(ck.code.rawValue))")
        }
    }
}
