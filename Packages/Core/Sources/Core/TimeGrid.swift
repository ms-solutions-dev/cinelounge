import CoreMedia

/// The time grid of a track — and snapping to it. For picture (from
/// `DefaultDuration`) as for audio (from frame length and sample rate).
///
/// **The finding F-005 (2026-09-04, S latple Micutror):** Zero dropouts, zero discarded
/// pictures, every piece fetched once — and yet "stutters, does not play
/// smoothly". Matroska writes timestamps in milliseconds; at 23.976 pictures per
/// second a picture is 41.708 ms long, so the stamps alternate between 41 and 42.
/// The repackager gave each picture its stamp, the writer derived the duration from
/// it, and the TV got pictures of 41, 42, 42, 41 ms instead of exactly 41.708. The
/// server path (ffmpeg) writes exact times — that is why the same film played
/// smoothly there.
///
/// The file names its grid itself: `DefaultDuration` of the picture track in
/// nanoseconds (41 708 333 for 23.976). From that an exact fraction is formed
/// (1001/24000), and every stamp that deviates from the grid point by at most one
/// and a half milliseconds snaps to it. What deviates further — files with a
/// changing frame rate — stays as it is.
public struct TimeGrid: Sendable {
    /// A picture, as an exact fraction.
    public let step: CMTime
    /// The phase of the grid: where the first grid point lies. **Not always zero** —
    /// S latple Micutror lies half a picture length (21 ms) off the grid starting at zero,
    /// evenly across the whole film.
    public var anchor: CMTime = .zero
    /// Up to what distance snapping happens.
    public static let tolerance: TimeInterval = 0.0015

    /// The known frame rates, as the duration of one picture (numerator, denominator).
    static let known: [(Int64, Int32)] = [
        (1001, 24000), (1, 24), (1, 25), (1001, 30000), (1, 30), (1, 50), (1001, 60000), (1, 60),
    ]

    /// - Parameters:
    ///   - nanosekundenJeBild: `DefaultDuration` of the track — or an average from
    ///     measured stamps.
    ///   - nurBekannte: Whether only one of the known frame rates yields a grid.
    ///     **Yes for estimates**: An average from stamps of a file with a changing
    ///     frame rate is no grid.
    public init?(nanosecondsPerFrame: UInt64?, knownOnly: Bool = false) {
        guard let toNanoseconds = nanosecondsPerFrame, toNanoseconds > 0 else { return nil }
        let seconds = Double(toNanoseconds) / 1e9
        guard seconds >= 1.0 / 480, seconds <= 1 else { return nil }
        // 24.000 and 23.976 are 0.1 % apart — the limit has to lie below that, otherwise
        // one turns into the other.
        if let (counter, denominator) = Self.known.first(where: {
            abs(Double($0.0) / Double($0.1) - seconds) / seconds < 0.0005
        }) {
            step = CMTime(value: counter, timescale: denominator)
        } else if knownOnly {
            return nil
        } else {
            step = CMTime(value: CMTimeValue(toNanoseconds), timescale: CMTimeScale(NSEC_PER_SEC))
        }
    }

    /// A grid from frame length and sample rate — for audio.
    public init(step: CMTime) {
        self.step = step
    }

    /// The time base in which every step comes out as an integer.
    ///
    /// 24000 for 23.976, 30000 for 29.97, 60000 for 59.94 — and 90 000 for everything
    /// integral (24, 25, 30, 50, 60 all divide into it). AVAssetWriter would otherwise
    /// take 600, and 23.976 pictures per second are 25.025 ticks in it: alternately 25
    /// and 26, once again a cadence instead of a beat.
    public var timebase: CMTimeScale {
        step.value == 1001 ? step.timescale : 90_000
    }

    /// Snaps a time to the grid starting at zero — or leaves it if it is too far off.
    /// **Starting at zero**, not at the first picture: Every piece of a file is made on
    /// its own, and only a common anchor lets the pieces butt together exactly at the
    /// seam.
    public func snap(_ time: CMTime) -> CMTime {
        let seconds = (time - anchor).seconds
        guard seconds.isFinite, step.seconds > 0 else { return time }
        let n = (seconds / step.seconds).rounded()
        guard n >= 0, n < Double(Int32.max) else { return time }
        let ideal = anchor + CMTimeMultiply(step, multiplier: Int32(n))
        guard abs((time - ideal).seconds) <= Self.tolerance else { return time }
        return ideal
    }

    /// Detects the grid from many stamps over a long stretch — the times of the seek
    /// table.
    ///
    /// **At the start of the file 24.000 and 23.976 cannot be told apart**: Over two
    /// seconds the two grids are less than 0.1 ms apart. Over two hours they are 7 s
    /// apart. The stamps of the seek table (keyframes, rounded to milliseconds)
    /// therefore all lie within half a millisecond only on the right grid — on every
    /// other one they scatter evenly across the step.
    ///
    /// - Parameters:
    ///   - marken: Times in units of the file (`TimestampScale`).
    ///   - skala: Nanoseconds per unit.
    public static func detect(marks: [Int64], scale: UInt64) -> TimeGrid? {
        guard marks.count >= 8, scale > 0 else { return nil }
        let seconds = marks.map { Double($0) * Double(scale) / 1e9 }
        for (counter, denominator) in known {
            let step = Double(counter) / Double(denominator)
            let probe = GridProbe(seconds: seconds, step: step)
            // **Not all, but almost all**: A table over two hours may have individual crooked
            // stamps (a cut, a break in the stream); on the wrong grid, by contrast, only a
            // few fit.
            guard probe.matching * 20 >= probe.deviations.count * 19 else { continue }
            var phase = probe.reference + probe.midpoint
            if phase >= step { phase -= step }
            if phase < 0 { phase += step }
            var raster = TimeGrid(step: CMTime(value: counter, timescale: denominator))
            raster.anchor = CMTime(seconds: phase, preferredTimescale: CMTimeScale(NSEC_PER_SEC))
            return raster
        }
        return nil
    }

    /// What the detection saw per known frame rate — for diagnostics and probe, when
    /// ``detect(marks:scale:)`` yielded nothing.
    public static func checkReport(marks: [Int64], scale: UInt64) -> String {
        guard marks.count >= 2, scale > 0 else { return "zu wenige Marken" }
        let seconds = marks.map { Double($0) * Double(scale) / 1e9 }
        var rows: [String] = []
        for (counter, denominator) in known.prefix(4) {
            let step = Double(counter) / Double(denominator)
            let probe = GridProbe(seconds: seconds, step: step)
            let bad = probe.deviations.enumerated()
                .filter { abs($0.element - probe.midpoint) > 0.00075 }.prefix(3)
                .map { String(format: "#%d %+.2f ms", $0.offset, ($0.element - probe.midpoint) * 1000) }
            rows.append(
                "\(counter)/\(denominator): \(probe.matching) of \(probe.deviations.count) matching, midpoint "
                    + String(format: "%+.2f ms", probe.midpoint * 1000)
                    + (bad.isEmpty ? "" : ", e.g. " + bad.joined(separator: " ")))
        }
        return rows.joined(separator: "; ")
    }

    /// The residuals of all stamps against a candidate grid starting at zero, their
    /// center and how many lie close enough.
    ///
    /// **The common core of ``detect(marks:scale:)`` and
    /// ``checkReport(marks:scale:)``** — until 2026-09-27 written twice (repackager
    /// review, finding 6), with the risk that a change in one place forgets the other.
    /// On the right grid the residuals all lie together (the phase), on every other one
    /// they scatter across the whole step. Around the center, not around the first
    /// stamp: If the file rounds down (S latple Micutror: 2085 for 2085.4), the stamps
    /// scatter one millisecond wide below the grid — the center lies at half of that,
    /// and ±0.75 ms around it catches all of them.
    private struct GridProbe {
        let reference: Double
        let deviations: [Double]
        let midpoint: Double
        let matching: Int

        init(seconds: [Double], step: Double) {
            let remainders = seconds.map { $0 - ($0 / step).rounded(.down) * step }
            let reference = remainders[0]
            let deviations = remainders.map { rest -> Double in
                var d = rest - reference
                if d > step / 2 { d -= step }
                if d < -step / 2 { d += step }
                return d
            }
            let sortedEntries = deviations.sorted()
            let midpoint = sortedEntries[sortedEntries.count / 2]
            self.reference = reference
            self.deviations = deviations
            self.midpoint = midpoint
            self.matching = deviations.filter { abs($0 - midpoint) <= 0.00075 }.count
        }
    }

    /// Estimates the step from the stamps of a piece — by a best-fit line, when the
    /// seek table yields no global grid.
    ///
    /// **S latple Micutror has no global grid:** every five seconds a picture is missing
    /// (83 ms instead of 42), the phase drifts across the film. Locally the axis is
    /// nevertheless regular, and the step can be determined from 48 stamps to a
    /// hundredth of a millisecond — enough to separate 23.976 from 24.000 (0.04 ms
    /// difference). Gaps are counted as skipped pictures, not as distance.
    ///
    /// The grid does not accept more than one second per picture anyway; above that
    /// the conversion to nanoseconds would halt the process for stamps from a nonsense
    /// time scale (repackager review, follow-up 2026-09-27) — then there is no grid.
    public static func estimate(marks: [Int64], scale: UInt64) -> TimeGrid? {
        guard marks.count >= 24, scale > 0 else { return nil }
        let times = marks.sorted().map { Double($0) * Double(scale) / 1e9 }
        let gaps = zip(times, times.dropFirst()).map { $1 - $0 }.filter { $0 > 0 }
        guard !gaps.isEmpty else { return nil }
        let median = gaps.sorted()[gaps.count / 2]
        guard median > 0 else { return nil }
        // Picture numbers: A distance of two medians is a skipped picture.
        var numbers: [Double] = [0]
        for spacing in zip(times, times.dropFirst()).map({ $1 - $0 }) {
            numbers.append(numbers[numbers.count - 1] + max(1, (spacing / median).rounded()))
        }
        let n = Double(times.count)
        let mx = numbers.reduce(0, +) / n
        let my = times.reduce(0, +) / n
        var counter = 0.0
        var denominator = 0.0
        for (x, y) in zip(numbers, times) {
            counter += (x - mx) * (y - my)
            denominator += (x - mx) * (x - mx)
        }
        guard denominator > 0 else { return nil }
        let step = counter / denominator
        guard step.isFinite, step > 0, step <= 1 else { return nil }
        return TimeGrid(nanosecondsPerFrame: UInt64(step * 1e9), knownOnly: true)
    }

}
