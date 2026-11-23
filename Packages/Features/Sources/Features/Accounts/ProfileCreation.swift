import Core
import DesignSystem
import ParentalControls
import ProfileKit
import SwiftUI

/// **"Create profile" from "Who is watching?"** — one card, two paths behind it (AP45/AP48,
/// product decision 3 of 2026-09-25).
///
/// **Profiles without an iPhone are the normal case.** A profile is self-contained: name, color,
/// picture and kind come into being here on the TV (``ProfileSheet``), without any other
/// needing to exist anywhere. iCloud and the QR code only ease the move and the
/// progress — that is why "Get from iPhone" stands as the **second** path behind the same
/// card and not as a start screen of its own, and the first start is not held up.
///
/// **Getting means: with an Apple account via the code** (AP44, ``CloudSheet`` without profile, page
/// "Get profile"), **without one over the wire** (``HandoffReceiveView``). Which path it is
/// is decided by ``pullMode(cloud:)`` — whoever sits in front of the TV should not have to know
/// whether this device is currently attached to iCloud.
struct ProfileCreation: View {

    @ObservedObject var model: ProfileModel
    let cloud: ProfileCloud?
    /// Called when a profile was created or fetched — or when it was cancelled.
    let onDone: () -> Void

    enum Step: Equatable {
        case choice
        case fresh
        case fetch
    }

    /// How it is fetched.
    nonisolated enum PullMode: Equatable {
        /// Via iCloud and the code — the profile arrives with its state and stays in sync.
        case cloud
        /// Over the wire in the home network — without an Apple account.
        case wire
    }

    nonisolated static func pullMode(cloud available: Bool) -> PullMode {
        available ? .cloud : .wire
    }

    @State private var step: Step = .choice
    @FocusState private var focus: String?

    var body: some View {
        switch step {
        case .choice:
            choice
        case .fresh:
            ProfileSheet(
                existing: nil,
                suggestion: model.nextColor,
                previousLimit: nil,
                onSave: { name, color, kind, limit, avatar in
                    let fresh = model.create(name: name, color: color, kind: kind, avatar: avatar)
                    // **The limit belongs to the new child** — the same computation as in
                    // ``ProfileView`` (``ProfileTarget``), not to the one who is currently watching.
                    if kind == .kind, let target = ProfileTarget.limitBelongsTo(nil, fresh: fresh) {
                        ParentalControlsState().set(limit: limit, forItem: target.rawValue)
                    }
                    onDone()
                },
                onCancel: { step = .choice },
                // Cross-check AP45, M2 — see ``ProfileSheet/promptsForPin(kind:isPinSet:)``.
                isPinSet: ParentalControlsState().rule.isPinSet)
        case .fetch:
            switch Self.pullMode(cloud: cloud != nil) {
            case .cloud:
                if let cloud {
                    CloudSheet(profile: nil, cloud: cloud) {
                        model.load()
                        onDone()
                    }
                }
            case .wire:
                HandoffReceiveView(
                    cancel: { step = .choice },
                    done: {
                        model.load()
                        onDone()
                    })
            }
        }
    }

    private var choice: some View {
        ZStack {
            ColorRole.reason.color.ignoresSafeArea()
            VStack(spacing: 50) {
                VStack(spacing: 12) {
                    Text(app: "profiles.add")
                        .font(TypeLevel.title.font)
                        .foregroundStyle(ColorRole.text.color)
                    Text(app: "profiles.create.hint")
                        .font(TypeLevel.footer.font)
                        .foregroundStyle(ColorRole.textQuiet.color)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: 1000)
                }
                HStack(alignment: .top, spacing: 60) {
                    card(
                        identifier: "neu", character: Glyph.add.name,
                        title: "profiles.create.new", hint: "profiles.create.newHint"
                    ) { step = .fresh }
                    card(
                        identifier: "holen", character: Glyph.fetchProfile.name,
                        title: "profiles.create.fromPhone",
                        hint: "profiles.create.fromPhoneHint"
                    ) { step = .fetch }
                }
            }
            .padding(60)
        }
        .onAppear { focus = "neu" }
        .onExitCommand(perform: onDone)
    }

    private func card(
        identifier: String, character: String, title: String, hint: String,
        action: @escaping () -> Void
    ) -> some View {
        let hasFocus = focus == identifier
        return Button(action: action) {
            VStack(spacing: 22) {
                Image(systemName: character)
                    .font(.system(size: 64))
                    .foregroundStyle(hasFocus ? ColorRole.reason.color : ColorRole.textMatt.color)
                    .frame(width: 180, height: 180)
                    .background(
                        hasFocus ? ColorRole.text.color : ColorRole.surface.color, in: Circle())
                Text(appKey: title)
                    .font(TypeLevel.header.font)
                    .foregroundStyle(hasFocus ? ColorRole.text.color : ColorRole.textMatt.color)
                Text(appKey: hint)
                    .font(TypeLevel.lowercased.font)
                    .foregroundStyle(ColorRole.textQuiet.color)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(width: 440)
            .scaleEffect(hasFocus ? 1.05 : 1)
            .animation(.easeOut(duration: 0.18), value: hasFocus)
        }
        .bareFocusableButton()
        .focused($focus, equals: identifier)
        .info(appKey: title)
    }
}
