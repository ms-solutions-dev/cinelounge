import CoreImage
import CoreImage.CIFilterBuiltins
import SwiftUI

/// Generates QR images for display on the TV.
///
/// Intended for sign-in: instead of typing the server address with the remote,
/// one holds the phone up to it. Together with the six-digit code
/// that is the most convenient way — the camera takes the address, the fingers only
/// six digits.
public enum QRCode {

    /// - Parameters:
    ///   - contents: What the QR code should contain, usually an address.
    ///   - scale: Enlargement of the generated dots. The filter delivers a
    ///     very small image; without enlargement it would be blurry on the TV.
    public static func image(for contents: String, scale: CGFloat = 16) -> Image? {
        guard let cgImage = cgImage(for: contents, scale: scale) else { return nil }
        return Image(decorative: cgImage, scale: 1)
    }

    static func cgImage(for contents: String, scale: CGFloat = 16) -> CGImage? {
        guard !contents.isEmpty, let data = contents.data(using: .utf8) else { return nil }

        let filter = CIFilter.qrCodeGenerator()
        filter.message = data
        // Medium error correction: tolerates reflections and oblique
        // viewing angles on a TV without needlessly densifying the pattern.
        filter.correctionLevel = "M"

        guard let output = filter.outputImage else { return nil }

        let scaled = output.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        return CIContext().createCGImage(scaled, from: scaled.extent)
    }
}
