import CloudSync
import Foundation

/// The "forgot PIN" way out on the TV — **two ways, both via the Apple account**
/// (AP43).
///
/// **Without a way out, a lock is not a lock but a trap.** On the phone it has long existed
/// (``FeaturesPhone/PinForgottenView``: the account password at the media server is the
/// higher authority). On the TV it did not exist — the PIN lies in the Keychain and comes
/// back from the iCloud backup, even after a reinstall.
///
/// ## Two ways
///
/// 1. **Confirmation on a second device of the same Apple ID.** The TV files a
///    request, the other devices get a silent push, a person confirms there, the lock
///    falls. The fast way.
/// 2. **Reset with a waiting period**, if there is no second device: 24 hours,
///    visible throughout and cancelable from any device. The product decision of
///    2026-09-23 against the dead end.
///
/// ## Why this does not live in the profile zone
///
/// **Since AP44 a profile can belong to a foreign Apple account.** If the request lived in
/// the profile zone, a **participant** could lift the owner's parental controls —
/// they see the zone and may write in it. Whoever brings their profile onto a second
/// household's TV would thereby lift its lock, and nobody would notice: both actions
/// are permitted on their own.
///
/// Hence the zone ``zone`` — private, **never shared**, and it carries only what belongs
/// to the device owner.
///
/// ## Why the deadline does not run on the device's clock
///
/// **The tvOS system clock is in *its* settings and not behind this lock.** Whoever computed
/// the deadline against `Date()` would have one that a child skips in two minutes: set the
/// clock a day ahead, done.
///
/// The deadline is therefore computed against ``CloudSync/CloudRecord/serverTime`` — the stamp
/// that CloudKit sets and that no device can write. The consequence is inconvenient and
/// right: **without a network no deadline expires** (``State/wartetAufServer``). A device
/// without a connection has no credible time anchor, and a deadline that can be accelerated
/// via airplane mode is none.
///
/// For the **display** ("19 hours left") the device time may serve — it is information and
/// not a decision.
public enum PINFallback {

    /// The zone in which the request lies — **not a profile, and therefore without the prefix.**
    ///
    /// ``CloudSync/ZoneID/isProfile`` is thus `false`; the profile sync does not touch it, and
    /// ``CloudSync/CloudHub/split(_:title:)`` is never applied to it.
    public static let zone = ZoneID(name: "haushalt")

    public static let contentType = "Pinruecksetzung"

    /// **What the way out applies to — and there are two different locks** (AP45,
    /// 2026-09-24).
    ///
    /// **The finding that made this type necessary:** the way out was built for the
    /// **parental controls**, and there "one request per household" is **right** — there is
    /// exactly one set of parental controls. AP45 demands a way out for **profile** PINs, and
    /// those exist per person. Handling both under a single name would mean either putting
    /// two household members on one deadline or costing the parental controls their running
    /// request with every change.
    public enum Lock: Equatable, Sendable {
        /// The household's one set of parental controls.
        case parentalControls
        /// A profile's PIN.
        case profile(Profile.Identifier)
    }

    /// The name of the request — **one per lock.**
    ///
    /// **Two simultaneous ones would be two deadlines on the same lock, and the shorter one
    /// would win** — without anyone having seen it. That was the reasoning for the single
    /// name and applies unchanged; it just does **not** forbid two different locks having one
    /// each.
    ///
    /// **The parental controls keep "aktuell"**, and that is not convenience: a running
    /// request lies in the cloud under this name, and renaming it would mean losing a deadline
    /// that someone set hours ago.
    public static func name(forItem lock: Lock) -> String {
        switch lock {
        case .parentalControls: "aktuell"
        case .profile(let identifier): "profil-" + identifier.rawValue
        }
    }

    /// The profile ID from the name of a request — `nil` for the parental controls and for
    /// everything that is not a profile request. The inverse of ``name(forItem:)``.
    public static func profile(fromName name: String) -> Profile.Identifier? {
        let prefix = "profil-"
        guard name.hasPrefix(prefix), name.count > prefix.count else { return nil }
        return Profile.Identifier(rawValue: String(name.dropFirst(prefix.count)))
    }

    /// Twenty-four hours.
    ///
    /// **A child sits out an hour, few get through a day.** And whoever really needs the way
    /// out has it the next evening — that is the price for it not being abused.
    public static let deadline: TimeInterval = 24 * 60 * 60

    static let deadlineField = "frist"
    static let deviceField = "geraet"
    static let confirmedField = "bestaetigt"

    public static func recordName(forItem lock: Lock) -> RecordName {
        RecordName(contentType: contentType, name: name(forItem: lock))
    }

    // MARK: - The state

    /// Where the way out stands — **that is also what appears on the screen.**
    public enum State: Equatable, Sendable {
        /// Niemand hat etwas beantragt.
        case none
        /// Requested, but the server has not stamped it yet — **without its stamp no deadline
        /// runs.**
        case wartetAufServer(device: String)
        /// The deadline runs. `due` is information for the display.
        case isRunning(due: Date, device: String)
        /// The deadline is over — the PIN may fall.
        case due(device: String)
        /// Another device of the same Apple ID has confirmed; the deadline no longer counts.
        case confirmed(device: String)

        /// Whether the lock may fall now.
        public var resolves: Bool {
            switch self {
            case .due, .confirmed: true
            case .none, .wartetAufServer, .isRunning: false
            }
        }

        /// Whether a request is open — for the line on the PIN sheet.
        public var pending: Bool { self != .none }
    }

    // MARK: - Antrag und Auswertung

    /// The record that the locking device deposits.
    ///
    /// - Parameter geraet: **the name of this device, and it is not an extra.** Otherwise the
    ///   iPhone says "A PIN reset was requested", and nobody knows whether that was their own
    ///   TV or the one in another room.
    public static func request(
        forItem lock: Lock, device: String, now: Date = Date()
    ) -> CloudRecord {
        CloudRecord(
            contentType: contentType, name: name(forItem: lock),
            fields: [
                // **The deadline is in the record**, so that the checker sees it and
                // not only the one who set it — the same rule as with
                // ``Pairing/deadline``.
                deadlineField: .double(deadline),
                deviceField: .text(device),
            ],
            changed: now)
    }

    /// How to read the request.
    ///
    /// - Parameter jetzt: **only for the comparison with the server time.** A device clock set
    ///   ahead does not make the deadline shorter, only the display wrong —
    ///   and one set back does not make it longer than the server sees it.
    public static func state(from message: CloudRecord?, now: Date = Date()) -> State {
        guard let message else { return .none }
        let device = message[deviceField]?.text ?? ""

        if message[confirmedField]?.text?.isEmpty == false { return .confirmed(device: device) }

        // **Without the server's stamp no deadline.** The request then lies only in the mirror;
        // it goes up as soon as there is a network again, and only then does the clock start.
        guard let stamped = message.serverTime else { return .wartetAufServer(device: device) }

        let duration = message[deadlineField]?.double ?? deadline
        let due = stamped.addingTimeInterval(duration)
        return now >= due ? .due(device: device) : .isRunning(due: due, device: device)
    }

    /// The record with which a second device confirms.
    ///
    /// **The existing request is supplemented and not replaced** — `device` stays,
    /// so that the right name keeps appearing on the TV, and `serverTime` comes fresh on the
    /// next read anyway.
    public static func confirmation(zu message: CloudRecord, finished device: String) -> CloudRecord {
        var fresh = message
        fresh.fields[confirmedField] = .text(device)
        return fresh
    }

    /// Who confirmed — `nil` as long as nobody has.
    public static func confirmedBy(_ message: CloudRecord?) -> String? {
        guard let text = message?[confirmedField]?.text, !text.isEmpty else { return nil }
        return text
    }
}
