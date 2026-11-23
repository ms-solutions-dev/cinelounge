import DesignSystemPhone
import Downloads
import NetworkStatus
import SwiftUI

/// Sheet: **network and usage.**
///
/// **It first shows what the phone is currently attached to, and only then the rule.** The
/// order is the statement: "Wi-Fi only" without the information that you are on an
/// **expensive** Wi-Fi is no answer to the question why nothing downloads. Plex's limit
/// exists and has no effect — that is worse than none, and the difference is exactly
/// this row.
struct NetworkSheet: View {

    let route: NetworkPath
    @Binding var rule: NetworkRule
    /// What was last measured — `nil` as long as nothing has been measured on this path.
    var mbit: Double?

    var body: some View {
        ScrollSurface {
            VStack(alignment: .leading, spacing: 0) {
                SectionHeader(title: "network.current")
                HintRow(
                    icon: icon, color: color, title: routeName, message: routeText)

                // **Without a measurement it says "not yet measured" and shows no number.** An invented
                // rate would be worse than none — it looks like a measurement, and the
                // finish times next to it inherited the error.
                HintRow(
                    icon: Glyph.check.name, title: "network.measured",
                    wording: mbit.map { String(format: "%.1f Mbit/s", $0) })

                SectionHeader(title: "stock.rules")
                SwitchRow(
                    title: "stock.wifiOnly", message: "stock.wifiOnlyBody",
                    on: Binding(get: { rule.wifiOnly }, set: { rule.wifiOnly = $0 }))

                verdict
            }
        }
    }

    /// **What the rule currently does is shown as a sentence** — and not as a switch position
    /// from which you would have to derive it. Whoever switches "Wi-Fi only" off and still gets
    /// nothing downloaded otherwise faces a switch that seems to work.
    @ViewBuilder
    private var verdict: some View {
        switch rule.verdict(forItem: route) {
        case .isRunning:
            HintRow(
                icon: Glyph.done.pair.outlined, color: ColorRole.success.color,
                title: "network.willLoad")
        case .halted(let reason):
            HintRow(
                icon: Glyph.warning.name, color: ColorRole.progress.color,
                title: TransferText.reasonText(reason).raw,
                // **The one way beside it is only there where it helps.** "Download anyway" with
                // no network would be an invitation into the void — see
                // ``NetworkRule/relaxable(_:)``.
                message: NetworkRule.relaxable(reason) ? "network.unlockHint" : nil)
        }
    }

    private var routeName: String {
        switch route.kind {
        case .wifi: route.expensive ? "network.wifiMetered" : "network.wifi"
        case .cellular: "network.cellular"
        case .wired: "network.wired"
        case .other: "network.other"
        case .none: "network.none"
        }
    }

    /// **The sentence names the case that you do not otherwise see.** A hotspot reports itself as
    /// Wi-Fi; without this row everyone would take it for their home network.
    private var routeText: String? {
        if route.frugal { return "network.lowDataOn" }
        if route.expensive && route.kind == .wifi { return "network.hotspotHint" }
        return nil
    }

    private var icon: String {
        route.carries ? Glyph.done.pair.outlined : Glyph.airplaneMode.name
    }

    private var color: Color {
        if !route.carries { return ColorRole.textQuiet.color }
        return route.largeVolumesAcceptable ? ColorRole.success.color : ColorRole.progress.color
    }
}
