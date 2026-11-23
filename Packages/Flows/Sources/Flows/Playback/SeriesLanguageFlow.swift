import Diagnose
import Foundation
import Observation

/// "Language of this series" — **once for all episodes** (AP58 G1, decision 27, A9).
///
/// **Why it is permanent** (viewer request 2026-08-28: choose it centrally instead of having to
/// select it for every episode individually, since otherwise automatic playback
/// from episode to episode would not work at all): a choice per episode would have to be
/// made anew at every episode change. The TV had it on the
/// detail page; the phone had only the choice per episode in the player. The flow lived in the
/// TV's `DetailModel` and now lives here for both.
///
/// **The remembered choice is cheap, the list expensive.** For the list the bridge descends to
/// the first episode of each of the first three seasons; it is fetched only when someone
/// opens the choice.
@Observable
public final class SeriesLanguageFlow {

    /// The paths to the source — the same `PortalSource` on the TV and on the phone.
    nonisolated public struct Routes: Sendable {
        public let read: @Sendable () async throws -> String
        public let list: @Sendable () async throws -> [String]
        public let set: @Sendable (String) async throws -> Void

        public init(
            read: @escaping @Sendable () async throws -> String,
            list: @escaping @Sendable () async throws -> [String],
            set: @escaping @Sendable (String) async throws -> Void
        ) {
            self.read = read
            self.list = list
            self.set = set
        }
    }

    /// The chosen language — empty means: no preference.
    public private(set) var language = ""
    /// The languages in which the series can be watched — empty until they are fetched.
    public private(set) var languages: [String] = []
    public private(set) var isLoading = false

    @ObservationIgnored private let routes: Routes

    public init(routes: Routes) {
        self.routes = routes
    }

    /// Fetch the remembered choice. **For a series that has never been touched, there is
    /// nothing** — and "nothing" is not a malfunction but "no preference".
    public func loadLanguage() async {
        language = (try? await routes.read()) ?? ""
    }

    /// Fetch the options — **only on request, and once.**
    public func loadLanguages() async {
        guard languages.isEmpty, !isLoading else { return }
        isLoading = true
        languages = (try? await routes.list()) ?? []
        isLoading = false
    }

    /// Set the choice. An empty text withdraws it.
    ///
    /// **Immediately in the display, then reported.** The path to the bridge goes through a third-party
    /// site and takes time; a button that flips only afterwards feels broken.
    /// **If the report fails, the old choice is back** — showing it wrongly would be
    /// worse than being slow.
    public func select(_ fresh: String) async {
        let previous = language
        language = fresh
        do {
            try await routes.set(fresh)
        } catch {
            Diagnose.error(
                .playback, "Series language \(fresh) not saved, back to \(previous)", error)
            // **Revert only if nothing newer came in between** (remuxer audit, finding
            // 8, 2026-09-27): without this guard an overtaken failure threw the
            // meanwhile chosen, newer language back to the state BEFORE the
            // overtaken call — the viewer briefly saw the right choice and then
            // the old one again, although their second choice had long since been saved
            // successfully.
            if language == fresh { language = previous }
        }
    }
}
