import CloudSync
import Foundation

/// The profile PIN as a record of the profile zone — and back (AP52, 2026-09-25).
///
/// **A record type of its own and not a profile setting** — the lesson from AP49, and it is
/// hard here: every already installed version clears on every pass every
/// `Profileinstellung` record that it does not write itself (``ProfileCloud/ownTypes``).
/// If the PIN lay there, an old phone would take it out of the cloud on every pass, and the
/// TV would write it up again on the next — a profile that is protected one moment
/// and not the next. **A type that a version does not know, it does not clear.** For the
/// same reason it is also **not** among the cleared types in this version,
/// only among the read ones (``ProfileCloud/readTypes``): a PIN has its "gone"
/// as a tombstone (``ProfilePIN/ContentEntryRecord/verifier`` `== nil`), not as a deletion.
///
/// **The younger writer wins, by its own time field** (``rule``) — provided it has not
/// overlooked the cloud's PIN (``baseField``) — and not by
/// `changed`: the zone sets that when writing into the mirror, even when a
/// device merely passes on an older state. ``timeField`` is the time at which a person
/// set or removed the PIN.
///
/// **Salt and digest lie in `encryptedValues`** (``isSecret``) — from the first write on,
/// because a field cannot be encrypted afterwards. What the digest protects and
/// what not is stated at ``ProfilePIN``.
///
/// **A new type means a new schema:** before the next TestFlight build, `ProfilePIN` together with
/// its six fields (since the review of the evening of 2026-09-25 including `basis`) must go in the
/// CloudKit console from development to production (AP54).
public enum ProfilePINMapping {

    /// The record type.
    public static let contentType = "Profilpin"

    /// The record name — **fixed**, because a profile has at most one PIN and two devices
    /// would otherwise create two records side by side instead of deciding a conflict.
    public static let name = "pin"

    static let timeField = "zeit"
    static let noneField = "keine"
    static let saltField = "salz"
    static let digestField = "abdruck"
    static let roundsField = "runden"
    static let baseField = "basis"

    /// The encrypted fields.
    public static let isSecret: Set<String> = [saltField, digestField]

    /// How the zone merges two versions: **the own one only if it supersedes the server's**
    /// (``ProfilePIN/ContentEntryRecord/resolves(from:)``) — younger and without having overlooked its PIN.
    ///
    /// **No longer merely the later time** (review 2026-09-25 evening): a device that
    /// set a first PIN without knowing the one already pushed up also won with it in the
    /// conflict at the server. An unreadable record on one side falls back to the old rule
    /// — it is not an entry one could ask.
    public static let rule = MergeRule { own, server in
        guard let mine = entry(from: [own]), let there = entry(from: [server]) else {
            return MergeRule.greaterValue(timeField).merge(own, server)
        }
        return mine.resolves(from: there) ? own : server
    }

    /// The entry as a record.
    public static func message(forItem entry: ProfilePIN.ContentEntryRecord) -> CloudRecord {
        var fields: [String: FieldValue] = [
            timeField: .date(entry.time),
            noneField: .bool(entry.verifier == nil),
        ]
        if let basis = entry.basis { fields[baseField] = .date(basis) }
        if let value = entry.verifier {
            fields[saltField] = .data(value.salt)
            fields[digestField] = .data(value.digest)
            fields[roundsField] = .integer(value.rounds)
        }
        return CloudRecord(
            contentType: contentType, name: name, fields: fields, changed: entry.time, encrypted: isSecret)
    }

    /// The entry from the records of a zone — `nil` if none is there or it is unreadable.
    ///
    /// **Unreadable does not mean "no PIN".** A record without a time or with half a verification value
    /// is skipped; if one read it as a tombstone, a damaged record would open the
    /// profile on every device.
    ///
    /// **Also unreadable is a round count outside ``ProfilePIN/roundsRange``**
    /// (review 2026-09-25 evening): it is computed while typing, and two billion
    /// rounds from a foreign record froze the device. The record is skipped like
    /// any other damaged one, and the last good state stays on the device.
    public static func entry(from wordings: [CloudRecord]) -> ProfilePIN.ContentEntryRecord? {
        guard let message = wordings.first(where: { $0.contentType == contentType && $0.name == name }),
            let time = message[timeField]?.date
        else { return nil }
        let basis = message[baseField]?.date
        if message[noneField]?.bool == true {
            return ProfilePIN.ContentEntryRecord(verifier: nil, time: time, basis: basis)
        }
        guard let salt = message[saltField]?.data, let digest = message[digestField]?.data,
            let rounds = message[roundsField]?.integer, !salt.isEmpty, !digest.isEmpty,
            ProfilePIN.roundsRange.contains(rounds)
        else { return nil }
        return ProfilePIN.ContentEntryRecord(
            verifier: ProfilePIN.Verifier(salt: salt, digest: digest, rounds: rounds),
            time: time, basis: basis)
    }
}
