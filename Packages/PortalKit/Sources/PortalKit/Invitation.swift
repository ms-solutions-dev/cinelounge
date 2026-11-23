import Core
import Foundation

/// What is in a pasted invitation.
///
/// **The finding of 2026-09-12, from the requester.** The console generates a link —
/// `http://<server>:8100/?invite=<token>` —, and the requester typed it into the field
/// for the **server address**. That was not their mistake: there was no field for an
/// invitation, and the address field was the only one into which anything fit at all.
/// The answer was "The bridge does not answer" — correct and completely useless.
///
/// **And the link knows more than just the password: it knows where the server is.**
/// That is exactly the information that otherwise has to be typed in by hand. A single
/// paste can thus do both — that is why this type carries the address along and not
/// just the password.
///
/// **Three notations, one meaning.** A link, an address with a question mark, or the
/// bare password. Whoever types a pairing code from the remote has no link; whoever
/// copies an invitation from a message has one. Both mean the same.
public struct Invitation: Sendable, Equatable {

    /// The password that goes to `/redeem` — **in the field `token`, not `code`.**
    public let password: String

    /// Where the server is, **if the link says so.**
    ///
    /// `nil` for the bare password. **And `nil` for `cl.example` too** — see
    /// ``bridgeAddress(from:)``: that address is meant for the browser and the wrong way for an
    /// app.
    public let bridgeAddress: URL?

    /// Is this a six-digit pairing code instead of an invitation?
    ///
    /// **Only for labelling, never for deciding.** Both go the same way; the server tells
    /// them apart itself. The app needs it to say the right thing when something goes
    /// wrong — "code" and "invitation" are not the same for the viewer.
    public var isPairingCode: Bool { password.count == 6 }

    /// From an input an invitation — `nil` if nothing usable is in it.
    ///
    /// **Letter case stays as it comes.** The server writes six-character codes in
    /// uppercase and invitations in lowercase and accepts both in any spelling; converting
    /// here would mean making an assumption about its leniency.
    public init?(input: String) {
        let clean = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return nil }

        // A link — or something that carries a query part.
        if let split = URLComponents(string: clean),
            let password = split.queryItems?.first(where: { $0.name == "invite" })?.value,
            !password.isEmpty
        {
            self.password = password
            self.bridgeAddress = Self.bridgeAddress(from: split)
            return
        }

        // The bare password. **What is checked is the shape and not the length alone:** a
        // pasted sentence is no password, and sending it to the server would produce a
        // refusal that explains nothing.
        let isAllowed = CharacterSet.alphanumerics
        guard clean.count >= 6, clean.count <= 64,
            clean.unicodeScalars.allSatisfy(isAllowed.contains)
        else { return nil }
        self.password = clean
        self.bridgeAddress = nil
    }

    /// The address from an invitation link — **or none.**
    ///
    /// **`cl.example` is left out, and that is the core of this function.** The server runs
    /// two addresses: plain text on 8100 for the devices and `https://cl.example` for the
    /// browser. The console generates the link with the address through which one is
    /// currently operating it — browse via `cl.example`, and `cl.example` is in the link. An app
    /// that adopted that would fail on the certificate chain: the certificate is from
    /// mkcert, and its root sits in the household browser and not in every device. That is
    /// exactly why the app takes the plain text.
    ///
    /// Without a port number likewise `nil`: `https://cl.example/` does not say where the
    /// service listens for devices, and guessing 8100 would be the same claim that was
    /// just abolished as a default.
    static func bridgeAddress(from split: URLComponents) -> URL? {
        guard let calculator = split.host, !calculator.isEmpty, let number = split.port else {
            return nil
        }
        guard split.scheme == "http" else { return nil }
        var clean = URLComponents()
        clean.scheme = "http"
        clean.host = calculator
        clean.port = number
        return clean.url
    }
}
