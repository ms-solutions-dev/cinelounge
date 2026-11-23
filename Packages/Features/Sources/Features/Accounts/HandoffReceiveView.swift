import Core
import CoreImage.CIFilterBuiltins
import DesignSystem
import SecondScreen
import SwiftUI

/// "Set up from phone" — the screen with the code.
///
/// **The most expensive screen of this app is the first one**, and it is
/// particularly expensive on a TV: Whoever has to type a server address here does it via an
/// on-screen keyboard with a remote. A phone that is already set up
/// does the same with one look through the camera.
///
/// **The code is drawn and not loaded.** `CIQRCodeGenerator` is built into the system;
/// fetching an image from a service would mean sending the one-time key there —
/// that is, giving away exactly the secret that this is all about.
public struct HandoffReceiveView: View {

    @State private var model = HandoffReceiveModel()
    @EnvironmentObject private var themes: ThemeStore
    let cancel: () -> Void
    /// What happens when everything has arrived — the app can start over.
    let done: () -> Void

    public init(cancel: @escaping () -> Void, done: @escaping () -> Void) {
        self.cancel = cancel
        self.done = done
    }

    public var body: some View {
        VStack(spacing: 30) {
            switch model.state {
            case .waiting: waitingSurface
            case .imported(let report): doneSurface(report)
            case .failed(let message): disruption(message)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task { model.begin() }
        .onDisappear { model.stopListening() }
    }

    // MARK: - Waiting

    @ViewBuilder
    private var waitingSurface: some View {
        Text("handover.tv.title")
            .font(TypeLevel.title.font)
            .foregroundStyle(ColorRole.text.color)

        // **Not compressible vertically** (on-device test 2026-09-27, T3): The stack divides its
        // height among QR code, title and buttons, and SwiftUI truncated the instructions to
        // one line — "TV e…". Precisely the path there was missing.
        Text("handover.tv.text")
            .font(TypeLevel.footer.font)
            .foregroundStyle(ColorRole.textMatt.color)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: 720)

        if let key = model.key, let image = Self.render(key.asText) {
            // **On a white backing and with a border.** A QR code on a dark ground cannot be read by
            // many cameras; the quiet zone around it belongs to the code and
            // not to the design.
            Image(decorative: image, scale: 1)
                .interpolation(.none)
                .resizable()
                .frame(width: 360, height: 360)
                .padding(28)
                .background(.white, in: RoundedRectangle(cornerRadius: 16))

            // **The name stands below**, because it is in the code and nobody reads it
            // there: Whoever has two TVs sees this way which one they are currently setting up.
            Text(key.target)
                .font(TypeLevel.footer.font)
                .foregroundStyle(ColorRole.textQuiet.color)
                .kerning(2)

            Text("handover.tv.validFor \(Int(model.remainingTime.rounded()))")
                .font(TypeLevel.footer.font)
                .foregroundStyle(ColorRole.textQuiet.color)
                .monospacedDigit()
        }

        Button(action: cancel) { Text(app: "common.cancel") }
            .padding(.top, 10)
    }

    // MARK: - Arrived

    @ViewBuilder
    private func doneSurface(_ report: Takeover.Report) -> some View {
        Image(systemName: "checkmark.circle.fill")
            .font(.system(size: 64))
            .foregroundStyle(ColorRole.brandLight.color)

        Text("handover.tv.done.title")
            .font(TypeLevel.title.font)
            .foregroundStyle(ColorRole.text.color)

        // **The list and not a success message.** "Transferred" does not answer the
        // question that someone with two devices has — they want to know what is now
        // here. The same consideration as with the phone's done page.
        VStack(alignment: .leading, spacing: 10) {
            if let name = report.jellyfin {
                row("handover.tv.done.server \(name)")
            }
            if report.channelLists > 0 {
                row("handover.tv.done.playlists \(report.channelLists)")
            }
            if report.bridge { row("handover.item.bridge") }
            if report.key > 0 {
                row("handover.tv.done.keys \(report.key)")
            }
            // **A row of its own, because it was missing until 2026-09-21** (AP40): The
            // shelf order stood on the sheet "What moves along" and arrived nowhere.
            // Whoever transfers it now should also read it — otherwise the promise would remain
            // a claim, only this time a correct one.
            if report.shelves > 0 { row("handover.tv.done.shelves \(report.shelves)") }
            // **Only the new ones** — see ``SecondScreen/Takeover/Report/profile``.
            if report.profile > 0 { row("handover.tv.done.profiles \(report.profile)") }
            if report.parentalControls { row("handover.tv.done.parental") }
            // **What did not arrive is the more important row** (AP23,
            // 2026-09-11). This TV keeps its own parental controls, and they
            // are not overwritten by a bundle — whoever does not read this sets
            // a limit on the phone and believes it applies here.
            if report.parentalControlsRejected {
                rejectedRow("handover.tv.done.parentalKept")
            }
        }
        .frame(maxWidth: 720, alignment: .leading)

        Button("handover.tv.done.button") { close(using: report) }
            .padding(.top, 10)
    }

    /// **The color pattern only on leaving**, although the store already carries it.
    ///
    /// A pattern change rebuilds the whole interface (``ThemeStore/rebuildID``), and
    /// in doing so the state of this view would be lost: Instead of the list there would stand a
    /// new code, as if nothing had arrived.
    private func close(using report: Takeover.Report) {
        done()
        if let patterns = Takeover.colorPattern(report.colorPattern) {
            themes.choose(patterns)
        }
    }

    /// **Color AND symbol**, as with every note in this app: A checkmark for "is
    /// there", a lock for "stays as it was". A marker that carries only color
    /// is missing for one in ten.
    private func rejectedRow(_ text: LocalizedStringKey) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Image(systemName: "lock.fill")
                .font(TypeLevel.footer.font)
                .foregroundStyle(ColorRole.textMatt.color)
            Text(app: text)
                .font(TypeLevel.text.font)
                .foregroundStyle(ColorRole.textMatt.color)
        }
    }

    private func row(_ text: LocalizedStringKey) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Image(systemName: "checkmark")
                .font(TypeLevel.footer.font)
                .foregroundStyle(ColorRole.brandLight.color)
            Text(app: text)
                .font(TypeLevel.text.font)
                .foregroundStyle(ColorRole.textMatt.color)
        }
    }

    // MARK: - Failure

    @ViewBuilder
    private func disruption(_ message: String) -> some View {
        Image(systemName: "exclamationmark.triangle")
            .font(.system(size: 56))
            .foregroundStyle(ColorRole.textMatt.color)

        Text("handover.tv.error.title")
            .font(TypeLevel.title.font)
            .foregroundStyle(ColorRole.text.color)

        Text(verbatim: message)
            .font(TypeLevel.footer.font)
            .foregroundStyle(ColorRole.textMatt.color)
            .multilineTextAlignment(.center)
            .frame(maxWidth: 720)

        // **"Once more" creates a new code.** The old one is used up — it is valid
        // once, and a second attempt with the same code would be one that the
        // receiver no longer accepts at all.
        HStack(spacing: 20) {
            Button("handover.tv.retry") { model.begin() }
            Button(action: cancel) { Text(app: "common.cancel") }
        }
        .padding(.top, 10)
    }

    // MARK: - The code as an image

    /// **As a function and not in the view body.** Otherwise it runs on every
    /// redraw — and the redraw comes every second here, because the clock below
    /// counts.
    ///
    /// **Error correction "M" and not "L".** Light falls on a TV, and nobody
    /// holds the camera steady; the middle level carries some of that without making the
    /// code so dense that it is no longer readable from two meters.
    nonisolated static func render(_ text: String) -> CGImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let image = filter.outputImage else { return nil }
        return CIContext().createCGImage(image, from: image.extent)
    }
}
