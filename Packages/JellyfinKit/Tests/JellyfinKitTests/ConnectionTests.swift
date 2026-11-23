import Core
import Foundation
import Testing

@testable import JellyfinKit

/// What is checked is what can be checked without a running server: the preparation of
/// the typed address and the header line entry. Both are places where errors would only
/// be noticed by the user — a swallowed address leads to "not reachable" although the
/// server is running.
@Suite("Server connection")
struct ConnectionTests {

    @Test(
        "A typed address is completed to a valid one",
        arguments: [
            ("192.0.2.44:8096", "http://192.0.2.44:8096"),
            ("jellyfin.example", "http://jellyfin.example"),
            ("http://jellyfin.example", "http://jellyfin.example"),
            ("https://jellyfin.example", "https://jellyfin.example"),
            // Nobody likes typing the protocol on a TV.
            ("  jellyfin.example  ", "http://jellyfin.example"),
            // A trailing slash would otherwise double with every call.
            ("http://jellyfin.example/", "http://jellyfin.example"),
        ]
    )
    func normalizeAddress(input: String, expected: String) {
        let url = JellyfinConnection.normalizeAddress(input)

        #expect(url?.absoluteString == expected)
    }

    @Test("Unusable input yields no address")
    func rejectsGarbage() {
        #expect(JellyfinConnection.normalizeAddress("") == nil)
        #expect(JellyfinConnection.normalizeAddress("   ") == nil)
        #expect(JellyfinConnection.normalizeAddress("http://") == nil)
    }

    @Test("The header entry names application and device")
    func authorizationHeader() {
        let header = JellyfinConnection.authorizationHeader(
            deviceID: "ABC-123",
            deviceName: "Wohnzimmer"
        )

        #expect(header.contains(#"Client="CineLounge""#))
        #expect(header.contains(#"Device="Wohnzimmer""#))
        #expect(header.contains(#"DeviceId="ABC-123""#))
        // Without sign-in no access token may be sent along.
        #expect(!header.contains("Token="))
    }

    @Test("With an access token it is appended")
    func authorizationHeaderWithToken() {
        let header = JellyfinConnection.authorizationHeader(
            deviceID: "ABC-123",
            deviceName: "Wohnzimmer",
            token: "geheim"
        )

        #expect(header.contains(#"Token="geheim""#))
    }

    @Test("Every failure case has its own translation key")
    func distinctMessages() {
        // On the TV it must say *what* is wrong. A common "sign-in failed" for all cases would
        // be worthless.
        let failures: [JellyfinConnection.Failure] = [
            .invalidAddress, .unreachable, .notAJellyfinServer,
            .wrongCredentials, .timedOut, .server(status: 500),
        ]
        let keys = Set(failures.map(\.messageKey))

        #expect(keys.count == failures.count, "no key twice")
        #expect(keys.allSatisfy { $0.hasPrefix("error.") })
    }
}

@Suite("Credentials")
struct CredentialsTests {

    @Test("Credentials survive encoding")
    func roundTrip() throws {
        let original = ServerCredentials(
            serverURL: URL(string: "http://192.0.2.44:8096")!,
            userID: "f00dfeedf00dfeedf00dfeedf00dfeed",
            username: "livingroom",
            accessToken: "abc123"
        )

        let data = try JSONEncoder().encode(original)
        let restored = try JSONDecoder().decode(ServerCredentials.self, from: data)

        #expect(restored == original)
    }

    @Test("The password is not stored along")
    func noPasswordStored() throws {
        // Only the server's access token is kept. That allows a lost device to be locked out
        // server-side without changing the password.
        let credentials = ServerCredentials(
            serverURL: URL(string: "http://example.local")!,
            userID: "u",
            username: "name",
            accessToken: "token"
        )
        let json = try String(data: JSONEncoder().encode(credentials), encoding: .utf8) ?? ""

        #expect(!json.lowercased().contains("password"))
        #expect(!json.lowercased().contains("\"pw\""))
    }

    @Test("The store saves, reads and deletes")
    func storeRoundTrip() throws {
        // Volatile store instead of Keychain: access to the real Keychain makes the test run
        // hang on a computer, because an approval is expected there — without an error message,
        // it just stands. That the Keychain itself holds up is shown by the run on the device.
        let store = InMemoryStore()
        let key = "probe"

        try store.set("Wert", for: key)
        #expect(try store.value(for: key) == "Wert")

        // Writing again must replace, not fail.
        try store.set("Neu", for: key)
        #expect(try store.value(for: key) == "Neu")

        try store.remove(key)
        #expect(throws: SecureStore.Failure.notFound) { try store.value(for: key) }
    }

    @Test("Missing entries report that instead of guessing")
    func missingEntry() {
        #expect(throws: SecureStore.Failure.notFound) {
            try InMemoryStore().value(for: "gibtesnicht")
        }
    }
}

@Suite("Sign-in by code")
struct QuickConnectTests {

    @Test("The code is shown in groups of two")
    func groupedCode() {
        // Six digits in a row are hard to read from three meters away and even harder to type
        // into the phone without errors.
        let session = QuickConnect.Session(code: "485677", secret: "geheim")

        #expect(session.groupedCode == "48 56 77")
    }

    @Test("Odd code lengths do not break the display either")
    func oddLength() {
        #expect(QuickConnect.Session(code: "12345", secret: "s").groupedCode == "12 34 5")
        #expect(QuickConnect.Session(code: "1", secret: "s").groupedCode == "1")
        #expect(QuickConnect.Session(code: "", secret: "s").groupedCode == "")
    }

    @Test("The secret does not appear in the display")
    func secretStaysHidden() {
        // Whoever reads off the code must not be able to do anything with it — only the secret
        // authorizes redeeming, and that stays in the device.
        let session = QuickConnect.Session(code: "485677", secret: "C1BBFA13BD2E78A3")

        #expect(!session.groupedCode.contains("C1BBFA"))
        #expect(session.code == "485677")
    }

    @Test("Every failure case has its own translation key")
    func distinctMessages() {
        let failures: [QuickConnect.Failure] = [.notEnabled, .expired, .unreachable]
        #expect(Set(failures.map(\.messageKey)).count == failures.count)
    }
}

@Suite("Robustness while waiting")
struct QuickConnectResilienceTests {

    @Test("Isolated network dropouts do not end the wait")
    func toleratesHiccups() async throws {
        // Over a shaky line a single poll fails constantly. If the loop broke off at the first
        // failure, sign-in would never come about — that was exactly the bug.
        let quickConnect = QuickConnect(timeout: 1)
        let unreachable = URL(string: "http://192.0.2.1:8096")!  // address reserved for tests

        let started = ContinuousClock.now
        await #expect(throws: QuickConnect.Failure.self) {
            _ = try await quickConnect.waitForApproval(
                server: unreachable,
                session: .init(code: "000000", secret: "s"),
                deviceID: "test",
                deviceName: "Test",
                interval: .milliseconds(10),
                timeout: .seconds(30)
            )
        }
        let elapsed = started.duration(to: .now)

        // Only after several failures is it given up — not immediately.
        #expect(elapsed > .milliseconds(30), "it was tried more than once")
        // And not until the full waiting time has run out.
        #expect(elapsed < .seconds(25))
    }
}

@Suite("Address variants")
struct AddressCandidateTests {

    @Test("Without a port plain text and TLS are both tried — plain text first")
    func addsDefaultPort() throws {
        // Background: behind a name like jellyfin.lan there is often an upstream proxy on
        // port 80 that redirects to encrypted connections — whose self-issued certificates no
        // Apple device trusts. The server itself listens on 8096.
        //
        // Since G2 the two TLS variants stand behind it: a server that answers only encrypted
        // was otherwise unreachable from a short form. They stand LAST because on a home
        // network the plaintext case is the normal one, and a TLS attempt placed first cost a
        // timeout at every start.
        let url = try #require(JellyfinConnection.normalizeAddress("jellyfin.example"))
        let candidates = JellyfinConnection.candidates(for: url)

        #expect(
            candidates.map(\.absoluteString) == [
                "http://jellyfin.example",
                "http://jellyfin.example:8096",
                "https://jellyfin.example",
                "https://jellyfin.example:8920",
            ])
    }

    /// **An explicit `https` is never taken back to `http`.**
    ///
    /// The version up to 2026-09-07 appended `http://host:8096` to every input without a port —
    /// even to one that began with `https://`. A connection the user had requested
    /// encrypted thereby came about unnoticed in plaintext as soon as the TLS path stayed
    /// silent.
    @Test("Explicit https does not fall back to http")
    func neverDowngradesExplicitHTTPS() throws {
        let url = try #require(JellyfinConnection.normalizeAddress("https://media.example"))
        let candidates = JellyfinConnection.candidates(for: url)

        #expect(candidates.allSatisfy { $0.scheme == "https" })
        #expect(
            candidates.map(\.absoluteString) == [
                "https://media.example",
                "https://media.example:8920",
            ])
    }

    /// **A named port is a statement.** Whoever types it knows where they want to go; turning
    /// that into a list would mean overruling their input — and would cost three timeouts
    /// for addresses they did not mean.
    @Test("With an explicit port it stays at this one address")
    func keepsExplicitPort() throws {
        let url = try #require(JellyfinConnection.normalizeAddress("192.0.2.44:8096"))
        let candidates = JellyfinConnection.candidates(for: url)

        #expect(candidates.count == 1)
        #expect(candidates[0].port == 8096)
    }

    @Test("The first listed variant is always the typed one")
    func inputComesFirst() throws {
        // Whoever enters something deliberately should also be served with it first.
        let url = try #require(JellyfinConnection.normalizeAddress("https://media.example"))
        #expect(JellyfinConnection.candidates(for: url).first?.absoluteString == "https://media.example")
    }
}

/// How disturbances are interpreted — and **when one is none**.
///
/// The test suite belongs to a message that kept appearing on the TV: "No answer. Is the
/// server running, and is it on the same network?" The server had been running the whole
/// time. In the device's diagnostic report the reason stood: error −999, that is, a
/// **cancellation** — triggered by the viewer switching sections while loading was still
/// going on, or by the TV falling asleep.
///
/// Reporting a cancellation as a server outage is wrong twice over: the message points at
/// the wrong thing, and it stays up because nothing clears it. That is why only signing
/// out and signing in again helped.
@Suite("Interpreting disruptions")
struct FailureInterpretationTests {

    @Test("A cancellation is not a disruption")
    func cancellationIsRecognised() {
        #expect(JellyfinSource.wasCancelled(CancellationError()))
        // Depending on whether the cancellation catches the task or the request first, it comes
        // back in one shape or the other. Both count.
        #expect(JellyfinSource.wasCancelled(URLError(.cancelled)))
    }

    @Test("A real disruption is not a cancellation")
    func realFailuresAreNotCancellations() {
        #expect(!JellyfinSource.wasCancelled(URLError(.timedOut)))
        #expect(!JellyfinSource.wasCancelled(URLError(.cannotFindHost)))
        #expect(!JellyfinSource.wasCancelled(JellyfinSource.SourceFailure.unauthorized))
    }

    @Test("Only what is the line's fault is retried")
    func retryPolicy() {
        // In the diagnostic report there are timeouts on ordinary fetches on the home network —
        // once on `Views`, while nothing at all was going on. A connection that hits a dip
        // stands still; a new one usually gets through immediately.
        #expect(JellyfinSource.isWorthRetrying(URLError(.timedOut)))
        #expect(JellyfinSource.isWorthRetrying(URLError(.networkConnectionLost)))
        #expect(JellyfinSource.isWorthRetrying(URLError(.cannotConnectToHost)))

        // A cancellation is not retried — nobody is waiting for the result any more.
        #expect(!JellyfinSource.isWorthRetrying(URLError(.cancelled)))
        // And a rejected sign-in would come back the same way the second time.
        #expect(!JellyfinSource.isWorthRetrying(JellyfinSource.SourceFailure.unauthorized))
    }
}
