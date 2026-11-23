import DesignSystemPhone
import SwiftUI

#if os(iOS)
    import AVFoundation
#endif

/// The camera that looks for the code on the TV.
///
/// **The only way in.** The code's text carries a scheme of its own
/// (``HandoffKey/schema``), and it is **not** registered in the Info file:
/// it is scanned and not opened. A registered scheme would be an entrance that
/// every app on the device could use — for a flow that does not need it at all.
///
/// **No empty screen without permission.** Whoever declines the camera sees the reason and
/// the way into Settings; a black rectangle without explanation would look like a
/// bug in the app.
struct QRScanner: View {

    /// Every text read — the switch lives in the model, not here. A camera sees
    /// packaging and Wi-Fi codes; what of it counts is decided by ``HandoffModel``.
    let read: (String) -> Void

    #if os(iOS)
        @State private var isAllowed: Bool?
    #endif

    var body: some View {
        #if os(iOS)
            Group {
                switch isAllowed {
                case .some(true):
                    CameraImage(read: read)
                        .clipShape(RoundedRectangle(cornerRadius: MetricsBoard.phone.fieldRadius))
                        .overlay {
                            // **The frame says where to aim.** Without it one aims
                            // at the whole screen, and the code sits in the middle of
                            // the TV.
                            RoundedRectangle(cornerRadius: MetricsBoard.phone.fieldRadius)
                                .strokeBorder(ColorRole.text.color.opacity(0.5), lineWidth: 2)
                        }
                case .some(false):
                    StateView(state: .cameraDenied, action: Self.openSettings)
                case nil:
                    LoadingState(message: "handover.scan.opening")
                }
            }
            .task { isAllowed = await Self.requestCamera() }
        #else
            // On the Mac there is no camera — there only `swift test` runs.
            Color.clear
        #endif
    }

    #if os(iOS)
        /// **The request comes from here and not at launch.** A camera question at the
        /// app's first startup would be a question without cause — and whoever declines it there
        /// gets stuck at this point without going to
        /// System Settings.
        private static func requestCamera() async -> Bool {
            switch AVCaptureDevice.authorizationStatus(for: .video) {
            case .authorized: return true
            case .notDetermined: return await AVCaptureDevice.requestAccess(for: .video)
            default: return false
            }
        }

        private static func openSettings() {
            guard let target = URL(string: UIApplication.openSettingsURLString) else { return }
            UIApplication.shared.open(target)
        }
    #endif
}

#if os(iOS)

    /// The running camera image including code detection.
    ///
    /// **The session starts on a thread of its own.** `startRunning()` blocks for up to
    /// half a second; on the main thread that is a visible stutter at exactly
    /// the moment the screen appears.
    struct CameraImage: UIViewRepresentable {

        let read: (String) -> Void

        func makeUIView(context: Context) -> CameraSurface {
            let surface = CameraSurface()
            context.coordinator.read = read
            surface.build(using: context.coordinator)
            return surface
        }

        func updateUIView(_ surface: CameraSurface, context: Context) {
            context.coordinator.read = read
        }

        static func dismantleUIView(_ surface: CameraSurface, coordinator: Reader) {
            surface.stopListening()
        }

        func makeCoordinator() -> Reader { Reader() }

        /// Receives the codes.
        ///
        /// **Every text read goes through**, even the same one twice: the camera reports
        /// a code as long as it is in the image, and the sorting out belongs in the model —
        /// there lives the switch that skips a second code after the first.
        final class Reader: NSObject, AVCaptureMetadataOutputObjectsDelegate {
            var read: ((String) -> Void)?

            func metadataOutput(
                _ output: AVCaptureMetadataOutput,
                didOutput objects: [AVMetadataObject],
                from connection: AVCaptureConnection
            ) {
                for fund in objects {
                    guard let code = fund as? AVMetadataMachineReadableCodeObject,
                        code.type == .qr, let text = code.stringValue
                    else { continue }
                    read?(text)
                }
            }
        }
    }

    /// Carries the session across the thread boundary — **and nothing else.**
    ///
    /// `AVCaptureSession` is not `Sendable`, and `startRunning()` still does not belong
    /// on the main thread: the call blocks for up to half a second, and that is
    /// a visible stutter at exactly the moment the screen appears.
    ///
    /// **`@unchecked` with a justification and not `@preconcurrency` over the whole module:**
    /// Apple explicitly describes starting and stopping as calls that should come from a
    /// thread of their own; only these two cross over here, and nobody else touches
    /// either. Importing with `@preconcurrency`, by contrast, would silence **every** future
    /// warning from AVFoundation — including the ones that mean something.
    private struct SessionBox: @unchecked Sendable {
        let session: AVCaptureSession

        init(_ session: AVCaptureSession) { self.session = session }

        func start() {
            DispatchQueue.global(qos: .userInitiated).async { session.startRunning() }
        }

        func stop() {
            DispatchQueue.global(qos: .userInitiated).async { session.stopRunning() }
        }
    }

    /// The surface the camera image lies on.
    ///
    /// **A `UIView` of its own with `AVCaptureVideoPreviewLayer` as its layer**, so that the
    /// preview grows along by itself. Whoever hangs the layer by hand into an ordinary view
    /// must update its size on every rotation — and forgets it once.
    final class CameraSurface: UIView {

        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }

        private var session: AVCaptureSession?

        var lookahead: AVCaptureVideoPreviewLayer {
            layer as! AVCaptureVideoPreviewLayer
        }

        func build(using reader: CameraImage.Reader) {
            let session = AVCaptureSession()
            guard let device = AVCaptureDevice.default(for: .video),
                let input = try? AVCaptureDeviceInput(device: device),
                session.canAddInput(input)
            else { return }
            session.addInput(input)

            let outcome = AVCaptureMetadataOutput()
            guard session.canAddOutput(outcome) else { return }
            session.addOutput(outcome)
            outcome.setMetadataObjectsDelegate(reader, queue: .main)
            // **Add first, then set the types.** Before that the list of
            // possible types is empty, and requiring `.qr` in it throws.
            outcome.metadataObjectTypes = [.qr]

            lookahead.session = session
            lookahead.videoGravity = .resizeAspectFill
            self.session = session

            SessionBox(session).start()
        }

        func stopListening() {
            guard let session else { return }
            SessionBox(session).stop()
            self.session = nil
        }
    }
#endif
