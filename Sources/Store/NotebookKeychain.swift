import CryptoKit
import Foundation
import Security

/// Caches a notebook's key in the login keychain so the passphrase is not asked every time.
/// The cache is not part of the notebook format: deleting it only means the passphrase is asked again.
/// Items stay on this Mac (never synced) and are readable only while it is unlocked.
public enum NotebookKeychain {
    private static let service = "com.stevencoutts.NoteCanvas.notebook-key"

    private static func base(_ notebookID: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: notebookID.lowercased()]
    }

    @discardableResult
    public static func save(_ key: SymmetricKey, notebookID: String) -> Bool {
        SecItemDelete(base(notebookID) as CFDictionary)
        var item = base(notebookID)
        item[kSecValueData as String] = key.withUnsafeBytes { Data($0) }
        item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
    }

    public static func load(notebookID: String) -> SymmetricKey? {
        var query = base(notebookID)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data,
              data.count == 32 else { return nil }
        return SymmetricKey(data: data)
    }

    public static func remove(notebookID: String) {
        SecItemDelete(base(notebookID) as CFDictionary)
    }
}
