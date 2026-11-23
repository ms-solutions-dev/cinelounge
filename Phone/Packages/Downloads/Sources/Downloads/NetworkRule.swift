import NetworkStatus

/// When downloading is allowed — **"Wi-Fi only", and that is more than a question about Wi-Fi.**
///
/// **Expensive is its own attribute.** A hotspot is Wi-Fi and still expensive; a
/// corporate Wi-Fi with a data cap likewise. `NetworkPath` states both separately, and
/// whoever lumps them together downloads fourteen gigabytes over a colleague's phone.
///
/// **Paused is not an error.** The draft says "Paused — you are on cellular" and puts
/// exactly one way next to it to change the rule. That is why ``Verdict`` carries a
/// **reason** and not an error message: a reason can be answered, a message can only
/// be dismissed. Plex's cellular limit exists and has no effect — that is worse than
/// having none.
public struct NetworkRule: Sendable, Hashable, Codable {
    /// Stored keys keep their original (German) names — renaming them would
    /// make data written by earlier versions unreadable (AP85 B4).
    private enum CodingKeys: String, CodingKey {
        case wifiOnly = "nurImWLAN"
    }

    /// On by default. **When in doubt, not downloading means a postponed film; when in doubt,
    /// downloading means a bill.**
    public var wifiOnly: Bool

    public init(wifiOnly: Bool = true) {
        self.wifiOnly = wifiOnly
    }

    public enum Reason: String, Sendable, Hashable, Codable {
        /// No connection at all.
        case noNetwork = "keinNetz"
        /// Cellular, and the rule is set to "Wi-Fi only".
        case cellular = "mobilfunk"
        /// Wi-Fi, but the system considers it expensive — the hotspot case.
        case expensive = "teuer"
        /// The viewer has switched on Low Data Mode.
        ///
        /// **Outweighs any measurement of our own**, because it is an explicit request and not
        /// a guess about the line. That is why it pauses even when "Wi-Fi only" is switched
        /// off: whoever relaxes the rule says something about their Wi-Fi — not about Low Data
        /// Mode.
        case frugal = "sparsam"
    }

    public enum Verdict: Sendable, Hashable {
        case isRunning
        case halted(Reason)
    }

    /// **The order of the questions is the statement.** Without a network Low Data Mode is
    /// irrelevant, and an expensive Wi-Fi stays expensive even when the rule is relaxed.
    /// Whoever asked about the rule first would get a "running" without a connection when
    /// "Wi-Fi only" is switched off.
    public func verdict(forItem route: NetworkPath) -> Verdict {
        guard route.carries else { return .halted(.noNetwork) }
        if route.frugal { return .halted(.frugal) }
        if route.expensive { return .halted(.expensive) }
        guard wifiOnly else { return .isRunning }
        return route.kind == .cellular ? .halted(.cellular) : .isRunning
    }

    /// Whether relaxing the rule would make this reason go away.
    ///
    /// **So that the one way next to it is the right one.** "Paused — you are on
    /// cellular" may offer "Download anyway"; "Paused — no network" may not,
    /// because there the switch changes nothing and would be an invitation into the void.
    public static func relaxable(_ reason: Reason) -> Bool {
        reason == .cellular
    }
}
