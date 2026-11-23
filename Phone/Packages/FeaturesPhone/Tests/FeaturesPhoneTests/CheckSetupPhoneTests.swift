import Core
import Foundation
import PlaylistKit
import SecondScreen
import Testing

@testable import FeaturesPhone

/// The phone side of the "Setup" check of 2026-09-27 (E2, E6, E14) — as a guard.
@Suite("Setup check — phone")
struct CheckSetupPhoneTests {

    /// Separate stores per check — the device's Keychain, lists and trust stay
    /// out.
    @MainActor
    private static func model(
        secure: SecureStore, listen: PlaylistStore, trust: CertificateTrustStore
    ) -> HandoffModel {
        let name = "test.\(UUID().uuidString)"
        let store = UserDefaults(suiteName: name) ?? .standard
        return HandoffModel(
            status: SetupState(
                keychain: secure, listen: listen, store: store, ledgerStore: InMemoryStore()),
            backup: ParentalControlsState(store: store, keychain: secure),
            keychain: secure, listen: listen, trust: trust, store: store,
            shelfStore: InMemoryStore(), ledgerStore: InMemoryStore())
    }

    @MainActor
    private static func listen() -> PlaylistStore {
        PlaylistStore(store: InMemoryStore(), secrets: InMemoryStore(), ledger: InMemoryStore())
    }

    /// E6: The phone packed **all** trusted hosts, not just the media server.
    @Test("The bundle carries only the digest of the Jellyfin server")
    @MainActor
    func onlyJellyfin() throws {
        let secure = SecureStore(service: "test.\(UUID().uuidString)")
        defer { try? secure.clearCredentials() }
        try secure.saveCredentials(
            ServerCredentials(
                serverURL: try #require(URL(string: "https://jellyfin.example:8920")), userID: "u1",
                username: "Alex", accessToken: "token"))
        let trust = CertificateTrustStore(store: InMemoryStore())
        try trust.trust(CertificateFingerprint(value: "AA:AA"), for: "jellyfin.example")
        try trust.trust(CertificateFingerprint(value: "BB:BB"), for: "nas.example")

        let bundles = Self.model(secure: secure, listen: Self.listen(), trust: trust).bundles()
        #expect(bundles.jellyfin?.trusted == ["jellyfin.example": "AA:AA"])
    }

    /// E2: A list's EPG address did not travel along.
    @Test("A list's guide source travels along")
    @MainActor
    func epgMigratesAlong() throws {
        let secure = SecureStore(service: "test.\(UUID().uuidString)")
        let listen = Self.listen()
        let epg = try #require(URL(string: "http://epg.example/guide.xml"))
        listen.add(
            Playlist(
                name: "Provider",
                kind: .xtream(server: try #require(URL(string: "http://provider.example")), username: "u"),
                epgURL: epg),
            password: "secret")

        let bundles = Self.model(
            secure: secure, listen: listen, trust: CertificateTrustStore(store: InMemoryStore())
        ).bundles()
        #expect(bundles.channelLists.first?.epg == epg)
    }

    /// E14: The phone setup rolled IDs instead of computing them.
    @Test("Setup assigns the computed list key")
    @MainActor
    func listKeyInsteadOfRandom() throws {
        let name = "test.\(UUID().uuidString)"
        let listen = Self.listen()
        let setup = SetupState(
            keychain: SecureStore(service: name), listen: listen,
            store: UserDefaults(suiteName: name) ?? .standard, ledgerStore: InMemoryStore())
        let model = SourceFormModel(
            state: setup, deviceID: "test", accessInfo: { _, _ in nil })
        let address = try #require(URL(string: "http://provider.example:8080"))
        let m3u = try #require(URL(string: "http://list.example/a.m3u"))

        model.addChannelList(name: "A", address: address, user: "abc", password: "x")
        model.createList(name: "B", address: m3u)

        #expect(
            Set(listen.playlists.map(\.id))
                == [
                    ListKey.forItem(.xtream(server: address, username: "abc")),
                    ListKey.forItem(.m3u(m3u)),
                ])
    }
}
