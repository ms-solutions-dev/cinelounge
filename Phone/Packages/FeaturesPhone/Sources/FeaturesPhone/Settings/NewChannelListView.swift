import DesignSystemPhone
import SwiftUI

/// Area 1, third level: **create a list — with the setup form.**
///
/// **It is not rebuilt but used.** ``SetUpChannelListView`` has existed since AP4 and
/// asks the same questions: Xtream or M3U, name, address, access. Building it a second time
/// here would be a second place where the same errors look different — and one of them would
/// be forgotten at the next finding. The roadmap says so literally.
///
/// **What was missing was the way there without the route selection.** Setup is a flow with a
/// beginning; from Settings one arrives in the middle and wants to go back afterwards, rather
/// than land on "Done". That is exactly what this wrapper does: it puts the flow on the step
/// that matters and intercepts its end.
///
/// **A ``SourceFormModel`` of its own and not the one from setup.** The state of this form
/// belongs to this screen; a shared model would mean that a half-filled list shows up in
/// setup when someone sets the app up again.
struct NewChannelListView: View {

    @State private var model: SourceFormModel
    private let done: () -> Void

    init(deviceID: String, done: @escaping () -> Void = {}) {
        let built = SourceFormModel(entry: .channelList, deviceID: deviceID)
        _model = State(initialValue: built)
        self.done = done
    }

    var body: some View {
        ZStack {
            ColorRole.reason.color.ignoresSafeArea()
            SetUpChannelListView(model: model)
        }
        // **The end of the flow is a way back here.** `addChannelList` switches to `.done`,
        // because that is the next screen in setup; here there is none — the list is stored, and the
        // viewer wants to see it in the list.
        .onChange(of: model.step) { _, fresh in
            if fresh == .done { done() }
        }
    }
}
