import Foundation

/// A chapter marker, as the server keeps it.
///
/// Jellyfin reads them from the container (Matroska and MP4 carry chapters) or
/// generates them itself. For the app they are jump targets: from button to button
/// through the film, without aiming on the scrub bar.
public struct Chapter: Sendable, Equatable, Hashable, Codable {

    /// The name of the marker — often just "Chapter 3", in which case it contributes nothing.
    public var title: String?
    /// Beginn in Sekunden ab Filmanfang.
    public var start: TimeInterval
    /// Identifier of the thumbnail image the server extracted for the marker.
    /// Optional: the "Extract chapter images" task must have run.
    public var imageTag: String?

    public init(title: String? = nil, start: TimeInterval, imageTag: String? = nil) {
        self.title = title
        self.start = start
        self.imageTag = imageTag
    }
}

extension [Chapter] {

    /// How far past a chapter start "back" still means the same chapter.
    ///
    /// Whoever presses back four seconds after the chapter start wants **its**
    /// start — whoever presses again right after wants the chapter before.
    /// Without this grace period you would never get further than the current start:
    /// every press would land where the previous one led.
    public static var replayGrace: TimeInterval { 4 }

    /// The start of the next chapter after this position, or `nil` at the end.
    ///
    /// With a two-second lead: whoever stands exactly on a chapter start
    /// does not mean the one after next by "forward" — but certainly the next.
    public func nextStart(after position: TimeInterval) -> TimeInterval? {
        map(\.start)
            .sorted()
            .first { $0 > position + 2 }
    }

    /// The start of the current or previous chapter — see ``replayGrace``.
    public func previousStart(before position: TimeInterval) -> TimeInterval? {
        map(\.start)
            .sorted()
            .last { $0 < position - Self.replayGrace }
    }
}
