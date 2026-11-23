/// Where an entry comes from.
///
/// Six areas instead of the two that `Core.Diagnostics` knows (`network` and
/// `playback`). On the TV two were enough, because there were only two things there that could
/// go wrong. On the phone four more come in, and two of them do not exist on the TV
/// at all: a prefetch that loads in the background, and a lock that
/// refuses something.
///
/// The separation is not a sense of order: a playback error is recognizable only by **sequence and
/// intervals** and gets lost among server fetches.
public enum Area: String, CaseIterable, Sendable, Codable {
    case network = "netz"
    case playback = "wiedergabe"
    case downloads = "vorrat"
    case surface = "oberflaeche"
    case login = "anmeldung"
    case parentalControls = "kindersicherung"

    /// The abbreviation in the report line — fixed width, so that the columns line up.
    public var tag: String {
        switch self {
        case .network: "NETZ"
        case .playback: "SPIEL"
        case .downloads: "VORR"
        case .surface: "OBFL"
        case .login: "ANM "
        case .parentalControls: "KIND"
        }
    }
}
