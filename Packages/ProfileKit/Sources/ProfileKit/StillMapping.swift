import CloudSync
import Core
import Foundation

/// A person's state as records of their zone — and back.
///
/// **Pure like ``ProfileMapping``**, for the same reason: Whether the right thing
/// is in the record should be answerable without a server, without an account and without ``ProfileZone``.
///
/// **The cut follows the conflict, not the type.** ``Core/StateRecording`` is a
/// value with five fields; as **one** record, two devices would fight over
/// the same row with every film. It is therefore split where two people or two devices
/// can really collide:
///
/// | What | Where to | Why there |
/// |---|---|---|
/// | ``Core/StateRecording/titlePositions`` | one `State` **per title** | Living room watches a film, bedroom a series — no conflict |
/// | ``Core/StateRecording/channelFavorites`` | one `Senderfavorit` **per channel** | Deselecting must be a deletion, see below |
/// | ``Core/StateRecording/lastChannel`` | `Profileinstellung` per list | One list per row; two lists never interfere |
/// | Group order and hidden items | one `Profileinstellung` each | One deliberate action in one go — the younger one applies |
///
/// **Why the favorites are not a list in one field.** They could be merged on
/// conflict — but a merge **cannot tell removed from
/// not-yet-added.** A deselected channel would come back from the other device, and
/// every time. One record per channel makes deselecting a deletion, and a
/// deletion is unambiguous.
public enum StillMapping {

    // MARK: - The names in the container

    public static let stillType = "Stand"
    public static let channelFavoriteType = "Senderfavorit"
    public static let settingType = ProfileMapping.settingType

    /// `lastChannel.<listenschluessel>` — and for "last overall" the prefix
    /// **without** the dot, because there the list key is empty (see
    /// ``Core/StateRecording/lastChannel``).
    public static let lastChannelPrefix = "letzterSender."
    public static let lastChannelOverall = "letzterSender"
    public static let groupOrderKey = "gruppenreihenfolge"
    public static let hiddenGroupsKey = "ausgeblendeteGruppen"

    static let positionField = "stelle"
    static let durationField = "dauer"
    static let watchedField = "gesehen"
    static let favoriteField = "favorit"
    static let titleField = "titel"
    static let kindField = "art"
    static let imageField = "bild"
    static let lastField = "zuletzt"
    static let channelField = "sender"
    static let valueField = ProfileMapping.valueField

    /// The merge rule for `State`.
    ///
    /// **The younger writer and not the larger value.** ``CloudSync`` brings both,
    /// and StoryShelf uses `greaterValue` correctly — for session end times that only
    /// grow. A playback position does not only grow: Whoever stops at 01:12:30 on the TV
    /// and picks "start over" on the iPad would, with "larger value wins",
    /// get their 01:12:30 back — every time. The stale writer of a long-
    /// absent device is already caught by ``CloudSync/CloudRecord/changed``.
    public static let stillRule = MergeRule.newer

    // MARK: - Hinauf

    public static func wordings(
        forItem state: StateRecording, now: Date = Date()
    )
        -> [CloudRecord]
    {
        titleRecords(forItem: state, now: now)
            + favoriteRecords(forItem: state, now: now)
            + settings(forItem: state, now: now)
    }

    public static func titleRecords(
        forItem state: StateRecording, now: Date = Date()
    )
        -> [CloudRecord]
    {
        state.titlePositions
            .sorted { $0.key < $1.key }
            .map { identifier, location in message(identifier, location, now: now) }
    }

    /// A title as a record.
    ///
    /// **Empty fields are left out instead of being stored empty.** A `image` field with empty text
    /// is a field that exists in CloudKit; a missing one is one that does not.
    /// When reading it is the same case — when viewing in the dashboard it is not, and there
    /// you look for errors.
    public static func message(
        _ identifier: String, _ location: StateRecording.TitlePosition, now: Date = Date()
    ) -> CloudRecord {
        var fields: [String: FieldValue] = [
            watchedField: .bool(location.seen),
            favoriteField: .bool(location.favorite),
        ]
        if let value = location.location { fields[positionField] = .double(value) }
        if let value = location.duration { fields[durationField] = .double(value) }
        if let value = location.title, !value.isEmpty { fields[titleField] = .text(value) }
        if let value = location.kind { fields[kindField] = .text(value.rawValue) }
        if let value = location.image, !value.isEmpty { fields[imageField] = .text(value) }
        if let value = location.recent { fields[lastField] = .date(value) }
        return CloudRecord(contentType: stillType, name: identifier, fields: fields, changed: now)
    }

    /// The channel favorites — one record per channel.
    ///
    /// The record name **is** the favorite key. It has always been the channel name
    /// reduced to a comparison form, and applies **across all lists**
    /// (`PlaylistKit/PlaylistStore/favoriteKey(for:)`) — that is why the `list` field
    /// from the schema is left unwritten here: There is none.
    public static func favoriteRecords(
        forItem state: StateRecording, now: Date = Date()
    )
        -> [CloudRecord]
    {
        state.channelFavorites.sorted().map { key in
            CloudRecord(
                contentType: channelFavoriteType, name: key,
                fields: [channelField: .text(key)], changed: now)
        }
    }

    public static func settings(
        forItem state: StateRecording, now: Date = Date()
    )
        -> [CloudRecord]
    {
        var wordings = state.lastChannel
            .sorted { $0.key < $1.key }
            .filter { !$0.value.isEmpty }
            .map { list, channels in
                setting(channelKey(forItem: list), channels, now: now)
            }
        if !state.groupOrder.isEmpty {
            wordings.append(
                setting(
                    groupOrderKey, list(state.groupOrder), now: now))
        }
        if !state.hiddenGroups.isEmpty {
            wordings.append(
                setting(
                    hiddenGroupsKey, list(state.hiddenGroups),
                    now: now))
        }
        return wordings
    }

    /// `lastChannel` for "last overall", otherwise `lastChannel.<list>`.
    public static func channelKey(forItem list: String) -> String {
        list.isEmpty ? lastChannelOverall : lastChannelPrefix + list
    }

    // MARK: - Herunter

    public static func state(from wordings: [CloudRecord]) -> StateRecording {
        var recording = StateRecording()
        for message in wordings {
            switch message.contentType {
            case stillType:
                recording.titlePositions[message.name] = titlePosition(from: message)
            case channelFavoriteType:
                recording.channelFavorites.append(message.name)
            case settingType:
                read(message, in: &recording)
            default:
                // A type this version does not know is skipped and **not
                // deleted**: It comes from a newer app on the same account.
                continue
            }
        }
        recording.channelFavorites.sort()
        return recording
    }

    public static func titlePosition(from message: CloudRecord) -> StateRecording.TitlePosition {
        StateRecording.TitlePosition(
            location: message[positionField]?.double,
            duration: message[durationField]?.double,
            seen: message[watchedField]?.bool ?? false,
            favorite: message[favoriteField]?.bool ?? false,
            title: message[titleField]?.text,
            kind: message[kindField]?.text.flatMap(MediaItem.Kind.init(rawValue:)),
            image: message[imageField]?.text,
            recent: message[lastField]?.date)
    }

    private static func read(_ message: CloudRecord, in recording: inout StateRecording) {
        guard let value = message[valueField]?.text else { return }
        switch message.name {
        case lastChannelOverall:
            recording.lastChannel[""] = value
        case groupOrderKey:
            recording.groupOrder = entries(value)
        case hiddenGroupsKey:
            recording.hiddenGroups = entries(value)
        case let name where name.hasPrefix(lastChannelPrefix):
            recording.lastChannel[String(name.dropFirst(lastChannelPrefix.count))] = value
        default:
            // Every other `Profileinstellung` belongs to the profile and not to the state
            // (`name`, `color`, `kind`) — it is not touched here.
            break
        }
    }

    // MARK: - Listen in einem Feld

    /// An ordered list as one field — **separated with U+001F.**
    ///
    /// The same separator as in the old shelf order before AP40, and for the same reason:
    /// A group name may carry any printable character, comma and semicolon
    /// included. A separator that can occur in the value will eventually split wrongly —
    /// and silently, because one group becomes two and both look plausible.
    static let separator = "\u{001F}"

    static func list(_ entries: [String]) -> String {
        entries.joined(separator: separator)
    }

    static func entries(_ value: String) -> [String] {
        value.isEmpty ? [] : value.components(separatedBy: separator)
    }

    private static func setting(
        _ name: String, _ value: String, now: Date
    )
        -> CloudRecord
    {
        CloudRecord(
            contentType: settingType, name: name, fields: [valueField: .text(value)], changed: now)
    }
}
