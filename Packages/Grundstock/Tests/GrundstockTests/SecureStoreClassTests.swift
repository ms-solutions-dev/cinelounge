import Security
import Testing

@testable import Grundstock

/// AP54, 2026-09-27: pairing credentials are bound to the device, access credentials are not.
@Suite("SecureStore: access class")
struct SecureStoreClassTests {

    @Test("Without a setting an entry travels with the backup, a device-bound one does not")
    func sizeClass() {
        #expect(SecureStore().accessClass == kSecAttrAccessibleAfterFirstUnlock)
        #expect(
            SecureStore(thisDeviceOnly: true).accessClass
                == kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly)
    }
}
