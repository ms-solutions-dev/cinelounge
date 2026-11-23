import Foundation

/// Where the portal service stands.
///
/// **The finding (G2, 2026-09-07):** The address was hard-wired. `PortalBridge.standard()` knew a
/// fixed host name and port of the home network, `MainView` built the source with exactly
/// that, and the settings area only displayed the address. So the portals worked on the TV
/// **only where that one name resolves** — on another Apple TV they did not exist, and
/// nothing said why.
///
/// **Two things that must not be confused here:**
///
/// * **Which portals exist** cannot be changed by the app. That is the answer to App Store
///   rules 5.2.1 and 5.2.2 and stays that way. Portal names do not appear in the shipped
///   app.
/// * **Where the service stands** is a machine of the viewer — just like the address of the
///   media server. There is no App Store reason for that.
///
/// **Since 2026-09-12 there is no default any more, and that is a reversal.** Until then it
/// said here: `nil` means "under its usual name" and not "no portals", because whoever empties
/// the field wants the default back. The product decision is different — **"if nothing is
/// entered, nothing should work"** — and it is the better one: A default is a claim about a
/// foreign home network. In the original household it held true, in every other it led to an
/// app that reaches silently into nothing and looks broken while doing so. An empty field, by
/// contrast, is information: Nothing is set up here.
///
/// **The store key stays `setup.portalBridge`.** It carries the name of the old service, and
/// that is no oversight: Both apps read it, and a new name would mean losing the configured
/// address on update.
///
/// **In the Keychain and not in the default store**, unlike in the phone project. There the
/// argument was that a host name is no secret and the Keychain therefore a hassle. On the TV
/// it does not hold: Here the remembered settings area (``SettingsSection/storageKey``) already
/// lives there, and a second store for a single value would be the bigger hassle.
public enum BridgeAddress {

    /// The store key. The same spelling as in the phone project, so that both programs speak
    /// about the same thing with the same name.
    public static let storageKey = "setup.portalBridge"

    /// The entered address — `nil` means: **no portals.**
    public static func load(from store: any KeyValueStore) -> URL? {
        guard let text = try? store.value(for: storageKey) else { return nil }
        return normalize(text)
    }

    /// What is actually attempted.
    ///
    /// **The difference from ``load(from:)`` is the test hook and nothing else.** Until
    /// 2026-09-12 it was the default; that has fallen, and the question "what is entered" versus
    /// "what is attempted" remains a real one all the same — the callers still ask the second.
    ///
    /// **`CINELOUNGE_PORTALE` exists only in the simulator, and what is entered wins.** The same
    /// pattern as on the phone (``SourceAssembly``), and for a reason measured on the evening of
    /// 2026-09-12: A fresh Apple TV simulator has an empty Keychain, and the address lives there
    /// — so it would have to be entered via the **TV keyboard** before anything can be tested at
    /// all. Typing is the most expensive operation this app knows on the TV; for a test that
    /// starts over three times an evening, it cannot be paid.
    ///
    /// **A fallback and not an override**, so that the hook never explains why a device uses a
    /// different address than the one in the field. On a real Apple TV the environment is empty,
    /// and the function answers like ``load(from:)``.
    public static func effective(from store: any KeyValueStore) -> URL? {
        if let entered = load(from: store) { return entered }
        guard let override = ProcessInfo.processInfo.environment["CINELOUNGE_PORTALE"] else {
            return nil
        }
        return normalize(override)
    }

    /// Is a portal service set up at all?
    ///
    /// **The question the interface has had to ask since 2026-09-12** Before, it did not exist: One
    /// was always set up, the presumed one if need be. Now "nothing entered" is a state that a
    /// screen must name — empty portal shelves without a sentence next to them are the worst way
    /// to say it.
    public static func isConfigured(in store: any KeyValueStore) -> Bool {
        load(from: store) != nil
    }

    /// Enters an address. Empty text takes it back.
    ///
    /// - Returns: `false` if the text yields no usable address — then the old one stays. A
    ///   mistyped entry must not switch off the portals; on the TV keyboard a typo is the rule and
    ///   not the exception.
    @discardableResult
    public static func save(_ text: String, to store: any KeyValueStore) -> Bool {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if clean.isEmpty {
            try? store.remove(storageKey)
            return true
        }
        guard normalize(clean) != nil else { return false }
        try? store.set(clean, for: storageKey)
        return true
    }

    /// From an input, an address — **typed without a scheme is the normal case.**
    ///
    /// The same rule as ``JellyfinConnection/normalizeAddress(_:)`` in the neighboring package,
    /// and for the same reason: Whoever types `192.168.1.10:8100` means an address, even if they
    /// leave out `http://`. Rebuilt instead of shared, because `Core` does not sit on `JellyfinKit`
    /// — the dependency would run the wrong way.
    ///
    /// Plaintext and not TLS: The service stands in the home network and listens only there. For
    /// the CineLounge server the plaintext on 8100 is moreover deliberate — a TV should not fail
    /// on a certificate chain that protects nothing in the home network. For the browser there is
    /// a host name of the home server with its own certificate; the app does not use it.
    public static func normalize(_ input: String) -> URL? {
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if !text.contains("://") { text = "http://" + text }
        guard let split = URLComponents(string: text), split.host?.isEmpty == false else {
            return nil
        }
        return split.url
    }
}
