import Foundation
import Security

/// Sendable so `AppState.start()` can read the Keychain off the main thread.
public protocol KeychainServicing: Sendable {
    func save(account: String, value: String) throws
    func retrieve(account: String) throws -> String?
    func delete(account: String) throws
}

public struct KeychainService: KeychainServicing {
    /// The service the shipped app stores credentials under. Never change this:
    /// every installed copy's saved accounts live here.
    public static let productionServiceName = "com.claudebar"

    /// Development builds get their own service so they never touch the real
    /// accounts. They are signed differently from a release build, and a
    /// login-keychain item's ACL is bound to the signing identity -- sharing one
    /// item means macOS prompts for the keychain password on every switch
    /// between a dev build and the installed app, on top of the risk of a
    /// half-finished change corrupting live credentials. For the same reason
    /// run.sh and bundle.sh get a service each: those two are signed differently
    /// from each other as well.
    ///
    /// `isDebug` covers `scripts/run.sh`, which runs a bare debug binary with no
    /// Info.plist. `override` covers `scripts/bundle.sh`, which builds in release
    /// configuration and so stamps the key into the bundle it produces instead,
    /// and release.sh's smoke test, which passes it in the environment -- editing
    /// the Info.plist of the bundle it is about to ship would break its signature.
    static func resolveServiceName(isDebug: Bool, override: String?) -> String {
        if isDebug { return "\(productionServiceName).dev" }
        return override ?? productionServiceName
    }

    public static let defaultServiceName: String = {
        #if DEBUG
        let isDebug = true
        #else
        let isDebug = false
        #endif
        return resolveServiceName(
            isDebug: isDebug,
            override: ProcessInfo.processInfo.environment["CLAUDEBAR_KEYCHAIN_SERVICE"]
                ?? Bundle.main.object(forInfoDictionaryKey: "ClaudeBarKeychainService") as? String
        )
    }()

    public let serviceName: String

    public init(serviceName: String = KeychainService.defaultServiceName) {
        self.serviceName = serviceName
    }

    public func save(account: String, value: String) throws {
        guard let data = value.data(using: .utf8) else {
            throw KeychainError.encodingFailed
        }

        let identity: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: account,
        ]

        // Upsert: update if present, add if not. delete+add fails when the
        // existing item's ACL blocks delete (errSecDuplicateItem on re-add).
        let updateStatus = SecItemUpdate(identity as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if updateStatus == errSecSuccess { return }
        if updateStatus != errSecItemNotFound {
            throw KeychainError.saveFailed(updateStatus)
        }

        var addQuery = identity
        addQuery[kSecValueData as String] = data
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw KeychainError.saveFailed(addStatus)
        }
    }

    public func retrieve(account: String) throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else {
            throw KeychainError.retrieveFailed(status)
        }
        return String(data: data, encoding: .utf8)
    }

    public func delete(account: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: account,
        ]

        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.deleteFailed(status)
        }
    }
}

public enum KeychainError: Error {
    case encodingFailed
    case saveFailed(OSStatus)
    case retrieveFailed(OSStatus)
    case deleteFailed(OSStatus)
}
