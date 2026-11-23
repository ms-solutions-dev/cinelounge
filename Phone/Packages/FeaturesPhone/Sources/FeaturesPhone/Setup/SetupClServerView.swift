import Core
import DesignSystemPhone
import Flows
import SwiftUI

/// A6 — **access to the household's CL-Server: a request, or for a child the pairing code**
/// (AP88 §1.2, the TV's `ClServerJoinView`).
///
/// The same pages from the same machine step (``Flows/ClServerStep``): searching, not found, the
/// request with the profile's name and color, waiting without having to wait ("Continue" leads
/// back to A4 with the row on "waiting"), approved, declined or expired. **A child never asks**
/// (§1.4 point 4): its device is paired with a code.
struct SetupClServerView: View {

    /// What the screen shows — **one page per answer**, the TV's pages.
    enum Page: Equatable {
        case searching
        case notFound
        case ask
        case waiting(RequestState)
        case approved(name: String, withTag: Bool)
        /// Declined, expired, or the request did not go out — asking again is possible.
        case ended(RequestState)
        case childPairing
    }

    nonisolated static func page(_ step: ClServerStep) -> Page {
        switch step {
        case .searching: .searching
        case .notFound: .notFound
        case .childPairing: .childPairing
        case .request(let request):
            switch request {
            case .none: .ask
            case .waiting, .throttled: .waiting(request)
            case .approved(let name, let withTag): .approved(name: name, withTag: withTag)
            case .rejected, .expired, .failed: .ended(request)
            case .notForChildren: .childPairing
            }
        }
    }

    /// **A second tap within a few seconds is discarded** — the server throttles at three
    /// requests per hour, and the answer of the first is still on its way.
    static let requestPause: TimeInterval = 5

    let model: SetupModel

    @State private var code = ""
    @State private var refusal: String?
    @State private var isWorking = false
    @State private var lastRequest: Date?

    private var step: (profile: SetupProfile?, page: Page)? {
        guard case .clServer(let identifier, let step) = model.state else { return nil }
        return (model.profile(identifier), Self.page(step))
    }

    private var request: RequestState? {
        guard case .clServer(_, .request(let request)) = model.state else { return nil }
        return request
    }

    private var address: URL? { model.journey.machine.clServerAddress }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: MetricsBoard.phone.gutter) {
                SetupStepHead(profile: step?.profile, source: "CL-Server")
                if let step { content(step.page, profile: step.profile) }
            }
            .padding(.horizontal, MetricsBoard.phone.margin)
            .padding(.bottom, MetricsBoard.phone.section)
        }
        .scrollBounceBehavior(.basedOnSize)
        .task(id: request?.waiting ?? false) { await follow() }
    }

    @ViewBuilder
    private func content(_ page: Page, profile: SetupProfile?) -> some View {
        switch page {
        case .searching:
            LoadingState(message: "setup.clServer.searching")
        case .notFound:
            heading("setup.clServer.notFoundTitle")
            Footnote(message: "setup.clServer.notFound")
            button("common.back") { model.send(.back) }
        case .ask:
            heading("setup.clServer.askTitle")
            Footnote(
                wording: AppLanguageSetting.text("settings.portals.joinHint \(profile?.profile.name ?? "")"))
            Footnote(message: "setup.clServer.noWait")
            button("settings.portals.joinRequest", loud: true, action: sendRequest)
        case .waiting(let request):
            heading("setup.clServer.sent")
            Footnote(
                wording: AppLanguageSetting.text("setup.clServer.sentHint \(profile?.profile.name ?? "")"))
            waitingLine(request)
            button("setup.clServer.continue", loud: true) {
                model.send(.sourceFinished(.portals, .waiting))
            }
            button("settings.portals.joinCancel") {
                model.clServerCalls.withdraw(at: address)
                model.send(.requestState(.none))
            }
        case .approved(let name, let withTag):
            heading("setup.clServer.approvedTitle")
            Footnote(
                wording: AppLanguageSetting.text(
                    withTag
                        ? "settings.portals.joinApproved \(name)"
                        : "settings.portals.joinApprovedNoMark \(name)"))
            button("setup.clServer.continue", loud: true) {
                model.send(.sourceFinished(.portals, .done(detail: name)))
            }
        case .ended(let request):
            heading("setup.clServer.askTitle")
            ended(request)
            button("setup.clServer.askAgain", loud: true, action: sendRequest)
        case .childPairing:
            heading("setup.clServer.childTitle")
            Footnote(message: "settings.portals.inviteHint")
            InputField(text: $code, placeholder: "settings.portals.invitePrompt", kind: .address)
            if let refusal { HintCapsule(wording: refusal) }
            if isWorking {
                LoadingState(message: "pairing.working")
            } else {
                button("settings.portals.redeem", loud: true) { Task { await redeem() } }
                    .disabled(code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }

    @ViewBuilder
    private func ended(_ request: RequestState) -> some View {
        switch request {
        case .rejected: HintCapsule(message: "settings.portals.joinDeclined")
        case .expired: HintCapsule(message: "settings.portals.joinExpired")
        case .failed(let sentence): HintCapsule(wording: sentence)
        default: EmptyView()
        }
    }

    @ViewBuilder
    private func waitingLine(_ request: RequestState) -> some View {
        switch request {
        case .throttled(let seconds?):
            Footnote(
                wording: AppLanguageSetting.text("settings.portals.joinThrottled \((seconds + 59) / 60)"))
        case .throttled(nil):
            Footnote(message: "settings.portals.joinThrottledSoon")
        default:
            Label {
                Text(app: "setup.clServer.waiting")
            } icon: {
                Image(systemName: Glyph.pending.name)
            }
            .font(TypeLevel.footer.font)
            .foregroundStyle(ColorRole.brandLight.color)
        }
    }

    private func heading(_ key: String) -> some View {
        Text(appKey: key)
            .font(TypeLevel.title.font)
            .foregroundStyle(ColorRole.text.color)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func button(_ key: String, loud: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(appKey: key).frame(maxWidth: .infinity)
        }
        .setupButtonStyle(loud: loud)
    }

    // MARK: - Actions

    private func sendRequest() {
        let now = Date()
        if let lastRequest, now.timeIntervalSince(lastRequest) < Self.requestPause { return }
        lastRequest = now
        model.send(.sendJoinRequest)
    }

    private func redeem() async {
        guard !isWorking else { return }
        isWorking = true
        defer { isWorking = false }
        refusal = nil
        switch await model.clServerCalls.redeem(code, at: address) {
        case .paired(let person):
            code = ""
            model.send(.sourceFinished(.portals, .done(detail: person ?? address?.host() ?? "")))
        case .refused(let sentence):
            refusal = sentence
        }
    }

    /// The beat of the waiting — **every 15 seconds, at most a minute while throttled**
    /// (``Flows/RequestState/spacing``), and only while this screen is open.
    private func follow() async {
        while let current = request, current.waiting {
            do {
                try await Task.sleep(for: .seconds(current.spacing))
            } catch {
                // bewusst still: `Task.sleep` throws only on cancellation — the screen is gone.
                return
            }
            let result = await model.clServerCalls.poll(at: address)
            guard let now = request, let fresh = RequestState.afterInquiry(current: now, result: result)
            else {
                continue
            }
            model.send(.requestState(fresh))
        }
    }
}
