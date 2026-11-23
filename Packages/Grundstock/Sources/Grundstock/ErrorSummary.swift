import Foundation

/// Translates an error into **one sentence for the viewer** — and thereby separates it
/// from what belongs in the diagnostics.
///
/// **The finding** (AP5 · B6, expert review 2026-08-24): On the TV there
/// stood in red 25 pt `badRequest`, `badStatus(400)`, `Netzwerkfehler -999`,
/// `containerNotNativelySupported` and `Reply 407` — plus twice an `NSError` dump
/// about 700 characters long with memory addresses. And
/// ``Diagnostics/explain(_:)`` prints, for a transport-security error,
/// an instruction to the developer into the living room: "Check: Is
/// NSAllowsArbitraryLoads in the Info.plist …". The label next to it
/// promises "the cause in plain text".
///
/// **Two readers, two texts.** ``Diagnostics/explain(_:)`` stays as it is —
/// it writes into the trace, and there the error code is the information. Here
/// the sentence for the screen is produced: as a **key** and not as text,
/// because translation happens in the app and not in the computation core.
///
/// **What the viewer wants to know is not the code but the direction:**
/// Is it them, their network, the server or the provider? No error message
/// carries more, and less is not enough.
public enum ErrorSummary {

    /// How long an accompanying addendum may be at most.
    ///
    /// Two hundred characters — the `NSError` dump came to about 700, with
    /// memory addresses in it. Nobody reads anything longer on the TV, and
    /// it is not needed there anyway: the whole line is in the trace.
    public static let maxLength = 200

    /// The language key for an error.
    ///
    /// - Parameter status: The response status, if the error carries one. Which
    ///   error types know a status is known only to the program — `Core` reads it
    ///   from its remuxer refusals, the reading app from its server responses.
    ///   That is why it comes from outside and is not guessed here.
    public static func key(forItem error: Error, status: Int?) -> String {
        if let url = error as? URLError {
            switch url.code {
            case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed:
                return "fehler.netz"
            case .timedOut:
                return "fehler.langsam"
            case .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed:
                return "fehler.unerreichbar"
            case .secureConnectionFailed, .serverCertificateUntrusted,
                .serverCertificateHasBadDate, .serverCertificateHasUnknownRoot,
                .appTransportSecurityRequiresSecureConnection:
                return "fehler.zertifikat"
            case .userAuthenticationRequired:
                return "fehler.zugang"
            default:
                return "fehler.allgemein"
            }
        }
        // The provider's refusals: they are not a network question but a
        // question of authorization — and that is the only information the
        // viewer can do anything with.
        if let status {
            if isPermissionDenial(status) { return "fehler.zugang" }
            if (500..<600).contains(status) { return "fehler.serverstoerung" }
            return "fehler.allgemein"
        }
        return "fehler.allgemein"
    }

    /// Whether a status is information about **authorization**.
    ///
    /// 401, 402, 403 and 407 say: "You may not." That does not change in the
    /// next few seconds, and every further request goes to the same account.
    /// Other error statuses are not a refusal in this sense: a 500 may succeed on the
    /// next attempt.
    public static func isPermissionDenial(_ status: Int) -> Bool {
        [401, 402, 403, 407].contains(status)
    }

    /// The addendum under the sentence — shortened and without address.
    ///
    /// **Empty rather than raw:** Where nothing readable remains, nothing is shown.
    /// A truncated `NSError` dump is not half an answer but
    /// complete confusion.
    public static func extras(_ error: Error) -> String? {
        guard let raw = Diagnostics.withoutAddress("\(error)") else { return nil }
        let clean = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return nil }
        guard clean.count > maxLength else { return clean }
        return String(clean.prefix(maxLength)) + " …"
    }
}
