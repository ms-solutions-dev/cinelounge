import Foundation

/// The events that exist only on a phone.
///
/// Each one can end a playback, and **without recording one sees
/// afterwards only "it stopped"**. The TV has none of them: there nobody
/// calls, nobody pulls out headphones, and memory does not run short.
public enum PhoneEvent: String, CaseIterable, Sendable {

    /// The app went into the background.
    case movedToBackground = "inDenHintergrund"
    /// And back again.
    case returnedToForeground = "zurueckGeholt"
    /// The system has reclaimed memory.
    case memoryWarning = "speicherwarnung"
    /// A call or another sound interrupted.
    case interrupted = "unterbrochen"
    /// Headphones pulled out, speaker switched.
    case audioRouteChanged = "tonwegGewechselt"
    /// WLAN ↔ Mobilfunk.
    case networkChanged = "netzGewechselt"

    /// The sentence that goes into the book.
    public var message: String {
        switch self {
        case .movedToBackground: "moved to the background"
        case .returnedToForeground: "back in the foreground"
        case .memoryWarning: "system memory warning"
        case .interrupted: "playback interrupted (call or foreign audio)"
        case .audioRouteChanged: "audio route changed"
        case .networkChanged: "network path changed"
        }
    }

    /// Where the entry belongs.
    public var area: Area {
        switch self {
        case .movedToBackground, .returnedToForeground, .memoryWarning: .surface
        case .interrupted, .audioRouteChanged: .playback
        case .networkChanged: .network
        }
    }

    /// How severe it is.
    ///
    /// A scene change is a step and is in the book only with verbose recording. A
    /// **memory warning** is a note and is always in it: it is the
    /// harbinger of termination, and whoever asks afterwards why the app restarted
    /// finds the answer here.
    public var severity: Severity {
        switch self {
        case .movedToBackground, .returnedToForeground, .audioRouteChanged: .step
        case .memoryWarning, .interrupted, .networkChanged: .hint
        }
    }

    /// Writes the event to the book.
    public func note(_ extras: String? = nil) {
        let text = extras.map { "\(message) — \($0)" } ?? message
        switch severity {
        case .step: Diagnose.step(area, text)
        default: Diagnose.hint(area, text)
        }
    }
}
