import Foundation

/// A profile to take along as **a link in the QR code** — the same way as "Add device"
/// in StoryShelf (E52), which has proven itself there.
///
/// `cinelounge-profile://setUp?approval=<iCloud-AccessGrant-Link>&person=<Name>`
///
/// **The finding (on-device test 2026-09-28):** bringing profiles from the TV to the phone
/// worked neither with the reader in the app nor with the system camera. The TV put the
/// share link under a code into a **public mailbox** in iCloud, and
/// the phone was supposed to pick it up there — three steps, a public database whose
/// schema has to be in the production environment, and a code scheme that was deliberately
/// registered nowhere. StoryShelf carries the link **in the code itself**: no
/// mailbox, no pickup, and the system camera offers "Open in …".
///
/// **Our own link is the carrier, not the iCloud link** — the same rationale as
/// with StoryShelf's `Einrichtungscode`: if you append something to the iCloud link, it is
/// no longer the one CloudKit issued. The other way round it is safe.
///
/// **Only iCloud shares are accepted.** Whoever calls the scheme determines the
/// link; the app must not pass an arbitrary address in it on to CloudKit.
public struct ProfileLink: Sendable, Equatable {

    public static let schema = "cinelounge-profil"
    static let path = "einrichten"
    static let shareKey = "freigabe"
    static let personKey = "person"
    static let deviceKey = "geraet"

    /// The iCloud share link of the profile zone.
    public let approval: URL
    /// What the profile is called over there — only for the feedback; the name itself comes from the
    /// zone (``ProfileCloud/accept(_:)``).
    public let person: String?
    /// Which device hands it over — for "arrived from …" on the phone.
    public let device: String?

    public init(approval: URL, person: String?, device: String? = nil) {
        self.approval = approval
        self.person = person
        self.device = device
    }

    /// The link for the QR code.
    public var url: URL {
        var split = URLComponents()
        split.scheme = Self.schema
        split.host = Self.path
        var fields = [URLQueryItem(name: Self.shareKey, value: approval.absoluteString)]
        if let person, !person.isEmpty {
            fields.append(URLQueryItem(name: Self.personKey, value: person))
        }
        if let device, !device.isEmpty {
            fields.append(URLQueryItem(name: Self.deviceKey, value: device))
        }
        split.queryItems = fields
        return split.url ?? approval
    }

    /// Reads what camera or system hand in — `nil` for everything else.
    public init?(_ text: String) {
        guard
            let split = URLComponents(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
            split.scheme?.lowercased() == Self.schema,
            split.host?.lowercased() == Self.path,
            let raw = split.queryItems?.first(where: { $0.name == Self.shareKey })?.value,
            let approval = URL(string: raw), Self.isICloudShare(approval)
        else { return nil }
        func field(_ name: String) -> String? {
            split.queryItems?.first(where: { $0.name == name })?.value.flatMap { $0.isEmpty ? nil : $0 }
        }
        self.init(
            approval: approval, person: field(Self.personKey), device: field(Self.deviceKey))
    }

    /// `https://www.icloud.com/share/…` — the form in which CloudKit issues shares.
    static func isICloudShare(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https", let host = url.host()?.lowercased() else {
            return false
        }
        return host == "icloud.com" || host.hasSuffix(".icloud.com")
    }
}
