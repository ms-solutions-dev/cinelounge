import CloudSync
import Core
import Foundation

/// The person token as a record of the profile zone — and back (AP47, decision A).
///
/// **A record type of its own, and that is the only form that holds.** The finding on
/// ``PreferenceMapping`` applies here literally: every already installed version clears
/// every `Profileinstellung` and `Access` record that it does not write itself during
/// sync (``ProfileCloud/ownTypes``), and a `Access` record with a field it does not
/// know it writes back on the next run **without** that field — its fields differ from the
/// mirror, so it "changes" it. The token would thus disappear on every run of the iPhone.
/// A type that a version does not know it neither clears nor writes.
///
/// **This version does not clear it either.** A token has no "gone" that would have to
/// travel over the cloud: a revocation brings a **new** token that replaces the old one. A
/// device that has not yet fetched the token could otherwise delete it before ever having
/// seen it.
///
/// **The field is encrypted, from the first write** (`CKRecord.encryptedValues`).
/// A field cannot be encrypted retroactively, and containers are never
/// deleted — the same reasoning as with ``ChannelListMapping/isSecret``.
///
/// **A new type means a new schema:** before the next TestFlight build it has to go from
/// development to production in the CloudKit console, otherwise the server rejects every record
/// of this type.
public enum PortalMarkerMapping {

    /// The record type.
    public static let contentType = "Portalmarke"

    /// The record name — **fixed**, because a profile carries at most one token and two
    /// devices would otherwise create two records side by side instead of deciding a conflict.
    ///
    /// **No longer `portals`** (diagnosis F-025, 2026-09-28): that is already the name of the
    /// CL-Server access (``ProfileMapping/recordName(forItem:)``), and a name applies in
    /// a zone across all types. If a profile carried access **and** token, CloudKit rejected
    /// every run with "You can't save the same record twice" — and with it everything else
    /// of this profile.
    public static let name = "portalmarke"

    static let valueField = ProfileMapping.valueField

    /// The encrypted fields.
    public static let isSecret: Set<String> = [valueField]

    /// The token as a record — empty without a token.
    public static func wordings(forItem tag: PersonMarker?, now: Date) -> [CloudRecord] {
        guard let tag else { return [] }
        return [
            CloudRecord(
                contentType: contentType, name: name, fields: [valueField: .text(tag.value)], changed: now,
                encrypted: isSecret)
        ]
    }

    /// The token from the records of a zone — everything else is skipped.
    public static func tag(from wordings: [CloudRecord]) -> PersonMarker? {
        // By type and not by name: a token that lies up there under the old name
        // is thus still read.
        wordings.first { $0.contentType == contentType }?[valueField]?.text
            .flatMap(PersonMarker.init(value:))
    }
}
