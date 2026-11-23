import Core
import DesignSystemPhone
import Foundation
import PlaylistKit
import SwiftUI

/// A provider credential or a list file.
///
/// **Two procedures, one screen.** An Xtream credential brings categories and
/// program guide along in structured form, an M3U file is a list of addresses.
/// Separate screens for them would be two paths that differ in three fields.
///
/// **The credential is stored and not checked.** The account allows **one** connection,
/// and a connection burst leads to an IP throttle that also blocks the API
/// and lasts minutes (measured on 2026-08-15). A check query here would be a connection that
/// nobody needs — and at the worst moment of all: whoever mistypes presses
/// twice.
///
/// - Note: That leaves out the case that according to the roadmap is **not a mistyped entry** —
///   "recognized, but expired". It cannot be determined without a check query and is
///   named open in the roadmap; whoever builds it builds the throttle avoidance at the same time.
struct SetUpChannelListView: View {

    @Bindable var model: SourceFormModel

    @State private var xtream = true
    @State private var name = ""
    @State private var address = ""
    @State private var user = ""
    @State private var password = ""

    var body: some View {
        SetupSheet(
            title: "setup.playlist.title", explanation: "setup.playlist.text",
            error: model.error
        ) {
            VStack(alignment: .leading, spacing: MetricsBoard.phone.gutter) {
                SegmentPicker(
                    links: AppLanguageSetting.text("setup.playlist.xtream"),
                    right: AppLanguageSetting.text("setup.playlist.m3u"),
                    isRightSelected: Binding(get: { !xtream }, set: { xtream = !$0 }))

                // **The name is no decoration.** With two credentials the
                // same wording would otherwise stand twice in the index, and nobody could tell
                // them apart — the finding of 2026-09-05.
                InputField(text: $name, placeholder: "setup.playlist.name", kind: .name)
                InputField(
                    text: $address, placeholder: "setup.playlist.address", kind: .address)

                if xtream {
                    InputField(
                        text: $user, placeholder: "common.username", kind: .name)
                    InputField(
                        text: $password, placeholder: "common.password", kind: .password)
                }

                Button(action: create) {
                    Text(appKey: "setup.continue").frame(maxWidth: .infinity)
                }
                .buttonStyle(.loud)
                .disabled(!complete)

                Footnote(message: "setup.playlist.footnote")
            }
            .padding(.top, 4)
        }
    }

    /// The typed address — **through the shared rule** (``PlaylistKit/ChannelListCheck``,
    /// AP58 R7). Until then `URL(string:)` took `provider.tv:8080` as a scheme without a host.
    private var target: URL? {
        xtream ? ChannelListCheck.serverAddress(address) : ChannelListCheck.address(address)
    }

    private var complete: Bool {
        guard target != nil else { return false }
        return xtream ? !user.isEmpty : true
    }

    private func create() {
        guard let target else { return }
        let label = name.isEmpty ? (target.host() ?? "IPTV") : name
        if xtream {
            model.addChannelList(
                name: label, address: target, user: user, password: password)
        } else {
            model.createList(name: label, address: target)
        }
    }
}
