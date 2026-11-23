import Core
import DesignSystemPhone
import Diagnose
import ProfileKit
import SwiftUI

/// "A PIN reset was requested on the TV" — **the page that confirms or cancels** (AP43,
/// 2026-09-23).
///
/// **This device is the fast way.** On the TV, resetting takes a day, because nobody there
/// can prove they are the parent. Here they can: whoever has unlocked this phone is signed
/// in to the Apple ID — the way out requires no more than that, and could not check more.
///
/// **Cancel stands next to it as an equal and is not the small exit.** The most likely case
/// is not the forgetful parent but the child who found the button. Whoever sees this page
/// without having requested anything should be able to stop with one tap.
///
/// **The device name is in the sentence.** "A reset was requested" does not answer the
/// decisive question — whether it was one's own TV or the one in the child's room.
///
/// **Since 2026-09-25 all requests, not only parental controls** (second review, strand C,
/// finding 6): a profile with its own PIN can also file a request `profile-<Identifier>`; it
/// appears here with profile name, requesting device and remaining time — see ``PinFallbacks``.
struct PinFallbackView: View {

    let cloud: ProfileCloud
    /// Where the ``ProfileKit/ProfileBook`` lives — for the profile names.
    var ledgerStore: any KeyValueStore = FileStore()
    /// Called when the page should close.
    var close: () -> Void = {}

    @State private var escapes = PinFallbacks.none

    var body: some View {
        ZStack {
            ColorRole.reason.color.ignoresSafeArea()

            ScrollSurface {
                VStack(alignment: .leading, spacing: MetricsBoard.phone.gutter) {
                    LargeTitle(title: "childLock.reset.title")

                    if escapes.isEmpty {
                        message("childLock.reset.none")
                    }
                    ForEach(escapes.entries) { entry in
                        section(entry)
                    }
                }
                .padding(.horizontal, MetricsBoard.phone.margin)
                .padding(.top, MetricsBoard.phone.gutter)
            }
        }
        .navigationTitle(Text(app: "childLock.reset.title"))
        .toolbarTitleDisplayMode(.inline)
        .task { await read() }
        .onReceive(NotificationCenter.default.publisher(for: .pinEscape)) { _ in
            Task { await read() }
        }
    }

    @ViewBuilder
    private func section(_ entry: PinFallbacks.ContentEntryRecord) -> some View {
        VStack(alignment: .leading, spacing: MetricsBoard.phone.gutter) {
            if let name = entry.name {
                Text(app: "childLock.reset.forProfile \(name)")
                    .font(TypeLevel.section.font)
                    .foregroundStyle(ColorRole.text.color)
            } else {
                Text(app: "childLock.title")
                    .font(TypeLevel.section.font)
                    .foregroundStyle(ColorRole.text.color)
            }
            switch entry.state {
            case .none:
                message("childLock.reset.none")
            case .wartetAufServer(let device):
                message("childLock.reset.waiting \(device)")
            case .isRunning(let due, let device):
                running(entry.lock, due: due, device: device)
            case .due(let device):
                message("childLock.reset.due \(device)")
                cancel(entry.lock)
            case .confirmed(let device):
                message("childLock.reset.confirmed \(device)")
                cancel(entry.lock)
            }
        }
        .padding(.bottom, MetricsBoard.phone.section)
    }

    @ViewBuilder
    private func running(_ lock: PINFallback.Lock, due: Date, device: String) -> some View {
        message("childLock.reset.running \(device)")

        HStack(spacing: 8) {
            Text(app: "childLock.forgot.remaining")
            // The display may use the device time — the calculation is made against the server's
            // clock, see ``ProfileKit/PINFallback``.
            Text(timerInterval: Date()...max(Date(), due), countsDown: true)
        }
        .font(TypeLevel.text.font)
        .foregroundStyle(ColorRole.text.color)
        .padding(.vertical, 4)

        Button {
            Task {
                _ = await PinFallbacks.confirm(lock, cloud: cloud, device: DeviceName.thisDevice)
                await read()
            }
        } label: {
            Text(app: "childLock.reset.confirm").frame(maxWidth: .infinity)
        }
        .buttonStyle(.loud)

        cancel(lock)

        Footnote(message: "childLock.reset.footnote")
    }

    private func cancel(_ lock: PINFallback.Lock) -> some View {
        Button(role: .destructive) {
            Task {
                await PinFallbacks.cancel(lock, cloud: cloud)
                await read()
            }
        } label: {
            Text(app: "childLock.reset.cancel").frame(maxWidth: .infinity)
        }
        .buttonStyle(.quiet)
    }

    /// **A `LocalizedStringKey` and not a `String`** (finding of 2026-09-25): with `String`,
    /// "childlock.reset.waiting \(geraet)" was assembled **before** the lookup, and the catalog
    /// did not know "childlock.reset.waiting Example TV" — the page showed the raw key including
    /// the device name. As a key, this becomes "childlock.reset.waiting %@".
    private func message(_ key: LocalizedStringKey) -> some View {
        Text(app: key)
            .font(TypeLevel.footer.font)
            .foregroundStyle(ColorRole.textMatt.color)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func read() async {
        escapes = await PinFallbacks.read(cloud: cloud, ledgerStore: ledgerStore)
    }
}
