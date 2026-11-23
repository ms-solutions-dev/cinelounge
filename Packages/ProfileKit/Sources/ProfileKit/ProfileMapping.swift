import CloudSync
import Core
import Foundation

/// A profile as records of its zone — and back.
///
/// **Pure and without a zone**, so that the question "is the right thing in the record?" can be
/// answered without creating a server, an account or even a ``ProfileZone``.
/// The sync itself is another task (``ProfileCloud``).
///
/// **One zone per profile, and the zone *is* the profile.** There is no record kind
/// `ProfileKit`: its name is in the zone identifier (`profile-<uuid>`), everything else as
/// records in it. A kind of its own would be a record whose name the zone already
/// carries — and two places where the same identifier would have to appear.
///
/// **Name and color are not freely chosen.** ``CloudSync/CloudHub`` reads both
/// when connecting: if it finds in the private database a profile zone whose
/// `Profileinstellung/name` carries the same name, that is the same person on another
/// device, and the profile takes this zone instead of a new one. That is why
/// the keys here are called `name` and `color` and not, say, `profileName`.
public enum ProfileMapping {

    // MARK: - The names in the container

    /// **Written out and not taken over from ``CloudSync/CloudHub``.**
    ///
    /// Its constants are bound to `@MainActor`, this mapping is not — it
    /// is meant to be usable in a background run too. That the four nevertheless **must**
    /// match character for character is checked by
    /// `ProfileMappingTests/dieselben Namen for in der Zentrale`: if `CloudSync` renames
    /// them, this check turns red — and not only the sync on the device.
    public static let settingType = "Profileinstellung"
    public static let accessType = "Zugang"

    public static let nameKey = "name"
    public static let colorKey = "farbe"
    public static let kindKey = "art"

    /// The profile picture (AP49) — **a record type of its own and not the fourth
    /// `Profileinstellung` record**, as the concept had planned.
    ///
    /// **The reason is in ``ProfileCloud/ownTypes``:** every already installed version
    /// clears during sync every `Profileinstellung` record that it does not write itself.
    /// An iPhone on a build from before AP49 would thus delete the picture on every
    /// run, the TV would write it up again on the next — a picture that never arrives on the
    /// second device. The same trap, the same way out as with
    /// ``PreferenceMapping`` and ``PortalMarkerMapping``: a type that a version does
    /// not know it neither clears nor writes.
    ///
    /// **This version never clears it either** (it is not under
    /// ``ProfileCloud/ownTypes``). The first version did, and the counter-check of
    /// 2026-09-25 found the price: `nil` meant both "never decided" and "No picture".
    /// A device whose mirror already had the record, but whose book did not have the field yet
    /// (the first build after the update), deleted the record on the next run — and
    /// the picture was gone on all devices.
    ///
    /// **"No picture" is therefore a value of its own: the empty name `""`**, as a record with
    /// a timestamp like every other choice. That way deselecting arrives on the other device,
    /// and between "picture" and "No picture" the newer writer decides — even
    /// offline, which a delete without a time could not do. `nil` means "never decided":
    /// no record, no deleting, and on download the local value stays.
    ///
    /// **A new type means a new schema:** before the next TestFlight build it has to go from
    /// development to production in the CloudKit console.
    public static let avatarType = "Profilbild"

    /// The record name — fixed, because a profile carries at most one picture.
    public static let avatarKey = "avatar"

    static let valueField = "wert"
    static let kindField = "art"
    static let serverField = "server"
    static let userIDField = "benutzerkennung"
    static let displayNameField = "anzeigename"
    static let identifierField = "kennung"
    static let personField = "person"
    static let orderField = "reihenfolge"

    /// The zone of this profile.
    ///
    /// **By identifier and not by name.** A profile may be renamed
    /// without losing its state — ``ProfileKit/Identifier`` is assigned once and
    /// never changes again, and exactly that is stated in ``ProfileKit/Identifier`` as the reasoning.
    ///
    /// - Returns: `nil` if the identifier is not a UUID. ``ProfileKit/Identifier/fresh()`` always creates
    ///   one; but the identifier can be built publicly, and a zone with a
    ///   different name pattern could not be found again on the second device — a
    ///   silent error that would only be noticed when the state does not arrive.
    public static func zone(forItem identifier: Profile.Identifier, owner: String? = nil) -> ZoneID? {
        guard let uuid = UUID(uuidString: identifier.rawValue) else { return nil }
        return ZoneID(profile: uuid, owner: owner)
    }

    // MARK: - Hinauf

    /// The profile as records — settings and accesses.
    ///
    /// ``ProfileKit/identifier`` is in **no** record: it is the zone name.
    public static func wordings(forItem profile: Profile, now: Date = Date()) -> [CloudRecord] {
        settings(forItem: profile, now: now) + avatar(forItem: profile, now: now)
            + credentials(forItem: profile, now: now)
    }

    /// The profile picture as a record — **none only as long as nothing was ever decided.**
    ///
    /// `nil` yields no record, `""` ("No picture") a record with an empty value, a name
    /// a record with the name. **The empty value here is not an absence but the
    /// tombstone** — unlike with the portals person in ``credentials(forItem:now:)``.
    /// See ``avatarType``.
    public static func avatar(forItem profile: Profile, now: Date = Date()) -> [CloudRecord] {
        guard let avatar = profile.avatar else { return [] }
        return [
            CloudRecord(
                contentType: avatarType, name: avatarKey, fields: [valueField: .text(avatar)],
                changed: now)
        ]
    }

    public static func settings(
        forItem profile: Profile, now: Date = Date()
    )
        -> [CloudRecord]
    {
        [
            (nameKey, profile.name),
            (colorKey, profile.color.rawValue),
            (kindKey, profile.kind.rawValue),
        ].map { key, value in
            CloudRecord(
                contentType: settingType, name: key, fields: [valueField: .text(value)],
                changed: now)
        }
    }

    /// The accesses — **with their order as a field.**
    ///
    /// Records come back sorted by name, and the order of the accesses is
    /// information: which access someone started with (see
    /// ``ProfileKit/credentials``). Without this field an alphabetical list would come back after the
    /// first sync, and nobody would have noticed.
    public static func credentials(forItem profile: Profile, now: Date = Date()) -> [CloudRecord] {
        profile.credentials.enumerated().map { slot, credential in
            var fields: [String: FieldValue] = [
                kindField: .text(credential.kind.rawValue),
                orderField: .integer(slot),
            ]
            switch credential {
            case .jellyfin(let server, let userID, let username):
                fields[serverField] = .text(server.absoluteString)
                fields[userIDField] = .text(userID)
                fields[displayNameField] = .text(username)
            case .channelList(let identifier):
                fields[identifierField] = .text(identifier)
            case .portals(let person):
                if let person, !person.isEmpty { fields[personField] = .text(person) }
            }
            return CloudRecord(
                contentType: accessType, name: recordName(forItem: credential), fields: fields, changed: now)
        }
    }

    /// The record name of an access — **the same on two devices.**
    ///
    /// Otherwise there would be duplicates instead of conflicts: two devices that deposit the same access under
    /// two names never argue with each other — both are simply there.
    ///
    /// Media server and portals get a fixed name, because there is only one of each per
    /// profile (``ProfileKit/create(_:)``, `onlyOnce`). A channel list carries
    /// its identifier, and since AP42 that is the `ListKey` from machine and account
    /// and not a rolled UUID — **that was the precondition for this line to work at
    /// all.**
    public static func recordName(forItem credential: Access) -> String {
        switch credential {
        case .jellyfin: Access.Kind.jellyfin.rawValue
        case .channelList(let identifier): "\(Access.Kind.channelList.rawValue)|\(identifier)"
        case .portals: Access.Kind.portals.rawValue
        }
    }

    // MARK: - Herunter

    /// The profile from the records of its zone.
    ///
    /// - Returns: `nil` if no name is in it. A profile without a name is an empty circle in the
    ///   switcher; better none than one that nobody can address.
    ///   Color, kind and picture, on the other hand, fall back to the default — those are taste,
    ///   not substance.
    public static func profile(
        identifier: Profile.Identifier, from wordings: [CloudRecord]
    ) -> Profile? {
        let settings = wordings.filter { $0.contentType == settingType }
        guard let name = value(nameKey, in: settings), !name.isEmpty else { return nil }
        return Profile(
            identifier: identifier,
            name: name,
            color: value(colorKey, in: settings).flatMap(Profile.ColorTag.init(rawValue:))
                ?? .amber,
            kind: value(kindKey, in: settings).flatMap(Profile.Kind.init(rawValue:))
                ?? .adult,
            credentials: credentials(from: wordings),
            avatar: avatar(from: wordings))
    }

    /// The profile picture from the records of a zone — `nil` without a record, `""` for "No picture".
    ///
    /// **`nil` here means "the cloud knows nothing"** and not "No picture"; whoever writes the profile
    /// from it into the book then keeps the local value (``ProfileCloud/download(_:)``,
    /// ``ProfileSync``). **A name that this bundle does not know still comes
    /// through** (see ``ProfileKit/avatar``). Whether it can draw it is decided by the display.
    public static func avatar(from wordings: [CloudRecord]) -> String? {
        guard let message = wordings.first(where: { $0.contentType == avatarType && $0.name == avatarKey })
        else { return nil }
        return message[valueField]?.text ?? ""
    }

    /// The name alone — for the zone search, which does not want to build a profile yet.
    public static func name(from wordings: [CloudRecord]) -> String? {
        value(nameKey, in: wordings.filter { $0.contentType == settingType })
    }

    /// The accesses, **in the order in which they were created.**
    ///
    /// An access without a readable kind is dropped and not guessed: what the kind does not
    /// know comes from a newer version of this program, and a half-read
    /// media server access would be worse than none.
    public static func credentials(from wordings: [CloudRecord]) -> [Access] {
        wordings
            .filter { $0.contentType == accessType }
            .sorted { links, right in
                let a = links[orderField]?.integer ?? Int.max
                let b = right[orderField]?.integer ?? Int.max
                return a == b ? links.name < right.name : a < b
            }
            .compactMap(credential(from:))
    }

    static func credential(from message: CloudRecord) -> Access? {
        guard let kind = message[kindField]?.text.flatMap(Access.Kind.init(rawValue:)) else { return nil }
        switch kind {
        case .jellyfin:
            guard let address = message[serverField]?.text, let server = URL(string: address),
                let userID = message[userIDField]?.text
            else { return nil }
            return .jellyfin(
                server: server, userID: userID,
                username: message[displayNameField]?.text ?? "")
        case .channelList:
            guard let identifier = message[identifierField]?.text, !identifier.isEmpty else { return nil }
            return .channelList(identifier: identifier)
        case .portals:
            // **An empty field is an answer here and not an absence.** "Portals without
            // person" is the case of the bare bridge (see ``Access/portals(person:)``).
            let person = message[personField]?.text
            return .portals(person: (person?.isEmpty ?? true) ? nil : person)
        }
    }

    private static func value(_ key: String, in wordings: [CloudRecord]) -> String? {
        wordings.first { $0.name == key }?[valueField]?.text
    }
}
