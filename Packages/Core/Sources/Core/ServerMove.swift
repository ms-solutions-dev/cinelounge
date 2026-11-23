import Foundation

/// Does a server move — **or is a different one there?**
///
/// **One rule, one text, both apps** (AP41, 2026-09-21). Until here this decision existed twice,
/// and it came out **opposite**:
///
/// * On the TV, "no server feature present" was *"no reason to refuse the move"*: The screen
///   said that it could not be checked and offered "Take over".
/// * On the phone the same case was a **dead end**. The message stood there, and `isAdoptable`
///   stayed `false` — there was no way on, and the reason (*"where there is no identifier, it
///   does not guess"*) described something the TV did not do either: **It does not guess, it
///   asks.**
///
/// **The common rule is the TV's, and it reads: do not guess, ask.** A wrongly guessed move lays
/// two catalogs on top of each other — so the app never decides on its own. But an access
/// without an identifier is no fault of the viewer: ``ServerCredentials/serverID`` is optional
/// because sign-ins from the time before do not carry it. Whoever therefore binds them forever
/// to a dead address punishes them for the age of their setup.
///
/// **What is compared is the identifier and never the name.** "Jellyfin" is the delivery name,
/// and two servers called that are no rarity.
public enum ServerMove {

    /// Who answers at the new address.
    public enum Finding: Sendable, Equatable {
        /// The same server — the case the identifier exists for.
        case sameOne(name: String)
        /// A server answers, but a **different** one.
        ///
        /// No error and no redirect into the sign-in: It may just as well be that a second server
        /// stands there and the address was only mistyped.
        case other(name: String)
        /// The old access carries no identifier — **nothing can be compared here.**
        case withoutIdentifier(name: String)
    }

    /// What the comparison of two identifiers means — **pure logic and without network.**
    ///
    /// As a function of its own, because the decision is made here and not in the fetch: A fetch
    /// brings back information; what it means stands here — and only that way can it be checked
    /// without running a server.
    public static func compare(reported: String, previous: String?, name: String) -> Finding {
        guard let previous else { return .withoutIdentifier(name: name) }
        return reported == previous ? .sameOne(name: name) : .other(name: name)
    }

    /// Whether the move may be carried out.
    ///
    /// - Parameter bestaetigt: Whether the person explicitly agreed **after** being told that it
    ///   could not be checked. A `true` from a view that asked nothing would be exactly the
    ///   guessing this rule prevents.
    public static func mayMove(_ finding: Finding, confirmed: Bool) -> Bool {
        switch finding {
        case .sameOne: true
        case .withoutIdentifier: confirmed
        case .other: false
        }
    }
}
