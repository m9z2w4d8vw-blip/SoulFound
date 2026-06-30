import Foundation
import Security

/// Minimal Keychain wrapper for storing the Soulseek username/password
/// so the app can auto-login on launch without storing plaintext in UserDefaults.
enum KeychainHelper {
    private static let service = "com.soulfound.app.credentials"

    static func save(username: String, password: String) {
        // Save username in UserDefaults (not sensitive on its own)
        UserDefaults.standard.set(username, forKey: "soulfound.username")

        // Save password securely in Keychain
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: username
        ]
        // Remove any existing entry first
        SecItemDelete(query as CFDictionary)

        var newItem = query
        newItem[kSecValueData as String] = password.data(using: .utf8)
        SecItemAdd(newItem as CFDictionary, nil)
    }

    static func loadSavedCredentials() -> (username: String, password: String)? {
        guard let username = UserDefaults.standard.string(forKey: "soulfound.username") else {
            return nil
        }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: username,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess,
              let data = result as? Data,
              let password = String(data: data, encoding: .utf8) else {
            return nil
        }

        return (username, password)
    }

    static func clear() {
        if let username = UserDefaults.standard.string(forKey: "soulfound.username") {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: username
            ]
            SecItemDelete(query as CFDictionary)
        }
        UserDefaults.standard.removeObject(forKey: "soulfound.username")
    }
}
