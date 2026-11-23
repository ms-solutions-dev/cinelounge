import Core
import Flows
import Foundation
import NetworkStatus

/// Input, groups, hits — **since AP58 R6 the shared flow** ``Flows/Search``.
///
/// What stays here is what only the phone has: the sources as ``SearchSource`` (with the
/// channel search as the fourth), the network guard for airplane mode and the total number of hits.
public typealias SearchViewModel = Search<ResultBundle>

extension ResultBundle: SearchGroup {
    public var hasMatches: Bool { !match.isEmpty }
    public var source: Core.Origin { origin.source }
    public var logLine: String { "\(origin.rawValue) \(match.count)" }
}

extension Search where Group == ResultBundle {

    /// - Parameter entprellung: **injectable from outside for the checks**; in the program
    ///   ``Flows/Search/waitTime``.
    public convenience init(
        debounce: Duration = Search.waitTime, sources: [any SearchSource] = [],
        networkMonitor: NetworkStatus.NetworkWatch? = nil
    ) {
        self.init(
            sources: sources.map { source in
                { word, atMost in await source.match(zu: word, atMost: atMost) }
            },
            debounce: debounce,
            offline: { networkMonitor?.route.carries == false ? .networkAirplaneMode : nil })
    }

    /// How many hits in total.
    public var total: Int { groups.reduce(0) { $0 + $1.match.count } }
}
