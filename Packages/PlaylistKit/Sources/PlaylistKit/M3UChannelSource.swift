import Core
import Foundation

/// A channel list that exists as an M3U file — local or via an address.
///
/// The parsing lives in ``M3UParser``; only the fetching is added here, and the
/// handling of what goes wrong in the process.
///
/// **The program guide does not come along.** An M3U contains no air times,
/// only channels. Where a provider supplies an XMLTV file for it, its
/// address is in ``Playlist/epgURL`` and is fetched separately — see
/// ``XMLTVParser``. That is why ``programmes(for:around:)`` returns nothing here,
/// instead of pretending there was a program.
public actor M3UChannelSource: ChannelSource {

    public enum Failure: Error, Equatable {
        case unreachable
        /// Fetched, but there were no channels in it. To be distinguished from
        /// "not reachable": In one case the address is wrong, in the other the
        /// file — and the user has to do different things.
        case empty

        public var messageKey: String {
            switch self {
            case .unreachable: "error.unreachable"
            case .empty: "error.playlistEmpty"
            }
        }
    }

    public let playlist: Playlist
    private let source: URL
    private let session: URLSession

    private var cached: [Channel]?

    public init(playlist: Playlist, url: URL) {
        self.playlist = playlist
        self.source = url

        let config = URLSessionConfiguration.default
        // More generous than usual: A list with a few thousand channels is
        // several megabytes in size, and such providers deliver slowly.
        config.timeoutIntervalForRequest = 60
        config.urlCache = URLCache(
            memoryCapacity: 2 * 1024 * 1024,
            diskCapacity: 100 * 1024 * 1024,
            diskPath: "cinelounge.m3u"
        )
        self.session = URLSession(configuration: config)
    }

    public func channels() async throws -> [Channel] {
        if let cached { return cached }

        let text = try await load()
        let channels = M3UParser.parse(text, playlistID: playlist.id)

        guard !channels.isEmpty else { throw Failure.empty }

        cached = channels
        return channels
    }

    /// An M3U knows no air times. See the explanation on the type.
    public func programmes(for channelID: String, around date: Date) async throws -> [Programme] {
        []
    }

    public func invalidateCache() {
        cached = nil
        session.configuration.urlCache?.removeAllCachedResponses()
    }

    // MARK: - Holen

    private func load() async throws -> String {
        // A file in the file system — for example one that the user puts there themselves.
        if source.isFileURL {
            guard let text = try? String(contentsOf: source, encoding: .utf8) else {
                throw Failure.unreachable
            }
            return text
        }

        Diagnostics.attempt(source, step: "Fetch channel list")

        do {
            let (data, response) = try await session.data(from: source)
            if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                Diagnostics.network.error("Channel list answered with \(http.statusCode)")
                throw Failure.unreachable
            }

            // First UTF-8, then Windows-1252 as a fallback.
            //
            // The reason is mundane but widespread: Many lists are produced on
            // Windows and contain umlauts in that platform's character encoding.
            // Without a fallback the file would not be readable although it is fine —
            // and the message would say "not reachable", which would be wrong.
            if let text = String(data: data, encoding: .utf8) {
                return text
            }
            if let text = String(data: data, encoding: .windowsCP1252) {
                Diagnostics.network.info("Channel list was not encoded in UTF-8")
                return text
            }
            throw Failure.unreachable
        } catch let failure as Failure {
            throw failure
        } catch {
            Diagnostics.failure(source, step: "Fetch channel list", error: error)
            throw Failure.unreachable
        }
    }
}
