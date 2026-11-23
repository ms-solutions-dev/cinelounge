import Darwin
import Foundation

/// The memory state of the app — and the guard that lets the system warn
/// before termination.
///
/// **Why** (Y3VF-GJ, 2026-09-04): "TR: A2 UHD" ran for 29 seconds with its own
/// decoder, then the app was gone — without signal, without chain, the
/// ``CrashGuard`` had nothing to write. A run that ends like that was
/// terminated by the system: `SIGKILL`, mostly because of memory. The number for it
/// was missing everywhere. Now the memory state appears in the
/// renderer balance, and the system's memory pressure goes into
/// the trace as a defect — with state, before the end comes.
public enum MemoryWatch {

    /// The actual footprint in bytes — the same number by which the
    /// system terminates (`phys_footprint`), not the resident size.
    public static var footprintBytes: UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        return info.phys_footprint
    }

    /// The footprint as text for the trace: "412 MB".
    public static var footprintText: String {
        "\(footprintBytes / 1_000_000) MB"
    }

    nonisolated(unsafe) private static var source: DispatchSourceMemoryPressure?

    /// Installs the guard — once at launch.
    public static func start() {
        guard source == nil else { return }
        let sourceItem = DispatchSource.makeMemoryPressureSource(
            eventMask: [.warning, .critical], queue: .global(qos: .utility))
        sourceItem.setEventHandler {
            let tier = sourceItem.data.contains(.critical) ? "critical" : "warning"
            Diagnostics.defect(
                "Memory pressure (\(tier)) at \(footprintText) — the system terminates apps next",
                since: nil)
        }
        sourceItem.activate()
        source = sourceItem
    }
}
