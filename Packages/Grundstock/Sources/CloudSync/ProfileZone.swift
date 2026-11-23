import Foundation
import Grundstock
import Observation

/// Where a profile's zone currently stands — for the diagnostic line in the statistics sheet.
public enum ZoneState: Sendable, Hashable {
    /// No service connected (test, preview without the cloud).
    case withoutCloud
    /// No iCloud account — everything stays local, the queue waits.
    case noAccount
    /// The zone is not chosen yet — the directory is running (first launch).
    case unbound
    /// Bound, but no pass to the server yet.
    case neverSynced
    case synced(Date)
    /// The last pass failed because of the network — the queue waits.
    case unreachable
    /// The zone no longer exists: share withdrawn or deleted by the owner.
    case lost
    /// The server refuses (schema, rights) — nothing waits in vain, the report says why.
    case rejected(String)
}

/// One zone per profile, as a **mirror with a queue**: The packages above read
/// and write synchronously on the main thread — the mirror updates immediately, the change
/// goes into the queue, and ``reconcile()`` carries it up as soon as the server
/// answers. What comes back from there lands in the mirror and with the observers per type.
///
/// **Why a mirror and not `async` all the way to the UI:** Watchlist, theme
/// and reading time lived in `UserDefaults` and iCloud KVS synchronously until E51; an
/// asynchronous carrier would have rebuilt every view. The mirror is also the
/// offline case — without a network the app reads and writes as if nothing were wrong (KONZEPT.md
/// §3: "not reachable" is a network state, not an error).
///
/// **Conflict:** Writing uses the server's seal
/// (`ifServerRecordUnchanged`). If the server says "different in the meantime", the type's
/// ``MergeRule`` merges both versions, and the record goes up once more
/// — at most four rounds per pass, so that a ping-pong between two devices does not
/// drain the battery. Without a rule the more recent change wins.
///
/// **Token:** One change token (`CKServerChangeToken`) per zone, on disk
/// next to the mirror — after a restart the zone fetches only what has come since.
///
/// **Rejected individually** (``SaveResult/rejected(_:)``, product decision 15):
/// If the server rejects one record alone — its type or a field is missing in the
/// production schema —, the remaining records of the batch still go up. The one
/// drops out of the queue so that it does not block every pass, stays in the mirror and
/// is listed in ``rejected``. It is retried on the next write of the same
/// record, on the next ``bind(on:)``, at every launch and in an ordinary
/// pass as soon as the server has news or ``retryInterval`` has elapsed since the
/// last attempt — a schema deployment heals it that way without a
/// restart, and no pass hammers twice against the same no.
///
/// A rejected record is thereby a **pending write request like any other**:
/// If another version arrives from remote, the type's ``MergeRule`` applies;
/// if a deletion arrives, the request wins. The rejection removes from the
/// queue only the state that was actually sent — whoever changes or deletes the record
/// during the pass keeps their change, and no note is left orphaned.
///
/// **Deleting from remote** wins against the mirror, but not against a
/// pending write request: Whoever continued a session offline while
/// the other device deleted the statistics keeps it — it was the newer intent.
///
/// **A vanished zone is not revived** (2026-09-27). Until then a
/// pass recreated a missing own zone and wrote the whole mirror up — even
/// after the person had chosen "Delete data" in the iOS settings, and also on
/// every other device after one had deleted the zone. The deletion was thereby
/// taken back on the next pass. Now this applies:
///
/// * **Only what this device has never seen on the server is newly created** — the
///   first pass of a new profile. A zone that was there once and is now missing
///   has been deleted by someone: the zone is **locked** (``removed``, ``ZoneState/lost``),
///   no pass goes to the server any more, and ``onRemoval`` reports it.
/// * **Deleted by the user** (``CloudError/deletedByUser``) additionally discards the
///   mirror — the dialog promises that, and Apple requires it. **Deleted from remote**
///   leaves it in place: another device has decided, and whether the data stays here
///   is up to the app (``discard()``, ``unbind()``).
/// * **Continuing happens only on explicit request:** ``discard()`` starts empty from scratch,
///   ``bind(on:)`` and ``unbind()`` release the lock as well.
///
/// **Why "seen once" and no note on the server:** Whoever deletes an app's zones
/// deletes every note along with them, and a device that was offline would never see it anyway —
/// it only gets `zoneNotFound`. The only thing it knows for sure is that it
/// had the zone once before.
@MainActor
@Observable
public final class ProfileZone {

    public private(set) var zone: ZoneID?
    public private(set) var state: ZoneState
    /// How many write and delete requests still have to go up.
    public private(set) var pending = 0
    /// The last successful pass to the server.
    public private(set) var recent: Date?
    /// Records that the server rejected **individually** (``SaveResult/rejected(_:)``),
    /// with its reason — for the diagnostic line. Empty means: everything is up.
    public var rejected: [RecordName: String] { rejections.mapValues(\.reason) }
    /// Who shared the zone — only for a foreign zone; the hub sets it.
    public var sharedBy: String?
    /// Why the zone is locked — `nil` as long as it is alive. See above, "A
    /// vanished zone is not revived".
    public private(set) var removed: ZoneRemoval?
    /// Reports that a zone this device knew has vanished — **once**, after
    /// the pass that noticed it. The app decides here what happens to its own data;
    /// without a callback the zone stays locked and its state ``ZoneState/lost``.
    public var onRemoval: (@MainActor (ZoneRemoval) -> Void)?

    public let service: (any CloudService)?
    private let file: URL?
    private let automatic: Bool
    private var wordings: [RecordName: CloudRecord] = [:]
    private var queue: [Job] = []
    private var tag: Data?
    private var rules: [String: MergeRule] = [:]
    private var observers: [UUID: (contentType: String, notify: @MainActor ([CloudRecord]) -> Void)] = [:]
    private var rejections: [RecordName: Rejection] = [:]
    private var isRunning = false
    private var repeatEntry = false
    private var planned = false
    /// Whether the zone was ever present on the server — only then does "missing" mean "deleted".
    private var confirmed = false
    /// After ``discard()``: The next missing zone may be newly created, even one
    /// deleted by the user.
    private var restarted = false

    /// A request in the queue — at most one per record, the last one applies.
    enum Job: Codable, Hashable {
        /// Stored case names keep their original (German) form — renaming them would
        /// make data written by earlier versions unreadable (AP85 B4).
        private enum CodingKeys: String, CodingKey {
            case write = "schreiben"
            case delete = "loeschen"
        }

        case write(RecordName)
        case delete(RecordName)

        var name: RecordName {
            switch self {
            case .write(let n), .delete(let n): n
            }
        }
    }

    /// A note from ``rejected`` — with the time of the last attempt, on which
    /// the deadline ``retryInterval`` depends.
    struct Rejection: Hashable {
        var reason: String
        var attempted: Date
    }

    /// What lies on disk: mirror, queue, token, zone.
    private struct Image: Codable {
        /// Stored keys keep their original (German) names — renaming them would
        /// make data written by earlier versions unreadable (AP85 B4).
        private enum CodingKeys: String, CodingKey {
            case zone
            case wordings = "saetze"
            case queue = "schlange"
            case tag = "marke"
            case recent = "zuletzt"
            case sharedBy = "geteiltVon"
            case rejected = "abgelehnt"
            case rejectedAttemptedAt = "abgelehntVersucht"
            case confirmed = "bestaetigt"
            case removed = "entfernt"
            case restarted = "neuBegonnen"
            case environment = "umgebung"
        }

        var zone: ZoneID?
        var wordings: [CloudRecord]
        var queue: [Job]
        var tag: Data?
        var recent: Date?
        var sharedBy: String?
        /// Optional, so that a mirror from before product decision 15 stays readable.
        var rejected: [RecordName: String]?
        /// The last attempt per note; if it is missing (older mirrors), the deadline counts as elapsed.
        var rejectedAttemptedAt: [RecordName: Date]?
        /// Optional as above: An older mirror with a token counts as confirmed.
        var confirmed: Bool?
        var removed: ZoneRemoval?
        var restarted: Bool?
        /// In welcher CloudKit-Umgebung dieser Spiegel entstand — siehe ``read()``.
        var environment: String?
    }

    /// How many records go to the server in one pass — CloudKit accepts 400,
    /// half of that leaves room for large watchlist IDs.
    static let burst = 200

    /// Further passes if jobs are still in the queue after ``conflictRounds``
    /// (ultra, 2026-09-27). One pass carries at most ``conflictRounds`` × ``burst`` records
    /// up; the first migration of old data can be more. Before, it still said
    /// "synced" afterwards while hundreds of records were still on their way. Now a new pass
    /// fetches fresh (which also resolves conflicts) and carries on; if even that is not enough,
    /// the old state stays in place, ``pending`` shows the rest, and the log says so.
    static let trailingJobs = 3
    /// How often a conflict is rewritten per pass.
    static let conflictRounds = 4
    /// How long a rejected record rests before a pass without news
    /// tries it again. A schema deployment is not an event the server reports — one
    /// hour is fast enough for whoever has just rolled it out, and too infrequent
    /// to keep the server busy with the same no.
    static let retryInterval: TimeInterval = 3600

    /// The time for note and deadline — set in tests.
    var clock: @MainActor () -> Date = { Date() }

    /// - Parameters:
    ///   - datei: the mirror on disk (`profile/<id>/cloud.json`); `nil` keeps
    ///     everything in memory only (tests, preview).
    ///   - dienst: the pass to the server; `nil` means: no iCloud (``ZoneState/withoutCloud``).
    ///   - zone: the zone, if the profile already has one — otherwise the hub binds.
    ///   - selbsttaetig: whether every change triggers a pass by itself (in operation);
    ///     the tests call ``reconcile()`` themselves so that nothing runs on the side.
    public init(
        file: URL?, service: (any CloudService)?, zone: ZoneID? = nil, automatic: Bool = true
    ) {
        self.file = file
        self.service = service
        self.automatic = automatic
        self.zone = zone
        self.state = service == nil ? .withoutCloud : (zone == nil ? .unbound : .neverSynced)
        read()
        if let zone { self.zone = zone }
        pending = queue.count
    }

    // MARK: - Lesen und Schreiben (Spiegel)

    /// All records of a type, ordered by name.
    public func read(_ contentType: String) -> [CloudRecord] {
        wordings.values.filter { $0.contentType == contentType }.sorted { $0.name < $1.name }
    }

    public func read(contentType: String, name: String) -> CloudRecord? {
        wordings[RecordName(contentType: contentType, name: name)]
    }

    /// The types that occur in the mirror.
    public func types() -> Set<String> { Set(wordings.values.map(\.contentType)) }

    /// Writes into the mirror and queues — the server's seal and the
    /// creator stay on the record, `changed` is set now.
    public func write(_ message: CloudRecord, now: Date = Date()) {
        var fresh = message
        fresh.seal = wordings[message.id]?.seal
        fresh.creator = wordings[message.id]?.creator ?? message.creator
        fresh.changed = now
        wordings[message.id] = fresh
        enqueue(.write(message.id))
    }

    public func delete(contentType: String, name: String) {
        let identifier = RecordName(contentType: contentType, name: name)
        let known = wordings.removeValue(forKey: identifier) != nil
        rejections[identifier] = nil
        let waiting = queue.contains { $0.name == identifier }
        guard known || waiting else { return }
        enqueue(.delete(identifier))
    }

    public func deleteAll(contentType: String) {
        for message in read(contentType) { delete(contentType: contentType, name: message.name) }
    }

    /// The rule for a type — without a rule the more recent change wins.
    public func rule(forItem contentType: String, _ rule: MergeRule) {
        rules[contentType] = rule
    }

    /// Reports when records of this type came from remote — with the whole
    /// state of the type. The return value holds the observation; if it is dropped, the observation ends.
    public func observe(
        _ contentType: String, _ notify: @escaping @MainActor ([CloudRecord]) -> Void
    ) -> ObservationResult {
        let identifier = UUID()
        observers[identifier] = (contentType, notify)
        return ObservationResult { [weak self] in self?.observers[identifier] = nil }
    }

    // MARK: - Binden

    /// Attaches the zone — the first time (own or found zone) or after
    /// an accepted share. The token is dropped so that the next pass fetches everything;
    /// what the mirror already has goes up as a write request and merges
    /// there with what is stored.
    public func bind(on zone: ZoneID) {
        guard self.zone != zone || removed != nil else { return }
        self.zone = zone
        removed = nil
        confirmed = false
        restarted = false
        tag = nil
        for message in wordings.values {
            var without = message
            without.seal = nil
            wordings[message.id] = without
            if !queue.contains(where: { $0.name == message.id }) { queue.append(.write(message.id)) }
        }
        pending = queue.count
        state = .neverSynced
        save()
        trigger()
    }

    /// Takes all records of a type out of the mirror — **without** a delete request: Nothing
    /// goes to the server, the records are merely forgotten. For taking over a
    /// share (addendum to E52): Before the mirror binds to the owner's zone,
    /// the own `Profileinstellung` records (name, color, theme) are dropped so that there
    /// the owner's apply — a ``delete(contentType:name:)`` would delete them at the owner
    /// after binding, leaving them in place would play them off against his.
    public func discard(contentType: String) {
        let names = wordings.values.filter { $0.contentType == contentType }.map(\.id)
        guard !names.isEmpty || queue.contains(where: { $0.name.contentType == contentType }) else { return }
        for name in names { wordings[name] = nil }
        queue.removeAll { $0.name.contentType == contentType }
        rejections = rejections.filter { $0.key.contentType != contentType }
        pending = queue.count
        save()
    }

    /// Detaches the zone from the mirror — "Remove from iCloud": The records stay,
    /// their seals and the token are dropped; on the next attach it is a new zone.
    public func unbind() {
        zone = nil
        tag = nil
        for message in wordings.values {
            var without = message
            without.seal = nil
            wordings[message.id] = without
        }
        queue.removeAll()
        rejections = [:]
        pending = 0
        recent = nil
        removed = nil
        confirmed = false
        restarted = false
        state = service == nil ? .withoutCloud : .unbound
        save()
    }

    /// **Starts empty from scratch** — the explicit request for a removal
    /// (``onRemoval``) or for "Delete all iCloud data" in the app.
    ///
    /// Mirror, queue, token and notes are dropped, the lock as well; the binding
    /// stays. The next pass may create the zone anew — even one deleted
    /// by the user — and carries up only what was written **afterwards**. Whoever observes gets
    /// the empty state of their type reported.
    public func discard() {
        let types = Set(wordings.values.map(\.contentType))
        clearMirror()
        removed = nil
        confirmed = false
        restarted = true
        state = service == nil ? .withoutCloud : (zone == nil ? .unbound : .neverSynced)
        save()
        notify(types)
    }

    /// The hub learned from the database changes that an **own** zone
    /// has been deleted — the same rule as in the pass: only one this device already knew,
    /// and not the one it has just started anew itself.
    public func noteRemoved(_ reason: ZoneRemoval) {
        guard removed == nil, let zone else { return }
        guard reason == .byUser ? !restarted : (confirmed && !restarted) else { return }
        lock(reason, zone)
        onRemoval?(reason)
    }

    /// Locks the zone — see above. Deleted by the user also means: the mirror is gone.
    private func lock(_ reason: ZoneRemoval, _ zone: ZoneID) {
        removed = reason
        state = .lost
        let types = Set(wordings.values.map(\.contentType))
        if reason == .byUser { clearMirror() }
        Diagnostics.step(
            reason == .byUser
                ? "Cloud \(zone.name): deleted in iOS Settings — mirror discarded, nothing is recreated"
                : "Cloud \(zone.name): deleted remotely — locked, nothing is recreated",
            since: nil, area: "Wolke")
        save()
        if reason == .byUser { notify(types) }
    }

    private func clearMirror() {
        wordings = [:]
        queue = []
        rejections = [:]
        tag = nil
        recent = nil
        pending = 0
    }

    /// The hub learned that the zone no longer exists.
    public func noteLost() {
        state = .lost
        save()
    }

    // MARK: - Der Gang zum Server

    /// Fetches what happened remotely and carries the queue up. If one is already running,
    /// it remembers that it has to run once more.
    public func reconcile() async {
        guard let service, let zone, removed == nil else { return }
        if isRunning {
            repeatEntry = true
            return
        }
        isRunning = true
        defer { isRunning = false }
        var trailingJobs = 0
        var noticed: ZoneRemoval?
        repeat {
            repeatEntry = false
            let status = await service.accountStatus()
            guard status == .available else {
                state = .noAccount
                save()
                return
            }
            do throws(CloudError) {
                let updates = try await fetch(service, zone)
                enqueueRejected(updates: updates)
                try await push(service, zone)
                if queue.isEmpty {
                    let now = Date()
                    recent = now
                    state = .synced(now)
                } else if trailingJobs < ProfileZone.trailingJobs {
                    trailingJobs += 1
                    repeatEntry = true
                } else {
                    Diagnostics.defect(
                        "Cloud \(zone.name): \(queue.count) jobs waiting after \(trailingJobs + 1) passes",
                        since: nil, area: "Wolke")
                }
            } catch {
                // **Deleted by the user in the middle of the pass** (between fetching and pushing) —
                // the same rule as in ``fetch(_:_:)``.
                if error == .deletedByUser, removed == nil, !restarted {
                    lock(.byUser, zone)
                }
                if let reason = removed {
                    noticed = reason
                    break
                }
                switch error {
                case .noAccount: state = .noAccount
                case .zoneMissing, .deletedByUser: state = .lost
                case .rejected(let reason): state = .rejected(reason)
                case .unreachable, .other: state = .unreachable
                }
                Diagnostics.defect("Cloud \(zone.name): \(error)", since: nil, area: "Wolke")
            }
            save()
        } while repeatEntry
        if let noticed { onRemoval?(noticed) }
    }

    /// - Returns: whether the server had anything new.
    private func fetch(_ service: any CloudService, _ zone: ZoneID) async throws(CloudError) -> Bool {
        let changes: Changes
        do throws(CloudError) {
            changes = try await service.changes(zone, since: tag)
        } catch .zoneMissing where !zone.shared {
            // **The own zone is missing.** If this device already knew it, someone has
            // deleted it — lock instead of reviving. Otherwise it is the first pass: create,
            // with everything the mirror has.
            if confirmed, !restarted {
                lock(.fromRemote, zone)
                throw .zoneMissing
            }
            try await recreate(service, zone)
            return false
        } catch .deletedByUser where restarted && !zone.shared {
            // bewusst still: explicitly intended after ``discard()`` — new and empty; the
            // deletion itself was already in the log when locking.
            try await recreate(service, zone)
            return false
        } catch .deletedByUser {
            lock(.byUser, zone)
            throw .deletedByUser
        }
        confirmed = true
        restarted = false
        adopt(changes)
        return !changes.changed.isEmpty || !changes.deleted.isEmpty
    }

    /// Creates the own zone and queues the whole mirror as a write request.
    private func recreate(_ service: any CloudService, _ zone: ZoneID) async throws(CloudError) {
        try await service.create(zone)
        confirmed = true
        restarted = false
        tag = nil
        for message in wordings.values {
            var without = message
            without.seal = nil
            wordings[message.id] = without
            if !queue.contains(where: { $0.name == message.id }) { queue.append(.write(message.id)) }
        }
    }

    /// Queues the rejected records that are due again — all of them if the server
    /// had news, otherwise those whose last attempt is further back than ``retryInterval``.
    /// Once per pass: if they fail again, `push` takes them out, and
    /// only the next pass asks again.
    private func enqueueRejected(updates: Bool) {
        let now = clock()
        let due = rejections.filter { name, rejection in
            wordings[name] != nil && !queue.contains { $0.name == name }
                && (updates || now.timeIntervalSince(rejection.attempted) >= ProfileZone.retryInterval)
        }
        guard !due.isEmpty else { return }
        for name in due.keys.sorted(by: { ($0.contentType, $0.name) < ($1.contentType, $1.name) }) {
            queue.append(.write(name))
        }
        pending = queue.count
    }

    /// Foreign changes into the mirror — with regard to the queue: A
    /// record whose deletion is still pending does not come back (after its own save the server returns
    /// its own records as a change — an
    /// echo that would otherwise undo a forgetting). A rejected record counts as a
    /// pending write request and is queued again in the process.
    func adopt(_ changes: Changes) {
        var affected: Set<String> = []
        for foreign in changes.changed {
            if queue.contains(.delete(foreign.id)) { continue }
            if waiting(foreign.id), let own = wordings[foreign.id] {
                var merged = rule(foreign.contentType).merge(own, foreign)
                merged.seal = foreign.seal
                wordings[foreign.id] = merged
                requeue(foreign.id)
            } else {
                wordings[foreign.id] = foreign
                rejections[foreign.id] = nil
            }
            affected.insert(foreign.contentType)
        }
        for name in changes.deleted {
            if waiting(name), wordings[name] != nil {
                wordings[name]?.seal = nil
                requeue(name)
                continue
            }
            rejections[name] = nil
            if wordings.removeValue(forKey: name) != nil { affected.insert(name.contentType) }
        }
        tag = changes.tag
        pending = queue.count
        notify(affected)
    }

    private func waiting(_ name: RecordName) -> Bool {
        queue.contains(.write(name)) || rejections[name] != nil
    }

    private func requeue(_ name: RecordName) {
        if !queue.contains(.write(name)) { queue.append(.write(name)) }
    }

    private func push(_ service: any CloudService, _ zone: ZoneID) async throws(CloudError) {
        var round = 0
        while !queue.isEmpty, round < ProfileZone.conflictRounds {
            round += 1
            let deletions = queue.compactMap { job -> RecordName? in
                if case .delete(let n) = job { return n }
                return nil
            }
            if !deletions.isEmpty {
                try await service.delete(Array(deletions.prefix(ProfileZone.burst)), in: zone)
                let done = Set(deletions.prefix(ProfileZone.burst))
                queue.removeAll { done.contains($0.name) }
                pending = queue.count
                save()
            }
            let wishes = queue.compactMap { job -> CloudRecord? in
                if case .write(let n) = job { return wordings[n] }
                return nil
            }
            guard !wishes.isEmpty else {
                queue.removeAll { wordings[$0.name] == nil && !$0.isDeletion }
                pending = queue.count
                continue
            }
            let burst = Array(wishes.prefix(ProfileZone.burst))
            let results = try await service.save(burst, in: zone)
            var affected: Set<String> = []
            for (sent, result) in zip(burst, results) {
                switch result {
                case .stored(let fresh):
                    rejections[sent.id] = nil
                    guard let current = wordings[sent.id] else { continue }
                    // **Seal and server time belong together.** Both are the server's statements
                    // *about* the record and not payload; whoever adopts only the seal
                    // has a record that lies at the server and still carries
                    // no stamp — and ``CloudRecord/serverTime`` would come only
                    // on the next read. For a deadline that depends on it that would mean:
                    // it starts to run only on the pass after next.
                    if current.changed == sent.changed {
                        var done = current
                        done.seal = fresh.seal
                        done.serverTime = fresh.serverTime
                        wordings[sent.id] = done
                        queue.removeAll { $0 == .write(sent.id) }
                    } else {
                        wordings[sent.id]?.seal = fresh.seal
                        wordings[sent.id]?.serverTime = fresh.serverTime
                    }
                case .conflict(let server):
                    guard let own = wordings[sent.id] else { continue }
                    var merged = rule(server.contentType).merge(own, server)
                    merged.seal = server.seal
                    merged.changed = max(merged.changed, own.changed)
                    wordings[sent.id] = merged
                    affected.insert(server.contentType)
                case .vanished:
                    wordings[sent.id]?.seal = nil
                case .rejected(let reason):
                    guard let current = wordings[sent.id], current.changed == sent.changed else {
                        continue
                    }
                    queue.removeAll { $0 == .write(sent.id) }
                    if rejections[sent.id] == nil {
                        Diagnostics.defect(
                            "Cloud \(zone.name): \(sent.contentType)/\(sent.name) rejected — \(reason)",
                            since: nil, area: "Wolke")
                    }
                    rejections[sent.id] = Rejection(reason: reason, attempted: clock())
                }
            }
            pending = queue.count
            save()
            notify(affected)
        }
    }

    private func rule(_ contentType: String) -> MergeRule { rules[contentType] ?? .newer }

    private func notify(_ types: Set<String>) {
        guard !types.isEmpty else { return }
        for (_, entry) in observers where types.contains(entry.contentType) {
            entry.notify(read(entry.contentType))
        }
    }

    private func enqueue(_ job: Job) {
        queue.removeAll { $0.name == job.name }
        queue.append(job)
        pending = queue.count
        save()
        trigger()
    }

    /// One pass, bundled: Whoever reorders ten watchlist entries triggers one, not ten.
    private func trigger() {
        guard automatic, service != nil, zone != nil, removed == nil, !planned else { return }
        planned = true
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard let self else { return }
            self.planned = false
            await self.reconcile()
        }
    }

    // MARK: - Platte

    private func read() {
        guard let file, let data = try? Data(contentsOf: file) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let image = try? decoder.decode(Image.self, from: data) else { return }
        zone = image.zone ?? zone
        wordings = Dictionary(image.wordings.map { ($0.id, $0) }, uniquingKeysWith: { _, b in b })
        queue = image.queue
        tag = image.tag
        recent = image.recent
        sharedBy = image.sharedBy
        confirmed = image.confirmed ?? (image.tag != nil || image.recent != nil)
        removed = image.removed
        restarted = image.restarted ?? false
        let attempted = image.rejectedAttemptedAt ?? [:]
        rejections = (image.rejected ?? [:]).filter { wordings[$0.key] != nil }.reduce(into: [:]) {
            $0[$1.key] = Rejection(reason: $1.value, attempted: attempted[$1.key] ?? .distantPast)
        }
        // Every launch tries the rejected records once — a schema deployment
        // in between heals them this way without anyone having to touch them. If they fail
        // again, the pass takes them out of the queue again.
        for name in rejections.keys.sorted(by: { ($0.contentType, $0.name) < ($1.contentType, $1.name) })
        where wordings[name] != nil && !queue.contains(where: { $0.name == name }) {
            queue.append(.write(name))
        }
        if let here = service?.environment, image.environment != here, zone != nil {
            beginInNewEnvironment(here, previous: image.environment)
        }
        if service != nil, zone != nil { state = recent.map(ZoneState.synced) ?? .neverSynced }
        if service != nil, removed != nil { state = .lost }
    }

    /// A mirror from a **different CloudKit environment** — first contact instead of a lock.
    ///
    /// **The finding (CineLounge, 2026-09-28):** The TV ran as a debug build against
    /// "Development", the phone from TestFlight against "Production" — two separate worlds
    /// with separate data, even with the same Apple ID. If a device switches environment,
    /// the zone is missing there although the mirror had confirmed it; that would mean "deleted
    /// from remote", and the caller would clear the profile on the device. The zone of the other
    /// environment is not deleted, though, it is merely not here. So: everything up anew,
    /// delete nothing. A mirror without an entry (from before this guard) counts as foreign — a
    /// first contact never deletes anything, only the lock is destructive.
    private func beginInNewEnvironment(_ here: String, previous: String?) {
        tag = nil
        recent = nil
        confirmed = false
        restarted = false
        removed = nil
        rejections = [:]
        for message in wordings.values {
            var without = message
            without.seal = nil
            wordings[message.id] = without
            if !queue.contains(where: { $0.name == message.id }) { queue.append(.write(message.id)) }
        }
        pending = queue.count
        Diagnostics.step(
            "Cloud \(zone?.name ?? "?"): mirror from \(previous ?? "unknown environment") — restarted in \(here)",
            since: nil, area: "Wolke")
        save()
    }

    private func save() {
        guard let file else { return }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let image = Image(
            zone: zone, wordings: Array(wordings.values), queue: queue, tag: tag, recent: recent,
            sharedBy: sharedBy, rejected: rejected.isEmpty ? nil : rejected,
            rejectedAttemptedAt: rejections.isEmpty ? nil : rejections.mapValues(\.attempted),
            confirmed: confirmed, removed: removed, restarted: restarted ? true : nil,
            environment: service?.environment)
        guard let data = try? encoder.encode(image) else { return }
        try? FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: file, options: .atomic)
    }
}

extension ProfileZone.Job {
    var isDeletion: Bool {
        if case .delete = self { return true }
        return false
    }
}

/// Holds an observation — if it is dropped, the observation ends.
public final class ObservationResult: Sendable {
    private let end: @Sendable () -> Void

    init(end: @escaping @MainActor () -> Void) {
        self.end = { Task { @MainActor in end() } }
    }

    deinit { end() }
}
