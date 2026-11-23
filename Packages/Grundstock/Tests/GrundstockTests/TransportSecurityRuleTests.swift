import Foundation
import Testing

@testable import Grundstock

/// These checks exist because of a specific incident: sign-in with
/// an address like a local home-server hostname failed although server and network were
/// fine. The cause was a combination of two entries in the
/// project configuration that cancel each other out. The error looked like
/// a network problem and cost time accordingly.
///
/// The last test case reads the **real** project file — so that it is noticed
/// immediately if the entries are ever combined unfortunately again.
@Suite("Transport security")
struct TransportSecurityRuleTests {

    @Test("The broad allowance alone permits hostname addresses")
    func arbitraryAlone() {
        let verdict = TransportSecurityRule.evaluate(["NSAllowsArbitraryLoads": true])

        #expect(verdict == .allowsAnyPlainHTTP)
        #expect(verdict.permitsCustomDomainNames)
    }

    @Test("Together with the home-network allowance it has no effect")
    func arbitraryCancelledOut() {
        // This very combination was the error. It looks more generous than
        // the wide permission alone, but is narrower.
        let verdict = TransportSecurityRule.evaluate([
            "NSAllowsArbitraryLoads": true,
            "NSAllowsLocalNetworking": true,
        ])

        #expect(verdict == .allowsLocalOnly(ineffectiveArbitraryLoads: true))
        #expect(
            !verdict.permitsCustomDomainNames,
            "an address like jellyfin.example would be blocked"
        )
    }

    @Test(
        "Each of the finer-grained keys overrides the broad allowance",
        arguments: TransportSecurityRule.overridingKeys
    )
    func anyOverridingKeyCancels(key: String) {
        let verdict = TransportSecurityRule.evaluate([
            "NSAllowsArbitraryLoads": true,
            key: true,
        ])

        #expect(!verdict.permitsCustomDomainNames, "\(key) disables the broad allowance")
    }

    @Test("The home-network allowance alone does not cover hostname addresses either")
    func localOnly() {
        let verdict = TransportSecurityRule.evaluate(["NSAllowsLocalNetworking": true])

        #expect(verdict == .allowsLocalOnly(ineffectiveArbitraryLoads: false))
        #expect(!verdict.permitsCustomDomainNames)
    }

    @Test("Without entries only encrypted connections are allowed")
    func nothingSet() {
        #expect(TransportSecurityRule.evaluate([:]) == .requiresHTTPS)
    }
}
