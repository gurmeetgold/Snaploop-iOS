import CryptoKit
import Foundation
import Security

/// Provides a pseudonymous source-installation identity scoped to one SnapLoop
/// account on one app installation. It is not a hardware identifier and must
/// never be treated as an authentication credential.
public protocol AccountInstallationIdentityProviding: Sendable {
    func id(for userId: String) -> String
    func resetInstallation()
}

/// Production implementation.
///
/// A random installation secret is stored as a ThisDeviceOnly Keychain item and
/// paired with a UserDefaults marker. The two-part state intentionally rotates:
/// - after uninstall/reinstall (preferences disappear even if Keychain survives)
/// - after backup/restore to another device (ThisDeviceOnly Keychain data does
///   not migrate even if preferences do)
///
/// The account-facing ID is HMAC-SHA256(installationSecret, userId + domain), so
/// different accounts on the same iPhone receive unrelated IDs and the Firebase
/// uid is not stored in a local preference key. The result is pseudonymous, not
/// secret, and server authorization must never rely on possession of this ID.
public final class SecureAccountInstallationIdentityStore: AccountInstallationIdentityProviding, @unchecked Sendable {
    private struct RootPayload: Codable {
        let marker: String
        let secret: Data
    }

    private let lock = NSLock()
    private let defaults: UserDefaults
    private let markerKey = "snaploop.installation.marker.v1"
    private let keychainService = "com.snaploop.installation.identity"
    private let keychainAccount = "root.v1"
    private var cachedRoot: RootPayload?
    private var isUsingEphemeralFallback = false

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func id(for userId: String) -> String {
        let normalizedUserId = userId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedUserId.isEmpty else { return "" }

        lock.lock()
        defer { lock.unlock() }

        let root = loadOrCreateRootLocked()
        let key = SymmetricKey(data: root.secret)
        let message = Data("snaploop-account-installation-v1:\(normalizedUserId)".utf8)
        let digest = HMAC<SHA256>.authenticationCode(for: message, using: key)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    public func resetInstallation() {
        lock.lock()
        defer { lock.unlock() }
        cachedRoot = nil
        isUsingEphemeralFallback = false
        defaults.removeObject(forKey: markerKey)
        SecItemDelete(keychainLookupQuery() as CFDictionary)
    }

    private func loadOrCreateRootLocked() -> RootPayload {
        if let cachedRoot,
           cachedRoot.secret.count >= 32,
           (isUsingEphemeralFallback || defaults.string(forKey: markerKey) == cachedRoot.marker) {
            return cachedRoot
        }

        let preferenceMarker = defaults.string(forKey: markerKey)
        if let preferenceMarker,
           let stored = readKeychainPayload(),
           stored.marker == preferenceMarker,
           stored.secret.count >= 32 {
            cachedRoot = stored
            isUsingEphemeralFallback = false
            return stored
        }

        // Missing/mismatched halves indicate a fresh install, reinstall, restore
        // to another device, or damaged local state. Rotate instead of trying to
        // reuse an ambiguous installation identity.
        let created = RootPayload(marker: UUID().uuidString.lowercased(), secret: randomSecret())
        if writeKeychainPayload(created) {
            defaults.set(created.marker, forKey: markerKey)
            isUsingEphemeralFallback = false
        } else {
            // Fail closed with respect to persistence: keep one process-local
            // root rather than writing a marker that could falsely look durable
            // on the next launch. Source identity is never an authorization factor.
            defaults.removeObject(forKey: markerKey)
            isUsingEphemeralFallback = true
        }
        cachedRoot = created
        return created
    }

    private func randomSecret() -> Data {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        if status == errSecSuccess { return Data(bytes) }

        // Extremely defensive fallback. UUID randomness is sufficient for a
        // pseudonymous installation namespace; this value is not a crypto key
        // protecting user content or granting authorization.
        return Data((UUID().uuidString + UUID().uuidString).utf8)
    }

    private func keychainLookupQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
        ]
    }

    private func readKeychainPayload() -> RootPayload? {
        var query = keychainLookupQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess,
              let data = result as? Data,
              let payload = try? JSONDecoder().decode(RootPayload.self, from: data)
        else { return nil }
        return payload
    }

    private func writeKeychainPayload(_ payload: RootPayload) -> Bool {
        guard let data = try? JSONEncoder().encode(payload) else { return false }

        let lookup = keychainLookupQuery()
        SecItemDelete(lookup as CFDictionary)

        var item = lookup
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
    }
}

/// Stable-in-process implementation for tests and development previews.
public final class InMemoryAccountInstallationIdentityStore: AccountInstallationIdentityProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var root = UUID().uuidString
    private var ids: [String: String] = [:]

    public init() {}

    public func id(for userId: String) -> String {
        lock.lock()
        defer { lock.unlock() }
        if let existing = ids[userId] { return existing }
        let created = "test-\(root)-\(UUID().uuidString)"
        ids[userId] = created
        return created
    }

    public func resetInstallation() {
        lock.lock()
        defer { lock.unlock() }
        root = UUID().uuidString
        ids.removeAll()
    }
}
