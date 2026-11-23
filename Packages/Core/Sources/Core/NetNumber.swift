import Foundation

/// Conversions for numbers that come from a stream or a file.
///
/// **Data from the network is never trustworthy** (remuxer check 2026-09-27). Swift
/// halts the whole process on `Int(UInt64)`, `Int(Double.nan)`, a range `1..<0` or
/// an overflow — without an error message, without a trace, in the middle of the
/// film. A cluster time of eight `0xFF`, a sample rate `NaN` or a time scale above
/// `Int64.max` were enough for that. Such values are no reason to crash, but a
/// reason to discard the spot or to report the file as unreadable.
///
/// **One place for all parsers** (Matroska, transport, CMAF, codecs): whoever
/// rebuilds the check at every call site forgets it at the next. The functions say
/// with their return type what happens in the error case:
///
/// * `Optional` — the value is unusable, the caller discards it.
/// * saturated — the calculation goes on, held at the limit. Only for times whose
///   nonsense is already reported elsewhere or stays without consequence.
enum NetNumber {

    /// An unsigned number as `Int` — `nil` if it does not fit.
    static func total(_ value: UInt64) -> Int? { Int(exactly: value) }

    /// An unsigned number as `Int64` — `nil` if it does not fit.
    static func int64(_ value: UInt64) -> Int64? { Int64(exactly: value) }

    /// A floating-point number, rounded, as `Int` — `nil` for `NaN`, `±∞` or outside
    /// the value range.
    static func roundedValue(_ value: Double) -> Int? {
        guard value.isFinite else { return nil }
        return Int(exactly: value.rounded())
    }

    /// A floating-point number as `Int32`, held in `area` — `NaN` becomes the lower
    /// bound. For multiples that go to `CMTimeMultiply`.
    static func clamped(_ value: Double, in area: ClosedRange<Int32>) -> Int32 {
        guard value.isFinite else { return area.lowerBound }
        let rounded = value.rounded()
        if rounded <= Double(area.lowerBound) { return area.lowerBound }
        if rounded >= Double(area.upperBound) { return area.upperBound }
        return Int32(rounded)
    }

    /// A product — `nil` on overflow.
    static func product(_ a: Int64, _ b: Int64) -> Int64? {
        let (value, overflow) = a.multipliedReportingOverflow(by: b)
        return overflow ? nil : value
    }

    /// A product, held at the limit of the value range.
    static func saturatedProduct(_ a: Int64, _ b: Int64) -> Int64 {
        let (value, overflow) = a.multipliedReportingOverflow(by: b)
        guard overflow else { return value }
        return (a < 0) == (b < 0) ? .max : .min
    }

    /// A sum, held at the limit of the value range.
    static func saturatedSum(_ a: Int64, _ b: Int64) -> Int64 {
        let (value, overflow) = a.addingReportingOverflow(b)
        guard overflow else { return value }
        return b < 0 ? .min : .max
    }

    /// A sum — `nil` on overflow.
    static func sum(_ a: Int, _ b: Int) -> Int? {
        let (value, overflow) = a.addingReportingOverflow(b)
        return overflow ? nil : value
    }

    /// A timestamp of the file in nanoseconds — `nil` if the product with the time scale
    /// overflows.
    static func toNanoseconds(_ tag: Int64, scale: UInt64) -> Int64? {
        guard let scale = int64(scale) else { return nil }
        return product(tag, scale)
    }

    /// `value · counter / denominator`, without the intermediate product overflowing — for
    /// the division of a file whose length a server claims. The share is limited to
    /// `0...1`, so the result always fits.
    static func portion(_ value: Int, mal counter: Int, finished denominator: Int) -> Int {
        guard denominator > 0, value >= 0, counter >= 0 else { return 0 }
        guard counter < denominator else { return value }
        return denominator.dividingFullWidth(value.multipliedFullWidth(by: counter)).quotient
    }
}
