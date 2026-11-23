import Core
import DesignSystemPhone
import SwiftUI

/// Area 5 · Ratings.
///
/// **Three keys and an honest sentence about what is missing without them.** A field with
/// the label "API key" and nothing else demands that the viewer know
/// why they should enter it. Without the keys **nothing is broken** — the
/// media server's ratings are on every tile anyway; what is missing is the
/// more precise information and the faces of the cast.
///
/// **In the Keychain and not in the source code.** They belong to the user, have a
/// daily quota and would be readable in a checked-in file for anybody who gets the
/// project in their hands.
struct RatingsView: View {
    @Environment(\.horizontalSizeClass) private var widthClass

    @State private var omdb = ""
    @State private var tmdb = ""
    /// The MyAnimeList client ID (AP68) — the anime rating per season.
    @State private var mal = ""

    private let store: SecureStore

    init(store: SecureStore = SecureStore()) {
        self.store = store
    }

    var body: some View {
        ZStack {
            ColorRole.reason.color.ignoresSafeArea()

            ScrollSurface {
                VStack(alignment: .leading, spacing: MetricsBoard.phone.section) {
                    keyField(
                        title: "settings.ratings.omdb", message: "settings.ratings.omdbText",
                        text: $omdb, save: { try? store.setOMDbAPIKey($0) })

                    keyField(
                        title: "settings.ratings.tmdb", message: "settings.ratings.tmdbText",
                        text: $tmdb, save: { try? store.setTMDbAPIKey($0) })

                    keyField(
                        title: "settings.ratings.mal", message: "settings.ratings.malText",
                        text: $mal, save: { try? store.setMALClientID($0) })

                    Footnote(message: "settings.ratings.footnote")
                }
                .contentColumn(widthClass)
                .padding(.top, MetricsBoard.phone.gutter)
            }
        }
        .task {
            omdb = store.omdbAPIKey() ?? ""
            tmdb = store.tmdbAPIKey() ?? ""
            mal = store.malClientID() ?? ""
        }
    }

    private func keyField(
        title: String, message: String, text: Binding<String>, save: @escaping (String) -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionHeader(title: title)
            Text(appKey: message)
                .font(TypeLevel.label.font)
                .foregroundStyle(ColorRole.textQuiet.color)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, MetricsBoard.phone.margin)
            // **As a password field with an eye button.** A key is a secret and
            // at the same time something you type — both apply, and the eye button is
            // exactly the resolution of this contradiction.
            InputField(text: text, placeholder: "settings.ratings.placeholder", kind: .password)
                .padding(.horizontal, MetricsBoard.phone.margin)
                .onChange(of: text.wrappedValue) { _, fresh in save(fresh) }
        }
    }
}
