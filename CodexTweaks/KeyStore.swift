import Foundation
import Security

// API key is stored in login Keychain. If the keychain can't be written to, it goes in a file in Application Support.
// The file has the same protection Codex gives the key in ~/.codex/auth.json. Saving again when Keychain works moves the key into it and deletes the file.
enum KeyStore {
    private static let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "local.codextweaks",
        kSecAttrAccount as String: "openai-api-key",
    ]

    private static var fallbackFile: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Codex Tweaks/openai-api-key")
    }

    static func load() -> String? {
        var q = query
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        if SecItemCopyMatching(q as CFDictionary, &item) == errSecSuccess,
           let data = item as? Data, let key = String(data: data, encoding: .utf8) {
            return key
        }
        return (try? String(contentsOf: fallbackFile, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func save(_ key: String) throws {
        if saveToKeychain(key) == errSecSuccess {
            try? FileManager.default.removeItem(at: fallbackFile)
            return
        }

        let fm = FileManager.default
        let folder = fallbackFile.deletingLastPathComponent()

        try fm.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        guard fm.createFile(atPath: fallbackFile.path, contents: Data(key.utf8), attributes: [.posixPermissions: 0o600])
        else { throw TweakError("Couldn't save the key.") }

        // Enforce owner-only access even if the file already existed.
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fallbackFile.path)
    }

    static func delete() {
        SecItemDelete(query as CFDictionary)
        try? FileManager.default.removeItem(at: fallbackFile)
    }

    // Update first so an existing item keeps its access settings, and add only when it's missing.
    private static func saveToKeychain(_ key: String) -> OSStatus {
        let data = Data(key.utf8)
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)

        guard status == errSecItemNotFound else { return status }
        var item = query
        item[kSecValueData as String] = data
        item[kSecAttrLabel as String] = "Codex Tweaks - OpenAI API key"

        return SecItemAdd(item as CFDictionary, nil)
    }
}
