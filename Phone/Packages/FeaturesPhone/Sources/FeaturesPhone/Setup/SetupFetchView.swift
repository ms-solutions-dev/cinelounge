import Core
import DesignSystemPhone
import Flows
import ProfileKit
import SwiftUI

/// "Get a profile with a code", **embedded in the setup** — the camera of "Devices & Sharing"
/// (``CloudView``) without the page around it (AP88 §1.2, `fetchingFromPhone`).
///
/// **The phone scans where the TV shows** (``Flows/SetupSteps/FetchFromPhone/scan``): the other
/// device shows its code under "Devices & Sharing" → "Give", this camera reads it, and the
/// profile comes through the household zone (``Flows/SharingFlow/PullMode/camera``).
///
/// **Neither the scan nor the pairing names the profile it brought**, so this view reads the book
/// before and after (``Flows/SetupWorld/arrivals(before:in:named:carried:)``) — the same as the
/// TV's fetching path: one new profile leads into its A4, several stand in A2.
struct SetupFetchView: View {

    let model: SetupModel

    @State private var flow: SharingFlow?
    @State private var before: Set<Profile.Identifier> = []

    var body: some View {
        VStack(alignment: .leading, spacing: MetricsBoard.phone.gutter) {
            Text(app: "setup.welcome.scan")
                .font(TypeLevel.title.font)
                .foregroundStyle(ColorRole.text.color)
            content
        }
        .padding(.horizontal, MetricsBoard.phone.margin)
        .padding(.top, MetricsBoard.phone.gutter)
        .task { open() }
        .onChange(of: flow?.pairing?.state) { _, state in
            if case .arrived(let name, _) = state { arrived(named: name) }
        }
        .onDisappear {
            let running = flow
            Task { await running?.back() }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch flow?.pairing?.state {
        case .expired:
            failed("pairing.expired")
        case .error(let key):
            failed(key)
        case .arrived, .pickedUp:
            LoadingState(message: "pairing.working")
        case .isRunning, .shows, .none:
            if flow?.pairing?.isProcessed == true {
                LoadingState(message: "pairing.working")
            } else {
                Text(app: "pairing.scanText")
                    .font(TypeLevel.footer.font)
                    .foregroundStyle(ColorRole.textMatt.color)
                    .fixedSize(horizontal: false, vertical: true)
                QRScanner(read: scanned)
                    .aspectRatio(1, contentMode: .fit)
                    .frame(maxWidth: .infinity)
            }
        }
    }

    private func failed(_ key: String) -> some View {
        VStack(alignment: .leading, spacing: MetricsBoard.phone.gutter) {
            HintCapsule(message: key)
            Button {
                model.send(.back)
            } label: {
                Text(app: "common.back").frame(maxWidth: .infinity)
            }
            .buttonStyle(.quiet)
        }
    }

    private func open() {
        guard flow == nil else { return }
        guard let cloud = model.stores.cloud() else {
            model.send(.back)
            return
        }
        before = Set(ProfileBook.read(from: model.stores.ledger).profile.map(\.identifier))
        let fresh = SharingFlow(profile: nil, cloud: cloud, pullMode: .camera)
        fresh.start(.isFetching)
        flow = fresh
    }

    private func scanned(_ text: String) {
        guard let flow else { return }
        Task { await flow.scanned(text) }
    }

    private func arrived(named name: String) {
        let arrival = SetupWorld.arrivals(
            before: before, in: ProfileBook.read(from: model.stores.ledger), named: name)
        guard let input = arrival.input(describe: model.describe) else {
            model.send(.back)
            return
        }
        model.send(input)
    }
}
