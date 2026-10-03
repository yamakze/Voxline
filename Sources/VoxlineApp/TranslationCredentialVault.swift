import Foundation
import Security

protocol TranslationCredentialVault: Sendable {
    func contains(serviceID: UUID) async throws -> Bool
    func read(serviceID: UUID) async throws -> String?
    func write(_ key: String?, serviceID: UUID) async throws
}

/// Actor isolation keeps blocking Keychain calls off the UI executor. No cross-device synchronization.
actor KeychainTranslationCredentialVault: TranslationCredentialVault {
    private let service: String
    init(service: String = "dev.voxline.translation") { self.service = service }

    func contains(serviceID: UUID) throws -> Bool {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service, kSecAttrAccount as String: serviceID.uuidString,
            kSecReturnAttributes as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        let code = SecItemCopyMatching(query as CFDictionary, nil)
        if code == errSecItemNotFound { return false }
        guard code == errSecSuccess else { throw TranslationCredentialError.keychain(code) }
        return true
    }

    func read(serviceID: UUID) throws -> String? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service, kSecAttrAccount as String: serviceID.uuidString,
            kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var result: CFTypeRef?
        let code = SecItemCopyMatching(query as CFDictionary, &result)
        if code == errSecItemNotFound { return nil }
        guard code == errSecSuccess else { throw TranslationCredentialError.keychain(code) }
        guard let data = result as? Data, let key = String(data: data, encoding: .utf8), !key.isEmpty else {
            throw TranslationCredentialError.invalidData
        }
        return key
    }

    func write(_ key: String?, serviceID: UUID) throws {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service, kSecAttrAccount as String: serviceID.uuidString]
        guard let key, !key.isEmpty else {
            let code = SecItemDelete(query as CFDictionary)
            guard code == errSecSuccess || code == errSecItemNotFound else { throw TranslationCredentialError.keychain(code) }
            return
        }
        let attributes: [String: Any] = [kSecValueData as String: Data(key.utf8)]
        let code = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if code == errSecItemNotFound {
            let added = SecItemAdd(query.merging(attributes) { _, new in new } as CFDictionary, nil)
            guard added == errSecSuccess else { throw TranslationCredentialError.keychain(added) }
        } else if code != errSecSuccess { throw TranslationCredentialError.keychain(code) }
    }
}

enum TranslationCredentialError: Error, LocalizedError {
    case keychain(OSStatus), invalidData
    var errorDescription: String? {
        switch self {
        case .keychain(let code): "Keychain 操作失败（\(code)）。请检查系统钥匙串访问。"
        case .invalidData: "Keychain 中的密钥数据无效，请重新配置。"
        }
    }
}
