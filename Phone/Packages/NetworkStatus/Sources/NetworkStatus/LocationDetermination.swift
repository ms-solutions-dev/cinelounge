import Foundation

#if canImport(Darwin)
    import Darwin
#endif

/// Whether the home network is **directly** reachable — determined, not claimed.
///
/// **The finding (AP6):** `location: .home` stood hard-coded at three places, and
/// ``LocationStatement`` has always said itself why that does not work: *"Whether one is 'at
/// home' is decided not by whether Wi-Fi is present but by whether the media server
/// answers without a tunnel — a foreign Wi-Fi is also Wi-Fi."*
///
/// **Why reachability alone is the wrong question.** Over WireGuard the media server of
/// this household answers from anywhere in the world. Whoever ties "at home" to the server
/// answering gets "at home" on the train — and that is exactly where the statements that
/// depend on it hang: whether a file is pulled in full resolution, whether downloads load,
/// what the location line promises.
///
/// **The question that can be answered is a different one: Is the server in *my*
/// network?** If the server's address is part of the subnet in which this phone itself
/// sits, it is in the same network — no tunnel, no intermediary. If it lies outside, the
/// path leads through something, and then one is on the go. Over the tunnel the phone gets
/// an address from the WireGuard network; the server's address in the home subnet is
/// reachable from there, but **not** in the phone's own subnet.
///
/// **Tunnel interfaces do not count as a network of their own here.** `utun` is the tunnel
/// itself — whoever counted it would compare the answer with the question. The same
/// exclusion list as in `JellyfinKit/NetworkScan`, and for the same reason.
///
/// **What it explicitly cannot do:** IPv6. A home network that reaches the media server
/// only over IPv6 reports `unknown` here — and that is the right answer, not the
/// convenient one. Guessing a location is exactly the error this package eliminates.
public enum LocationDetermination {

    /// A network in which this device itself sits.
    public struct Network: Sendable, Equatable {
        public let address: UInt32
        public let mask: UInt32

        public init(address: UInt32, mask: UInt32) {
            self.address = address
            self.mask = mask
        }

        /// Liegt diese Adresse in diesem Netz?
        public func contains(_ target: UInt32) -> Bool {
            (target & mask) == (address & mask)
        }
    }

    /// Interfaces that do not describe a network of their own.
    ///
    /// `utun` is the tunnel, and so are `ipsec` and `ppp`; `awdl` and `llw` are Apple's direct
    /// device-to-device connections, `bridge` and `ap` belong to sharing one's own connection.
    /// None of them says anything about which house one is in.
    static let foreignPorts = ["utun", "awdl", "bridge", "ap", "ipsec", "ppp", "llw"]

    /// This device's networks — without tunnels.
    public static func ownNetworks() -> [Network] {
        #if canImport(Darwin)
            var pointer: UnsafeMutablePointer<ifaddrs>?
            guard getifaddrs(&pointer) == 0, let first = pointer else { return [] }
            defer { freeifaddrs(pointer) }

            var found: [Network] = []
            var run: UnsafeMutablePointer<ifaddrs>? = first
            while let now = run {
                defer { run = now.pointee.ifa_next }

                let name = String(cString: now.pointee.ifa_name)
                guard !foreignPorts.contains(where: { name.hasPrefix($0) }) else { continue }
                guard now.pointee.ifa_flags & UInt32(IFF_UP) != 0,
                    now.pointee.ifa_flags & UInt32(IFF_LOOPBACK) == 0,
                    let addr = now.pointee.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET),
                    let mask = now.pointee.ifa_netmask
                else { continue }

                let ip = addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
                    UInt32(bigEndian: $0.pointee.sin_addr.s_addr)
                }
                let netmask = mask.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
                    UInt32(bigEndian: $0.pointee.sin_addr.s_addr)
                }
                found.append(Network(address: ip, mask: netmask))
            }
            return found
        #else
            return []
        #endif
    }

    /// A dotted address as a number — `nil` if it is not one.
    ///
    /// **No name service.** This function resolves nothing; it reads an address that already
    /// is one. Resolving lives in ``location(forItem:)`` and is the part that reaches into the
    /// network — kept separate so that the calculation stays testable.
    public static func address(from text: String) -> UInt32? {
        let split = text.split(separator: ".", omittingEmptySubsequences: false)
        guard split.count == 4 else { return nil }
        var number: UInt32 = 0
        for part in split {
            guard let byte = UInt8(part), String(byte) == String(part) else { return nil }
            number = (number << 8) | UInt32(byte)
        }
        return number
    }

    /// The decision itself — **without a network and therefore testable.**
    ///
    /// - Parameters:
    ///   - server: the media server's address as a number, or `nil` if it could not be
    ///     determined
    ///   - netze: the device's own networks from ``ownNetworks()``
    public static func location(server: UInt32?, networks: [Network]) -> LocationStatement.Location {
        // **Without an address or without a network of its own, nothing is claimed.** Both
        // happen: a name that does not resolve right now; a device in airplane mode.
        guard let server, !networks.isEmpty else { return .unknown }
        return networks.contains { $0.contains(server) } ? .home : .inFlight
    }

    /// The same for an address that may also be a name.
    ///
    /// **The name service runs here and not on the main thread.** The home server's name
    /// resolves only on the home network, and a resolution attempt that runs into nothing
    /// takes a while.
    ///
    /// **The decision goes into the ``NetworkLog``** (finding 11): Whether the address could
    /// be determined and how many networks of its own there are explains an "only on the home
    /// network" on screen — without naming the address itself.
    public static func location(forItem server: URL?) async -> LocationStatement.Location {
        guard let host = server?.host else {
            NetworkLog.note(.step, "Location unknown: no Jellyfin server configured")
            return .unknown
        }
        let networks = ownNetworks()
        let address: UInt32?
        let name: Bool
        if let immediately = Self.address(from: host) {
            address = immediately
            name = false
        } else {
            address = await Task.detached(priority: .utility) { redeem(host) }.value
            name = true
        }
        let result = location(server: address, networks: networks)
        NetworkLog.note(
            result == .unknown ? .hint : .step,
            logLine(result, addressResolved: address != nil, name: name, networks: networks.count))
        return result
    }

    /// The sentence for the decision — **without an address, without a name.**
    static func logLine(
        _ result: LocationStatement.Location, addressResolved: Bool, name: Bool, networks: Int
    ) -> String {
        let origin = name ? "name resolved" : "address direct"
        return
            "Location \(result.logName): server address \(addressResolved ? "resolved" : "not resolved") (\(origin)), \(networks) own network(s) without tunnel"
    }

    /// A name for an IPv4 address.
    private static func redeem(_ host: String) -> UInt32? {
        #if canImport(Darwin)
            var hint = addrinfo(
                ai_flags: 0, ai_family: AF_INET, ai_socktype: SOCK_STREAM, ai_protocol: 0,
                ai_addrlen: 0, ai_canonname: nil, ai_addr: nil, ai_next: nil)
            var result: UnsafeMutablePointer<addrinfo>?
            guard getaddrinfo(host, nil, &hint, &result) == 0, let first = result else {
                return nil
            }
            defer { freeaddrinfo(result) }
            guard let addr = first.pointee.ai_addr else { return nil }
            return addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
                UInt32(bigEndian: $0.pointee.sin_addr.s_addr)
            }
        #else
            return nil
        #endif
    }
}

extension LocationStatement.Location {
    /// The name in log lines — not the raw value, which stays as it is.
    var logName: String {
        switch self {
        case .home: "home"
        case .inFlight: "away"
        case .unknown: "unknown"
        }
    }
}
