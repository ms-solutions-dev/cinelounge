import Foundation

/// The rules of transport security, as the system actually
/// evaluates them — as checkable logic instead of knowledge in someone's head.
///
/// Background: On 2026-07-27 exactly this quirk caused hours of searching.
/// `NSAllowsArbitraryLoads` allows unencrypted connections —
/// **but is ignored entirely** as soon as one of the more finely scoped
/// keys stands next to it. The entries cancel each other out, and what remains
/// is the narrow rule, which does not know self-assigned suffixes such as `.home`.
/// The failure appears as `-1022` before a connection is even
/// established — which is easily mistaken for a network problem.
public enum TransportSecurityRule {

    /// The keys whose presence overrides `NSAllowsArbitraryLoads`.
    public static let overridingKeys = [
        "NSAllowsLocalNetworking",
        "NSAllowsArbitraryLoadsInWebContent",
        "NSAllowsArbitraryLoadsForMedia",
    ]

    public enum Verdict: Equatable {
        /// Unencrypted connections to arbitrary addresses are allowed.
        case allowsAnyPlainHTTP
        /// Only to addresses on the home network, without a dot or on `.local`.
        /// Self-assigned suffixes such as `.home` are therefore **not** covered.
        case allowsLocalOnly(ineffectiveArbitraryLoads: Bool)
        /// Exclusively encrypted connections.
        case requiresHTTPS

        /// Whether an address like `jellyfin.example` would be reachable with it.
        public var permitsCustomDomainNames: Bool {
            self == .allowsAnyPlainHTTP
        }
    }

    /// Evaluates a configuration the way the system does.
    public static func evaluate(_ settings: [String: Bool]) -> Verdict {
        let arbitrary = settings["NSAllowsArbitraryLoads"] ?? false
        let overriding = overridingKeys.contains { settings[$0] == true }

        if arbitrary && !overriding {
            return .allowsAnyPlainHTTP
        }
        if settings["NSAllowsLocalNetworking"] == true {
            // The decisive case: the broad permission is present here, but it
            // does not take effect — and that is exactly what is overlooked when reading.
            return .allowsLocalOnly(ineffectiveArbitraryLoads: arbitrary)
        }
        return .requiresHTTPS
    }
}
