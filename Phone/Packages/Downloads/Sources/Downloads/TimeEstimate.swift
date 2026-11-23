import Foundation

/// When a download job is finished — **the number a progress bar does not tell.**
///
/// **The reason lies in two measurements of this project.** Measured on 2026-09-06 from the same phone:
/// in a dead spot **0.6 Mbit/s**, outside **7.34** — and the difference is a
/// change of location, not noise. Ten gigabytes are thus once three hours and once
/// thirty-eight. A bar that shows both the same is no information; at
/// thirty-eight hours it is a lie in green.
///
/// **That is why the downloads calculate in times of day and not in percent.** "6.2 GB to go · done
/// around tomorrow 04:20" answers the question that is really asked before a flight.
public enum TimeEstimate {

    /// How long the remainder takes at this rate — `nil` if no number results.
    ///
    /// **Without a measurement nothing is guessed.** `BandwidthMemory` returns `nil`
    /// as long as nothing has been measured on this path; here that ends in `nil` and not in
    /// a default. An invented finish time would be worse than none — it looks
    /// like a measurement.
    public static func duration(bytes: Int64, mbit: Double) -> TimeInterval? {
        guard bytes > 0, mbit.isFinite, mbit > 0 else { return nil }
        // A megabit is 1,000,000 bits; a byte is eight. Not 1,048,576: lines
        // are counted decimally, files in binary, and whoever mixes both is off by 5 %.
        return Double(bytes) * 8 / (mbit * 1_000_000)
    }

    public static func finishesAt(bytes: Int64, mbit: Double, from now: Date) -> Date? {
        duration(bytes: bytes, mbit: mbit).map { now.addingTimeInterval($0) }
    }

    /// How many bytes a playing time occupies at this rate.
    ///
    /// Needed by the top-up and by the size estimate in the download sheet: the
    /// **running time** is known, and the calculation is in gigabytes.
    ///
    /// *Until 2026-09-09 this said "Needed by ``Reiseplanung``" — that is deleted;
    /// the other two callers were already there before.*
    public static func bytes(forItem duration: TimeInterval, mbit: Double) -> Int64 {
        guard duration > 0, mbit.isFinite, mbit > 0 else { return 0 }
        return Int64((duration * mbit * 1_000_000 / 8).rounded())
    }

    /// The same calculation for a running time that **may not exist at all** — and then
    /// the answer is `nil` and not a number.
    ///
    /// **Finding of 2026-09-09, from the product owner on the simulator:** *"it feels like all
    /// portal content is always 720 MB."* He was right, and it was not an estimate
    /// but a constant: ``DownloadChoice`` assumed 48 minutes without any running-time information,
    /// times 2 Mbit/s (``SelectionRule/suggestion``) that is exactly 720,000,000 to the byte —
    /// for **every** title of the same tier, regardless of what it is. Re-measured at the bridge
    /// (Bloufeit S1E1, Serieshub, HOSTA): `content-range: bytes 0-1/561149891`,
    /// so 561 MB. The fixed number was 28 % off and looked like information.
    ///
    /// **This is the same principle as above at ``duration(bytes:mbit:)``**, just on the
    /// other side of the equation: without a measurement nothing is guessed. `nil` means "nobody
    /// knows", and the display then writes nothing instead of something wrong.
    ///
    /// **The name is deliberately different** and not an overload of
    /// ``bytes(forItem:mbit:)``: two versions that differ only in the optionality of one
    /// argument are picked by the compiler by type — and whoever later makes a running time
    /// optional silently changes the meaning of the return value.
    public static func bytes(forRuntime runtime: TimeInterval?, mbit: Double) -> Int64? {
        guard let runtime, runtime > 0, mbit.isFinite, mbit > 0 else { return nil }
        return bytes(forItem: runtime, mbit: mbit)
    }
}
