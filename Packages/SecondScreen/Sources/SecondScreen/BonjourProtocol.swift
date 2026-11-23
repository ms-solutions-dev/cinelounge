import Diagnose
import Foundation
import Network

/// **What search and receiver do on the home network is in the log** (on-device test build
/// 1332, finding 13, 2026-09-27).
///
/// **The finding:** The phone showed "Apple TV (grayed out) · only reachable on the home
/// network" although it was on Wi-Fi — and the report said nothing. ``DeviceDiscovery/search()``
/// wrote nothing: A browser stuck in `.waiting` because "Local Network" is not allowed
/// (`-65570`, `kDNSServiceErr_PolicyDenied`) looked exactly like a house without a TV.
/// On the TV the receiver only reported "listening" — whether its service was registered or
/// the listener failed stayed open.
///
/// **The same path as since round A** (`Diagnose`, area `NETZ`). The strings are produced in
/// pure calculations so that they can be tested without a network. No device name in the
/// string: It is the name someone gave their living room.
enum BonjourProtocol {

    /// `kDNSServiceErr_PolicyDenied` — "Local Network" is off for this app.
    static let localNetworkDenied: Int32 = -65570

    /// An error from `Network` in plain text — **the denied permission by name.**
    static func description(_ error: NWError) -> String {
        if case .dns(let code) = error, code == localNetworkDenied {
            return "Local Network not allowed (-65570) — Settings → Privacy → Local Network"
        }
        return "\(error)"
    }

    /// What a search state writes to the log — `nil` for the setup.
    static func message(search state: NWBrowser.State) -> (Severity, String)? {
        switch state {
        case .setup: nil
        case .ready: (.step, "Remote: searching for TVs")
        case .waiting(let error): (.hint, "Remote: search waiting — \(description(error))")
        case .failed(let error): (.error, "Remote: search failed — \(description(error))")
        case .cancelled: (.step, "Remote: search ended")
        @unknown default: (.hint, "Remote: search in unknown state")
        }
    }

    /// What a receiver state writes to the log — `nil` for the setup.
    ///
    /// - Parameter who: "Remote" or "Handoff" — which receiver.
    static func message(receiver state: NWListener.State, who: String) -> (Severity, String)? {
        switch state {
        case .setup: nil
        case .ready: (.step, "\(who): receiver ready")
        case .waiting(let error): (.hint, "\(who): receiver waiting — \(description(error))")
        case .failed(let error): (.error, "\(who): receiver failed — \(description(error))")
        case .cancelled: (.step, "\(who): receiver ended")
        @unknown default: (.hint, "\(who): receiver in unknown state")
        }
    }

    /// What the registration of the service writes to the log.
    static func message(login: NWListener.ServiceRegistrationChange, who: String) -> String {
        switch login {
        case .add: "\(who): Bonjour service registered"
        case .remove: "\(who): Bonjour service unregistered"
        @unknown default: "\(who): Bonjour service changed"
        }
    }

    /// The string for a find — just the count.
    static func message(discoveries: Int) -> String {
        "Remote: \(discoveries) TVs found"
    }

    /// Writes a string with its severity.
    static func note(_ entry: (Severity, String)?) {
        guard let (severity, message) = entry else { return }
        switch severity {
        case .step: Diagnose.step(.network, message)
        case .hint: Diagnose.hint(.network, message)
        case .error, .abort: Diagnose.error(.network, message)
        }
    }

    /// Reports states and service registration of a receiver — **to be set before `start`.**
    static func observe(_ listener: NWListener, who: String) {
        listener.stateUpdateHandler = { state in note(message(receiver: state, who: who)) }
        listener.serviceRegistrationUpdateHandler = { login in
            Diagnose.step(.network, message(login: login, who: who))
        }
    }
}
