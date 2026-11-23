import Foundation

/// What Jellyfin says about this account — **read and displayed, not trusted.**
///
/// The core sentence from the integration notes is quoted here verbatim, because it justifies the whole file:
/// *The server's user policy is read and displayed, but the app does not
/// rely on it.*
///
/// **Two filters that want the same thing are not a mistake.** The server knows its
/// libraries and its shares; the app knows the device it runs on. Both
/// may block, and what is blocked is what **either one** blocks. Whoever relied on the
/// server alone would have no limit at all for Xtream and the portals — the
/// media server knows nothing about them.
///
/// **And it is displayed because it explains.** A parent who is missing titles on the phone
/// that appear on the TV would otherwise search in the wrong program: The limit can come from the
/// server. If it is shown, the question is answered at a glance.
public struct ServerPolicy: Sendable, Equatable {

    /// The limit that the server keeps for this account — as raw text, like everything else.
    public let maximumRating: String?

    /// Whether the server treats the account as restricted.
    public let isRestricted: Bool

    /// Libraries that the server denies this account.
    public let blockedCatalogs: [String]

    public init(
        maximumRating: String? = nil, isRestricted: Bool = false,
        blockedCatalogs: [String] = []
    ) {
        self.maximumRating = maximumRating
        self.isRestricted = isRestricted
        self.blockedCatalogs = blockedCatalogs
    }

    /// Whether the server has anything to say at all.
    ///
    /// **A server without a policy is the normal case**, and the sheet then says so:
    /// "The server keeps no limit for this account." An empty line would leave open whether
    /// nobody asked.
    public var hasContent: Bool {
        maximumRating != nil || isRestricted || !blockedCatalogs.isEmpty
    }

    /// The server's limit as a number — **as far as it can be interpreted.**
    ///
    /// The same path as for any other raw text: ``ApprovalInterpretation``. What the server
    /// writes is as little standardised as what is in the files.
    public var interpreted: ApprovalInterpretation.Interpretation {
        ApprovalInterpretation.interpret(maximumRating)
    }
}
