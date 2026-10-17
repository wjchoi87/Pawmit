import Foundation
import Security

/// 대화 provider API 키 저장소. config.json(평문)에는 절대 넣지 않고 macOS 키체인에 둔다.
public protocol ChatKeyStore: Sendable {
    func key(for provider: String) -> String?
    func setKey(_ key: String?, for provider: String) throws
}

public struct ChatKeychain: ChatKeyStore {
    public static let service = "dev.pawmit.Pawmit.chat"

    public init() {}

    private func query(_ provider: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: Self.service,
         kSecAttrAccount as String: provider]
    }

    public func key(for provider: String) -> String? {
        var q = query(provider)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        let s = String(decoding: data, as: UTF8.self)
        return s.isEmpty ? nil : s
    }

    /// nil이나 빈 문자열이면 지운다
    public func setKey(_ key: String?, for provider: String) throws {
        SecItemDelete(query(provider) as CFDictionary)
        guard let key = key?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty else { return }
        var q = query(provider)
        q[kSecValueData as String] = Data(key.utf8)
        q[kSecAttrLabel as String] = L10n.format("Pawmit 대화 API 키 (%@)", provider)
        q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(q as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status),
                          userInfo: [NSLocalizedDescriptionKey: L10n.format("키체인에 저장하지 못했어요 (%lld)", Int(status))])
        }
    }
}

/// 테스트용
public final class MemoryKeyStore: ChatKeyStore, @unchecked Sendable {
    private var keys: [String: String] = [:]
    private let lock = NSLock()
    public init(_ keys: [String: String] = [:]) { self.keys = keys }
    public func key(for provider: String) -> String? { lock.lock(); defer { lock.unlock() }; return keys[provider] }
    public func setKey(_ key: String?, for provider: String) throws { lock.lock(); keys[provider] = key; lock.unlock() }
}
