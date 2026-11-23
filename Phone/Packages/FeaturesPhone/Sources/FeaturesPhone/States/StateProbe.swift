import DesignSystemPhone
import NetworkStatus
import SwiftUI

/// The location rows at home and on the go side by side — for viewing.
///
/// The done condition of AP8 reads: airplane mode makes the app answer **differently per
/// source**. That an information message has no loud button and a job exactly
/// one is true by the type; that the six location rows really become different when toggling
/// is only seen by toggling.
///
/// **The two state blocks used to stand here and are gone.** They showed two of the
/// nineteen states in a place where neither of them ever appears;
/// ``StateShowcase`` has shown all nineteen since AP15 where they belong. What this
/// probe answers is a different question — that is why it stays.
struct StateProbe: View {

    @State private var inFlight = false

    private var location: LocationStatement.Location { inFlight ? .inFlight : .home }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle(isOn: $inFlight) {
                Text(verbatim: inFlight ? "unterwegs" : "daheim")
                    .font(TypeLevel.header.font)
                    .foregroundStyle(ColorRole.text.color)
            }
            .tint(ColorRole.tag.color)
            .padding(.horizontal, MetricsBoard.phone.margin)

            LocationRow(statement: LocationStatement.forItem(.library, location: location, source: .jellyfin))
            LocationRow(statement: LocationStatement.forItem(.library, location: location, source: .xtream))
            LocationRow(statement: LocationStatement.forItem(.live, location: location))
            LocationRow(statement: LocationStatement.forItem(.portals, location: location))
            LocationRow(statement: LocationStatement.forItem(.search, location: location))
            LocationRow(statement: LocationStatement.forItem(.sourceSheet, location: location))
        }
        .padding(.vertical, MetricsBoard.phone.section)
    }
}
