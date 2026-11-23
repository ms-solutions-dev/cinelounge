import CloudSync
import Core
import Foundation

/// Channel lists as records of their zone — and back.
///
/// **The only type with an encrypted field.** Everything else CineLounge
/// syncs carries no secrets: The media-server access in the ``ProfileBook`` holds
/// address, user ID and display name, but no password — for that there has been Quick Connect since
/// AP43. An Xtream panel has no such thing; its password must come along,
/// otherwise a transferred list on the second device is an empty wrapper.
///
/// **`secret` is encrypted from the start, and that is the only chance.**
/// An existing field cannot be encrypted later (Apple: *"Existing
/// fields in a CloudKit schema are not eligible for encryption"*), and containers are
/// never deleted. Whoever first creates it in plain text needs a second field later — and
/// the first stays next to it forever.
public enum ChannelListMapping {

    public static let contentType = "Senderliste"

    static let nameField = "name"
    static let kindField = "art"
    static let addressField = "adresse"
    static let userField = "benutzer"
    static let epgField = "epg"
    static let activeField = "aktiv"
    static let secretField = "geheimnis"

    /// The fields that are transferred encrypted.
    public static let isSecret: Set<String> = [secretField]

    // MARK: - Hinauf

    public static func wordings(
        forItem listen: [ChannelListAccess], now: Date = Date()
    )
        -> [CloudRecord]
    {
        listen.map { message(forItem: $0, now: now) }
    }

    public static func message(
        forItem list: ChannelListAccess, now: Date = Date()
    )
        -> CloudRecord
    {
        var fields: [String: FieldValue] = [
            nameField: .text(list.name),
            kindField: .text(list.kind.rawValue),
            activeField: .bool(list.active),
        ]
        if let address = list.address { fields[addressField] = .text(address.absoluteString) }
        if !list.user.isEmpty { fields[userField] = .text(list.user) }
        if let epg = list.epg { fields[epgField] = .text(epg.absoluteString) }
        if let secret = list.secret, !secret.isEmpty {
            fields[secretField] = .text(secret)
        }
        return CloudRecord(
            contentType: contentType, name: list.key, fields: fields, changed: now,
            encrypted: isSecret)
    }

    // MARK: - Herunter

    public static func listen(from wordings: [CloudRecord]) -> [ChannelListAccess] {
        wordings
            .filter { $0.contentType == contentType }
            .sorted { $0.name < $1.name }
            .compactMap(list(from:))
    }

    /// - Returns: `nil` if the type is missing or this version does not know it. **Not
    ///   guessed:** A half-read channel list would be an entry that looks like an
    ///   access and is not one — and the viewer looks for the error at the provider.
    public static func list(from message: CloudRecord) -> ChannelListAccess? {
        guard let kind = message[kindField]?.text.flatMap(ChannelListAccess.Kind.init(rawValue:))
        else { return nil }
        return ChannelListAccess(
            key: message.name,
            name: message[nameField]?.text ?? message.name,
            kind: kind,
            address: message[addressField]?.text.flatMap(URL.init(string:)),
            user: message[userField]?.text ?? "",
            epg: message[epgField]?.text.flatMap(URL.init(string:)),
            // **Without the field, "enabled" applies.** A list that would silently be off after
            // the sync looks like a vanished access.
            active: message[activeField]?.bool ?? true,
            secret: message[secretField]?.text)
    }

}
