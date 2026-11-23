import Core
import DesignSystem
import Flows
import ProfileKit
import SwiftUI

/// A6 — **access to the household's CL-Server: a request, or for a child the pairing code.**
///
/// Design A of 2026-11-15: the request (`POST /join`, AP47) carries the profile's name and
/// color, and nobody has to wait for the decision — "Continue" leads back to A4 with the row on
/// "waiting", and the CL-Server joins by itself once approved. **A profile with a person token
/// never sees this screen:** the machine signs it in by itself (``Flows/SetupEffect/enroll(_:)``).
/// **A child never asks** (§1.4 point 4): its device is paired by the administrator with a code.
///
/// **Driven from outside:** the machine's ``Flows/ClServerStep`` decides the page, the request is
/// the machine's effect, and polling, withdrawing and redeeming come in as ``ClServerCalls``.
public struct ClServerJoinView: View {

    /// What the screen shows — **one page per answer**, so that "declined" and "expired" each keep
    /// their own sentence.
    nonisolated enum Page: Equatable {
        case searching
        case notFound
        case ask
        case waiting(RequestState)
        case approved(name: String, withTag: Bool)
        /// Declined, expired, or the request did not go out — asking again is possible.
        case ended(RequestState)
        case childPairing
    }

    let journey: SetupJourney
    let calls: ClServerCalls

    @State private var code = ""
    @State private var refusal: String?
    @State private var isWorking = false
    @State private var lastRequest: Date?
    @FocusState private var focus: String?

    public init(journey: SetupJourney, calls: ClServerCalls) {
        self.journey = journey
        self.calls = calls
    }

    /// The program's calls, at the address the search found.
    public init(journey: SetupJourney) {
        self.init(journey: journey, calls: .onDevice(basis: { journey.machine.clServerAddress }))
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

    /// Where the focus goes on a page — **"Continue" while waiting** (design A6), otherwise the
    /// page's main path.
    nonisolated static func focusTarget(_ page: Page) -> String? {
        switch page {
        case .searching: nil
        case .notFound: "back"
        case .ask: "ask"
        case .waiting, .approved: "continue"
        case .ended: "ask-again"
        case .childPairing: "pairing"
        }
    }

    private var step: (profile: SetupProfile?, page: Page)? {
        guard case .clServer(let identifier, let step) = journey.state else { return nil }
        return (journey.machine.setupProfile(identifier), Self.page(step))
    }

    private var request: RequestState? {
        guard case .clServer(_, .request(let request)) = journey.state else { return nil }
        return request
    }

    public var body: some View {
        SetupSheetFrame(title: step?.profile?.sheetTitle("CL-Server") ?? "CL-Server") {
            if let step { content(step.page, profile: step.profile) }
        }
        .onExitCommand { journey.send(.back) }
        .onChange(of: step.flatMap { Self.focusTarget($0.page) }, initial: true) { _, target in
            focus = target
        }
        .task(id: request?.waiting ?? false) { await follow() }
    }

    @ViewBuilder
    private func content(_ page: Page, profile: SetupProfile?) -> some View {
        switch page {
        case .searching: searching
        case .notFound: notFound
        case .ask: ask(profile)
        case .waiting(let request): waiting(request, profile: profile)
        case .approved(let name, let withTag): approved(name, withTag: withTag)
        case .ended(let request): ended(request)
        case .childPairing: childPairing
        }
    }

    // MARK: - Before the request

    private var searching: some View {
        HStack(spacing: 18) {
            ProgressView()
            Text(app: "setup.clServer.searching")
                .font(TypeLevel.text.font)
                .foregroundStyle(ColorRole.textMatt.color)
        }
    }

    private var notFound: some View {
        VStack(alignment: .leading, spacing: 34) {
            heading("setup.clServer.notFoundTitle")
            SetupNote(text: Text(app: "setup.clServer.notFound"))
            Spacer(minLength: 0)
            SetupButton(title: "common.back", identifier: "back", focus: $focus) { journey.send(.back) }
        }
    }

    private func ask(_ profile: SetupProfile?) -> some View {
        VStack(alignment: .leading, spacing: 34) {
            heading("setup.clServer.askTitle")
            SetupNote(text: Text(app: "settings.portals.joinHint \(profile?.profile.name ?? "")"))
            SetupNote(text: Text(app: "setup.clServer.noWait"))
            Spacer(minLength: 0)
            HStack(spacing: 24) {
                SetupButton(
                    title: "settings.portals.joinRequest", rank: .main, identifier: "ask", focus: $focus,
                    action: sendRequest)
                SetupButton(title: "common.back", identifier: "back", focus: $focus) { journey.send(.back) }
            }
        }
    }

    // MARK: - After the request

    private func waiting(_ request: RequestState, profile: SetupProfile?) -> some View {
        VStack(spacing: 30) {
            if let profile {
                ProfileCircle(
                    letter: profile.profile.initial, avatar: profile.profile.avatar, edge: 150,
                    font: TypeLevel.title.font, letterColor: ColorRole.text.color,
                    surface: ProfileColor.tag(profile.profile.color.rawValue), frame: nil)
            }
            heading("setup.clServer.sent")
            Text(app: "setup.clServer.sentHint \(profile?.profile.name ?? "")")
                .font(TypeLevel.text.font)
                .foregroundStyle(ColorRole.textMatt.color)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 1100)
            waitingPill(request)
            Spacer(minLength: 0)
            HStack(spacing: 24) {
                SetupButton(title: "settings.portals.joinCancel", identifier: "withdraw", focus: $focus) {
                    calls.withdraw()
                    journey.send(.requestState(.none))
                }
                SetupButton(
                    title: "setup.clServer.continue", rank: .main, identifier: "continue", focus: $focus
                ) {
                    journey.send(.sourceFinished(.portals, .waiting))
                }
            }
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private func waitingPill(_ request: RequestState) -> some View {
        switch request {
        case .throttled(let seconds?):
            SetupNote(text: Text(app: "settings.portals.joinThrottled \((seconds + 59) / 60)"))
        case .throttled(nil):
            SetupNote(text: Text(app: "settings.portals.joinThrottledSoon"))
        default:
            Label {
                Text(app: "setup.clServer.waiting")
            } icon: {
                Image(systemName: Glyph.hourglass.name)
            }
            .font(TypeLevel.footer.font)
            .foregroundStyle(ColorRole.reason.color)
            .padding(.horizontal, 26)
            .padding(.vertical, 12)
            .background(ColorRole.brandLight.color, in: Capsule())
        }
    }

    private func approved(_ name: String, withTag: Bool) -> some View {
        VStack(alignment: .leading, spacing: 34) {
            Label {
                Text(app: "setup.clServer.approvedTitle")
            } icon: {
                Image(systemName: Glyph.done.pair.filled)
            }
            .font(TypeLevel.title.font)
            .foregroundStyle(ColorRole.text.color)
            SetupNote(
                text: withTag
                    ? Text(app: "settings.portals.joinApproved \(name)")
                    : Text(app: "settings.portals.joinApprovedNoMark \(name)"))
            Spacer(minLength: 0)
            SetupButton(title: "setup.clServer.continue", rank: .main, identifier: "continue", focus: $focus)
            {
                journey.send(.sourceFinished(.portals, .done(detail: name)))
            }
        }
    }

    private func ended(_ request: RequestState) -> some View {
        VStack(alignment: .leading, spacing: 34) {
            heading("setup.clServer.askTitle")
            switch request {
            case .rejected: SetupErrorLine(text: Text(app: "settings.portals.joinDeclined"))
            case .expired: SetupErrorLine(text: Text(app: "settings.portals.joinExpired"))
            case .failed(let sentence): SetupErrorLine(text: Text(verbatim: sentence))
            default: EmptyView()
            }
            Spacer(minLength: 0)
            HStack(spacing: 24) {
                SetupButton(
                    title: "setup.clServer.askAgain", rank: .main, identifier: "ask-again", focus: $focus,
                    action: sendRequest)
                SetupButton(title: "common.back", identifier: "back", focus: $focus) { journey.send(.back) }
            }
        }
    }

    // MARK: - A child's device

    private var childPairing: some View {
        VStack(alignment: .leading, spacing: 30) {
            heading("setup.clServer.childTitle")
            SetupNote(text: Text(app: "settings.portals.pairingHint"))
            HStack(spacing: 20) {
                InputRow(
                    title: "settings.portals.pairingPrompt", text: $code, state: .alone, kind: .identifier,
                    width: 320, identifier: "pairing", focus: $focus)
                SetupButton(
                    title: "settings.portals.redeem", rank: .main, identifier: "redeem", focus: $focus
                ) {
                    Task { await redeem() }
                }
            }
            if let refusal { SetupErrorLine(text: Text(verbatim: refusal)) }
            Spacer(minLength: 0)
            SetupButton(title: "common.back", identifier: "back", focus: $focus) { journey.send(.back) }
        }
        .onChange(of: code) { _, _ in refusal = nil }
    }

    // MARK: - Actions

    private func heading(_ key: LocalizedStringKey) -> some View {
        Text(app: key)
            .font(TypeLevel.title.font)
            .foregroundStyle(ColorRole.text.color)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// **A second press within a few seconds is discarded** — the server throttles at three
    /// requests per hour, and the answer of the first is still on its way.
    private func sendRequest() {
        let now = Date()
        if let lastRequest, now.timeIntervalSince(lastRequest) < Self.requestPause { return }
        lastRequest = now
        journey.send(.sendJoinRequest)
    }

    static let requestPause: TimeInterval = 5

    private func redeem() async {
        guard !isWorking, !code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        isWorking = true
        defer { isWorking = false }
        switch await calls.redeem(code) {
        case .paired(let person):
            code = ""
            journey.send(
                .sourceFinished(
                    .portals, .done(detail: person ?? journey.machine.clServerAddress?.host() ?? "")))
        case .refused(let sentence):
            refusal = sentence
        }
    }

    /// The beat of the waiting — **every 15 seconds, at most a minute while throttled**
    /// (``Flows/RequestState/spacing``), and only while this screen is open. What a poll brings
    /// is decided by ``Flows/RequestState/afterInquiry(current:result:)``.
    private func follow() async {
        while let current = request, current.waiting {
            do {
                try await Task.sleep(for: .seconds(current.spacing))
            } catch {
                // bewusst still: `Task.sleep` throws only on cancellation — the screen is gone.
                return
            }
            let result = await calls.poll()
            guard let now = request, let fresh = RequestState.afterInquiry(current: now, result: result)
            else {
                continue
            }
            journey.send(.requestState(fresh))
        }
    }
}
