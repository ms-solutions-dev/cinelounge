import Foundation

/// The marks of a channel start in the remuxer — so that the startup line says **where**
/// the time went instead of only how much it was (AP7 · 1).
///
/// Until here the breakdown stood in five single lines (redirect, response, entry, downloads
/// ready, clock starts), and whoever wanted to know whether the provider or the downloads
/// cost the second computed it by hand. Now the session collects the marks, and
/// ``StartupTiming`` writes them as one calculation: "Provider 610 · Keyframe 40 · Downloads
/// 230 · Player 240".
public struct StartupMarks: Sendable, Equatable {
    /// The first reach to the provider.
    public var connected: Date?
    /// The panel's redirect to the edge — missing with a warm address.
    public var redirected: Date?
    /// The first byte of the broadcast.
    public var firstData: Date?
    /// The first keyframe — from here writing is possible.
    public var firstKeyframe: Date?
    /// The downloads with which the session releases the engine.
    public var downloadsReady: Date?
    /// Whether the reach went past the panel directly to the edge (``EdgeMemory``).
    public var warmAddress = false

    public init() {}

    /// The calculation as text — only the sections whose marks are present.
    ///
    /// - Parameters:
    ///   - start: The beginning of startup from the player's point of view.
    ///   - end: The first drawn picture.
    public func breakdown(start: Date, end: Date) -> String {
        func ms(_ a: Date?, _ b: Date?) -> String? {
            guard let a, let b else { return nil }
            return String(format: "%.0f", max(0, b.timeIntervalSince(a)) * 1000)
        }
        var split: [String] = []
        if let s = ms(start, firstData) {
            split.append("Provider \(s)" + (warmAddress ? " (warm)" : ""))
        }
        if let s = ms(firstData, firstKeyframe) { split.append("Keyframe \(s)") }
        if let s = ms(firstKeyframe ?? firstData, downloadsReady) { split.append("Buffer \(s)") }
        if let s = ms(downloadsReady, end) { split.append("Player \(s)") }
        return split.joined(separator: " · ")
    }
}
