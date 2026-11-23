import Core
import FeaturesPhone
import Flows
import Foundation
import ProfileKit

/// What **this phone** contributes to the startup of the profiles — the sequence itself has
/// been in the shared ``Flows/ProfileStartup`` since AP58 R2 (finding P5), called via
/// ``FeaturesPhone/SetupState/createProfiles(fallbackName:)``, which knows this phone's
/// stores.
///
/// **What stays here is the language catalog.** The name for a device without a media
/// server user is a key and not text in the model.
extension ProfileStartup {

    @MainActor
    static func fetch(
        state: FeaturesPhone.SetupState = FeaturesPhone.SetupState(),
        store: any KeyValueStore = FileStore()
    ) {
        // **The pointer first** — who is watching is settled before anything reads its state. The
        // sequence sets it once more at the end, because on the very first start the profiles only
        // come into being there.
        pointToActive(in: store)
        state.createProfiles(
            fallbackName: AppLanguageSetting.text("profile.default.name"))
    }
}
