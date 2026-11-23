import CloudSync
import Core
import Foundation

/// Bringing a profile to a foreign device — **the direction the TV needs** (AP44,
/// direction 2).
///
/// **Why there are two directions: the TV has no camera.**
///
/// *Direction 1* is the simple one: the device that has the profile shows the sharing link
/// as a QR code, the other scans it and accepts. That does not need this type — it is enough to
/// use ``CloudSync/CloudHub/split(_:title:)`` and ``CloudSync/CloudHub/accept(url:)``.
///
/// *Direction 2* is the one here: the **TV** wants a profile from the phone. It cannot
/// scan anything, so the path turns around — it shows a one-time code, the phone scans it,
/// puts the sharing link under this code into the **public** CloudKit database, and the
/// TV picks it up there. No server of our own, and it also works away from home.
///
/// ## What is dangerous about the public database
///
/// It is public. Whoever knows the record name reads the content — without sign-in,
/// without throttle. And the content is the **sharing link**: whoever has it gets into the
/// zone. The code is therefore not a hint about the key, it **is** the key.
///
/// Three rules follow, and all three are checked:
///
/// 1. **Long.** Sixteen characters from an unambiguous alphabet are about
///    10²⁴ possibilities. Six would be a billion — for a mailbox that can be queried
///    without a throttle, that is too few. **Length costs nothing here**, because
///    nobody types the code: the TV shows it as a QR code, the phone scans it.
/// 2. **Short-lived.** Five minutes. The deadline is **in the record**, so that the
///    collector checks it too and not only the one who set it.
/// 3. **Single use.** After pickup the entry is deleted — by the collector, because only
///    it knows that the entry arrived.
public enum Pairing {

    public static let contentType = "Kopplung"

    static let linkField = "link"
    static let untilField = "bis"
    static let deviceField = "geraet"

    /// How long a deposited link is valid.
    public static let deadline: TimeInterval = 300

    /// The characters a code consists of.
    ///
    /// **Without `0`, `O`, `1`, `I` and `l`.** The camera reads the code, but it also appears
    /// as text under the QR code — for the case that a camera does not cooperate, and for
    /// troubleshooting. An alphabet in which one can mistype turns a way out into a second
    /// dead end.
    static let alphabet = Array("ABCDEFGHJKMNPQRSTUVWXYZ23456789")

    /// The length of a code — see the reasoning above.
    static let length = 16

    /// A fresh code.
    public static func code() -> String {
        String((0..<length).map { _ in alphabet.randomElement() ?? "A" })
    }

    public static func name(forItem code: String) -> RecordName {
        RecordName(contentType: contentType, name: code.uppercased())
    }

    // MARK: - What the QR carries

    /// Who shows the code — **and with it what the scanner has to do.**
    ///
    /// **Without this information a device deposits where it should fetch.** Both directions
    /// use the same mailbox and the same code; only the role says who puts in and who takes
    /// out. Writing it into the QR code is cheaper than two code formats — and more reliable
    /// than a screen that remembers why it is currently open.
    public enum Role: String, Sendable, CaseIterable {
        /// "I have the profile." The displaying device has already deposited; the scanner **fetches**.
        case give = "gebe"
        /// "I would like a profile." The displaying device waits; the scanner **deposits**.
        case search = "suche"

        /// What the scanner does when it sees this code.
        public var scannerFetches: Bool { self == .give }
    }

    /// The scheme that older codes carried — **it is still read**, so that a TV with the old
    /// build and a phone with the new one can still find each other.
    public static let schema = "cinelounge"

    /// The scheme that codes carry today — **registered on the phone** (on-device finding 2026-09-30).
    ///
    /// Until then this said "not registered in any Info file, and that is intentional: the text is
    /// scanned and not opened". That was exactly the complaint: the iPhone camera did not open
    /// it, and one had to scan a second time in the app — in StoryShelf the system camera is
    /// enough. The objection to an open entrance remains correct and is now answered at the
    /// place where it counts: before the phone **hands over** a profile on an opened code, it
    /// asks (``Role/search``), and it deposits only for this one code with its deadline.
    public static let cameraScheme = "cinelounge-koppeln"

    public static func link(code: String, role: Role) -> URL {
        var split = URLComponents()
        split.scheme = cameraScheme
        split.host = "koppeln"
        split.queryItems = [
            URLQueryItem(name: "code", value: code.uppercased()),
            URLQueryItem(name: "rolle", value: role.rawValue),
        ]
        return split.url ?? URL(string: "\(cameraScheme)://koppeln")!
    }

    /// Reads what the camera has seen.
    ///
    /// **A camera sees packaging and Wi-Fi codes.** What does not fit here is not an error but
    /// simply nothing for us — hence `nil` and no message.
    public static func read(_ text: String) -> (code: String, role: Role)? {
        guard let split = URLComponents(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
            let kind = split.scheme?.lowercased(), kind == schema || kind == cameraScheme,
            split.host?.lowercased() == "koppeln",
            let code = split.queryItems?.first(where: { $0.name == "code" })?.value,
            let raw = split.queryItems?.first(where: { $0.name == "rolle" })?.value,
            let role = Role(rawValue: raw.lowercased())
        else { return nil }
        // **Length checked, not only presence.** A truncated code from a half-captured QR would
        // yield a mailbox that never answers — and would look to the viewer like "the other
        // device is too slow".
        let clean = code.uppercased()
        guard clean.count == length, clean.allSatisfy(alphabet.contains) else { return nil }
        return (clean, role)
    }

    // MARK: - The phone drops off

    /// The record that the **giving** device puts into the mailbox.
    ///
    /// - Parameter geraet: the name of the giving device — **for the feedback on both
    ///   sides.** Without it the TV would say "a profile has arrived", and nobody would know
    ///   whether it was the expected one.
    public static func store(
        code: String, link: URL, device: String, now: Date = Date()
    ) -> CloudRecord {
        CloudRecord(
            contentType: contentType, name: code.uppercased(),
            fields: [
                linkField: .text(link.absoluteString),
                untilField: .date(now.addingTimeInterval(deadline)),
                deviceField: .text(device),
            ],
            changed: now)
    }

    // MARK: - The TV picks up

    /// What was picked up.
    public struct Transmission: Sendable, Equatable {
        public let link: URL
        public let device: String
        public let until: Date
    }

    /// Reads the record — **and discards it if the deadline has passed.**
    ///
    /// **The collector checks the deadline itself.** CloudKit does not clean anything up by
    /// itself; an entry that nobody picked up stays there. Whoever relied on depositing
    /// already cleaning up would accept a link that has been lying in the mailbox for hours.
    public static func broadcast(from message: CloudRecord, now: Date = Date()) -> Transmission? {
        guard let address = message[linkField]?.text, let link = URL(string: address),
            let until = message[untilField]?.date
        else { return nil }
        guard until > now else { return nil }
        return Transmission(link: link, device: message[deviceField]?.text ?? "", until: until)
    }
}
