import DesignSystemPhone
import SwiftUI

/// The explanation **before** the system prompt.
///
/// **This screen does not exist on the TV.** tvOS has no prompt for the
/// local network; iOS raises it at the moment the first UDP broadcast goes out on port
/// 7359. If it arrives without warning, it is tapped away — and afterwards the
/// search finds nothing, and **nobody knows why**, because iOS does not report the refusal.
///
/// This screen does two things: it announces the wording of the prompt, and it
/// offers the path that does not trigger it in the first place.
///
/// **Since AP88 wave 6 it is also the notice of the first setup** — at the same place as the TV's
/// `NetworkNoticeView`, before the first search (``Flows/SetupState/networkNotice(then:open:)``).
/// There it has one answer: the machine searches after it, and whoever does not want that
/// types the address in A5. The form from the settings keeps both answers.
struct NetworkLawView: View {

    /// "Search the home network".
    let search: () -> Void
    /// "Type the address myself" — `nil` where the search follows anyway.
    var byHand: (() -> Void)?

    var body: some View {
        SetupSheet(
            title: "setup.network.title", explanation: "setup.network.text"
        ) {
            VStack(alignment: .leading, spacing: MetricsBoard.phone.gutter) {
                HintCapsule(message: "setup.network.systemPrompt")

                Button(action: search) {
                    Text(appKey: "setup.network.allow").frame(maxWidth: .infinity)
                }
                .buttonStyle(.loud)

                // **Both answers lead on.** Whoever does not want the search types
                // the address — on the phone the cheapest operation there is.
                if let byHand {
                    Button(action: byHand) {
                        Text(appKey: "setup.network.byHand").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.quiet)

                    Footnote(message: "setup.network.footnote")
                }
            }
            .padding(.top, 4)
        }
    }
}
