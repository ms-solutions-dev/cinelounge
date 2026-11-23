import Foundation

#if canImport(UIKit)
    import UIKit
#endif

/// One of the sixteen bundled profile pictures — **name, face center, magnification.**
///
/// **One image, two drawings** (product decision of 2026-09-25, concept AP49,
/// addendum N1/N2): the whole motif is the title image, the profile circle shows an
/// enlarged crop around the face. The motifs are whole scenes — figure in the middle,
/// surroundings all around —, an inscribed circle would mostly show surroundings.
///
/// **The values are read off the image and not estimated** (2026-09-25, each of the
/// 512² PNGs opened with a grid in tenths): ``midpoint`` is the center of the face — between
/// eyes and mouth, horizontally between the cheeks —, ``zoom`` is chosen so that head and
/// shoulders fill the circle and hair, hat, helmet and ears are not cut off.
/// Where the figure already touches the top edge in the image (`comic-leserin`), the circle
/// does not cut off more than the image itself.
///
/// **Pure values, `Sendable` and without a view type** — the same rule as for
/// ``ProfileKit/ColorTag``: both programs read this directory, and each draws for itself.
/// The computation from center and zoom to an offset is therefore also here
/// (``slice``, ``offset(edge:)``), so that TV and phone show the same crop and not
/// two versions of it.
public struct AvatarMotif: Sendable, Equatable, Hashable, Identifiable {

    /// A point in the image, **in fractions of the edge** — `0…1`, top left is `(0, 0)`.
    public struct Point: Sendable, Equatable, Hashable {
        public let x: Double
        public let y: Double

        public init(x: Double, y: Double) {
            self.x = x
            self.y = y
        }
    }

    /// The asset name — **also the value in ``ProfileKit/avatar``** and the file name in
    /// `Assets.xcassets/Avatare/`.
    public let name: String
    /// The face center the circle aims at.
    public let midpoint: Point
    /// How much the circle magnifies: `1` shows the whole image, `2` half the edge.
    public let zoom: Double
    /// The language key for the announcement — **a short name of the motif.**
    ///
    /// Written out and not built from ``name``: `scripts/strings.py` reads strings as
    /// usage, and a composed key would be invisible to it — a missing one would show up only
    /// on the TV, as `profiles.avatar…` in the VoiceOver voice.
    public let info: String

    public var id: String { name }

    public init(name: String, midpoint: Point, zoom: Double, info: String) {
        self.name = name
        self.midpoint = midpoint
        self.zoom = zoom
        self.info = info
    }

    // MARK: - The catalog

    /// All sixteen, **in the order of the grid** (4 × 4).
    ///
    /// The names are **written out** and not composed (house rule, concept 4.4):
    /// that way anyone searching for a file name finds them, and
    /// `AvatarMotifTests/everyMotifHasAnImage` checks each against the asset directories.
    public static let all: [AvatarMotif] = [
        AvatarMotif(
            name: "comic-leserin", midpoint: Point(x: 0.49, y: 0.34), zoom: 1.5,
            info: "profiles.avatar.comicLeserin"),
        AvatarMotif(
            name: "couch-papa", midpoint: Point(x: 0.48, y: 0.38), zoom: 1.7,
            info: "profiles.avatar.couchPapa"),
        AvatarMotif(
            name: "frau-innenhof", midpoint: Point(x: 0.50, y: 0.38), zoom: 1.6,
            info: "profiles.avatar.frauInnenhof"),
        AvatarMotif(
            name: "junge-am-meer", midpoint: Point(x: 0.50, y: 0.35), zoom: 1.6,
            info: "profiles.avatar.jungeAmMeer"),
        AvatarMotif(
            name: "katze-cay-schlaeferin", midpoint: Point(x: 0.60, y: 0.45), zoom: 2.0,
            info: "profiles.avatar.katzeCaySchlaeferin"),
        AvatarMotif(
            name: "katze-treppen-pascha", midpoint: Point(x: 0.41, y: 0.40), zoom: 1.7,
            info: "profiles.avatar.katzeTreppenPascha"),
        AvatarMotif(
            name: "kettenbaby", midpoint: Point(x: 0.52, y: 0.46), zoom: 1.4,
            info: "profiles.avatar.kettenbaby"),
        AvatarMotif(
            name: "kleiner-astronaut", midpoint: Point(x: 0.49, y: 0.46), zoom: 1.4,
            info: "profiles.avatar.kleinerAstronaut"),
        AvatarMotif(
            name: "nasebohr-baby", midpoint: Point(x: 0.50, y: 0.42), zoom: 1.5,
            info: "profiles.avatar.nasebohrBaby"),
        AvatarMotif(
            name: "opa-teekanne", midpoint: Point(x: 0.49, y: 0.33), zoom: 1.6,
            info: "profiles.avatar.opaTeekanne"),
        AvatarMotif(
            name: "popcorn-waschbaer", midpoint: Point(x: 0.47, y: 0.41), zoom: 1.5,
            info: "profiles.avatar.popcornWaschbaer"),
        AvatarMotif(
            name: "samurai-tempelgarten", midpoint: Point(x: 0.52, y: 0.34), zoom: 1.8,
            info: "profiles.avatar.samuraiTempelgarten"),
        AvatarMotif(
            name: "skater-girl", midpoint: Point(x: 0.50, y: 0.39), zoom: 1.45,
            info: "profiles.avatar.skaterGirl"),
        AvatarMotif(
            name: "strick-oma", midpoint: Point(x: 0.51, y: 0.36), zoom: 1.5,
            info: "profiles.avatar.strickOma"),
        AvatarMotif(
            name: "strohhut-maedchen", midpoint: Point(x: 0.50, y: 0.48), zoom: 1.35,
            info: "profiles.avatar.strohhutMaedchen"),
        AvatarMotif(
            name: "zeichnerin-zug", midpoint: Point(x: 0.40, y: 0.35), zoom: 1.6,
            info: "profiles.avatar.zeichnerinZug"),
    ]

    /// The motif for a profile picture name — **`nil` means: draw the letter.**
    ///
    /// The first of the two fallbacks from concept 4.4: `nil`, an empty name **and a name
    /// this directory does not know**. The third case occurs as soon as the set grows and a
    /// device runs an older version. The second fallback — the name is listed here, the bundle
    /// still does not have the image — belongs to the UI, because only it can ask its bundle.
    public static func motif(forItem name: String?) -> AvatarMotif? {
        guard let name, !name.isEmpty else { return nil }
        return all.first { $0.name == name }
    }

    // MARK: - Bild oder Buchstabe

    /// What the profile circle draws — **decided in a computation and not in the body.**
    ///
    /// **Here since AP58 R2** (finding P6): the computation stood character for character in
    /// the TV's profile circle and in the phone's.
    public enum Presentation: Sendable, Equatable {
        case image(AvatarMotif)
        case letter
    }

    /// Image or letter — **with both fallbacks from concept 4.4.**
    ///
    /// 1. No name, an empty one or an unknown one: ``motif(forItem:)`` returns no motif. This
    ///    happens as soon as the set grows and a device carries an older version than the one
    ///    that wrote the name to the cloud.
    /// 2. The directory knows the name, **the bundle does not have the image.** `Image("…")`
    ///    would then silently draw nothing — an empty circle, indistinguishable from a load
    ///    failure. That is why it asks first.
    public static func appearance(
        avatar: String?, imageExists: (String) -> Bool = inAppBundle
    ) -> Presentation {
        guard let motif = motif(forItem: avatar), imageExists(motif.name) else { return .letter }
        return .image(motif)
    }

    /// Whether the **app bundle** carries this image — `in: .main`, not the package bundle.
    ///
    /// The avatars live in the program's asset catalog; `Image("…")` in a package would search
    /// the package's bundle and find nothing there. On the machine running `swift test` there
    /// is no `UIImage` — there the answer is always no, and the letter is drawn.
    public static func inAppBundle(_ name: String) -> Bool {
        #if canImport(UIKit)
            UIImage(named: name, in: .main, with: nil) != nil
        #else
            false
        #endif
    }

    // MARK: - The circle crop

    /// The magnification, **never below 1.** A circle that wanted to show more than the image
    /// would show emptiness at the edges.
    public var effectiveZoom: Double { max(zoom, 1) }

    /// Where the circle really aims — ``midpoint``, **clamped so that the crop stays entirely
    /// within the image.**
    ///
    /// At zoom `z` the circle shows a window of `1/z` of the edge. Its center must therefore
    /// be at least `1/(2z)` from the edge; otherwise a strip of background would be in the
    /// circle, and it would look like a load failure. The clamping prefers moving the face
    /// off-center to showing beyond the edge.
    public var slice: Point {
        let half = 1 / (2 * effectiveZoom)
        return Point(x: Self.clamp(midpoint.x, half), y: Self.clamp(midpoint.y, half))
    }

    /// The offset for a drawing with `scaleEffect(zoom)` around the center — **in the same
    /// unit as `edge`.**
    ///
    /// The image fills a square of edge `edge`, is magnified around its center by
    /// ``effectiveZoom`` and then shifted by this offset. After magnification the point
    /// ``slice`` lies at `edge · (0,5 + z · (a − 0,5))`; the offset pushes it back to
    /// the center. Positive downward and to the right, like `offset` in SwiftUI.
    public func offset(edge: Double) -> (x: Double, y: Double) {
        let z = effectiveZoom
        let a = slice
        return (x: -edge * z * (a.x - 0.5), y: -edge * z * (a.y - 0.5))
    }

    private static func clamp(_ value: Double, _ half: Double) -> Double {
        min(max(value, half), 1 - half)
    }
}
