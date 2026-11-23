import Core
import Foundation
import Network
import SecondScreen
import SourceProbe
import Testing

@testable import FeaturesPhone

/// A wire that replays the pairing — **without a network** and with a chosen error.
private actor PairingWire: PairingRoute {

    var connected = false
    private(set) var paired: [HandoffKey] = []
    private(set) var sent: [Command] = []
    private var error: (any Error)?

    nonisolated let states: AsyncStream<StateMirror>

    init(error: (any Error)? = nil) {
        self.error = error
        states = AsyncStream { _ in }
    }

    func connect(using target: DeviceDiscovery.Device) async throws {
        if let error { throw error }
        connected = true
    }

    func pair(using key: HandoffKey) async throws {
        paired.append(key)
        if let error { throw error }
        connected = true
    }

    func disconnect() async { connected = false }

    func send(_ command: Command) async throws { sent.append(command) }
}

/// **The phone side of remote pairing** — decision 6 of 2026-09-25, tvOS roadmap
/// "The password field gets the remote keyboard only once the wire is paired":
/// *"The phone side (scanning, storing the credential, messages) is built by the phone strand."*
@MainActor
@Suite("Remote pairing on the phone")
struct RemotePairingPhoneTests {

    /// A store with **one** credential for the TV `tv-1` — via the stored
    /// format, because a ``SecondScreen/RemoteCredential`` arises only in the package.
    private func storeWithCredential() -> (InMemoryStore, RemoteCredentialStore) {
        let secrets = InMemoryStore()
        let isSecret = Data(repeating: 7, count: 32).base64EncodedString()
        try? secrets.set(
            #"[{"telefon":"t-1","fernseher":"tv-1","name":"Wohnzimmer","schluessel":"\#(isSecret)"}]"#,
            for: ["zweitschirm", "fernausweise"].joined(separator: "."))
        let store = RemoteCredentialStore(secrets)
        return (secrets, store)
    }

    private let tv = DeviceDiscovery.Device(
        name: "Wohnzimmer", endpoint: .hostPort(host: "127.0.0.1", port: 9))

    // MARK: - Meldungen

    @Test("Every pairing error has its message and its next step")
    func errorToMessage() {
        let expected: [(RemotePairing.TestError, String, PairingMessage.Step)] = [
            (.unpaired, "remote.pairing.unpaired", .scan),
            (.dismissed, "remote.pairing.refused", .reconnect),
            (.pairingRejected, "remote.pairing.codeInvalid", .scan),
            (.tvTooOld, "remote.pairing.tvTooOld", .none),
            (.unreadable, "remote.pairing.unreadable", .scan),
        ]
        for (error, title, step) in expected {
            let report = PairingMessage.zu(error)
            #expect(report?.title == title, "\(error)")
            #expect(report?.message == title + "Text", "\(error)")
            #expect(report?.step == step, "\(error)")
        }
        #expect(PairingMessage.zu(HandoffWire.TestError.timedOut) == nil)
    }

    /// **The connection:** an unassigned refusal when connecting shows the hint — and
    /// the credential stays put. No deleting past the model.
    @Test("An unspecific refusal does not delete the credential")
    func rejectedDoesNotDelete() async {
        let (_, store) = storeWithCredential()
        let model = RemoteModel(
            wire: PairingWire(error: RemotePairing.TestError.dismissed), credentials: store)
        #expect(model.pairings.count == 1)
        await model.connect(using: tv)
        #expect(model.pairingMessage?.title == "remote.pairing.refused")
        #expect(store.all.map(\.tv) == ["tv-1"], "credential gone")
        #expect(model.pairings.count == 1)
        #expect(model.state != .disrupted(.networkTV), "reported as a network disruption")
    }

    @Test("A network disruption stays a network disruption and is not a pairing message")
    func networkStaysNetwork() async {
        let model = RemoteModel(
            wire: PairingWire(error: HandoffWire.TestError.timedOut), credentials: nil)
        await model.connect(using: tv)
        #expect(model.pairingMessage == nil)
        #expect(model.state == .disrupted(.networkTV))
    }

    // MARK: - Scannen

    @Test("Only a code with the remote pairing scheme pairs")
    func remoteSchemeOnly() async {
        let wire = PairingWire()
        let model = RemoteModel(wire: wire, credentials: nil)
        let key = HandoffKey.fresh(target: "Wohnzimmer")

        let foreign = await model.pair(text: key.asText(schema: "cinelounge-uebergabe"))
        #expect(!foreign)
        #expect(await wire.paired.isEmpty)

        let own = await model.pair(text: key.asText(schema: RemotePairing.schema))
        #expect(own)
        #expect(await wire.paired.map(\.secret) == [key.secret])
        #expect(model.state == .connected)
    }

    @Test("An expired code shows the matching message")
    func expiredCode() async {
        let model = RemoteModel(
            wire: PairingWire(error: RemotePairing.TestError.pairingRejected), credentials: nil)
        await model.pair(
            text: HandoffKey.fresh(target: "Wohnzimmer").asText(schema: RemotePairing.schema))
        #expect(model.pairingMessage?.title == "remote.pairing.codeInvalid")
    }

    // MARK: - Kopplungen

    @Test("A pairing can be forgotten")
    func forgotten() {
        let (_, store) = storeWithCredential()
        let model = RemoteModel(wire: PairingWire(), credentials: store)
        let credential = model.pairings[0]
        #expect(credential.name == "Wohnzimmer")
        model.forget(credential)
        #expect(model.pairings.isEmpty)
        #expect(store.all.isEmpty)
    }

    // MARK: - Das geheime Feld

    @Test("The secret field starts empty and keeps nothing from the TV")
    func secretField() async {
        let isSecret = StateMirror(keyboardOpen: true, keyboardText: "hunter2", keyboardSecret: true)
        #expect(KeyboardSheet.template(from: isSecret) == "")
        let pending = StateMirror(keyboardOpen: true, keyboardText: "Sample")
        #expect(KeyboardSheet.template(from: pending) == "Sample")

        // Only `.tap` is sent — and the model remembers nothing of it.
        let wire = PairingWire()
        let model = RemoteModel(wire: wire, credentials: nil)
        model.tap("secret")
        await model.broadcast?.value
        #expect(await wire.sent == [.tap("secret")])
        #expect(!model.status.keyboardText.contains("secret"))
    }

    // MARK: - Der Betrieb

    /// **Without credentials the wire no longer registers anywhere since decision 6.** The
    /// model's default must therefore bring them along — together with the device name for the list
    /// on the TV.
    @Test("In production the wire gets the credential store and the device name")
    func operationWithCredentials() throws {
        let text = try SourceText.read("RemoteModel.swift", in: .featuresPhone)
            .split(separator: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
        #expect(text.contains("OwnWire(credentials: store, phoneName: DeviceName.thisDevice)"))
        #expect(text.contains("RemoteCredentialStore(SecureStore(thisDeviceOnly: true))"))
    }

    // MARK: - Strang E (D2-1): „kein Platz"

    /// **A refusal while pairing does not use up the code** — "Connect again" tries
    /// the same code once more instead of demanding a new scan.
    @Test("Reconnecting repeats the pairing with the same code")
    func pairAgain() async {
        let wire = PairingWire(error: RemotePairing.TestError.dismissed)
        let model = RemoteModel(wire: wire, credentials: nil)
        let key = HandoffKey.fresh(target: "Wohnzimmer")
        await model.pair(text: key.asText(schema: RemotePairing.schema))
        #expect(model.pairingMessage?.step == .reconnect)
        await model.reconnect()
        #expect(await wire.paired.map(\.secret) == [key.secret, key.secret])
    }

    @Test("Reconnecting after a refusal while connecting asks the same TV")
    func reconnectDevice() async {
        let (_, store) = storeWithCredential()
        let model = RemoteModel(
            wire: PairingWire(error: RemotePairing.TestError.dismissed), credentials: store)
        await model.connect(using: tv)
        await model.reconnect()
        #expect(model.pairingMessage?.title == "remote.pairing.refused")
        #expect(store.all.count == 1, "the credential did not stay")
    }
}
