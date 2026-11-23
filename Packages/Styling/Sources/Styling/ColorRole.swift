/// The roles of a ``ColorBoard`` — **what a colour does, not what it is called.**
///
/// Both devices had the same roles under different names (`surface` versus `surface`,
/// `brand` versus `rot`). The name `rot` was already wrong as soon as a scheme
/// carries a blue brand colour. The roles here are the shared language; the old names forward
/// to them in the platform layers.
public enum ColorRole: String, Sendable, CaseIterable {
    case reason = "grund", surface = "flaeche", surfaceHigh = "flaecheHoch", line = "linie", lineQuiet =
        "linieLeise"
    case text, textMatt, textQuiet = "textLeise", textOnLight = "schriftAufHell"
    case outline = "umriss", outlineSheet = "umrissBlatt"
    case tag = "marke", brandLight = "markeHell", brandDeep = "markeTief", progress = "fortschritt", live,
        success = "erfolg"
    case deep = "tief", audio = "ton"

    /// The surfaces on which reading takes place — every font must hold up on each of them.
    public static let backgrounds: [ColorRole] = [.reason, .surface, .surfaceHigh]

    /// The fonts for ordinary text — 4.5 : 1 on every ``backgrounds``.
    public static let captions: [ColorRole] = [.text, .textMatt, .textQuiet]

    /// The signals that appear as a word or bar on the background.
    public static let signals: [ColorRole] = [.progress, .live, .success]
}
