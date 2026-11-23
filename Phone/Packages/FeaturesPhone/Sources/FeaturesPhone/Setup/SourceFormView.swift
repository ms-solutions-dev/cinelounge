import Core
import DesignSystemPhone
import SwiftUI

/// The form behind "Add account" and "New channel list" — **one path, no choice before it.**
///
/// **No progress bar.** The media server path has several steps, a channel list one; a bar
/// would claim they are equally long. Where you stand is stated by the heading instead. The
/// first setup has its own switch since AP88 wave 6 (``SetupView``).
///
/// **Language and diagnostics stand at the foot, even before sign-in.** Whoever cannot
/// get in needs both most urgently — on the TV they stand there for the same
/// reason.
public struct SourceFormView: View {

    @State private var model: SourceFormModel
    private let done: () -> Void

    public init(model: SourceFormModel, done: @escaping () -> Void = {}) {
        _model = State(initialValue: model)
        self.done = done
    }

    public var body: some View {
        ZStack {
            ColorRole.reason.color.ignoresSafeArea()

            VStack(alignment: .leading, spacing: 0) {
                header
                step
                Spacer(minLength: 0)
                // **The foot stood as a promise in the head of this file and nowhere
                // else.** Recounted on 2026-09-06: the body consisted of `header`,
                // `step` and a `Spacer` — language and diagnostics did not exist.
                SetupFooter()
            }
        }
        // **A sheet and not a step.** The certificate question interrupts the path, it
        // is not a station on it: whoever confirms stands afterwards where they were,
        // and whoever declines too. A tenth step would have needed a way back
        // that leads nowhere.
        .sheet(
            item: Binding(
                get: { model.certificatePrompt }, set: { if $0 == nil { model.rejectCertificate() } })
        ) {
            query in
            certificateSheet(query)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
                .presentationCornerRadius(MetricsBoard.phone.sheetRadius)
                .presentationBackground(ColorRole.surfaceHigh.color)
        }
    }

    /// **Two screens and not one with an extra line.** An unknown
    /// certificate is the normal case on the home network; a **changed** one is the warning the
    /// whole procedure was built for. Drawing both the same would drown the warning
    /// in the normal case.
    @ViewBuilder
    private func certificateSheet(_ query: CertificatePrompt.Pending) -> some View {
        ScrollView {
            if let known = query.known {
                CertificateChangedSheet(
                    query: query, known: known,
                    trustAnyway: { Task { await model.trustCertificate() } },
                    cancel: { model.rejectCertificate() })
            } else {
                CertificateSheet(
                    query: query,
                    trust: { Task { await model.trustCertificate() } },
                    reject: { model.rejectCertificate() })
            }
        }
    }

    @ViewBuilder
    private var header: some View {
        // **No way back at the first step** — the navigation that opened the form leads out.
        // Everywhere else there is one, one step back.
        if !model.isAtStart && model.step != .done {
            HStack {
                Button {
                    model.back()
                } label: {
                    Image(systemName: Glyph.back.name)
                        .foregroundStyle(ColorRole.textMatt.color)
                }
                .frame(width: Metrics.target, height: Metrics.target)
                .accessibilityLabel(Text(app: "common.back"))
                Spacer()
            }
            .padding(.horizontal, MetricsBoard.phone.margin - (Metrics.target - 19) / 2)
        }
    }

    @ViewBuilder
    private var step: some View {
        switch model.step {
        case .networkPermission:
            NetworkLawView(
                search: { model.continueToServer(withSearch: true) },
                byHand: { model.continueToServer() })
        case .server, .connect: ServerSearchView(model: model)
        case .loginRoute: SignInRouteView(model: model)
        case .password: PasswordView(model: model)
        case .code: QuickConnectView(model: model)
        case .channelList: SetUpChannelListView(model: model)
        case .done: DoneView(model: model, done: done)
        }
    }
}

/// A step of the setup: heading, explanation, content.
///
/// **One form for all.** Nine screens that differ in margin, title size and spacing
/// look like nine programs — and the viewer notices at the third
/// that they are not safe here.
struct SetupSheet<Content: View>: View {

    let title: String
    var explanation: String?
    var error: String?
    /// A finished title instead of the key — for a sentence with a name in it ("Confirm on
    /// Wohnzimmer").
    var wording: String?
    @ViewBuilder let content: Content

    /// **The scrolling belongs here and not in the nine views.**
    ///
    /// Four of them brought their own `ScrollView`, four did not — recounted on
    /// 2026-09-06. With large text the content of the other four ran off the bottom of the screen,
    /// and without any sign: a screen that does not scroll looks as if it were
    /// at its end. It would have hit the sign-in of all things, whose button is at the very bottom.
    ///
    /// **A `ScrollView` and not a ``ScrollSurface``.** Its "to top" button is meant
    /// for a hundred and three posters; over a form with three fields it only covers
    /// the spot where the keyboard opens. The name makes the deviation visible —
    /// that is exactly what it stands there for.
    var body: some View {
        ScrollView {
            bodyContent
        }
        .scrollBounceBehavior(.basedOnSize)
    }

    private var bodyContent: some View {
        VStack(alignment: .leading, spacing: MetricsBoard.phone.gutter) {
            Group {
                if let wording { Text(verbatim: wording) } else { Text(appKey: title) }
            }
            .font(TypeLevel.title.font)
            .foregroundStyle(ColorRole.text.color)
            .fixedSize(horizontal: false, vertical: true)

            if let explanation {
                Text(appKey: explanation)
                    .font(TypeLevel.footer.font)
                    .foregroundStyle(ColorRole.textMatt.color)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // **The error stands above the field, not below it.** Below the field it lies
            // outside the screen when the keyboard is open — and a message you cannot
            // see is none.
            if let error {
                HintCapsule(message: error)
            }

            content
        }
        .padding(.horizontal, MetricsBoard.phone.margin)
        .padding(.top, MetricsBoard.phone.gutter)
    }
}
