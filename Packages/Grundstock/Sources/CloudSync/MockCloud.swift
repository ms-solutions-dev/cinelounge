import Foundation

/// An in-memory CloudKit — **one server, several accounts**: ``credential(_:)``
/// returns a ``CloudService`` per Apple ID, and whatever one account shares, the
/// other sees in its shared database. This makes it possible to check on a single
/// machine what otherwise takes two devices and two Apple IDs: zones, tokens, conflicts via
/// the seal, sharing, acceptance, revoking, leaving.
///
/// The same stand-in runs in the simulator with `-attrappen` — there everything stays in the
/// process and no account is touched.
///
/// **What it simulates, and what not:** change tokens are sequence numbers
/// of a journal, seals are version numbers; saving with an old seal returns
/// the conflict with the server version, as CloudKit does. What is missing:
/// quotas, sizes, rates, the delay of a push — for these there are
/// ``reachable``, ``setAccount(_:_:)`` and ``refuse(contentType:reason:)`` (a record type
/// is missing from the schema) as levers that a check flips.
public final class MockCloud: @unchecked Sendable {

    /// Whether the "server" answers — `false` means: every call throws `unreachable`.
    public var reachable: Bool {
        get { lock.withLock { _reachable } }
        set { lock.withLock { _reachable = newValue } }
    }

    /// The clock of the "server" — **settable, and that is its purpose.**
    ///
    /// ``CloudRecord/serverTime`` is the anchor of every deadline; a check for it has to
    /// be able to fast-forward without touching the machine's clock. `nil` means: the
    /// ordinary time.
    public var clock: Date? {
        get { lock.withLock { _clock } }
        set { lock.withLock { _clock = newValue } }
    }

    /// Simulates a record type missing from the production schema: every record of this
    /// type comes back from saving as ``SaveResult/rejected(_:)``, while the
    /// remaining records of the same batch are saved — just as ``CloudKitService``
    /// passes on one `invalidArguments` per record. A second call with `nil`
    /// as the reason is the schema deployment: the type is accepted again.
    public func refuse(contentType: String, reason: String? = "Cannot create new type in production schema") {
        lock.withLock { _refused[contentType] = reason }
    }

    /// Simulates "Delete Data" in the iOS settings (`CKError.userDeletedZone`):
    /// the zone is gone, and every access by the owner to it throws
    /// ``CloudError/deletedByUser`` instead of ``CloudError/zoneMissing`` — until the owner recreates
    /// it. The database changes report it as deleted **and** deleted by the user.
    public func deleteByUser(_ zone: ZoneID, user: String) {
        lock.withLock {
            let real = ZoneID(name: zone.name, owner: user)
            guard zones[real] != nil else { return }
            notes(real, deleted: true, byUser: true)
            zones[real] = nil
            _userDeleted.insert(real)
        }
    }

    private let lock = NSLock()
    private var _userDeleted: Set<ZoneID> = []
    private var _refused: [String: String] = [:]
    private var _reachable = true
    private var _clock: Date?
    private var accounts: [String: AccountStatus] = [:]
    private var zones: [ZoneID: Zone] = [:]
    private var journals: [JournalKey: [JournalEntry]] = [:]
    private var runNumber = 0
    private var accountWakers: [String: [@Sendable () -> Void]] = [:]
    /// The public database — **one for all accounts**, because that is exactly what it is.
    private var mailbox: [RecordName: CloudRecord] = [:]

    /// A zone with its journal — the owner is part of the identifier.
    private struct Zone {
        var wordings: [RecordName: (message: CloudRecord, version: Int)] = [:]
        var journal: [(number: Int, name: RecordName, deleted: Bool)] = []
        var approval: (url: URL, participant: [String: Participant])?
    }

    private struct JournalKey: Hashable {
        let user: String
        let shared: Bool
    }

    private struct JournalEntry {
        let number: Int
        let zone: ZoneID
        let deleted: Bool
        var byUser = false
    }

    public init() {}

    /// The service of one account — `user` is the record name of the Apple ID
    /// (`_abc…` in CloudKit; here a name like "alice").
    /// - Parameter umgebung: the CloudKit environment this access reports
    ///   (``CloudService/environment``) — for checks of the environment guard.
    public func credential(_ user: String, name: String? = nil, environment: String? = nil) -> Access {
        lock.withLock { if accounts[user] == nil { accounts[user] = .available } }
        return Access(server: self, user: user, name: name ?? user, environment: environment)
    }

    /// Sets the account status of a user — and wakes whoever listens for `CKAccountChanged`.
    public func setAccount(_ user: String, _ status: AccountStatus) {
        let waker = lock.withLock {
            accounts[user] = status
            return accountWakers[user] ?? []
        }
        for w in waker { w() }
    }

    /// Everything that lies in a zone — for checks that look into the server's belly.
    public func content(_ zone: ZoneID) -> [CloudRecord] {
        lock.withLock { zones[zone]?.wordings.values.map(\.message).sorted { $0.name < $1.name } ?? [] }
    }

    public func zoneList() -> [ZoneID] { lock.withLock { Array(zones.keys) } }

    // MARK: - Innen (unter dem Schloss)

    /// `withLock` throws untyped — here the ``CloudError`` stays typed.
    fileprivate func locked<T>(_ bodyContent: () throws(CloudError) -> T) throws(CloudError) -> T {
        lock.lock()
        defer { lock.unlock() }
        return try bodyContent()
    }

    private func next() -> Int {
        runNumber += 1
        return runNumber
    }

    private func seal(_ version: Int) -> Data { Data(String(version).utf8) }
    private func version(_ seal: Data?) -> Int? {
        seal.flatMap { Int(String(decoding: $0, as: UTF8.self)) }
    }
    private func tag(_ number: Int) -> Data { Data(String(number).utf8) }
    private func number(_ tag: Data?) -> Int {
        tag.flatMap { Int(String(decoding: $0, as: UTF8.self)) } ?? 0
    }

    /// The zone as `user` sees it: his own, or someone else's in which he participates.
    private func actual(_ zone: ZoneID, forItem user: String) -> ZoneID? {
        guard let owner = zone.owner else {
            return zones[ZoneID(name: zone.name, owner: user)] != nil
                ? ZoneID(name: zone.name, owner: user) : nil
        }
        let real = ZoneID(name: zone.name, owner: owner)
        guard let z = zones[real], z.approval?.participant[user]?.accepted == true else { return nil }
        return real
    }

    /// Why `user` does not (or no longer) see this zone — deleted by the user or simply not there.
    fileprivate func isMissing(_ zone: ZoneID, forItem user: String) -> CloudError {
        let own = ZoneID(name: zone.name, owner: zone.owner ?? user)
        return _userDeleted.contains(own) ? .deletedByUser : .zoneMissing
    }

    /// Enters a zone change into the database journals of everyone who can see it.
    private func notes(
        _ zone: ZoneID, deleted: Bool, byUser: Bool = false, onlyFor user: String? = nil
    ) {
        guard let owner = zone.owner else { return }
        let n = next()
        if let user {
            journals[JournalKey(user: user, shared: true), default: []].append(
                JournalEntry(number: n, zone: zone, deleted: deleted))
            return
        }
        journals[JournalKey(user: owner, shared: false), default: []].append(
            JournalEntry(
                number: n, zone: ZoneID(name: zone.name), deleted: deleted,
                byUser: byUser))
        for (participant, entry) in zones[zone]?.approval?.participant ?? [:] where entry.accepted {
            journals[JournalKey(user: participant, shared: true), default: []].append(
                JournalEntry(number: n, zone: zone, deleted: deleted))
        }
    }

    // MARK: - Der Zugang eines Kontos

    public struct Access: CloudService {
        let server: MockCloud
        public let user: String
        public let name: String
        public let environment: String?

        /// When a push is meant "for this account": `["mock-shared": Bool]`.
        public func interpret(push: [AnyHashable: Any]) -> PushInterpretation? {
            guard let shared = push["mock-shared"] as? Bool else { return nil }
            return .database(shared: shared)
        }

        public func accountStatus() async -> AccountStatus {
            server.lock.withLock { server.accounts[user] ?? .noAccount }
        }

        public func accountChanges() -> AsyncStream<Void> {
            AsyncStream { continuation in
                server.lock.withLock {
                    server.accountWakers[user, default: []].append { continuation.yield() }
                }
            }
        }

        private func verify() throws(CloudError) {
            let (reachable, status) = server.lock.withLock { (server._reachable, server.accounts[user]) }
            guard reachable else { throw .unreachable }
            guard status == .available else { throw .noAccount }
        }

        public func create(_ zone: ZoneID) async throws(CloudError) {
            try verify()
            server.lock.withLock {
                let real = ZoneID(name: zone.name, owner: user)
                guard server.zones[real] == nil else { return }
                server._userDeleted.remove(real)
                server.zones[real] = Zone()
                server.notes(real, deleted: false)
            }
        }

        public func delete(_ zone: ZoneID) async throws(CloudError) {
            try verify()
            server.lock.withLock {
                let real = ZoneID(name: zone.name, owner: user)
                guard server.zones[real] != nil else { return }
                server.notes(real, deleted: true)
                server.zones[real] = nil
            }
        }

        public func zones(shared: Bool) async throws(CloudError) -> [ZoneID] {
            try verify()
            return server.lock.withLock {
                server.zones.compactMap { identifier, zone in
                    if !shared {
                        return identifier.owner == user ? ZoneID(name: identifier.name) : nil
                    }
                    return identifier.owner != user && zone.approval?.participant[user]?.accepted == true
                        ? identifier : nil
                }
                .sorted { $0.name < $1.name }
            }
        }

        public func databaseChanges(
            shared: Bool, since tag: Data?
        ) async throws(CloudError)
            -> DatabaseChanges
        {
            try verify()
            return server.lock.withLock {
                let since = server.number(tag)
                let entries = (server.journals[JournalKey(user: user, shared: shared)] ?? [])
                    .filter { $0.number > since }
                var state: [ZoneID: Bool] = [:]
                var byUser: Set<ZoneID> = []
                for e in entries {
                    state[e.zone] = e.deleted
                    if e.byUser { byUser.insert(e.zone) } else { byUser.remove(e.zone) }
                }
                let deleted = state.filter(\.value).map(\.key).sorted { $0.name < $1.name }
                return DatabaseChanges(
                    changed: state.filter { !$0.value }.map(\.key).sorted { $0.name < $1.name },
                    deleted: deleted,
                    deletedByUser: deleted.filter(byUser.contains),
                    tag: server.tag(server.runNumber))
            }
        }

        public func changes(
            _ zone: ZoneID, since tag: Data?
        ) async throws(CloudError)
            -> Changes
        {
            try verify()
            return try server.locked { () throws(CloudError) -> Changes in
                guard let real = server.actual(zone, forItem: user), let z = server.zones[real] else {
                    throw server.isMissing(zone, forItem: user)
                }
                let since = server.number(tag)
                var state: [RecordName: Bool] = [:]
                for e in z.journal where e.number > since { state[e.name] = e.deleted }
                let changed = state.filter { !$0.value }.keys.compactMap { name -> CloudRecord? in
                    guard let (message, version) = z.wordings[name] else { return nil }
                    var s = message
                    s.seal = server.seal(version)
                    return s
                }
                return Changes(
                    changed: changed.sorted { $0.name < $1.name },
                    deleted: state.filter(\.value).map(\.key).sorted { $0.name < $1.name },
                    tag: server.tag(server.runNumber))
            }
        }

        public func read(
            _ names: [RecordName], in zone: ZoneID
        ) async throws(CloudError)
            -> [CloudRecord]
        {
            try verify()
            return try server.locked { () throws(CloudError) -> [CloudRecord] in
                guard let real = server.actual(zone, forItem: user), let z = server.zones[real] else {
                    throw server.isMissing(zone, forItem: user)
                }
                return names.compactMap { name in
                    guard let (message, version) = z.wordings[name] else { return nil }
                    var s = message
                    s.seal = server.seal(version)
                    return s
                }
            }
        }

        public func save(
            _ wordings: [CloudRecord], in zone: ZoneID
        ) async throws(CloudError)
            -> [SaveResult]
        {
            try verify()
            return try server.locked { () throws(CloudError) -> [SaveResult] in
                guard let real = server.actual(zone, forItem: user), var z = server.zones[real] else {
                    throw server.isMissing(zone, forItem: user)
                }
                var results: [SaveResult] = []
                for message in wordings {
                    if let reason = server._refused[message.contentType] {
                        results.append(.rejected(reason))
                        continue
                    }
                    let existing = z.wordings[message.id]
                    let serverVersion = server.version(message.seal)
                    if let existing, existing.version != serverVersion {
                        var s = existing.message
                        s.seal = server.seal(existing.version)
                        results.append(.conflict(server: s))
                        continue
                    }
                    if existing == nil, serverVersion != nil {
                        results.append(.vanished)
                        continue
                    }
                    let version = (existing?.version ?? 0) + 1
                    var fresh = message
                    fresh.seal = nil
                    fresh.creator = existing?.message.creator ?? user
                    // **The server stamps, not the writer.** This very
                    // difference is the point of ``CloudRecord/serverTime``.
                    fresh.serverTime = server._clock ?? Date()
                    z.wordings[message.id] = (fresh, version)
                    z.journal.append((server.next(), message.id, false))
                    fresh.seal = server.seal(version)
                    results.append(.stored(fresh))
                }
                server.zones[real] = z
                server.notes(real, deleted: false)
                return results
            }
        }

        public func delete(_ names: [RecordName], in zone: ZoneID) async throws(CloudError) {
            try verify()
            try server.locked { () throws(CloudError) in
                guard let real = server.actual(zone, forItem: user), var z = server.zones[real] else {
                    throw server.isMissing(zone, forItem: user)
                }
                for name in names where z.wordings[name] != nil {
                    z.wordings[name] = nil
                    z.journal.append((server.next(), name, true))
                }
                server.zones[real] = z
                server.notes(real, deleted: false)
            }
        }

        public func subscribe() async throws(CloudError) { try verify() }

        // MARK: The public database

        /// **Without account separation, and that is not a simplification.** The public
        /// database is the same for every account; whoever knows the record name reads
        /// it. A stand-in that separated here would let a check go green that fails on
        /// the device — or worse: it would hide that a stranger
        /// can read along.
        public func putPublic(_ message: CloudRecord) async throws(CloudError) {
            try verify()
            try server.locked { server.mailbox[message.id] = message }
        }

        public func readPublic(
            _ name: RecordName
        ) async throws(CloudError)
            -> CloudRecord?
        {
            try verify()
            return try server.locked { server.mailbox[name] }
        }

        public func deletePublic(_ name: RecordName) async throws(CloudError) {
            try verify()
            try server.locked { server.mailbox[name] = nil }
        }

        // MARK: Freigabe

        public func split(_ zone: ZoneID, title: String) async throws(CloudError) -> AccessGrant {
            try verify()
            return try server.locked { () throws(CloudError) -> AccessGrant in
                let real = ZoneID(name: zone.name, owner: user)
                guard var z = server.zones[real] else { throw .zoneMissing }
                if z.approval == nil {
                    z.approval = (
                        URL(string: "https://www.icloud.com/share/mock-\(user)-\(zone.name)")!,
                        [user: Participant(identifier: user, name: name, owner: true, accepted: true)]
                    )
                    server.zones[real] = z
                }
                return AccessGrant(url: z.approval?.url, participant: participantList(z))
            }
        }

        private func participantList(_ z: Zone) -> [Participant] {
            (z.approval?.participant.values ?? [:].values).sorted {
                ($0.owner ? 0 : 1, $0.identifier) < ($1.owner ? 0 : 1, $1.identifier)
            }
        }

        public func approval(_ zone: ZoneID) async throws(CloudError) -> AccessGrant? {
            try verify()
            return try server.locked { () throws(CloudError) -> AccessGrant? in
                let real = ZoneID(name: zone.name, owner: user)
                guard let z = server.zones[real] else { throw .zoneMissing }
                guard let f = z.approval else { return nil }
                return AccessGrant(url: f.url, participant: participantList(z))
            }
        }

        public func remove(participant: String, from zone: ZoneID) async throws(CloudError) {
            try verify()
            server.lock.withLock {
                let real = ZoneID(name: zone.name, owner: user)
                guard var z = server.zones[real], z.approval?.participant[participant] != nil else { return }
                z.approval?.participant[participant] = nil
                server.zones[real] = z
                server.notes(real, deleted: true, onlyFor: participant)
            }
        }

        public func endSharing(_ zone: ZoneID) async throws(CloudError) {
            try verify()
            server.lock.withLock {
                let real = ZoneID(name: zone.name, owner: user)
                guard var z = server.zones[real], let f = z.approval else { return }
                for t in f.participant.keys where t != user {
                    server.notes(real, deleted: true, onlyFor: t)
                }
                z.approval = nil
                server.zones[real] = z
            }
        }

        public func sharingMetadata(_ url: URL) async throws(CloudError) -> ShareMetadata {
            try verify()
            return try server.locked { () throws(CloudError) -> ShareMetadata in
                guard let (identifier, z) = server.zones.first(where: { $0.value.approval?.url == url })
                else {
                    throw .rejected("Unknown share link")
                }
                // **As CloudKit does for the owner** (2026-09-28): when he opens his own share,
                // the owner is called `__defaultOwner__` — ``ZoneID`` turns that into the
                // own zone.
                let zone =
                    identifier.owner == user
                    ? ZoneID(name: identifier.name, owner: ZoneID.ownAccount) : identifier
                return ShareMetadata(
                    url: url, zone: zone,
                    ownerName: z.approval?.participant[identifier.owner ?? ""]?.name,
                    title: nil, accepted: z.approval?.participant[user]?.accepted == true)
            }
        }

        public func accept(_ metadata: ShareMetadata) async throws(CloudError) -> ZoneID {
            try verify()
            return try server.locked { () throws(CloudError) -> ZoneID in
                // **Your own share yields your own zone** — CloudKit does not even accept it,
                // it is already there (same Apple ID on two devices).
                if metadata.zone.owner == nil || metadata.zone.owner == user {
                    guard server.zones[ZoneID(name: metadata.zone.name, owner: user)] != nil
                    else { throw .zoneMissing }
                    return ZoneID(name: metadata.zone.name)
                }
                guard var z = server.zones[metadata.zone], z.approval != nil else { throw .zoneMissing }
                z.approval?.participant[user] = Participant(
                    identifier: user, name: name, owner: false, accepted: true)
                server.zones[metadata.zone] = z
                server.notes(metadata.zone, deleted: false, onlyFor: user)
                return metadata.zone
            }
        }

        public func leave(_ zone: ZoneID) async throws(CloudError) {
            try verify()
            server.lock.withLock {
                guard var z = server.zones[zone] else { return }
                z.approval?.participant[user] = nil
                server.zones[zone] = z
                server.notes(zone, deleted: true, onlyFor: user)
            }
        }
    }
}
