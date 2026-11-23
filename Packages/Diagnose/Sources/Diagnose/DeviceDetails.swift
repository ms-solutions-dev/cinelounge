import Foundation

#if canImport(UIKit)
    import UIKit
#endif

/// What is stated about the device in the report.
///
/// **Without personal identifiers.** What goes in here is decided by this file and
/// not by the call site — otherwise the report grows with every place that sends "just one
/// more little thing".
public struct DeviceDetails: Sendable, Equatable {

    public let device: String
    public let system: String
    public let version: String
    public let language: String

    public init(
        device: String,
        system: String,
        version: String,
        language: String
    ) {
        self.device = device
        self.system = system
        self.version = version
        self.language = language
    }

    /// This device's details.
    @MainActor
    public static func thisDevice() -> DeviceDetails {
        #if canImport(UIKit)
            let device = UIDevice.current.model
            let system = "\(UIDevice.current.systemName) \(UIDevice.current.systemVersion)"
        #else
            let device = "Mac"
            let system = ProcessInfo.processInfo.operatingSystemVersionString
        #endif

        let bundleInfo = Bundle.main.infoDictionary
        let short = bundleInfo?["CFBundleShortVersionString"] as? String ?? "?"
        let build = bundleInfo?["CFBundleVersion"] as? String ?? "?"

        return DeviceDetails(
            device: device,
            system: system,
            version: "\(short) (\(build))",
            language: Locale.current.identifier)
    }

    public var rows: [String] {
        [
            "Device:   \(device)",
            "System:   \(system)",
            "Version:  \(version)",
            "Language: \(language)",
        ]
    }
}
