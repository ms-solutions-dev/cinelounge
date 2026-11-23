import Core
import Flows
import Foundation
import PortalKit
import ProfileKit
import Styling
import Testing

@testable import FeaturesPhone

/// **Asking for admission and approving requests — on the phone too** (decision 27, B7).
///
/// The flow itself is shared and tested on the TV through the whole integration
/// (`JoinFlowTests`). What stands here is what the phone makes of it.
@MainActor
struct JoinPhoneTests {

    @Test("The request carries the profile color in the same notation as on the TV")
    func colorWord() {
        #expect(JoinRequester.colorWord(.lilac, colorValue: ProfileBrand.value) == "#9871C4")
    }

    @Test("Without a bridge there is no join and no approval list")
    func withoutBridge() async {
        let model = PortalSettingsModel(
            status: SetupState(store: UserDefaults(suiteName: UUID().uuidString)!),
            store: InMemoryStore())
        await model.loadState()
        #expect(!model.canJoin)
        #expect(model.approval == nil)
        await model.requestAdmission()
        #expect(model.requestState == .none)
    }
}
