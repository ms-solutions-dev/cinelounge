import Foundation

/// Whether an iCloud account is present — `CKContainer.accountStatus`, reduced to four answers.
public enum AccountStatus: Sendable, Hashable {
    case available
    case noAccount
    /// Restricted (parental controls, profile) or temporarily undeterminable.
    case restricted
    case unknown
}

/// What makes a call to the server fail — the classes the zone reacts to:
/// ``isTransient`` means "try again later", everything else needs a
/// human (no account, zone gone, rejected).
public enum CloudError: Error, Sendable, Hashable {
    case noAccount
    case unreachable
    /// The zone no longer exists (for this account) — deleted, or the share
    /// was revoked (`CKError.zoneNotFound`).
    case zoneMissing
    /// **The person deleted the data themselves** — iOS Settings → Apple Account →
    /// iCloud → Manage Storage → app → "Delete Data" (`CKError.userDeletedZone`,
    /// 2026-09-27).
    ///
    /// **A case of its own and not ``zoneMissing``:** the dialog promises "delete on all
    /// devices", and Apple requires the app to then discard its local data
    /// or ask before it uploads anything again. Until then the ``ProfileZone`` recreated a
    /// missing zone and wrote the mirror back up — the deletion was undone on the
    /// next call.
    case deletedByUser
    /// The server says no: permissions, quota, schema (field unknown in production).
    case rejected(String)
    case other(String)

    public var isTransient: Bool {
        switch self {
        case .unreachable, .other: true
        case .noAccount, .zoneMissing, .deletedByUser, .rejected: false
        }
    }
}

/// Why a zone this device already knew has disappeared — the reason reported by
/// ``ProfileZone/onRemoval``.
public enum ZoneRemoval: String, Sendable, Hashable, Codable {
    /// Deleted in the iOS settings (``CloudError/deletedByUser``). The mirror
    /// is already discarded — the dialog promises that.
    case byUser = "vomNutzer"
    /// Deleted by another device or program: the zone had been on the server before
    /// and is now missing (`zoneNotFound`), or the database reports it as deleted. The
    /// mirror stays; the zone is locked until the app decides.
    case fromRemote = "vonFern"
}

/// What has happened in a zone since a token — the answer of
/// `CKFetchRecordZoneChangesOperation`, without CloudKit types.
public struct Changes: Sendable {
    public var changed: [CloudRecord]
    public var deleted: [RecordName]
    /// The new token for the next call; `nil` means: start from scratch.
    public var tag: Data?

    public init(changed: [CloudRecord] = [], deleted: [RecordName] = [], tag: Data? = nil) {
        self.changed = changed
        self.deleted = deleted
        self.tag = tag
    }
}

/// Which zones of a database have changed since a token — the first
/// step after a silent push, before the zones themselves are asked.
public struct DatabaseChanges: Sendable {
    public var changed: [ZoneID]
    /// Deleted or — in the shared database — revoked.
    public var deleted: [ZoneID]
    /// The part of ``deleted`` that the person deleted themselves (iOS settings,
    /// see ``CloudError/deletedByUser``).
    public var deletedByUser: [ZoneID]
    public var tag: Data?

    public init(
        changed: [ZoneID] = [], deleted: [ZoneID] = [],
        deletedByUser: [ZoneID] = [], tag: Data? = nil
    ) {
        self.changed = changed
        self.deleted = deleted
        self.deletedByUser = deletedByUser
        self.tag = tag
    }
}

/// The result per record when saving with `ifServerRecordUnchanged`.
public enum SaveResult: Sendable {
    /// Accepted — with the server's new seal.
    case stored(CloudRecord)
    /// The server now has a different version — it comes along so that the
    /// zone can merge and write again.
    case conflict(server: CloudRecord)
    /// The seal points to a record the server no longer has.
    case vanished
    /// The server rejects **only this record** — for instance because its type or a field is missing from the
    /// production schema. The remaining records of the batch are saved.
    ///
    /// **Why no throw for the whole batch** (product decision 15): a new
    /// record type before the schema deployment would otherwise have dragged all other records of the same
    /// batch down with it, the zone would stand at "rejected", and the queue
    /// would get stuck on the same record on every call. The ``ProfileZone`` takes such a
    /// record out of the queue and notes it (``ProfileZone/rejected``).
    case rejected(String)
}

/// A participant of a share — owner or invitee, with whatever
/// CloudKit reveals about them (a name if the address book knows them; otherwise nothing).
public struct Participant: Sendable, Hashable, Identifiable {
    public let identifier: String
    public let name: String?
    public let owner: Bool
    public let accepted: Bool
    /// Read and write — always for us; CloudKit could also allow read-only.
    public let writable: Bool
    public var id: String { identifier }

    public init(identifier: String, name: String?, owner: Bool, accepted: Bool, writable: Bool = true) {
        self.identifier = identifier
        self.name = name
        self.owner = owner
        self.accepted = accepted
        self.writable = writable
    }
}

/// The share of a zone: the link to pass on and who reads along.
public struct AccessGrant: Sendable, Hashable {
    public let url: URL?
    public let participant: [Participant]

    public init(url: URL?, participant: [Participant]) {
        self.url = url
        self.participant = participant
    }

    /// The invitees without the owner.
    public var invited: [Participant] { participant.filter { !$0.owner } }
}

/// What a share link reveals about itself before it is accepted.
public struct ShareMetadata: Sendable, Hashable {
    public let url: URL
    public let zone: ZoneID
    public let ownerName: String?
    public let title: String?
    /// Whether this account has already accepted the share.
    public let accepted: Bool

    public init(url: URL, zone: ZoneID, ownerName: String?, title: String?, accepted: Bool) {
        self.url = url
        self.zone = zone
        self.ownerName = ownerName
        self.title = title
        self.accepted = accepted
    }
}

/// What a silent push means when it comes from CloudKit.
public enum PushInterpretation: Sendable, Hashable {
    /// A database has changed — `shared` says which one.
    case database(shared: Bool)
}

/// The call to the server — in production ``CloudKitService``, in checks and with
/// `-attrappen` the ``MockCloud``. Everything that is CloudKit sits behind this
/// protocol; the ``ProfileZone`` and the ``CloudHub`` know no `CKRecord`.
///
/// Every method throws ``CloudError`` — from it the zone decides whether it waits
/// (unreachable), stops (no account) or declares itself lost
/// (zone missing).
public protocol CloudService: Sendable {

    /// The CloudKit environment this service talks to (`"Production"`,
    /// `"Development"`) — `nil` if it is unknown (stand-in, or an app that does not
    /// state it). See ``ProfileZone`` for switching the environment.
    var environment: String? { get }

    func accountStatus() async -> AccountStatus
    /// Reports when the account changes (`CKAccountChanged`) — sign-out,
    /// iCloud off for the app, sign-in.
    func accountChanges() -> AsyncStream<Void>

    // MARK: Zonen

    func create(_ zone: ZoneID) async throws(CloudError)
    func delete(_ zone: ZoneID) async throws(CloudError)
    /// The zones of a database — the own ones, or the accepted ones of others.
    func zones(shared: Bool) async throws(CloudError) -> [ZoneID]
    func databaseChanges(
        shared: Bool, since tag: Data?
    ) async throws(CloudError)
        -> DatabaseChanges

    // MARK: Records

    func changes(_ zone: ZoneID, since tag: Data?) async throws(CloudError) -> Changes
    func read(_ names: [RecordName], in zone: ZoneID) async throws(CloudError) -> [CloudRecord]
    func save(
        _ wordings: [CloudRecord], in zone: ZoneID
    ) async throws(CloudError)
        -> [SaveResult]
    func delete(_ names: [RecordName], in zone: ZoneID) async throws(CloudError)

    // MARK: The public database

    /// Puts a record into the **public** database — the mailbox for the
    /// pairing of two accounts (AP44, direction 2).
    ///
    /// **Public means public.** Whoever knows the record name reads the content;
    /// there is no throttle and no sign-in in front of it. Whatever goes in here must therefore be built
    /// **itself** so that knowing the name is the only hurdle and that
    /// hurdle is high enough: a long, randomly generated name, a short deadline, and deleted
    /// as soon as it has been picked up.
    ///
    /// **No zones of its own.** The public database only knows the default zone;
    /// this is why this path takes a ``RecordName`` and no ``ZoneID``.
    func putPublic(_ message: CloudRecord) async throws(CloudError)

    /// - Returns: `nil` if the record does not (or no longer) exist. **Not an error**: a
    ///   mailbox that was picked up or has expired is the normal case and not a fault.
    func readPublic(_ name: RecordName) async throws(CloudError) -> CloudRecord?

    func deletePublic(_ name: RecordName) async throws(CloudError)

    // MARK: Pushes

    /// The two database subscriptions for silent pushes — once per device.
    func subscribe() async throws(CloudError)
    func interpret(push: [AnyHashable: Any]) -> PushInterpretation?

    // MARK: Freigabe

    /// Shares the zone (or reads the existing share) and returns the link.
    func split(_ zone: ZoneID, title: String) async throws(CloudError) -> AccessGrant
    /// The share of an own zone — `nil` if it is not shared.
    func approval(_ zone: ZoneID) async throws(CloudError) -> AccessGrant?
    func remove(participant: String, from zone: ZoneID) async throws(CloudError)
    func endSharing(_ zone: ZoneID) async throws(CloudError)
    func sharingMetadata(_ url: URL) async throws(CloudError) -> ShareMetadata
    /// Accepts — afterwards the zone lies in this account's shared database.
    func accept(_ metadata: ShareMetadata) async throws(CloudError) -> ZoneID
    /// The participant leaves — the zone disappears from their shared database.
    func leave(_ zone: ZoneID) async throws(CloudError)
}

extension CloudService {
    /// Unknown as long as a service does not state it itself.
    public var environment: String? { nil }
}
