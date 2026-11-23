import Core
import Foundation
import YouTubeKit

/// Resolves a YouTube key to the address that AVPlayer plays (AP78, 2026-10-11).
///
/// **HLS first, file only as a fallback — measured on 2026-10-11 on the Mac:** After 1.7 s YouTubeKit
/// returns an HLS manifest with all steps from 144p to 2160p and its own
/// audio tracks; AVPlayer picks the step matching the connection, as with any channel. The
/// "progressive" files (picture and sound in one file), in contrast, exist only in 360p —
/// at three metres' distance a postage stamp. That is why the file is the way only when the
/// manifest is missing.
///
/// Without remote fallback (`methods: [.local]`): YouTubeKit's fallback would run via a
/// third-party relay service, through which every request of the device would go. If local
/// resolution fails, the board says so, and the trailer plays in the YouTube app.
public enum TrailerResolution {

    public enum TestError: Error, Equatable {
        /// YouTubeKit answered, but found nothing playable — no manifest,
        /// no file with picture and sound that the system player can handle.
        case nothingPlayable
        /// YouTubeKit itself failed (block, age gate, changed page).
        case youtube(String)
    }

    /// The playable address and, for the record, what it turned out to be.
    public struct Address: Sendable, Equatable {
        public enum Route: Sendable, Equatable {
            case hls
            /// File with picture and sound, height in pixels (360 means: 360p).
            case file(height: Int?)
        }
        public let url: URL
        public let route: Route

        public init(url: URL, route: Route) {
            self.url = url
            self.route = route
        }
    }

    /// A file step as YouTubeKit reports it — as a form of its own, so the choice stays testable without
    /// YouTubeKit (its `Stream` cannot be built from outside).
    public struct FileTier: Sendable, Equatable {
        public let url: URL
        public let height: Int?
        public let videoAndAudio: Bool
        public let nativelyPlayable: Bool

        public init(url: URL, height: Int?, videoAndAudio: Bool, nativelyPlayable: Bool) {
            self.url = url
            self.height = height
            self.videoAndAudio = videoAndAudio
            self.nativelyPlayable = nativelyPlayable
        }
    }

    public static func address(youtubeID: String) async throws -> Address {
        let started = Date()
        let video = YouTube(videoID: youtubeID, methods: [.local])
        let manifests: [URL]
        do {
            manifests = try await video.livestreams.filter { $0.streamType == .hls }.map(\.url)
        } catch {
            Diagnostics.network.error(
                "Trailer \(youtubeID, privacy: .public): YouTubeKit fails on the manifest: \(error.localizedDescription, privacy: .public)"
            )
            throw TestError.youtube(error.localizedDescription)
        }
        if let manifest = manifests.first {
            Diagnostics.network.info(
                "Trailer \(youtubeID, privacy: .public): HLS after \(Int(Date().timeIntervalSince(started) * 1000)) ms"
            )
            return Address(url: manifest, route: .hls)
        }
        let slots: [FileTier]
        do {
            slots = try await video.streams.map {
                FileTier(
                    url: $0.url, height: $0.videoResolution,
                    videoAndAudio: $0.includesVideoAndAudioTrack,
                    nativelyPlayable: $0.isNativelyPlayable && $0.fileExtension == .mp4)
            }
        } catch {
            Diagnostics.network.error(
                "Trailer \(youtubeID, privacy: .public): YouTubeKit fails on the files: \(error.localizedDescription, privacy: .public)"
            )
            throw TestError.youtube(error.localizedDescription)
        }
        guard let file = choice(slots) else {
            Diagnostics.network.error(
                "Trailer \(youtubeID, privacy: .public): \(slots.count) tiers, none with picture and sound")
            throw TestError.nothingPlayable
        }
        Diagnostics.network.info(
            "Trailer \(youtubeID, privacy: .public): File \(file.height ?? 0)p after \(Int(Date().timeIntervalSince(started) * 1000)) ms"
        )
        return Address(url: file.url, route: .file(height: file.height))
    }

    /// The highest file with picture **and** sound that the system player can handle. A pure picture
    /// or pure audio track (DASH) does not help: AVPlayer does not join the two.
    public static func choice(_ slots: [FileTier]) -> FileTier? {
        slots.filter { $0.videoAndAudio && $0.nativelyPlayable }.max { ($0.height ?? 0) < ($1.height ?? 0) }
    }

    /// The jump into the YouTube app — only if it is installed, the caller checks
    /// via `canOpenURL` (scheme `youtube` is in the Info.plist).
    public static func youtubeApp(_ youtubeID: String) -> URL? {
        URL(string: "youtube://watch?v=" + youtubeID)
    }

    public static func youtubePage(_ youtubeID: String) -> URL? {
        URL(string: "https://www.youtube.com/watch?v=" + youtubeID)
    }
}
