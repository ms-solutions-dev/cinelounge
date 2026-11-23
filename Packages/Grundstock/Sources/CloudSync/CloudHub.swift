import Foundation
import Grundstock
import Observation

/// This device as it registers in the zone (record `Device`) — so that the
/// "iCloud & Devices" sheet can say who uses the zone. Apple only knows Apple IDs
/// as participants; the device list is our own bookkeeping.
public struct DeviceDescription: Sendable, Hashable {
    public let identifier: String
    public let name: String
    public let model: String

    public init(identifier: String, name: String, model: String) {
        self.identifier = identifier
        self.name = name
        self.model = model
    }
}

/// A device from the zone — for display. ``creator`` is the Apple ID that
/// registered it (this is how the sheet finds a participant's devices), ``named``
/// says that a person set the name — then the device no longer writes it back
/// with its system name.
public struct DeviceEntry: Sendable, Hashable, Identifiable {
    public let identifier: String
    public let name: String
    public let model: String
    public let recent: Date
    public let creator: String?
    public let named: Bool
    public var id: String { identifier }
}

/// What is settled after accepting a share: the zone in the shared
/// database, who gave it, and what the profile is called and looks like there.
public struct Accepted: Sendable, Hashable {
    public let zone: ZoneID
    public let ownerName: String?
    public let profileName: String?
    public let color: String?
}

/// The one place that knows the container: account status, the two
/// database subscriptions, the database tokens, the live zones — and what
/// a silent push triggers. In addition the **binding** of a profile to its zone and
/// everything around sharing.
///
/// **Binding (zone choice):** a profile that has no zone yet gets one with a
/// new identifier — **unless** the private database already holds a profile zone
/// whose record `Profileinstellung/name` carries the same name: then it is
/// the same reader on the same Apple ID on another device (the same reader on an iPhone,
/// the same reader on an iPad, E48), and the profile takes that zone. After that only
/// the identifier decides: renaming leaves the zone in place, a second profile with the same name on the
/// same device gets its own (the search only asks unbound profiles).
///
/// **A silent push** only says "a database has changed". The hub then
/// fetches the database changes (which zones) and nudges the affected
/// live zones; a revoked or deleted zone is noted as lost.
@MainActor
@Observable
public final class CloudHub {

    public static let settingType = "Profileinstellung"
    public static let deviceType = "Geraet"
    public static let nameKey = "name"
    public static let colorKey = "farbe"
    public static let valueField = "wert"
    /// On the `Device`: `1` if a person set the name (addendum to E52).
    public static let namedField = "benannt"
    /// The name of a participant, assigned by the owner — `Profileinstellung`
    /// `participant.<record name of the Apple ID>`: Apple reveals no identity for a share
    /// via the link, so the reader names who that is.
    public static let participantPrefix = "teilnehmer."

    public let service: (any CloudService)?
    public private(set) var account: AccountStatus = .unknown
    public let device: DeviceDescription

    private let file: URL?
    private var marks: [Bool: Data] = [:]
    private var subscribed = false
    private var zones: [ZoneHolder] = []
    private var accountWatch: Task<Void, Never>?

    private struct ZoneHolder {
        weak var zone: ProfileZone?
    }

    private struct Image: Codable {
        /// Stored keys keep their original (German) names — renaming them would
        /// make data written by earlier versions unreadable (AP85 B4).
        private enum CodingKeys: String, CodingKey {
            case privateToken = "privateMarke"
            case sharedToken = "geteilteMarke"
            case subscribed = "abonniert"
            case environment = "umgebung"
        }

        var privateToken: Data?
        var sharedToken: Data?
        var subscribed: Bool
        /// See ``CloudService/environment`` — change tokens only apply in their environment.
        var environment: String?
    }

    /// - Parameters:
    ///   - dienst: the call to the server; `nil` means: no iCloud in this run.
    ///   - datei: where tokens and subscription state are stored (`Application Support/cloud.json`).
    ///   - geraet: this device for the `Device` record.
    public init(service: (any CloudService)?, file: URL?, device: DeviceDescription) {
        self.service = service
        self.file = file
        self.device = device
        read()
    }

    public static var defaultFile: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appending(path: "wolke.json")
    }

    // MARK: - Start

    /// Account status, subscriptions, the account guard — and a first look into both
    /// databases. Once at startup; after that the pushes arrive.
    public func start() async {
        guard let service else { return }
        account = await service.accountStatus()
        if accountWatch == nil {
            accountWatch = Task { [weak self] in
                for await _ in service.accountChanges() {
                    await self?.accountChanged()
                }
            }
        }
        guard account == .available else { return }
        if !subscribed {
            do throws(CloudError) {
                try await service.subscribe()
                subscribed = true
                save()
            } catch {
                Diagnostics.defect("Cloud: subscription failed — \(error)", since: nil, area: "Wolke")
            }
        }
        await checkDatabases()
    }

    /// The account changed: sign-out, iCloud off for the app, sign-in. The zones
    /// learn about it on the next call — here it is triggered.
    public func accountChanged() async {
        guard let service else { return }
        let previous = account
        account = await service.accountStatus()
        Diagnostics.step("Cloud: account \(previous) → \(account)", since: nil, area: "Wolke")
        if account == .available {
            marks = [:]
            subscribed = false
            await start()
        }
        for zone in live { await zone.reconcile() }
    }

    public func register(_ zone: ProfileZone) {
        zones.removeAll { $0.zone == nil || $0.zone === zone }
        zones.append(ZoneHolder(zone: zone))
    }

    private var live: [ProfileZone] { zones.compactMap(\.zone) }

    // MARK: - Pushes

    /// A silent push — `true` if it came from CloudKit and there was something to fetch.
    public func process(push: [AnyHashable: Any]) async -> Bool {
        guard let service, let interpretation = service.interpret(push: push) else { return false }
        switch interpretation {
        case .database(let shared): await checkDatabase(shared: shared)
        }
        return true
    }

    /// Ask both databases for changed zones and nudge the live ones.
    public func checkDatabases() async {
        await checkDatabase(shared: false)
        await checkDatabase(shared: true)
    }

    private func checkDatabase(shared: Bool) async {
        guard let service else { return }
        do throws(CloudError) {
            let changes = try await service.databaseChanges(shared: shared, since: marks[shared])
            marks[shared] = changes.tag
            save()
            for zone in live {
                guard let identifier = zone.zone, identifier.shared == shared else { continue }
                // **Deleted and then recreated** (for instance after ``ProfileZone/discard()``)
                // is no longer a deletion — then the change counts.
                if changes.deleted.contains(identifier), !changes.changed.contains(identifier) {
                    if shared {
                        zone.noteLost()
                    } else {
                        // An **own** zone: do not revive (``ProfileZone``, 2026-09-27).
                        zone.noteRemoved(
                            changes.deletedByUser.contains(identifier) ? .byUser : .fromRemote)
                    }
                } else if changes.changed.contains(identifier) {
                    await zone.reconcile()
                }
            }
        } catch {
            Diagnostics.defect(
                "Cloud: database \(shared ? "shared" : "private") — \(error)", since: nil, area: "Wolke")
        }
    }

    // MARK: - Anbinden

    /// Attaches an unbound zone — found or new (see above). Returns the
    /// identifier the profile remembers; `nil` if there is no account
    /// (then the zone stays unbound and everything local).
    public func bind(_ zone: ProfileZone, identifier: UUID, name: String, color: String?) async -> ZoneID? {
        guard let service else { return nil }
        if let device = zone.zone {
            await syncAndRegister(zone, name: name, color: color)
            return device
        }
        account = await service.accountStatus()
        guard account == .available else { return nil }
        do throws(CloudError) {
            let needle = CloudHub.normalized(name)
            for foreign in try await service.zones(shared: false) where foreign.isProfile {
                let wordings = try await service.read(
                    [RecordName(contentType: CloudHub.settingType, name: CloudHub.nameKey)],
                    in: foreign)
                guard let there = wordings.first?[CloudHub.valueField]?.text,
                    CloudHub.normalized(there) == needle
                else { continue }
                Diagnostics.step(
                    "Cloud: profile \"\(name)\" takes zone \(foreign.name)", since: nil, area: "Wolke")
                zone.bind(on: foreign)
                await syncAndRegister(zone, name: name, color: color)
                return foreign
            }
            let own = ZoneID(profile: identifier)
            try await service.create(own)
            zone.bind(on: own)
            await syncAndRegister(zone, name: name, color: color)
            return own
        } catch {
            Diagnostics.defect(
                "Cloud: binding \"\(name)\" failed — \(error)", since: nil, area: "Wolke")
            return nil
        }
    }

    private func syncAndRegister(_ zone: ProfileZone, name: String, color: String?) async {
        if zone.zone?.shared != true { writeName(name, color: color, in: zone) }
        writeDevice(in: zone)
        await zone.reconcile()
    }

    /// Name and color of the profile into the zone — for the zone choice of the other
    /// device and for the profile a participant creates. Only if something changes.
    public func writeName(_ name: String, color: String?, in zone: ProfileZone) {
        let contentType = CloudHub.settingType
        if zone.read(contentType: contentType, name: CloudHub.nameKey)?[CloudHub.valueField]?.text != name {
            zone.write(
                CloudRecord(
                    contentType: contentType, name: CloudHub.nameKey,
                    fields: [CloudHub.valueField: .text(name)]))
        }
        if let color,
            zone.read(contentType: contentType, name: CloudHub.colorKey)?[CloudHub.valueField]?.text != color
        {
            zone.write(
                CloudRecord(
                    contentType: contentType, name: CloudHub.colorKey,
                    fields: [CloudHub.valueField: .text(color)]))
        }
    }

    /// This device into the zone — at most once per hour, so that the sync
    /// does not produce a write request at every start. If a person has named the device
    /// (``namedField``), their name stays; only `recent` moves.
    public func writeDevice(in zone: ProfileZone) {
        let existing = zone.read(contentType: CloudHub.deviceType, name: device.identifier)
        let named = existing?[CloudHub.namedField]?.bool == true
        let name = named ? (existing?["name"]?.text ?? device.name) : device.name
        if let existing, let recent = existing["zuletzt"]?.date, Date().timeIntervalSince(recent) < 3600,
            existing["name"]?.text == name
        {
            return
        }
        var fields: [String: FieldValue] = [
            "name": .text(name), "modell": .text(device.model), "zuletzt": .date(Date()),
        ]
        if named { fields[CloudHub.namedField] = .bool(true) }
        zone.write(CloudRecord(contentType: CloudHub.deviceType, name: device.identifier, fields: fields))
    }

    /// Rename a device — anyone with write permission may do this, also for someone else's
    /// device. The name stays afterwards (``namedField``). If the record does
    /// not exist yet (the own device right at joining), it is created with the name.
    public func nameDevice(_ identifier: String, name: String, in zone: ProfileZone) {
        let fresh = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !fresh.isEmpty else { return }
        var fields = zone.read(contentType: CloudHub.deviceType, name: identifier)?.fields ?? [:]
        if identifier == device.identifier {
            fields["modell"] = .text(device.model)
            fields["zuletzt"] = .date(Date())
        }
        guard fields["modell"] != nil else { return }
        fields["name"] = .text(fresh)
        fields[CloudHub.namedField] = .bool(true)
        zone.write(CloudRecord(contentType: CloudHub.deviceType, name: identifier, fields: fields))
    }

    /// Name a participant — as a `Profileinstellung` in the zone, so that every
    /// device of the owner sees the same name. An empty name deletes it.
    public func nameParticipant(_ identifier: String, name: String, in zone: ProfileZone) {
        let fresh = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let recordName = CloudHub.participantPrefix + identifier
        if fresh.isEmpty {
            zone.delete(contentType: CloudHub.settingType, name: recordName)
        } else {
            zone.write(
                CloudRecord(
                    contentType: CloudHub.settingType, name: recordName,
                    fields: [CloudHub.valueField: .text(fresh)]))
        }
    }

    /// The assigned name of a participant — `nil` if none is assigned.
    public static func participantName(_ identifier: String, in zone: ProfileZone) -> String? {
        zone.read(contentType: settingType, name: participantPrefix + identifier)?[valueField]?.text
    }

    /// The devices that use a zone — from the `Device` records.
    public static func devices(in zone: ProfileZone) -> [DeviceEntry] {
        zone.read(deviceType).compactMap { message in
            guard let name = message["name"]?.text else { return nil }
            return DeviceEntry(
                identifier: message.name, name: name, model: message["modell"]?.text ?? "",
                recent: message["zuletzt"]?.date ?? message.changed, creator: message.creator,
                named: message[namedField]?.bool == true)
        }
        .sorted { $0.recent > $1.recent }
    }

    /// The devices of a participant — the ones they registered themselves (`___createdBy`).
    /// This is how the sheet says "iPad · joined via link" where Apple only knows "unknown".
    public static func devices(from participant: String, in zone: ProfileZone) -> [DeviceEntry] {
        devices(in: zone).filter { $0.creator == participant }
    }

    /// How the zone choice compares names — lowercase, trimmed, a single space.
    public static func normalized(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    // MARK: - Freigabe

    public func split(_ zone: ZoneID, title: String) async throws(CloudError) -> AccessGrant {
        guard let service else { throw .noAccount }
        return try await service.split(zone, title: title)
    }

    public func approval(_ zone: ZoneID) async throws(CloudError) -> AccessGrant? {
        guard let service else { return nil }
        return try await service.approval(zone)
    }

    public func remove(participant: String, from zone: ZoneID) async throws(CloudError) {
        guard let service else { throw .noAccount }
        try await service.remove(participant: participant, from: zone)
    }

    public func endSharing(_ zone: ZoneID) async throws(CloudError) {
        guard let service else { throw .noAccount }
        try await service.endSharing(zone)
    }

    /// Accepts a share link and reads the name and color of the profile from the zone.
    public func accept(url: URL) async throws(CloudError) -> Accepted {
        guard let service else { throw .noAccount }
        let meta = try await service.sharingMetadata(url)
        let zone = try await service.accept(meta)
        // **An own zone that does not exist here is a different iCloud environment**
        // (2026-09-28): same Apple ID, but one device as a debug build ("Development"), the
        // other from TestFlight ("Production"). Until now this silently produced an empty
        // zone, and the profile arrived with just a name. Now it is a clear error.
        if !zone.shared, !(try await service.zones(shared: false)).contains(zone) {
            Diagnostics.defect(
                "Share points to an own zone that does not exist here — different iCloud environment "
                    + "(development/TestFlight)? Here: \(service.environment ?? "unknown")",
                since: nil, area: "Wolke")
            throw .rejected("Zone not in this iCloud environment")
        }
        let contentType = CloudHub.settingType
        let wordings = try await service.read(
            [
                RecordName(contentType: contentType, name: CloudHub.nameKey),
                RecordName(contentType: contentType, name: CloudHub.colorKey),
            ], in: zone)
        return Accepted(
            zone: zone, ownerName: meta.ownerName,
            profileName: wordings.first { $0.name == CloudHub.nameKey }?[CloudHub.valueField]?
                .text,
            color: wordings.first { $0.name == CloudHub.colorKey }?[CloudHub.valueField]?.text)
    }

    /// Whether a link is an iCloud share link.
    ///
    /// The host must be `icloud.com` or end in `.icloud.com` — a plain
    /// `hasSuffix("icloud.com")` also let `evilicloud.com` through (ultra, 2026-09-27).
    public static func isShareLink(_ url: URL) -> Bool {
        let host = (url.host() ?? "").lowercased()
        return (host == "icloud.com" || host.hasSuffix(".icloud.com")) && url.path.hasPrefix("/share")
    }

    /// Delete the zone of an own profile — data stays in the mirror.
    public func delete(_ zone: ZoneID) async throws(CloudError) {
        guard let service else { return }
        try await service.delete(zone)
    }

    public func leave(_ zone: ZoneID) async throws(CloudError) {
        guard let service else { return }
        try await service.leave(zone)
    }

    // MARK: - Platte

    private func read() {
        guard let file, let data = try? Data(contentsOf: file),
            let image = try? JSONDecoder().decode(Image.self, from: data)
        else { return }
        // **A different environment means: start from scratch** (2026-09-28). A change token from
        // "Development" is worthless in "Production", and a subscription there does not exist yet.
        if let here = service?.environment, image.environment != here { return }
        marks[false] = image.privateToken
        marks[true] = image.sharedToken
        subscribed = image.subscribed
    }

    private func save() {
        guard let file else { return }
        let image = Image(
            privateToken: marks[false], sharedToken: marks[true], subscribed: subscribed,
            environment: service?.environment)
        guard let data = try? JSONEncoder().encode(image) else { return }
        try? FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: file, options: .atomic)
    }
}
