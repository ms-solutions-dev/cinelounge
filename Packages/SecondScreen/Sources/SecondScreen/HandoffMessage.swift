import Core
import Foundation

/// **What a device says when the handoff fails — one set of keys for both sides**
/// (AP58 R5, finding Z1, 2026-09-26).
///
/// **Until then each side mapped ``HandoffWire/TestError`` itself**, with its own
/// keys (`handover.error.*` on the phone, `handover.tv.error.*` on the TV) in two
/// catalogs — and the TV knew only four of the seven cases; the rest said
/// "aborted". Now the board lives here, and the strings live in `WordingKit`.
///
/// **Two sides and not one string per error**, because the same rejection is
/// different advice depending on the viewpoint: A wrong version means on the phone "update the TV" and
/// on the TV "the phone is newer — update this TV". A neutral string
/// for both would lose exactly the information about who has to do something.
public enum HandoffMessage {

    /// Wer den Satz liest.
    public enum Page: Sendable {
        /// The phone that sends a packet.
        case channels
        /// The TV that accepts it.
        case receiver
    }

    /// The catalog key for a rejection — lives in `WordingKit`.
    public static func key(zu error: HandoffWire.TestError, page: Page) -> String {
        switch page {
        case .channels:
            switch error {
            case .noService: "handover.error.unreachable"
            case .timedOut: "handover.error.timeout"
            case .wasCancelled, .rejected(.accepted): "handover.error.aborted"
            case .rejected(.expired): "handover.error.expired"
            case .rejected(.wrongVersion): "handover.error.version"
            case .rejected(.unreadable): "handover.error.unreadable"
            }
        case .receiver:
            switch error {
            case .noService: "handover.error.receiver.noService"
            case .timedOut, .wasCancelled, .rejected(.accepted):
                "handover.error.receiver.aborted"
            case .rejected(.expired): "handover.error.receiver.expired"
            case .rejected(.wrongVersion): "handover.error.receiver.version"
            case .rejected(.unreadable): "handover.error.receiver.unreadable"
            }
        }
    }

    /// The string itself, in the app's language.
    public static func message(zu error: HandoffWire.TestError, page: Page) -> String {
        AppLanguageSetting.word(String.LocalizationValue(key(zu: error, page: page)))
    }
}
