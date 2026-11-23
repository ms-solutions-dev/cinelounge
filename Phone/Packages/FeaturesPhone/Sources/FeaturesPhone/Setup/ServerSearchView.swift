import Core
import DesignSystemPhone
import JellyfinKit
import SwiftUI

/// The address of the media server.
///
/// **Two faces, and both are full-fledged.** With permission the list of finds stands above
/// the field, without it only the field stands there — and **without permission nothing is
/// thrown at you**: typing the address is not an emergency exit but the path that most people
/// take on the phone anyway.
///
/// **The field stays, even while searching.** Whoever knows their address should
/// not wait until 253 addresses have been probed; and whoever finds nothing does not face
/// an empty screen with a spinner on it.
///
/// **The field takes less than an address.** Whoever types a short host name means one of
/// six spellings; `JellyfinConnection.candidates` knows them and tries them in
/// order. A field that demands the complete address demands knowledge that at
/// this point nobody has.
struct ServerSearchView: View {

    @Bindable var model: SourceFormModel

    var body: some View {
        SetupSheet(
            title: "setup.server.title", explanation: "setup.server.text",
            error: model.error
        ) {
            VStack(alignment: .leading, spacing: MetricsBoard.phone.gutter) {
                foundList

                InputField(
                    text: $model.address, placeholder: "setup.server.placeholder",
                    kind: .address)

                if model.isRunning {
                    // **The waiting screen is not a screen of its own.** It differs
                    // from the field by a spinner and nothing else — a second
                    // screen for it would make the field disappear, and whoever
                    // mistyped would only get back after the failure.
                    LoadingState(message: "setup.server.checking")
                        .padding(.top, MetricsBoard.phone.gutter)
                } else {
                    Button {
                        Task { await model.checkAddress() }
                    } label: {
                        Text(appKey: "setup.continue").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.loud)
                    .disabled(model.address.trimmingCharacters(in: .whitespaces).isEmpty)
                }

                Footnote(message: "setup.server.footnote")
            }
            .padding(.top, 4)
        }
    }

    /// The value column of a find: the machine, or **the note that this phone does
    /// not reach it.** It stays selectable anyway, as on the TV.
    private func valueText(_ found: ServerDiscovery.Found) -> String {
        guard !model.unreachable.contains(found.id) else {
            return AppLanguageSetting.text("login.serverUnreachable")
        }
        return found.address.host() ?? found.address.absoluteString
    }

    /// What was found on the home network — **none of it as long as no search is running.**
    ///
    /// **No "nothing found" with an exclamation mark.** Whoever allows the search and has no
    /// server has done nothing wrong; the field stands below the row anyway, and
    /// that is the answer. An error message would turn it into a failure.
    @ViewBuilder
    private var foundList: some View {
        if model.isSearching || !model.found.isEmpty {
            VStack(alignment: .leading, spacing: MetricsBoard.phone.gutter) {
                ForEach(model.found) { found in
                    // **The row is itself the button** — ``DisclosureRow`` brings target,
                    // height and chevron along. A button around it would be a second
                    // hit area over the same path.
                    DisclosureRow(
                        wording: found.name,
                        value: valueText(found),
                        isMissing: model.unreachable.contains(found.id)
                    ) {
                        Task { await model.select(found) }
                    }
                    .disabled(model.isRunning)
                }

                if model.isSearching {
                    // **The spinner stands below the finds and not above them.** The
                    // list grows while searching; a spinner on top would push it
                    // down with every find.
                    LoadingState(message: "settings.portals.searching")
                }
            }
            .padding(.bottom, 4)
        }
    }
}
