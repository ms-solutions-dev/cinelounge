import AVFoundation
import CoreMedia
import Foundation
import Testing

@testable import Core

/// The Dolby decoder for the renderer path — tested with real frames from
/// the test files. On the Mac there is Apple's decoder; on the device the
/// track says so.
@Suite("The Dolby decoder")
struct DolbyDecoderTests {
}
