import Foundation

/// Everything the service says about a portal — **in one piece.**
///
/// **Why this is no longer a tuple (stage 3, 2026-09-12):** ``PortalSource/availablePortals()``
/// returns four fields as a tuple, and the server sends nine. Nobody reads a tuple with nine
/// fields at the call site, and every tenth touches every caller.
///
/// **``PortalSource/availablePortals()`` stays anyway.** The same agreement as with
/// ``PortalSource/sources(forItem:)`` next to ``PortalSource/host(forItem:)``: two apps depend on
/// this package. Whoever needs more than "is it ready" calls ``PortalSource/portalRows()``.
public struct PortalRow: Sendable, Equatable, Identifiable {

    public let id: String
    public let name: String

    /// What the portal is, in one sentence. **Empty with the old bridge** — it does not carry the
    /// field, and that is not a gap but a difference between the services.
    public let description: String

    /// The kind of portal as a free word: `native`, or a kind that a server extension registers.
    ///
    /// **The app decides nothing on it**, and that is intended: the kind is a statement about a
    /// portal's origin and not about its operation. It counts at exactly one place — in the search,
    /// where for the same title a `native` portal comes first.
    public let kind: String

    /// What the portal can do. **Raw, because both vocabularies come through here** — it is checked
    /// with ``PortalCapability/settled(in:)``, never with a hard-coded word.
    public let capabilities: Set<String>

    /// What the portal **cannot** do, e.g. `drm_partial`.
    public let limits: [String]

    /// `direct` or a country code. Today always `direct`.
    public let network: String

    /// Whether the portal carries adult content.
    ///
    /// **The app hides nothing because of it.** The server does not deliver such portals to a
    /// child's device at all and rejects the direct call of their addresses with 403. The field is
    /// the label, not the lock.
    public let adult: Bool

    public let ready: Bool

    /// The service's state word, **raw** — `ready`/`broken`/`disabled` at the server, `ready` … at
    /// the old bridge.
    ///
    /// **The portal state is derived from this and not from ``reason``** (review 2026-09-27, portals
    /// B2): until then the apps passed the reason text on as the state word, and `needs_setting`
    /// without a reason would have become "silent" instead of "setting missing".
    public let state: String

    /// Why it is not ready.
    public let reason: String?

    /// - Parameter zustand: `nil` takes the word that fits `ready`.
    public init(
        id: String, name: String, description: String = "", kind: String = "",
        capabilities: Set<String> = [], limits: [String] = [], network: String = "direct",
        adult: Bool = false, ready: Bool = true, state: String? = nil, reason: String? = nil
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.kind = kind
        self.capabilities = capabilities
        self.limits = limits
        self.network = network
        self.adult = adult
        self.ready = ready
        self.state = state ?? (ready ? "ready" : "")
        self.reason = reason
    }

    /// Can this portal do that?
    public func can(_ capability: PortalCapability) -> Bool {
        capability.settled(in: capabilities)
    }

    /// **A built-in portal first.**
    ///
    /// A `native` portal addresses a broadcaster's interface; every other kind comes from an
    /// extension. If a title is in both, the `native` one belongs in front — that is a statement
    /// about origin, not about quality.
    public var isOfficial: Bool { kind == "native" || kind == "eigen" }
}

extension PortalSource {

    /// Everything the service says about its portals.
    ///
    /// **One fetch and not two.** Until here the apps fetched the list via ``availablePortals()``
    /// and the capabilities right after via ``capabilities()`` — two paths onto the same response, of
    /// which the second holds only if the first ran beforehand. Here both are together.
    public func portalRows() async throws -> [PortalRow] {
        _ = try await availablePortals()
        return reportedPortals.map {
            PortalRow(
                id: $0.id, name: $0.name, description: $0.description ?? "", kind: $0.kind,
                capabilities: Set($0.capabilities), limits: $0.limits ?? [],
                network: $0.network ?? "direct", adult: $0.adult ?? false, ready: $0.isReady,
                state: $0.state, reason: $0.reason)
        }
    }
}
