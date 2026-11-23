import NetworkStatus
import Testing

@testable import Downloads

/// Wi-Fi, cellular, hotspot, tunnel.
///
/// **The expensive mix-up is the hotspot.** It is Wi-Fi and still expensive; whoever only asks about
/// the type downloads fourteen gigabytes over a colleague's phone. These checks
/// mainly pin down this one case.
@Suite("Network rule")
struct NetworkRuleTests {

    private static let wifi = NetworkPath(kind: .wifi)
    private static let hotspot = NetworkPath(kind: .wifi, expensive: true)
    private static let cellular = NetworkPath(kind: .cellular, expensive: true)
    private static let savingWiFi = NetworkPath(kind: .wifi, frugal: true)

    @Test("On Wi-Fi it runs")
    func onWiFi() {
        #expect(NetworkRule().verdict(forItem: Self.wifi) == .isRunning)
    }

    @Test("Without a network it pauses, with a reason")
    func offline() {
        #expect(NetworkRule().verdict(forItem: .none) == .halted(.noNetwork))
    }

    @Test("On cellular it pauses")
    func onCellular() {
        #expect(NetworkRule().verdict(forItem: Self.cellular) == .halted(.expensive))
    }

    /// **The case this rule exists for.** A hotspot reports itself as Wi-Fi; whoever only reads
    /// `kind` takes it for a home network.
    @Test("A hotspot is Wi-Fi and is paused anyway")
    func hotspot() {
        #expect(NetworkRule().verdict(forItem: Self.hotspot) == .halted(.expensive))
    }

    /// **Also with the rule relaxed.** Whoever switches off "Wi-Fi only" is saying something about their
    /// Wi-Fi — not that they would not care about the hotspot's bill.
    @Test("The hotspot stays expensive, even when the rule is relaxed")
    func hotspotDespiteRelaxing() {
        #expect(NetworkRule(wifiOnly: false).verdict(forItem: Self.hotspot) == .halted(.expensive))
    }

    /// **Low data mode is a request and not an assumption.** It therefore outweighs
    /// every rule and every measurement of our own.
    @Test("Data Saver pauses even on cheap Wi-Fi")
    func frugal() {
        #expect(NetworkRule(wifiOnly: false).verdict(forItem: Self.savingWiFi) == .halted(.frugal))
    }

    /// **The order of the questions is the statement.** Whoever asked about the rule first
    /// would get a "runs" without a connection when "Wi-Fi only" is switched off.
    @Test("Without a network the missing route beats every relaxation")
    func noNetworkWins() {
        #expect(NetworkRule(wifiOnly: false).verdict(forItem: .none) == .halted(.noNetwork))
    }

    @Test("Relaxed, it runs on cellular")
    func relaxed() {
        #expect(NetworkRule(wifiOnly: false).verdict(forItem: NetworkPath(kind: .cellular)) == .isRunning)
    }

    /// **So that the one way next to it is the right one.** "Download anyway" may only
    /// appear where relaxing really helps.
    @Test("Only the cellular reason can be solved by relaxing")
    func relaxableCase() {
        #expect(NetworkRule.relaxable(.cellular))
        #expect(!NetworkRule.relaxable(.noNetwork))
        #expect(!NetworkRule.relaxable(.expensive))
        #expect(!NetworkRule.relaxable(.frugal))
    }
}
