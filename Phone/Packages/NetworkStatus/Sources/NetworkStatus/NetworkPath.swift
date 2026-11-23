/// What the phone is currently connected through.
///
/// **"Expensive" is an indication of its own and not the same as cellular.** A hotspot is
/// Wi-Fi and still expensive; so is a company Wi-Fi with a data cap. The system reports
/// both separately, and whoever lumps them together later takes a hotspot for a home
/// network.
public struct NetworkPath: Sendable, Equatable, Hashable {

    public enum Kind: String, Sendable, CaseIterable {
        case wifi = "wlan"
        case cellular = "mobilfunk"
        case wired = "kabel"
        /// Something that cannot be classified — **now only set, never reported.**
        ///
        /// Until 2026-09-13 a tunnel was translated to this, and that hid airplane mode: A full tunnel
        /// leaves its interface standing when nothing lies underneath. Since then what carries
        /// under the tunnel counts; see ``NetworkPath/init(_:)`` in `NetworkWatch.swift`.
        case other = "anderes"
        case none = "keines"
    }

    public let kind: Kind

    /// The system considers this connection expensive — cellular or hotspot.
    public let expensive: Bool

    /// The viewer has switched on "Low Data Mode".
    ///
    /// An explicit request, and not an assumption about the line. It therefore weighs more
    /// than any measurement of our own.
    public let frugal: Bool

    public init(kind: Kind, expensive: Bool = false, frugal: Bool = false) {
        self.kind = kind
        self.expensive = expensive
        self.frugal = frugal
    }

    public static let none = NetworkPath(kind: .none)

    /// Whether anything works at all.
    public var carries: Bool { kind != .none }

    /// Whether large amounts of data are acceptable now.
    ///
    /// Downloads ask here, and the answer is deliberately strict: When in doubt, not loading
    /// is a postponed movie, when in doubt, loading is a bill.
    public var largeVolumesAcceptable: Bool {
        carries && !expensive && !frugal
    }
}
