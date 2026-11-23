import Foundation
import SourceProbe
import Testing

@testable import ProfileKit

/// The directory of the sixteen profile pictures and the computation for the circle (AP49).
@Suite("The profile pictures")
struct AvatarMotifTests {

    /// The avatars in the TV's app bundle — **the real files**, so that the
    /// check sees the same ones that `actool` compiles.
    static let avatarFolder = CodeLocation.tvImages.url.appending(path: "Avatare")

    /// The names of the image sets in the folder, **only those with a PNG file in them.**
    static func imageSets() throws -> Set<String> {
        let files = FileManager.default
        let entries = try files.contentsOfDirectory(atPath: avatarFolder.path())
        var names: Set<String> = []
        for entry in entries where entry.hasSuffix(".imageset") {
            let name = String(entry.dropLast(".imageset".count))
            let image = avatarFolder.appending(path: entry).appending(path: name + ".png")
            if files.fileExists(atPath: image.path()) { names.insert(name) }
        }
        return names
    }

    /// **No name without an image and no image without a name.** A name without an image would be
    /// an empty tile in the picker; an image without a name would sit in the bundle and never be selectable.
    /// `Image("…")` is silent in both cases — that is why this is here.
    @Test("Every motif has an image in the bundle, every image a motif")
    func everyMotifHasAnImage() throws {
        let names = AvatarMotif.all.map(\.name)
        #expect(names.count == 16)
        #expect(Set(names).count == names.count)
        #expect(try Self.imageSets() == Set(names))
    }

    @Test("The lookup keys are unique and in the profiles' namespace")
    func info() {
        let key = AvatarMotif.all.map(\.info)
        #expect(Set(key).count == 16)
        #expect(key.allSatisfy { $0.hasPrefix("profiles.avatar.") })
    }

    /// The first fallback from concept 4.4: **no motif means letter** — also for a
    /// name from a newer version with a larger set.
    @Test("Nil, empty and unknown yield no motif")
    func fallback() {
        #expect(AvatarMotif.motif(forItem: nil) == nil)
        #expect(AvatarMotif.motif(forItem: "") == nil)
        #expect(AvatarMotif.motif(forItem: "drache-im-nebel") == nil)
        #expect(AvatarMotif.motif(forItem: "strick-oma")?.name == "strick-oma")
    }

    // MARK: - Die Rechnung

    @Test("A motif in the middle of the image needs no offset")
    func centerWithoutOffset() {
        let motif = AvatarMotif(
            name: "probe", midpoint: .init(x: 0.5, y: 0.5), zoom: 1.8, info: "probe")
        let offset = motif.offset(edge: 180)
        #expect(offset.x == 0)
        #expect(offset.y == 0)
    }

    /// `edge · z · (0,5 − a)`: At zoom 2 and a center 0.1 to the right of the image
    /// center, the image shifts left by a fifth of the edge.
    @Test("The offset moves the face centre to the circle centre")
    func offset() {
        let motif = AvatarMotif(
            name: "probe", midpoint: .init(x: 0.6, y: 0.45), zoom: 2, info: "probe")
        let offset = motif.offset(edge: 100)
        #expect(abs(offset.x - -20) < 1e-9)
        #expect(abs(offset.y - 10) < 1e-9)
    }

    /// **Clamping at the edge.** A face near the corner must not push the circle beyond the
    /// image — the circle would show a strip of background there.
    @Test("At the edge it is clamped, the crop stays inside the image")
    func clamping() {
        let motif = AvatarMotif(
            name: "probe", midpoint: .init(x: 0.05, y: 0.98), zoom: 2, info: "probe")
        #expect(motif.slice == .init(x: 0.25, y: 0.75))
        // At zoom 2, a quarter of the edge is the largest offset that still shows image.
        let offset = motif.offset(edge: 100)
        #expect(abs(offset.x - 50) < 1e-9)
        #expect(abs(offset.y - -50) < 1e-9)
    }

    @Test("A zoom below 1 counts as 1 and shows the whole image")
    func zoomBelowOne() {
        let motif = AvatarMotif(
            name: "probe", midpoint: .init(x: 0.9, y: 0.1), zoom: 0.5, info: "probe")
        #expect(motif.effectiveZoom == 1)
        #expect(motif.slice == .init(x: 0.5, y: 0.5))
    }

    /// **All sixteen windows lie within the image** — with their real values, not only with
    /// made-up ones. And no zoom is above 2: At 512² less than 256 px would otherwise remain
    /// for a circle that draws 389 px in focus.
    @Test("The directory's values are a valid crop")
    func directoryValues() {
        for motif in AvatarMotif.all {
            let half = 1 / (2 * motif.effectiveZoom)
            let a = motif.slice
            #expect(a.x - half >= 0 && a.x + half <= 1, "\(motif.name)")
            #expect(a.y - half >= 0 && a.y + half <= 1, "\(motif.name)")
            #expect((1...2).contains(motif.zoom), "\(motif.name)")
            #expect((0...1).contains(motif.midpoint.x) && (0...1).contains(motif.midpoint.y))
        }
    }
}
