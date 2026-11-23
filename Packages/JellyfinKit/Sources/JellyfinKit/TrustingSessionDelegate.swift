import Core
import Foundation
import Security

/// Decides at connection setup whether a certificate is trusted.
///
/// Only steps in when the usual check fails — that is, with self-issued certificates, as
/// are common on home networks. Valid certificates go through the system's check as
/// always.
///
/// Explicitly **not** done is what many guides suggest: accepting everything across the
/// board. That would be an open barn door for anyone on the same network. Instead the
/// fingerprint is compared with what the user confirmed once.
/// It also measures **how** a connection came about — see
/// ``urlSession(_:task:didFinishCollecting:)``.
public final class TrustingSessionDelegate: NSObject, URLSessionDelegate,
    URLSessionTaskDelegate, Sendable
{

    private let trustStore: CertificateTrustStore

    public init(trustStore: CertificateTrustStore = CertificateTrustStore()) {
        self.trustStore = trustStore
    }

    /// From what duration on a **successful** request is recorded anyway.
    ///
    /// On the home network the media server answers in milliseconds. Three seconds are
    /// therefore nothing that would need explaining — they are a finding.
    static let slowThreshold: TimeInterval = 3

    /// Records how the connection came about.
    ///
    /// **This method is the answer to a troubleshooting that went in circles.** From the TV
    /// the same fetch ran into the timeout twice in a row, which a computer on the same
    /// network got answered in fifty milliseconds. "Timeout" alone does not reveal what the
    /// cause was — these numbers do:
    ///
    /// - **Reused, no first byte:** written onto a dead connection. tvOS frees sockets when
    ///   the app goes to the background ("socket resource reclaim", Technote 2277), but
    ///   keeps remembering them; the next request on one hangs until the timeout, without an
    ///   error. A known problem without an official remedy — Apple's own advice is to catch
    ///   it.
    /// - **New connection, setup takes long:** the network itself is the problem, not the
    ///   reuse.
    /// - **First byte came quickly, then standstill:** the server started and did not finish
    ///   delivering — then it is the server or the line in between.
    ///
    /// Only what stands out is recorded. A Home screen triggers dozens of requests; entering
    /// each would mean filling the ring buffer with trivia and losing the one line that
    /// matters.
    ///
    /// With verbose recording (``DebugMode``) the opposite holds, on purpose: then **every**
    /// request goes in, including the successful one. For the search for a stutter, the time
    /// to first byte of the fetches that went well is exactly the measurement that is
    /// otherwise missing — the trace grows accordingly.
    public func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didFinishCollecting metrics: URLSessionTaskMetrics
    ) {
        guard let url = task.originalRequest?.url,
            let transaction = metrics.transactionMetrics.last
        else { return }

        let failed = task.error != nil
        let duration = metrics.taskInterval.duration
        guard
            let step = Self.recordingStep(
                failed: failed,
                duration: duration,
                verbose: DebugMode.current.isOn
            )
        else { return }

        // The values are extracted **here** and not passed on: `URLSessionTaskMetrics` cannot be
        // transferred across thread boundaries, and the entry lands on the main thread.
        let connect: TimeInterval? =
            if let start = transaction.connectStartDate, let end = transaction.connectEndDate {
                end.timeIntervalSince(start)
            } else {
                nil
            }
        let firstByte: TimeInterval? =
            if let start = transaction.requestStartDate,
                let response = transaction.responseStartDate
            {
                response.timeIntervalSince(start)
            } else {
                nil
            }

        Diagnostics.connection(
            url,
            step: step,
            facts: Diagnostics.ConnectionFacts(
                reused: transaction.isReusedConnection,
                networkProtocol: transaction.networkProtocolName,
                remoteAddress: transaction.remoteAddress,
                connectDuration: connect,
                timeToFirstByte: firstByte,
                bytes: transaction.countOfResponseBodyBytesReceived
            )
        )
    }

    /// Under which step a request goes into the trace — or `nil` for none.
    ///
    /// Extracted as a function of its own so the rule is checkable without reproducing a
    /// `URLSession` with its metrics. The ranking is deliberate: a failure stays a failure and
    /// a slow request a slow one, even when verbose recording is on — otherwise the finding
    /// would vanish into the uniform gray of the "request" lines.
    static func recordingStep(failed: Bool, duration: TimeInterval, verbose: Bool) -> String? {
        if failed { return "Connection on failure" }
        if duration >= slowThreshold { return "Slow request" }
        return verbose ? "Anfrage" : nil
    }

    public func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge
    ) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {

        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
            let serverTrust = challenge.protectionSpace.serverTrust
        else {
            return (.performDefaultHandling, nil)
        }

        let host = challenge.protectionSpace.host

        // The regular check first. If the certificate is valid anyway, there is nothing to
        // decide.
        var error: CFError?
        if SecTrustEvaluateWithError(serverTrust, &error) {
            return (.performDefaultHandling, nil)
        }

        guard let fingerprint = Self.fingerprint(of: serverTrust) else {
            Diagnostics.network.error(
                "Certificate from \(host, privacy: .public) unreadable — rejected"
            )
            return (.cancelAuthenticationChallenge, nil)
        }

        switch trustStore.evaluate(fingerprint, for: host) {
        case .accept:
            Diagnostics.network.info(
                "Certificate from \(host, privacy: .public) is confirmed — accepted"
            )
            return (.useCredential, URLCredential(trust: serverTrust))

        case .askUser:
            // Nothing is decided here: the connection fails, and the UI asks the user. Only after
            // their confirmation does the branch above take effect on the next attempt.
            //
            // **And now it also learns about it** (AP5 · B4): until 2026-09-02 this branch ended in the
            // log — the fingerprint was lost on the way to the UI, because only a `URLError` arrives
            // there. The four translated sentences `cert.*` had stood unused in the language file
            // ever since. See ``CertificatePrompt``.
            Diagnostics.network.error(
                "Certificate from \(host, privacy: .public) unknown (\(fingerprint.short, privacy: .public)) — confirmation needed"
            )
            CertificatePrompt.shared.location(
                CertificatePrompt.Pending(host: host, fingerprint: fingerprint))
            return (.cancelAuthenticationChallenge, nil)

        case .changed(let known, _):
            Diagnostics.network.error(
                """
                Certificate from \(host, privacy: .public) has changed. \
                Known was \(known.short, privacy: .public), presented was \
                \(fingerprint.short, privacy: .public). Rejected.
                """
            )
            // **The changed certificate is asked about too, not concealed** — but with the known one
            // next to it. That is the case the whole procedure was built for: an attacker on the
            // same network would be noticed here, and the viewer should be able to see them.
            CertificatePrompt.shared.location(
                CertificatePrompt.Pending(
                    host: host, fingerprint: fingerprint, known: known))
            return (.cancelAuthenticationChallenge, nil)
        }
    }

    /// Reads the fingerprint of the certificate the server presents.
    public static func fingerprint(of trust: SecTrust) -> CertificateFingerprint? {
        guard let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
            let leaf = chain.first
        else { return nil }

        let data = SecCertificateCopyData(leaf) as Data
        return CertificateFingerprint(certificateData: data)
    }
}
