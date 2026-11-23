import Diagnose
import NetworkStatus

extension NetworkLog {

    /// **Forwards the sentences of `NetworkStatus` into the error log** (finding 11) — area `NETZ`, a
    /// hint stays a hint, a step a step.
    ///
    /// **Here and not in `NetworkStatus`:** the package deliberately depends on nothing; StoryShelf
    /// includes it via the path. The app sets the hook; anyone who does not set it stays silent.
    static func wireWithDiagnostics() {
        set { tier, message in
            switch tier {
            case .step: Diagnose.step(.network, message)
            case .hint: Diagnose.hint(.network, message)
            }
        }
    }
}
