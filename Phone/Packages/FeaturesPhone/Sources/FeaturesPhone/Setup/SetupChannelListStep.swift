import Core
import DesignSystemPhone
import Flows
import SwiftUI

/// The IPTV sheet of A4 — **the settings' form, inside the setup** (AP88 §3).
///
/// The fields are ``SetUpChannelListView``'s and the list lands through
/// ``SetupState/create(channelList:password:)`` in the active profile — the setup's profile, which
/// the machine activated before this sheet (§1.4 point 1). This view adds the head and the way
/// back into the journey: a stored list is ``Flows/SetupInput/sourceFinished(_:_:)`` with the
/// provider's host, as the TV's row says it.
struct SetupChannelListStep: View {

    let model: SetupModel
    let profile: SetupProfile?

    @State private var form: SourceFormModel

    init(model: SetupModel, profile: SetupProfile?) {
        self.model = model
        self.profile = profile
        _form = State(initialValue: model.channelListForm())
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SetupStepHead(profile: profile, source: "IPTV")
                .padding(.horizontal, MetricsBoard.phone.margin)
            if !model.journey.machine.isOnline {
                Footnote(message: "setup.channelList.offline")
                    .padding(.horizontal, MetricsBoard.phone.margin)
                    .padding(.top, MetricsBoard.phone.gutter)
            }
            SetUpChannelListView(model: form)
        }
        .onChange(of: form.step) { _, step in
            guard step == .done else { return }
            model.send(.sourceFinished(.channelList, .done(detail: Self.detail(form.storedAddress))))
        }
    }

    /// What the row says after ✓ — **the provider's host**, as the TV's `ChannelListSheet.detail`.
    nonisolated static func detail(_ address: URL?) -> String {
        address?.host() ?? ""
    }
}
