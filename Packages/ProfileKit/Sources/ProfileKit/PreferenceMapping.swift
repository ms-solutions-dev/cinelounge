import CloudSync
import Core
import Foundation

/// A person's playback preferences as records of their zone — and back.
///
/// **Owner decision 4 of 2026-09-24:** Audio preference and subtitles travel with the
/// profile. They stand **one per key** in the zone and not as a bundle: Whoever changes
/// the subtitle size on the phone and the audio language on the TV has made two
/// changes, and both should arrive. As one record the younger
/// pass would win **entirely** and take the other change with it.
///
/// **A record type of its own and not `Profileinstellung`** (cross-check of
/// 2026-09-24). Every already installed version clears, on sync, every
/// `Profileinstellung` record it does not write itself — so the phone would clear the preferences on
/// every pass, and the TV would write them up again on the next. A type it does not know
/// it does not clear (``ProfileCloud/ownTypes``), and the zone's mirror
/// keeps it. For the same reason this type is also **not** among the cleared types
/// here: A preference has no "gone" — there is no action that revokes it.
///
/// **The collision rule is that of name and color:** For the type, no rule of its own is set in
/// ``ProfileCloud/zone(forItem:)``, so the zone's default applies,
/// ``CloudSync/MergeRule/newer`` — the younger writer wins, per
/// record. On a device's first contact the cloud wins
/// (``ProfileCloud/reconcile(_:now:)``).
///
/// **A new type means a new schema:** CloudKit creates it in the development environment on
/// first write itself; for production the schema has to be
/// deployed from the console, otherwise the server rejects every record of this type.
public enum PreferenceMapping {

    /// The record type. The record name is the store key itself.
    public static let contentType = "Profilvorzug"

    static let valueField = ProfileMapping.valueField

    /// A person's own values as records.
    public static func wordings(
        forItem values: [String: String], now: Date
    ) -> [CloudRecord] {
        values.sorted { $0.key < $1.key }.map { key, value in
            CloudRecord(
                contentType: contentType, name: key, fields: [valueField: .text(value)], changed: now)
        }
    }

    /// The values from a zone's records — everything else is skipped.
    public static func values(from wordings: [CloudRecord]) -> [String: String] {
        var values: [String: String] = [:]
        for message in wordings where message.contentType == contentType {
            guard let value = message[valueField]?.text else { continue }
            values[message.name] = value
        }
        return values
    }
}
