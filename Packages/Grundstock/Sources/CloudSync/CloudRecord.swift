import Foundation

/// A field of a record — the value types CloudKit carries without a detour
/// (text, integer, decimal, point in time, bytes). A truth value is
/// a number in CloudKit; ``bool`` therefore also reads `integer(0)` and `integer(1)`.
///
/// The stored form (mirror, queue) keeps the original German case names
/// (`number`, `kommazahl`, `time`, `wahrheit`, `data`) — see `CodingKeys`.
public enum FieldValue: Sendable, Hashable, Codable {
    case text(String)
    case integer(Int)
    case double(Double)
    case date(Date)
    case bool(Bool)
    case data(Data)

    /// Stored keys keep their original (German) names — renaming them would
    /// make data written by earlier versions unreadable (AP85 B4). The shape is the one
    /// Swift synthesizes for an enum case with one unlabeled value: `{"number":{"_0":5}}`.
    private enum CodingKeys: String, CodingKey {
        case text
        case integer = "zahl"
        case double = "kommazahl"
        case date = "zeit"
        case bool = "wahrheit"
        case data = "daten"
    }

    private enum PayloadKey: String, CodingKey {
        case value = "_0"
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard let key = container.allKeys.first, container.allKeys.count == 1 else {
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: "Expected exactly one field type"))
        }
        let payload = try container.nestedContainer(keyedBy: PayloadKey.self, forKey: key)
        switch key {
        case .text: self = .text(try payload.decode(String.self, forKey: .value))
        case .integer: self = .integer(try payload.decode(Int.self, forKey: .value))
        case .double: self = .double(try payload.decode(Double.self, forKey: .value))
        case .date: self = .date(try payload.decode(Date.self, forKey: .value))
        case .bool: self = .bool(try payload.decode(Bool.self, forKey: .value))
        case .data: self = .data(try payload.decode(Data.self, forKey: .value))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .text(let v):
            var p = container.nestedContainer(keyedBy: PayloadKey.self, forKey: .text)
            try p.encode(v, forKey: .value)
        case .integer(let v):
            var p = container.nestedContainer(keyedBy: PayloadKey.self, forKey: .integer)
            try p.encode(v, forKey: .value)
        case .double(let v):
            var p = container.nestedContainer(keyedBy: PayloadKey.self, forKey: .double)
            try p.encode(v, forKey: .value)
        case .date(let v):
            var p = container.nestedContainer(keyedBy: PayloadKey.self, forKey: .date)
            try p.encode(v, forKey: .value)
        case .bool(let v):
            var p = container.nestedContainer(keyedBy: PayloadKey.self, forKey: .bool)
            try p.encode(v, forKey: .value)
        case .data(let v):
            var p = container.nestedContainer(keyedBy: PayloadKey.self, forKey: .data)
            try p.encode(v, forKey: .value)
        }
    }

    public var text: String? {
        if case .text(let t) = self { return t }
        return nil
    }

    public var integer: Int? {
        switch self {
        case .integer(let z): z
        case .double(let k): Int(k)
        case .bool(let w): w ? 1 : 0
        default: nil
        }
    }

    public var double: Double? {
        switch self {
        case .double(let k): k
        case .integer(let z): Double(z)
        default: nil
        }
    }

    public var date: Date? {
        if case .date(let z) = self { return z }
        return nil
    }

    public var bool: Bool? {
        switch self {
        case .bool(let w): w
        case .integer(let z): z != 0
        default: nil
        }
    }

    public var data: Data? {
        if case .data(let d) = self { return d }
        return nil
    }
}

/// Type and name together — the address of a record in its zone.
public struct RecordName: Sendable, Hashable, Codable {
    /// Stored keys keep their original (German) names — renaming them would
    /// make data written by earlier versions unreadable (AP85 B4).
    private enum CodingKeys: String, CodingKey {
        case contentType = "typ"
        case name
    }

    public let contentType: String
    public let name: String

    public init(contentType: String, name: String) {
        self.contentType = contentType
        self.name = name
    }
}

/// A record as the zone holds it: type, name (the `recordName` — chosen by the
/// packages above so that the same value gets the same name on two devices,
/// otherwise there would be duplicates instead of conflicts), the fields, and ``changed``
/// as the clock by which "the more recent change wins" is decided.
///
/// ``seal`` is what CloudKit knows about the record (the system fields with
/// the server's change tag) — without a seal the record is new to the server,
/// with a seal it is a change request that the server accepts only if it still has
/// the state (`ifServerRecordUnchanged`). The packages above never set it themselves.
///
/// ``creator`` is the Apple ID that created the record (`___createdBy`,
/// the user's record name) — the server sets it, the packages only read it. With it
/// a `Device` record can be assigned to a participant of the share, whose
/// identity Apple otherwise does not reveal with a share via the link.
public struct CloudRecord: Sendable, Hashable, Codable, Identifiable {
    /// Stored keys keep their original (German) names — renaming them would
    /// make data written by earlier versions unreadable (AP85 B4).
    private enum CodingKeys: String, CodingKey {
        case contentType = "typ"
        case name
        case fields = "felder"
        case changed = "geaendert"
        case seal = "siegel"
        case creator = "ersteller"
        case encrypted = "verschluesselt"
        case serverTime = "serverzeit"
    }

    public let contentType: String
    public let name: String
    public var fields: [String: FieldValue]
    public var changed: Date
    public var seal: Data?
    public var creator: String?

    /// Which fields are transmitted **encrypted** (`CKRecord.encryptedValues`).
    ///
    /// **A field is either encrypted or not, and that forever.** Apple:
    /// *"Existing fields in a CloudKit schema are not eligible for encryption."* Whoever
    /// first stores a password in plain text and later wants to encrypt it has to create a
    /// **new field** — the old one stays in the container, and containers are
    /// not deleted. That is why this set is fixed at the very first write of a kind
    /// and not touched afterwards.
    ///
    /// **Must not be encrypted:** references (`CKReference`) and everything that is
    /// searched or sorted by: an encrypted field carries no index. ``changed``
    /// therefore always stays in plain text — it is the clock of the ``MergeRule``, and in the
    /// dashboard it is the first thing you look at.
    ///
    /// **On reading, ``CloudKitService`` fills it from the record itself.** The caller
    /// does not need to know what was once created encrypted — it learns it.
    public var encrypted: Set<String>

    /// When the **server** last wrote this record — `nil` as long as it
    /// exists only in the mirror.
    ///
    /// **``changed`` is the clock of the writing device and is no good as a deadline.**
    /// It goes out as an ordinary field (``CloudKitService``) and thus carries
    /// exactly the time that was set there. For the merge rule that is
    /// right — it asks "who was last", and there the person's intent counts. For a
    /// **deadline** it is wrong: Whoever computes one against a clock that
    /// the same person can set has no deadline.
    ///
    /// The case that decided this is the way out "forgot PIN" on the TV
    /// (CineLounge AP43): the system clock of tvOS lives in **its** settings and
    /// not behind the app's parental controls — a child sets it a
    /// day ahead in two minutes.
    ///
    /// The field is filled only on reading, from `CKRecord.modificationDate`. It
    /// **never** goes out: a value the device could set would again be
    /// the device's clock.
    public var serverTime: Date?

    public init(
        contentType: String, name: String, fields: [String: FieldValue], changed: Date = Date(),
        seal: Data? = nil,
        creator: String? = nil, encrypted: Set<String> = [], serverTime: Date? = nil
    ) {
        self.contentType = contentType
        self.name = name
        self.fields = fields
        self.changed = changed
        self.seal = seal
        self.creator = creator
        self.encrypted = encrypted
        self.serverTime = serverTime
    }

    /// **Read by hand, and only because of one line.**
    ///
    /// ``encrypted`` was added on 2026-09-21. On devices that carry StoryShelf build 236,
    /// the mirror lies as a file **without** this field; the decoding
    /// generated by Swift demands every key and would have failed at exactly this point
    /// — the whole mirror would be unreadable, and with it the queue:
    /// everything a device wrote without a network and could not yet send.
    ///
    /// A `decodeIfPresent` costs these twenty lines and prevents that.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        contentType = try container.decode(String.self, forKey: .contentType)
        name = try container.decode(String.self, forKey: .name)
        fields = try container.decode([String: FieldValue].self, forKey: .fields)
        changed = try container.decode(Date.self, forKey: .changed)
        seal = try container.decodeIfPresent(Data.self, forKey: .seal)
        creator = try container.decodeIfPresent(String.self, forKey: .creator)
        encrypted =
            try container.decodeIfPresent(Set<String>.self, forKey: .encrypted) ?? []
        serverTime = try container.decodeIfPresent(Date.self, forKey: .serverTime)
    }

    public var id: RecordName { RecordName(contentType: contentType, name: name) }

    public subscript(field: String) -> FieldValue? {
        get { fields[field] }
        set { fields[field] = newValue }
    }
}

/// A zone: its name and, for a foreign one, who owns it. The own zone lies
/// in the private database (``owner`` `nil`), an accepted share in the
/// shared database under the owner's record name.
public struct ZoneID: Sendable, Hashable, Codable {

    /// Every profile zone is called `profile-<id>` — the ID is a UUID that the
    /// profile gets on first binding and never changes (renaming leaves the zone
    /// in place; the name was only the crutch of the key store until E51).
    public static let preamble = "profil-"

    public let name: String
    public let owner: String?

    /// CloudKit's name for **the own account** (`CKCurrentUserDefaultName`).
    ///
    /// **The finding (CineLounge, on-device test 2026-09-28):** Apple TV and iPhone with the same
    /// Apple ID. The phone accepted the share of a profile that belongs to itself;
    /// CloudKit named `__defaultOwner__` as the owner, and because every ID with an owner
    /// counted as ``shared``, the mirror queried the **shared** database —
    /// "Only shared zones can be accessed in the shared DB" (CKError 12), on every pass.
    /// Of the profile only the name arrived. The own account is not a foreign owner.
    public static let ownAccount = "__defaultOwner__"

    public init(name: String, owner: String? = nil) {
        self.name = name
        self.owner = owner == Self.ownAccount ? nil : owner
    }

    /// Even a stored mirror that already carries the placeholder reads correctly.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            name: try container.decode(String.self, forKey: .name),
            owner: try container.decodeIfPresent(String.self, forKey: .owner))
    }

    private enum CodingKeys: String, CodingKey { case name, owner = "besitzer" }

    public init(profile identifier: UUID, owner: String? = nil) {
        self.init(name: ZoneID.preamble + identifier.uuidString.lowercased(), owner: owner)
    }

    public var shared: Bool { owner != nil }

    /// Whether it is a profile zone — the shared database can carry other things too.
    public var isProfile: Bool { name.hasPrefix(ZoneID.preamble) }
}

/// The rule by which two versions of the same record become one — the
/// own change against what the server has in the meantime.
public struct MergeRule: Sendable {
    public let merge: @Sendable (_ own: CloudRecord, _ server: CloudRecord) -> CloudRecord

    public init(_ merge: @escaping @Sendable (CloudRecord, CloudRecord) -> CloudRecord) {
        self.merge = merge
    }

    /// The more recent change wins — settings, watchlist entries.
    public static let newer = MergeRule { own, server in
        own.changed >= server.changed ? own : server
    }

    /// The larger value of a field wins — for sessions the later end (the
    /// running audiobook session keeps growing); with an equal value the more recent change.
    public static func greaterValue(_ field: String) -> MergeRule {
        MergeRule { own, server in
            let e = own[field]?.date?.timeIntervalSince1970 ?? own[field]?.double ?? 0
            let s = server[field]?.date?.timeIntervalSince1970 ?? server[field]?.double ?? 0
            if e != s { return e > s ? own : server }
            return MergeRule.newer.merge(own, server)
        }
    }
}
