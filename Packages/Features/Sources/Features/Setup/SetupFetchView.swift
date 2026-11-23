import Core
import DesignSystem
import Flows
import ProfileKit
import SwiftUI

/// "Get a profile from the iPhone", **embedded in the setup instead of a screen of its own**
/// (AP88 §1.2, `fetchingFromPhone`) — the same two paths as in "Who is watching?"
/// (``ProfileCreation``): with iCloud the code page of ``CloudSheet``, without it the handoff
/// through the home network (``HandoffReceiveView``) behind the reception door.
///
/// **Neither path names the profile it brought**, so this view reads the book before and after
/// (``Flows/SetupWorld/arrivals(before:in:named:carried:)``): one new profile leads into its A4,
/// several stand in A2 for someone to pick, nothing new means cancelled — back to A2.
struct SetupFetchView: View {

    let mode: SetupPullMode
    let cloud: ProfileCloud?
    let onArrival: (SetupWorld.Arrival) -> Void
    let onCancel: () -> Void

    @State private var before = Self.bookProfiles()

    var body: some View {
        ZStack {
            ColorRole.reason.color.ignoresSafeArea()
            switch (mode, cloud) {
            case (.cloud, let cloud?):
                CloudSheet(profile: nil, cloud: cloud, onClose: finish)
            default:
                ParentalControlsDoor("uebergabeEmpfang") {
                    HandoffReceiveView(cancel: onCancel, done: finish)
                }
            }
        }
    }

    private func finish() {
        let arrival = SetupWorld.arrivals(before: before, in: ProfileBook.read(from: FileStore()))
        guard arrival != .none else {
            onCancel()
            return
        }
        onArrival(arrival)
    }

    private static func bookProfiles() -> Set<Profile.Identifier> {
        Set(ProfileBook.read(from: FileStore()).profile.map(\.identifier))
    }
}
