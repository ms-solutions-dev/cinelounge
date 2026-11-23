import Foundation

/// What the server says about the file while it sends a block.
///
/// **The headers are not a side issue here.** On them hangs the question of whether, after
/// re-resolving, the same file lies at the other end — and that is the difference between a
/// finished movie and one that falls apart in the middle on the plane. `Core.ByteRangeSource`
/// does not deliver them; it is built for playback, where nobody writes to the same file
/// for hours.
public struct BlockResponse: Sendable, Equatable {

    public let status: Int
    public let data: Data
    /// The total length from `Content-Range` — for a range response it is there and not in
    /// `Content-Length`, which measures only the block.
    public let totalLength: Int64?
    public let tag: String?
    public let changed: String?
    public let acceptsRanges: String?
    /// The SHA-256 sum of the **whole** file, if the server sends one along
    /// (`Repr-Digest`, RFC 9530, or the older `Digest`, RFC 3230) — otherwise `nil`.
    ///
    /// **Both describe the whole representation and not the block** (check wrapper H5):
    /// That lets the finished file be checked at the end before it counts as finished.
    public let checksum: Data?

    public init(
        status: Int, data: Data, totalLength: Int64? = nil,
        tag: String? = nil, changed: String? = nil, acceptsRanges: String? = nil,
        checksum: Data? = nil
    ) {
        self.status = status
        self.data = data
        self.totalLength = totalLength
        self.tag = tag
        self.changed = changed
        self.acceptsRanges = acceptsRanges
        self.checksum = checksum
    }

    /// The total length from `Content-Range: bytes 0-1/8700000000`.
    ///
    /// **The asterisk is a valid value and means "I don't know".** Reading it as a number would
    /// give zero, and a file of length zero counts as finished before it has begun.
    /// Reads the SHA-256 sum from `Repr-Digest` (`sha-256=:…:`) or `Digest`
    /// (`SHA-256=…`); other algorithms are skipped.
    public static func checksum(reprDigest: String?, digest: String?) -> Data? {
        for (header, bracket) in [(reprDigest, true), (digest, false)] {
            guard let header else { continue }
            for entry in header.split(separator: ",") {
                let split = entry.split(separator: "=", maxSplits: 1)
                guard split.count == 2,
                    split[0].trimmingCharacters(in: .whitespaces).lowercased() == "sha-256"
                else { continue }
                var value = split[1].trimmingCharacters(in: .whitespaces)
                if bracket {
                    guard value.hasPrefix(":"), value.hasSuffix(":"), value.count > 2 else { continue }
                    value = String(value.dropFirst().dropLast())
                }
                if let sum = Data(base64Encoded: value), sum.count == 32 { return sum }
            }
        }
        return nil
    }

    public static func totalLength(fromContentRange header: String?) -> Int64? {
        guard let part = header?.split(separator: "/").last, part != "*" else { return nil }
        return Int64(part)
    }
}

/// Where the next block goes — **address, deadline and the headers to go with it.**
///
/// **The headers have been part of the contract since 2026-09-09, because of a measurement at
/// the bridge.** `/play?weiterleiten=false` answers with `address` **and**
/// `headers` — at the ARD the list is empty (`passedThrough: true`, the bridge sets
/// them itself), at a host that demands a `Referer` it is filled there.
/// Until then this contract returned only `(URL, Date?)`, and ``URLBlockFetcher`` set
/// only `Range`. For such a host that is a `403` **before the first byte** — and on screen
/// it looked like "the download does not work", not like "a line is missing here".
///
/// **A type of its own and not a third tuple member.** A tuple of three things names none
/// of them at every call site; and the next addition — the host after next, a
/// bandwidth limit — would again be a contract change at all places at once.
public struct TargetAddress: Sendable, Equatable {

    public let address: URL
    /// Until when it applies. `nil` means **"unlimited"** — for media server and provider.
    public let validUntil: Date?
    /// What the host wants to see on the request — `Referer`, `Origin`, an identifier.
    ///
    /// **Empty is the normal case and not a deficiency.** If the stream runs through the bridge
    /// (`passedThrough: true`), they are already set there; setting them a second time here
    /// would at best have no effect.
    public let headers: [String: String]

    public init(_ address: URL, validUntil: Date? = nil, headers: [String: String] = [:]) {
        self.address = address
        self.validUntil = validUntil
        self.headers = headers
    }
}

/// Who fetches a range.
///
/// **A contract of its own, so that the difficult part can be tested without a network.**
/// What ``BackgroundSession`` decides — resume or start over, how large the next block is,
/// when to re-resolve — depends on responses and not on lines.
public protocol BlockFetcher: Sendable {
    func fetch(_ area: ClosedRange<Int64>, from target: TargetAddress) async throws -> BlockResponse
}

/// Where the address for the next block comes from.
///
/// **For Jellyfin and for the provider it is fixed** — ``FixedAddress``. For a portal it
/// applies for five minutes, and then the session asks the bridge again. That is the whole
/// difference between the three sources at this point, and it sits in a protocol instead of
/// in a case distinction.
public protocol AddressProvider: Sendable {
    /// The address, its deadline and the headers to go with it.
    func address() async throws -> TargetAddress

    /// Fall back to the **next** source — `false` means: there is none left.
    ///
    /// **The reason this is here and not in the session:** Which hosts exist is known only to
    /// whoever resolves. The session, in turn, is the only one that knows **when** it is worth
    /// it — namely exactly when a response carries no ranges
    /// (``LoadError/notResumable(_:)``). Each of the two halves in the wrong place would
    /// have dragged the other along.
    ///
    /// **Built on 2026-09-09, as the redemption of a comment.** ``DownloadChoice`` promised in so many
    /// words: *"If the chosen host does not carry, the job takes the next one — without
    /// asking."* Until then only the throwing was built; **not a single caller in the project
    /// caught the error.** At Animehub four hosts are on offer and three carry — a download job
    /// that gives up at the first one therefore fails in three of four cases on a choice that
    /// nobody made.
    func fallBack() async -> Bool
}

extension AddressProvider {

    /// **Without a response of its own there is no fallback.** Media server and provider hold
    /// exactly one file per title; "take another host" has no target there.
    public func fallBack() async -> Bool { false }
}

public struct FixedAddress: AddressProvider {
    private let url: URL
    public init(_ url: URL) { self.url = url }
    public func address() async throws -> TargetAddress { TargetAddress(url) }
}

/// What can go wrong when loading — **and every case carries its own sentence.**
///
/// A common error message would be particularly expensive here: "Not resumable" demands a
/// different host, "different file" demands a fresh start, and "no space" demands cleaning
/// up. Hiding three different next steps behind one warning triangle is exactly the
/// half-built state that Streamyfin's users complain about.
///
/// **Since 2026-09-09 the rule is also redeemed.** Until then each of these cases ended on
/// screen as `network("CancellationError()")` or as raw Swift text under a warning triangle —
/// that is, as exactly the one error message this type was built against. The sentences are
/// in ``TransferText/loadText(_:)``, one per case, each with the next step.
///
/// **`Hashable` and `Sendable`, because ``Transfer/Situation`` now carries the error**
/// instead of a string. A string would have lost the case distinction, and the view would
/// have to guess it back from Swift internals.
public enum LoadError: Error, Equatable, Hashable, Sendable {
    case notResumable(String)
    case differentFile
    case noSpace
    case wasCancelled
    case network(String)

    /// The job cannot be started at all — **no folder or no resolution.**
    ///
    /// **A case of its own and not `network("")`.** Until 2026-09-09 an empty string stood here, and
    /// on screen a red warning triangle **without text**. That is not a network error: It is a
    /// job that lacks the store or the playback job, and the next step is a different one.
    case notReady

    /// **The file arrived damaged** — wrong size or wrong checksum at the end (check wrapper
    /// H5, 2026-09-27). The partial file is discarded; a new attempt starts from the
    /// beginning. Before, such a file was reported as finished and was noticed only on
    /// playback.
    case corrupted

    /// **Something was delivered for which there is no download path — and the reason is
    /// attached.**
    ///
    /// **A product question of 2026-09-09 forced this case:** *"are there common formats that
    /// we forgot to consider? … can this be made universal?"* Until then every delivery that
    /// was not a range request ended as ``network(_:)`` — on screen "Connection lost", for a
    /// response that had arrived flawlessly. The viewer waited for better network, and better
    /// network never helped.
    ///
    /// **The cases are at ``DeliveryKind/Rejection`` and not here**, because there they sit together
    /// with the measurement they come from. Here it only says that there is one.
    case notLoadable(DeliveryKind.Rejection)
}
