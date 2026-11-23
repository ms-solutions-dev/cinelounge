import Core
import Diagnose
import Foundation
import PlaylistKit

/// The channels of a provider credential — via the shared ``LiveLibrary``.
///
/// **Of 666 lines of the TV's `LiveModel`, none moves here, and that is no
/// oversight.** Recounted on 2026-09-05: the file has 298 lines of program, the rest is
/// reasoning; of those, 22 are TV-specific (focus, dwell time, Combine). The
/// essential part has long lived in shared packages — `LiveLibrary` (1,324 lines),
/// `LivePreferences` (230), `ChannelName` (198). The roadmap assumed the big chunk
/// was the model; the big chunk was already shared, and the model was the wrapper
/// around it.
///
/// This file is therefore thin: it translates between the library and what the
/// view needs — there was nothing more to gain.
public struct ProviderChannelSource: ChannelListingSource {

    private let library: LiveLibrary
    /// The list store — **only for the favorites.**
    ///
    /// `LiveLibrary` reads them when loading (`refreshedFavorites`), but cannot set
    /// them: the store does that. Both point to the same slot, and that is why a
    /// second one is ruled out here — ``SourceAssembly`` passes the same one through.
    private let listen: PlaylistStore?

    public init(library: LiveLibrary, listen: PlaylistStore? = nil) {
        self.library = library
        self.listen = listen
    }

    public func channels() async -> ChannelCatalog {
        let result = await library.load()
        if !result.issues.isEmpty {
            Diagnose.step(
                .network, "Live: \(result.issues.count) list(s) without a reply")
        }
        return ChannelCatalog(
            channels: result.channels, silent: result.issues.map(\.playlistName))
    }

    public func program(forItem channels: [Channel]) async -> [String: [Programme]] {
        await library.storedProgrammes(for: channels)
    }

    public func freshProgramme() async -> Int {
        let count = await library.syncGuide()
        Diagnose.step(.network, "Live: guide matched — \(count) programmes")
        return count
    }

    public func sport(from: Date, until: Date) async -> [SportEvent] {
        // **With timing, because the first version was impossible to assess without it.**
        // On 2026-09-06 the schedule sat in the loading state for six minutes, at 0 % processor —
        // and the log stayed silent. Without a start and an end in the recording, "still computing"
        // cannot be told from "hung", and exactly these two cases
        // look the same on screen.
        Diagnose.step(.network, "Live: schedule requested")
        let start = Date()
        let found = await library.sportEvents(from: from, to: until)
        Diagnose.step(
            .network,
            "Live: schedule ready — \(found.count) events in "
                + String(format: "%.1f", Date().timeIntervalSince(start)) + " s")
        return found
    }

    public func address(forItem channels: Channel) async -> URL {
        let raw = channels.streamURL
        guard raw.pathExtension.lowercased() == "m3u8" else { return raw }
        let isAllowed = await Self.allowsHLS(listen, channels.playlistID)
        if !isAllowed {
            Diagnose.step(.playback, "Channel: access does not allow m3u8 — raw stream (ts)")
        }
        return Self.address(forItem: channels, allowsHLS: isAllowed, store: SecureStore())
    }

    /// **The same choice as on the TV** (AP58 R4, ``Core/ChannelAddressChoice``): besides the
    /// credential, the watchlist and the raw-stream rule count — today only the TV maintains both,
    /// but they are read here all the same. A function of its own, so that the check guards this half on
    /// the phone the way `LiveModelTests` does on the TV.
    static func address(
        forItem channels: Channel, allowsHLS: Bool, store: any KeyValueStore
    ) -> URL {
        ChannelAddressChoice.address(
            forItem: channels.streamURL, name: channels.name, allowsHLS: allowsHLS, store: store)
    }

    /// Whether this credential yields HLS lists — **asked once, then remembered.**
    ///
    /// The answer does not change as long as the credential is the same; fetching it anew for every
    /// channel would be one request per switch. If the panel does not answer at
    /// all, "yes" applies — the same direction as in `AccountInfo.allowsHLS`: whoever says
    /// nothing is not refuted.
    private static let remembered = FormatMemory()

    static func allowsHLS(_ listen: PlaylistStore?, _ listID: String) async -> Bool {
        if let known = await remembered.value(listID) { return known }
        guard let listen else { return true }
        let found = await MainActor.run { () -> (Playlist, XtreamEndpoint)? in
            guard let list = listen.playlists.first(where: { $0.id == listID }),
                case .xtream(let address, _) = list.kind,
                let credential = listen.credentials(for: listID)
            else { return nil }
            return (
                list,
                XtreamEndpoint(
                    server: address, username: credential.username, password: credential.password)
            )
        }
        guard let (list, credential) = found else { return true }
        let reply = (try? await XtreamClient(playlist: list, credentials: credential).verify())
        let isAllowed = reply?.allowsHLS ?? true
        Diagnose.step(
            .network,
            "Access: allowed extensions "
                + (reply?.allowedOutputFormats?.joined(separator: ", ") ?? "not named"))
        await remembered.memorize(isAllowed, forItem: listID)
        return isAllowed
    }

    /// What a credential yields in extensions — per list, across the program run.
    ///
    /// An actor and not a dictionary: two channels can start at the same time, and two
    /// simultaneous write accesses to the same board would be exactly the error that
    /// strict concurrency is meant to prevent.
    actor FormatMemory {
        private var board: [String: Bool] = [:]
        func value(_ list: String) -> Bool? { board[list] }
        func memorize(_ isAllowed: Bool, forItem list: String) { board[list] = isAllowed }
    }

    public func setEnabled(favorite channels: Channel) async -> Bool {
        guard let listen else { return channels.isFavorite }
        let new = await MainActor.run { () -> Bool in
            listen.toggleFavorite(channels)
            return listen.isFavorite(channels)
        }
        Diagnose.step(
            .network, "Live: \(channels.favoriteName) " + (new ? "remembered" : "no longer remembered"))
        return new
    }

    /// The window of the program grid **from the cache** — the same query as on the TV.
    public func gridProgramme(
        forItem channels: [Channel], from: Date, until: Date
    ) async -> [String: [Programme]] {
        await library.storedProgrammes(for: channels, from: from, to: until)
    }

    public func dailyProgramme(forItem channels: Channel) async -> [Programme] {
        // **The path of the shared library, not one of its own.** It asks the
        // cache first and goes to the network only if nothing is stored there — and without a
        // EPG ID it does not ask at all, because the provider answers that with an
        // empty list instead of an error.
        await library.programmes(for: channels)
    }

    public func downloadsState() async -> ProgrammeState {
        // The window does not matter here: what is asked for is the **full catalog** and when
        // it was fetched, not how much of it falls into the next few hours. The
        // library requires a span all the same — the current day is used.
        let now = Date()
        let state = await library.downloadsState(
            from: now.addingTimeInterval(-12 * 3600), to: now.addingTimeInterval(12 * 3600))
        return ProgrammeState(broadcasts: state.broadcasts, recent: state.lastFetched)
    }
}
