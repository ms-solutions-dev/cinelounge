import Styling
import Testing

@testable import DesignSystemPhone

/// **What the phone's views show — meaning by meaning, against the register** (AP58 final
/// step, 2026-09-26).
///
/// Until the final step, every old name (`Sinnbilder.x`) forwarded to the register here; the
/// views now name the meaning itself. The symbols are copied on purpose: whoever changes one
/// changes the device and should decide it at this spot. Since the move, only the rows from
/// **decision 24** have changed (rating as half star, series, empty catalog).
@Suite("The symbols on the phone")
struct TabGlyphTests {

    static let character: [(String, String, String)] = [
        ("abspielen", Glyph.play.name, "play.fill"),
        ("anhalten", Glyph.pause.name, "pause.fill"),
        ("anmeldungNoetig", Glyph.login.name, "person.crop.circle.badge.exclamationmark"),
        ("archiv", Glyph.history.name, "clock.arrow.circlepath"),
        ("auffrischen", Glyph.refresh.name, "arrow.clockwise"),
        ("aufklappen", Glyph.down.name, "chevron.down"),
        ("ausgeblendet", Glyph.hidden.name, "eye.slash"),
        ("bearbeiten", Glyph.edit.name, "pencil"),
        ("bereichDarstellung", Glyph.appearance.name, "paintbrush"),
        ("bereichDiagnose", Glyph.diagnose.name, "stethoscope"),
        ("bereichKindersicherung", Glyph.parentalControls.name, "lock.shield"),
        ("bereichKonto", Glyph.account.name, "person.crop.circle"),
        ("bereichSpeicher", Glyph.storage.name, "internaldrive"),
        ("bereichWiedergabe", Glyph.playback.name, "play.circle"),
        ("bewertung", Glyph.rating.name, "star.leadinghalf.filled"),
        ("bibliothek.umrissen", Glyph.Tab.library.outlined, "square.grid.2x2"),
        ("bibliothek.gefuellt", Glyph.Tab.library.filled, "square.grid.2x2.fill"),
        ("bildFuellen", Glyph.fillPicture.name, "arrow.up.left.and.arrow.down.right"),
        ("bildGanz", Glyph.fitPicture.name, "arrow.down.right.and.arrow.up.left"),
        ("bildImBild", Glyph.pictureInPicture.name, "pip.enter"),
        ("datenschutz", Glyph.privacy.name, "hand.raised"),
        ("dreissigVor", Glyph.thirtyForward.name, "goforward.30"),
        ("entfernen", Glyph.remove.name, "trash"),
        ("erreichbar", Glyph.done.pair.outlined, "checkmark.circle"),
        ("favorit.umrissen", Glyph.favorite.pair.outlined, "heart"),
        ("favorit.gefuellt", Glyph.favorite.pair.filled, "heart.fill"),
        ("flugmodus", Glyph.airplaneMode.name, "airplane"),
        ("frist", Glyph.clock.name, "clock"),
        ("gattungFilme", Glyph.film.name, "film"),
        ("gattungHeimvideos", Glyph.homeVideo.name, "video"),
        ("gattungLive", Glyph.live.name, "dot.radiowaves.left.and.right"),
        ("gattungMusik", Glyph.music.name, "music.note"),
        ("gattungOrdner", Glyph.folder.name, "folder"),
        ("gattungPortal", Glyph.portal.name, "globe"),
        ("gattungSammlung", Glyph.isCollection.name, "rectangle.stack"),
        ("gattungSerien", Glyph.series.name, "play.rectangle.on.rectangle"),
        ("gesehen.umrissen", Glyph.done.pair.outlined, "checkmark.circle"),
        ("gesehen.gefuellt", Glyph.done.pair.filled, "checkmark.circle.fill"),
        ("helligkeit", Glyph.brightness.name, "sun.max.fill"),
        ("hinweis", Glyph.info.name, "info.circle"),
        ("kamera", Glyph.camera.name, "camera"),
        ("kapitel", Glyph.chapters.name, "list.bullet.indent"),
        ("keineAntwort", Glyph.offline.name, "wifi.slash"),
        ("kinderkonto", Glyph.kind.name, "figure.child"),
        ("lautstaerke", Glyph.volume.name, "speaker.wave.2.fill"),
        ("leer", Glyph.emptyCatalog.name, "tray"),
        ("live.umrissen", Glyph.Tab.live.outlined, "play.tv"),
        ("live.gefuellt", Glyph.Tab.live.filled, "play.tv.fill"),
        ("lizenz", Glyph.license.name, "text.document"),
        ("luftbild", Glyph.aerialImage.name, "airplayvideo"),
        ("mehr", Glyph.more.name, "ellipsis"),
        ("melden", Glyph.report.name, "flag"),
        ("merken.umrissen", Glyph.bookmark.pair.outlined, "star"),
        ("merken.gefuellt", Glyph.bookmark.pair.filled, "star.fill"),
        ("mobilfunk", Glyph.funk.name, "antenna.radiowaves.left.and.right"),
        ("nachOben", Glyph.upward.name, "arrow.up"),
        ("nachUnten", Glyph.downward.name, "arrow.down"),
        ("netzFehlt", Glyph.networkMissing.name, "wifi.exclamationmark"),
        ("person", Glyph.person.name, "person.fill"),
        ("portale.umrissen", Glyph.Tab.portals.outlined, "square.stack.3d.up"),
        ("portale.gefuellt", Glyph.Tab.portals.filled, "square.stack.3d.up.fill"),
        ("pruefung", Glyph.check.name, "exclamationmark.shield"),
        ("quellen", Glyph.sources.name, "square.stack.3d.down.right"),
        ("schliessen", Glyph.close.name, "xmark"),
        ("schloss", Glyph.locked.name, "lock.fill"),
        ("schrittFehl", Glyph.failed.name, "xmark.circle.fill"),
        ("schrittFertig", Glyph.done.pair.filled, "checkmark.circle.fill"),
        ("schrittOffen", Glyph.pending.name, "circle"),
        ("server", Glyph.server.name, "externaldrive"),
        ("serverFehlt", Glyph.serverMissing.name, "externaldrive.badge.questionmark"),
        ("sichtbar", Glyph.isVisible.name, "eye"),
        ("sortierung", Glyph.sorting.name, "arrow.up.arrow.down"),
        ("sprungVor", Glyph.skipForward.name, "goforward"),
        ("sprungZurueck", Glyph.skipBack.name, "gobackward"),
        ("start.umrissen", Glyph.Tab.start.outlined, "house"),
        ("start.gefuellt", Glyph.Tab.start.filled, "house.fill"),
        ("suche.umrissen", Glyph.Tab.search.outlined, "magnifyingglass.circle"),
        ("suche.gefuellt", Glyph.Tab.search.filled, "magnifyingglass.circle.fill"),
        ("teilen", Glyph.share.name, "square.and.arrow.up"),
        ("ton", Glyph.audio.name, "waveform"),
        ("trailer", Glyph.broadcast.name, "play.rectangle"),
        ("uebergabe", Glyph.handoff.name, "arrow.up.forward.app"),
        ("untertitel", Glyph.subtitles.name, "captions.bubble"),
        ("verbindungBelegt", Glyph.tv.name, "tv"),
        ("verfallen", Glyph.expire.name, "clock.badge.exclamationmark"),
        ("vonVorn", Glyph.fromStart.name, "arrow.counterclockwise"),
        ("vorrat", Glyph.downloads.name, "arrow.down.circle"),
        ("warnung", Glyph.warning.name, "exclamationmark.triangle"),
        ("weiter", Glyph.next.name, "chevron.right"),
        ("zehnZurueck", Glyph.tenBack.name, "gobackward.10"),
        ("ziel", Glyph.target.name, "tv.and.hifispeaker.fill"),
        ("zurueck", Glyph.back.name, "chevron.left"),
    ]

    @Test("Every meaning shows its symbol")
    func unchanged() {
        for (name, now, expected) in Self.character {
            #expect(now == expected, "\(name) shows \(now) instead of \(expected)")
        }
    }

    /// The register's rule also holds from this side — a falsified rule in `Styling` is
    /// thereby noticed in both platform layers.
    @Test("The register has no forbidden double assignment")
    func tabsClean() {
        #expect(Glyph.forbiddenDoubleAssignments().isEmpty)
        #expect(Glyph.favorite.name == "heart")
    }
}
