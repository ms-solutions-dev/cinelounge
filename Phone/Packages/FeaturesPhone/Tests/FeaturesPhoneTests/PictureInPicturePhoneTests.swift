import Foundation
import Playback
import SourceProbe
import Testing

@testable import FeaturesPhone

/// Picture in Picture on the phone — **the finding from the on-device test of build 1332** (2026-09-27).
///
/// On the iPhone the small window opens when one leaves the app while the film
/// is playing. iOS does that only with `canStartPictureInPictureAutomaticallyFromInline`, and the
/// value was never set anywhere in the project. The controller itself can be checked only on the device —
/// `swift test` runs on the computer, where there is no `AVPictureInPictureController`.
/// This check therefore reads the place where the controller is created.
@Suite("Picture in Picture on the phone")
struct PictureInPicturePhoneTests {

    /// **The one line because of which the window never opened on the phone.** It must sit behind
    /// `#if os(iOS)`: on the TV the property does not exist, and a build for
    /// tvOS would otherwise fail — which `swift build` on the computer would never see.
    @Test("The controller starts by itself when leaving the app, on iOS only")
    func startOnLeaving() throws {
        let source = SourceText.strippingCommentLines(
            try SourceText.read("PictureInPicture.swift", in: .playback))
        let row = "canStartPictureInPictureAutomaticallyFromInline = true"
        let location = try #require(
            source.range(of: row), "\(row) is missing — without it iOS opens no window when leaving")
        let before = source[..<location.lowerBound]
        let switchPoint = try #require(before.range(of: "#if os(iOS)", options: .backwards))
        #expect(
            before[switchPoint.upperBound...].range(of: "#endif") == nil,
            "the line is not inside #if os(iOS)")
    }

    /// Without background audio there would be no window even with the line above.
    @Test("The app may play audio in the background")
    func backgroundAudio() throws {
        let project = try SourceText.read(.phoneProject)
        let block = try #require(project.range(of: "UIBackgroundModes:"))
        #expect(project[block.upperBound...].prefix(40).contains("- audio"))
    }

    /// **The pinch has to reach the picture at all** (on-device test, build 1332). Above the
    /// video surface lie the swipe zones with a hit shape over the whole screen; a
    /// gesture on the surface below never got a finger. It is therefore attached as a
    /// simultaneous gesture to the shared stack — and the swipe zones listen to it.
    @Test("The pinch gesture sits on top of the swipe zones, not beneath them")
    func pinchReachesTheImage() throws {
        let gesture = SourceText.strippingCommentLines(
            try SourceText.read("PinchGesture.swift", in: .featuresPhone))
        #expect(gesture.contains(".simultaneousGesture(pinch"))
        let player = SourceText.strippingCommentLines(
            try SourceText.read("SpielerView.swift", in: .featuresPhone))
        let surface = try #require(player.range(of: "VideoSurface(host:"))
        #expect(
            !player[surface.upperBound...].prefix(400).contains(".withPinch("),
            "the pinch gesture is attached to the video surface again, beneath the swipe zones")
        #expect(
            player.contains("isPinching: isPinching"),
            "the swipe zones do not learn that a pinch is happening")
    }

    /// **Every refusal has its reason** — the first one that applies, in the order
    /// in which one would have to fix it.
    @Test("The refusal names the foremost reason")
    func rejection() {
        #expect(
            PictureInPicture.rejection(supported: false, controller: true, possible: true)
                == .deviceCannot)
        #expect(
            PictureInPicture.rejection(supported: true, controller: false, possible: false)
                == .noController)
        #expect(
            PictureInPicture.rejection(supported: true, controller: true, possible: false)
                == .notYetPossible)
        #expect(PictureInPicture.rejection(supported: true, controller: true, possible: true) == nil)
    }
}
