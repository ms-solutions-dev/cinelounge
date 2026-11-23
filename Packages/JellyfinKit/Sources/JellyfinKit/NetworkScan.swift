import Foundation

#if canImport(Darwin)
    import Darwin
#endif

/// Finds Jellyfin servers by **probing** the local network — the second way besides the
/// broadcast from ``ServerDiscovery``.
///
/// **Why both are needed is measured, not assumed** (2026-09-10): the home server
/// **never** answers the broadcast. It runs in a container on the bridge network
/// `edge-jellyfin` and publishes only `8096/tcp`; port `7359/udp` does not exist from
/// outside, and Docker does not carry a broadcast to the network address into a bridge
/// anyway. The server's network configuration says `AutoDiscovery: true` — the setting
/// is right, the packets just never arrive. **A search that finds nothing in one's own
/// home is worse than none.**
///
/// **And why the broadcast stays anyway:** it is the way Jellyfin provides, it costs a
/// single packet, and it finds servers even where probing does not reach — behind a
/// different mask, on a different port, in a network too large for 254 requests. Whoever
/// only probes loses these cases; whoever only broadcasts loses this home. The broadcast
/// therefore runs first and the probing alongside it.
///
/// **What explicitly does not happen here:** no port scan over port ranges, no trying out
/// foreign networks. A single address is asked per machine, the way a browser would —
/// `System/Info/Public` is the information Jellyfin hands out **without sign-in** for
/// exactly this purpose.
public enum NetworkScan {

    /// The port Jellyfin answers on without further configuration.
    ///
    /// **One and not three.** Every additional one triples the number of requests for a
    /// case that the input field next to it handles in five seconds. Whoever has put their
    /// server on a custom port knows that — they are not the person who needs a search.
    public static let port = 8096

    /// How many machines are probed at most.
    ///
    /// **One `/24` and not a step further.** A home network practically always is one; a
    /// `/16` would be 65,534 requests, and that is no longer searching but knocking on every
    /// door in town. If the network is larger, probing is skipped — the broadcast then
    /// carries alone, and the field sits next to it.
    public static let maximumCount = 254

    /// The addresses that are probed — empty if the network is too large.
    ///
    /// **The device's own address drops out**, as do the network and broadcast addresses: this
    /// device runs on the first, and the other two are not machines. A pure calculation, so
    /// it can be checked without a network.
    ///
    /// - Parameters:
    ///   - eigene: This device's IPv4 address, such as `192.168.1.33`.
    ///   - maske: The matching netmask, such as `255.255.255.0`.
    public static func addresses(own: String, mask: String) -> [String] {
        guard let isMarkedItself = number(own), let maskNumber = number(mask) else { return [] }
        // A mask is a run of ones followed by zeros. Anything else is not a mask, and computing
        // a range from it would mean making something up.
        let reversed = ~maskNumber
        guard maskNumber != 0, (reversed & (reversed &+ 1)) == 0 else { return [] }

        let network = isMarkedItself & maskNumber
        let broadcast = network | reversed
        guard broadcast > network else { return [] }
        let count = broadcast - network - 1
        guard count > 0, count <= UInt32(maximumCount) else { return [] }

        return ((network + 1)...(broadcast - 1))
            .filter { $0 != isMarkedItself }
            .map(dottedNotation)
    }

    /// The device's own address and mask — `nil` if this device is in no IPv4 network.
    ///
    /// **The interface taken is the one you also talk over**: Wi-Fi before cable-via-adapter,
    /// and nothing that points back at itself or belongs to a tunnel. A tunnel is the case
    /// that would silently go wrong here — on the road the phone is on WireGuard, and probing
    /// its network would mean sending 254 requests through a line measured at 0.6 Mbit/s.
    public static func ownNetwork() -> (address: String, mask: String)? {
        #if canImport(Darwin)
            var pointer: UnsafeMutablePointer<ifaddrs>?
            guard getifaddrs(&pointer) == 0, let start = pointer else { return nil }
            defer { freeifaddrs(start) }

            var found: (address: String, mask: String)?
            for entry in sequence(first: start, next: { $0.pointee.ifa_next }) {
                let data = entry.pointee
                guard let address = data.ifa_addr, address.pointee.sa_family == UInt8(AF_INET),
                    let mask = data.ifa_netmask
                else { continue }
                let flags = Int32(data.ifa_flags)
                guard flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0,
                    flags & IFF_POINTOPOINT == 0
                else { continue }
                let name = String(cString: data.ifa_name)
                guard isUsable(name) else { continue }
                let pair = (text(address), text(mask))
                guard !pair.0.isEmpty, !pair.1.isEmpty else { continue }
                // The first usable one wins, and the system's order puts `en0` first — on the phone
                // that is Wi-Fi.
                found = pair
                break
            }
            return found
        #else
            return nil
        #endif
    }

    /// Whether an interface is a candidate for the search.
    ///
    /// `utun` is WireGuard and anything else that sets up a tunnel; `awdl` and `llw` are
    /// Apple's near-field radio, `bridge` and `ap` are this device's hotspot. None of them
    /// has a media server in it.
    static func isUsable(_ name: String) -> Bool {
        let excluded = ["utun", "ipsec", "ppp", "awdl", "llw", "bridge", "ap"]
        return !excluded.contains { name.hasPrefix($0) }
    }

    // MARK: - Fragen

    /// Probes all addresses and reports every find as soon as it is there.
    ///
    /// **Reported one by one and not at the end.** A pass over 254 addresses takes seconds;
    /// showing a list only afterwards makes the viewer wait in front of a spinner although
    /// the home's only server answered long ago.
    ///
    /// - Parameter frage: How a single address is asked — from outside, so the flow can be
    ///   checked without a network.
    public static func knock(
        on addresses: [String],
        concurrently: Int = 64,
        query: @Sendable @escaping (String) async -> ServerDiscovery.Found?,
        fund: @Sendable @escaping (ServerDiscovery.Found) -> Void
    ) async {
        guard !addresses.isEmpty else { return }
        let width = max(1, min(concurrently, addresses.count))
        var next = width

        await withTaskGroup(of: ServerDiscovery.Found?.self) { group in
            // **A window and not 254 tasks at once.** Sending them all off at the same time means
            // the system queues them anyway — only without anyone controlling how many connections
            // are open.
            for address in addresses.prefix(width) {
                group.addTask { await query(address) }
            }
            while let result = await group.next() {
                if let result { fund(result) }
                if next < addresses.count {
                    let address = addresses[next]
                    next += 1
                    group.addTask { await query(address) }
                }
            }
        }
    }

    /// The default: a request to `System/Info/Public`.
    ///
    /// **One second and no retry.** The vast majority of the 254 addresses are not assigned
    /// at all; waiting on each as if something could be there would turn seconds into
    /// minutes. Whoever is really there answers in milliseconds on a home network — measured
    /// on 2026-09-10 against the home server.
    ///
    /// **The timeout times the number of rounds is the duration of the search**, and that is
    /// why it stands here together with the window width: 253 addresses at 64 at a time are
    /// four rounds. With 32 and one and a half seconds it was a measured 12.3 seconds — for a
    /// screen someone is waiting in front of, double what is bearable.
    public static func queryServer(
        _ address: String, deadline: TimeInterval = 1
    ) async
        -> ServerDiscovery.Found?
    {
        guard let target = URL(string: "http://\(address):\(port)/System/Info/Public") else {
            return nil
        }
        var request = URLRequest(url: target)
        request.timeoutInterval = deadline
        request.httpMethod = "GET"
        // No cache: a search that reports a switched-off server from memory sends the viewer to
        // an address that does not answer.
        request.cachePolicy = .reloadIgnoringLocalCacheData

        let session = URLSession(configuration: .ephemeral)
        guard let (data, reply) = try? await session.data(for: request),
            let http = reply as? HTTPURLResponse, http.statusCode == 200
        else { return nil }
        return interpret(data, from: address)
    }

    /// Evaluates the response — `nil` if there is no Jellyfin there.
    ///
    /// **The identifier decides, not the status code.** Anything at all can answer on 8096;
    /// only `Id` and `ServerName` turn a response into a find. A device that cheerfully says
    /// 200 is not a media server yet.
    static func interpret(_ data: Data, from address: String) -> ServerDiscovery.Found? {
        struct StateInfo: Decodable {
            let id: String
            let name: String?

            enum CodingKeys: String, CodingKey {
                case id = "Id"
                case name = "ServerName"
            }
        }
        guard let info = try? JSONDecoder().decode(StateInfo.self, from: data),
            !info.id.isEmpty,
            let url = URL(string: "http://\(address):\(port)")
        else { return nil }
        return ServerDiscovery.Found(
            id: info.id, name: info.name ?? address, address: url)
    }

    // MARK: - Zusammenlegen

    /// Merges broadcast and probing — **without a server appearing twice.**
    ///
    /// **The broadcast wins on the same identifier**, and that is no courtesy: its address is
    /// the one the server itself considers right (`PublishedServerUri`, for instance), and
    /// that one also works from outside the network. The probed address is only ever the one
    /// IP under which it happened to be reachable from here.
    ///
    /// **Nothing is guessed without an identifier.** Two finds without a common identifier
    /// are two servers, even if they have the same name — if in doubt, one too many is in the
    /// list, and that is the more harmless error.
    public static func create(
        combined broadcast: [ServerDiscovery.Found], and probed: [ServerDiscovery.Found]
    ) -> [ServerDiscovery.Found] {
        // **The broadcast alone can be doubled too** (on-device test 2026-09-27, T2): it goes to
        // more than one broadcast address, and the same server answers on each. Until then only
        // the comparison against probing was made, and setup showed the same server twice side
        // by side. The first find wins.
        //
        // **And by address** (simulator 2026-09-28): despite merging by identifier, the test
        // server's entry still appeared twice. The same address is the same server, whatever
        // identifier it happens to report.
        var identifiers = Set<String>()
        var addresses = Set<String>()
        var result: [ServerDiscovery.Found] = []
        for found in broadcast + probed {
            let address = "\(found.address.host() ?? ""):\(found.address.port ?? 0)"
            guard !identifiers.contains(found.id), !addresses.contains(address) else { continue }
            identifiers.insert(found.id)
            addresses.insert(address)
            result.append(found)
        }
        return result
    }

    // MARK: - Address arithmetic

    static func number(_ text: String) -> UInt32? {
        let split = text.split(separator: ".", omittingEmptySubsequences: false)
        guard split.count == 4 else { return nil }
        var accumulated: UInt32 = 0
        for part in split {
            guard let octet = UInt8(part) else { return nil }
            accumulated = (accumulated << 8) | UInt32(octet)
        }
        return accumulated
    }

    static func dottedNotation(_ value: UInt32) -> String {
        "\((value >> 24) & 255).\((value >> 16) & 255).\((value >> 8) & 255).\(value & 255)"
    }

    #if canImport(Darwin)
        private static func text(_ address: UnsafeMutablePointer<sockaddr>) -> String {
            var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard
                getnameinfo(
                    address, socklen_t(address.pointee.sa_len), &buffer, socklen_t(buffer.count),
                    nil, 0, NI_NUMERICHOST) == 0
            else { return "" }
            // Read up to the zero: the buffer is NI_MAXHOST long, the address in it is short.
            let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
            return String(decoding: bytes, as: UTF8.self)
        }
    #endif
}
