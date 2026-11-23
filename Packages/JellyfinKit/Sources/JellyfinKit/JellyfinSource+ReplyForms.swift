import Foundation

extension JellyfinSource {

    // MARK: - Antwortformen

    // Moved out on 2026-09-02. (AP18). Pure shapes without behavior — the same
    // reasoning as at ``JellyfinSource+Order``.

    /// Three reports, three shapes — although the fields overlap.
    ///
    /// The server has three endpoints for this and not one with a flag, and
    /// the shapes really do differ: Only the start carries `CanSeek`,
    /// only the progress carries `IsPaused`. A shared shape would have to always
    /// send both and, on sign-out, would claim a pause state
    /// that no longer exists then.

    // The session identifiers appear in all three shapes and are optional: If
    // the handshake is missing — for instance because `PlaybackInfo` did not answer —, the
    // report goes out without them, and the server only assigns it to the title. With
    // them it is tied to the encoding, and the encoding's survival depends on exactly that.

    struct PlaybackStartReport: Encodable {
        let itemId: String
        let positionTicks: Int
        let canSeek: Bool
        let playSessionId: String?
        let mediaSourceId: String?

        enum CodingKeys: String, CodingKey {
            case itemId = "ItemId"
            case positionTicks = "PositionTicks"
            case canSeek = "CanSeek"
            case playSessionId = "PlaySessionId"
            case mediaSourceId = "MediaSourceId"
        }
    }

    struct ProgressReport: Encodable {
        let itemId: String
        let positionTicks: Int
        let isPaused: Bool
        let playSessionId: String?
        let mediaSourceId: String?

        enum CodingKeys: String, CodingKey {
            case itemId = "ItemId"
            case positionTicks = "PositionTicks"
            case isPaused = "IsPaused"
            case playSessionId = "PlaySessionId"
            case mediaSourceId = "MediaSourceId"
        }
    }

    struct PlaybackStopReport: Encodable {
        let itemId: String
        let positionTicks: Int
        let playSessionId: String?
        let mediaSourceId: String?

        enum CodingKeys: String, CodingKey {
            case itemId = "ItemId"
            case positionTicks = "PositionTicks"
            case playSessionId = "PlaySessionId"
            case mediaSourceId = "MediaSourceId"
        }
    }
}
