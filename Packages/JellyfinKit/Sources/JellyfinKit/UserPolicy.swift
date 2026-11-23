import Foundation

/// What the media server says about the signed-in user.
///
/// **Read out and displayed, not trusted.** The server knows its libraries and
/// its approvals and filters more reliably than any app — it does not hand out blocked
/// titles in the first place. In return it knows nothing about Xtream, nothing about the portals and nothing
/// about the device the app is running on. **Two filters that want the same thing are
/// not a bug**; relying on the server alone would leave three of four sources
/// with no limit at all.
///
/// **And it is displayed because it explains.** Whoever is missing titles on the phone that are on the
/// TV otherwise searches in the wrong program: the limit can come from the server.
public struct UserPolicy: Sendable, Equatable {

    /// The highest permitted rating level, as the server counts it.
    ///
    /// **Jellyfin keeps a number here and no text**, and the number is the level from
    /// the server's rating table — for the German entries it is the
    /// minimum age. `nil` means: no limit.
    public let maximumRating: Int?

    /// Whether the server lists the account as disabled.
    public let disabled: Bool

    /// The identifiers of the libraries that are denied to this account.
    public let blockedCatalogs: [String]

    public init(
        maximumRating: Int? = nil, disabled: Bool = false,
        blockedCatalogs: [String] = []
    ) {
        self.maximumRating = maximumRating
        self.disabled = disabled
        self.blockedCatalogs = blockedCatalogs
    }
}

/// How `Users/Me` answers — **only the three fields that are needed.**
///
/// `UserDto` has more than twenty; including them all would mean maintaining, for every Jellyfin
/// version, a decoding that nobody reads.
struct UserResponse: Decodable {

    let policy: Policy?

    struct Policy: Decodable {
        let maxParentalRating: Int?
        /// Since Jellyfin 10.11 the same field is named like this.
        let maxParentalRatingScore: Int?
        let isDisabled: Bool?
        let blockedMediaFolders: [String]?

        enum CodingKeys: String, CodingKey {
            case maxParentalRating = "MaxParentalRating"
            case maxParentalRatingScore = "MaxParentalRatingScore"
            case isDisabled = "IsDisabled"
            case blockedMediaFolders = "BlockedMediaFolders"
        }
    }

    enum CodingKeys: String, CodingKey {
        case policy = "Policy"
    }

    var accessPolicy: UserPolicy {
        UserPolicy(
            // **The new spelling first.** A server that carries both means the
            // new one; an old one carries only the old one, and then the second branch applies.
            maximumRating: policy?.maxParentalRatingScore ?? policy?.maxParentalRating,
            disabled: policy?.isDisabled ?? false,
            blockedCatalogs: policy?.blockedMediaFolders ?? [])
    }
}
