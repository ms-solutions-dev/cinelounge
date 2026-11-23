import Foundation

/// Where the subtitle line has to sit so that it survives a filled picture.
///
/// **Filling cuts away exactly what the subtitles are there for.** Anyone who fills
/// a 4:3 home video on a 19.5:9 screen loses a fifth of the picture height at the
/// top and bottom — and the subtitles are at the bottom. On the TV the question
/// never arises: There the picture has always been ``ImageLayout/fullImage``, and the
/// line sits where the engine puts it.
///
/// **Computed and not guessed.** A fixed offset ("ten percent higher") would be
/// too much at 21:9 and too little at 4:3; how far the line has to move depends on
/// both aspect ratios. That is why the calculation lives here, next to
/// ``SubtitleStyle``, and not in the engine: This way it can be checked without
/// building a player.
public enum SubtitleLayout {

    /// What fraction of the picture height remains visible when filling — 0 to 1.
    ///
    /// **Filling always goes in one direction, not both.** If the picture is wider than
    /// the surface (21:9 on 19.5:9), something is cut off left and right and the
    /// height stays whole — the subtitles do not notice. Only when the picture is
    /// **narrower** than the surface does the fill cut at the top and bottom. That is
    /// the case this calculation exists for.
    ///
    /// For unusable numbers the answer is 1: An engine that does not know a size yet
    /// reports 0 — deducing a cut from that would mean moving the line for no reason.
    public static func visibleFraction(image: Double, screen: Double) -> Double {
        guard image.isFinite, screen.isFinite, image > 0, screen > 0 else { return 1 }
        return min(1, image / screen)
    }

    /// Where the line should sit, in percent of the **picture height** from the top —
    /// `nil` if nothing needs to be moved.
    ///
    /// **The line keeps its place, only within the visible band.** It sits where it
    /// would sit in the whole picture — at nine tenths of the height —, but measured
    /// against the band that remains after the cut. That way it moves up exactly as far
    /// as is cut away at the bottom, and not one point further: A subtitle that
    /// suddenly stands in the middle of the picture is as wrong as one that cannot be
    /// seen.
    ///
    /// **`nil` and not 90 for an uncut picture.** Returning a number here would
    /// prescribe a rule to the engine where so far the system's accessibility settings
    /// applied — and those belong to the viewer as long as nothing displaces them.
    public static func linePlacement(visibleFraction portion: Double) -> Int? {
        guard portion.isFinite, portion > 0, portion < Self.threshold else { return nil }
        let margin = (1 - portion) / 2
        return Int((margin + portion * Self.restingSpace) * 100 + 0.5)
    }

    /// Where the line sits in the uncut picture — nine tenths of the height.
    ///
    /// That is the position WebVTT assumes without its own setting; repeating it here
    /// is not an invention but the reference value against which the shift is made.
    static let restingSpace = 0.9

    /// From when a cut counts as one.
    ///
    /// **Two percent tolerance**, the same limit as at ``PictureFill`` in the phone
    /// project: A picture that almost hits the surface is trimmed by a few lines by the
    /// fill — moving the line for that would be a visible movement for an invisible
    /// gain.
    static let threshold = 0.98
}
