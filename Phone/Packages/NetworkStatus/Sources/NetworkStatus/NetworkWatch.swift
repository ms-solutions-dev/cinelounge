import Foundation
import Network
import Observation

/// The observation of the network path.
///
/// **Today there is not a single line `NWPathMonitor` in the whole project** (LUECKEN
/// no. 10) — the app does not know whether it is on Wi-Fi, and the downloads rule "Wi-Fi
/// only" is thus a declaration of intent. This is the line.
///
/// ``changeCount`` counts every change. The ``BandwidthMemory`` hangs on it: A measured
/// value is valid for **this** path and expires as soon as anything changes — not after a
/// time of day.
@MainActor
@Observable
public final class NetworkWatch {

    public private(set) var route: NetworkPath = .none

    /// How often the path has changed. Starts at 0 and rises.
    public private(set) var changeCount = 0

    /// Whether anyone has reported in at all yet.
    ///
    /// **"Not yet measured" is something different from "no network", and the difference is
    /// visible at startup:** ``route`` starts at `.none`, and `NWPathMonitor` reports a moment
    /// later. Whoever takes the default for an answer takes every start for airplane mode —
    /// the same rule as everywhere here: `nil` means "nobody has asked" and not "zero".
    ///
    /// **Separate from ``changeCount`` and not read from it:** A report that names the same path
    /// again is a report — but it does not count a change, and the ``BandwidthMemory``
    /// hangs on the counter.
    public private(set) var reported = false

    /// The interfaces of the last report, to read up on in the error ledger — `utun3, en0`.
    ///
    /// **Because the translation carries an assumption about the tunnel** (see
    /// ``NetworkPath/init(_:)``), it should be possible to look up on the device what `Network`
    /// really reported when the bar disappears or stands where it should not.
    public private(set) var interfaces: [String] = []

    @ObservationIgnored private var watcher: NWPathMonitor?

    public init() {}

    public func start() {
        guard watcher == nil else { return }
        let watcher = NWPathMonitor()
        self.watcher = watcher
        watcher.pathUpdateHandler = { [weak self] path in
            let fresh = NetworkPath(path)
            let names = path.availableInterfaces.map(\.name)
            Task { @MainActor in self?.adopt(fresh, interfaces: names) }
        }
        watcher.start(queue: DispatchQueue(label: "dev.ms-solutions.cinelounge.networkwatch"))
    }

    public func halt() {
        watcher?.cancel()
        watcher = nil
    }

    /// Looks again — **for the "Try again" button without a network.**
    ///
    /// **The way back comes by itself anyway:** `NWPathMonitor` reports as soon as something
    /// carries again, and the bar is then back without anyone doing anything. The button is
    /// still right — a screen without any button feels like a dead end even if it is not, and
    /// the viewer should be able to do something instead of waiting and hoping.
    ///
    /// **Restarted instead of queried:** `Network` does not hand out a snapshot of the path;
    /// what exists is the report when it starts. So it is cancelled and started again — that
    /// costs nothing and delivers exactly one fresh answer.
    public func lookUp() {
        halt()
        start()
    }

    /// Only for checks and previews.
    ///
    /// **Every change goes into the ``NetworkLog``** (finding 11) — with what the
    /// translation decided about the tunnel. A full tunnel without a carrier is a hint: It
    /// explains why the app shows "no network" although `Network` reports a path.
    public func adopt(_ fresh: NetworkPath, interfaces: [String] = []) {
        reported = true
        self.interfaces = interfaces
        guard fresh != route else { return }
        let old = route
        route = fresh
        changeCount += 1
        NetworkLog.note(
            Self.tier(fresh, interfaces: interfaces),
            Self.logLine(old: old, fresh: fresh, interfaces: interfaces))
    }

    /// Interfaces that are a tunnel — the same prefixes as in
    /// ``LocationDetermination/foreignPorts``, without the direct connections.
    static let tunnelPrefixes = ["utun", "ipsec", "ppp"]

    static func tunnel(in interfaces: [String]) -> [String] {
        interfaces.filter { name in tunnelPrefixes.contains { name.hasPrefix($0) } }
    }

    /// A tunnel is up, but nothing carries underneath — airplane mode with WireGuard.
    static func tier(_ fresh: NetworkPath, interfaces: [String]) -> NetworkLog.Tier {
        fresh.kind == .none && !tunnel(in: interfaces).isEmpty ? .hint : .step
    }

    /// The sentence for a change — **a calculation, so that it can be checked.**
    static func logLine(old: NetworkPath, fresh: NetworkPath, interfaces: [String]) -> String {
        var message = "Network path \(old.label) → \(fresh.label)"
        let tunnel = tunnel(in: interfaces)
        if !tunnel.isEmpty {
            let names = tunnel.joined(separator: ", ")
            message +=
                fresh.kind == .none
                ? " · Full tunnel without carrier (\(names)) — counts as no network"
                : " · Tunnel detected (\(names)) over \(fresh.kind.logName)"
        }
        message += " · Interfaces: " + (interfaces.isEmpty ? "none" : interfaces.joined(separator: ", "))
        return message
    }
}

extension NetworkPath.Kind {
    /// The name in log lines. **Not the raw value** — that one is kept stable on its own
    /// terms, while log text may be reworded freely.
    var logName: String {
        switch self {
        case .wifi: "wifi"
        case .cellular: "cellular"
        case .wired: "wired"
        case .other: "other"
        case .none: "none"
        }
    }
}

extension NetworkPath {
    /// Short for the log — `wifi`, `cellular expensive`, `wifi frugal`.
    var label: String {
        [kind.logName, expensive ? "expensive" : nil, frugal ? "frugal" : nil]
            .compactMap { $0 }.joined(separator: " ")
    }
}

extension NetworkPath {
    /// Translates what `Network` reports.
    ///
    /// **A path without a radio or cable interface does not carry** — and that is the line
    /// that was missing from the finding of 2026-09-09. On the iPhone the offline screen did not
    /// appear in airplane mode, and `NWPathMonitor` seemed to be silent. It was not silent, it
    /// said something wrong: This household runs WireGuard as a full tunnel, and in airplane
    /// mode that leaves its `utun` interface with the default route standing. For `Network`
    /// there is then a path — `satisfied`, interface type `.other` — and the old translation
    /// turned that into `.other`, i.e. "carries". Yet the tunnel leads nowhere as long as
    /// there is no Wi-Fi and no cellular underneath.
    ///
    /// **So what counts now is what lies under the tunnel**, not the tunnel: Wi-Fi,
    /// cellular or cable among the available interfaces — otherwise `.none`. The same view
    /// as ``LocationDetermination/foreignPorts``: `utun` does not describe a network of its
    /// own.
    ///
    /// **What falls away with that is `.other` as a carrying path.** The case stays in the
    /// enum so that checks and previews can pose it; it no longer arises from a report by
    /// `Network`.
    init(_ path: NWPath) {
        self.init(
            status: path.status,
            interfaces: path.availableInterfaces.map(\.type),
            expensive: path.isExpensive, frugal: path.isConstrained)
    }

    /// The translation as a rule — **without `NWPath`, so that it can be checked.** Nobody can
    /// build an `NWPath`; the list of interface types they can.
    init(
        status: NWPath.Status, interfaces: [NWInterface.InterfaceType],
        expensive: Bool = false, frugal: Bool = false
    ) {
        guard status == .satisfied else {
            self.init(kind: .none)
            return
        }
        let kind: Kind =
            if interfaces.contains(.wifi) {
                .wifi
            } else if interfaces.contains(.cellular) {
                .cellular
            } else if interfaces.contains(.wiredEthernet) {
                .wired
            } else {
                .none
            }
        guard kind != .none else {
            self.init(kind: .none)
            return
        }
        self.init(kind: kind, expensive: expensive, frugal: frugal)
    }
}
