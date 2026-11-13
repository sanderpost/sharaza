import Foundation
import Security

/// Secure macOS Keychain credential vault (`Security.framework`, service `app.sharaza.credentials`).
/// Ensures API keys, OAuth tokens, and custom uploader secrets never reside in plaintext config files.
public final class KeychainManager: Sendable {
    public static let shared = KeychainManager()
    private let service = "app.sharaza.credentials"

    public enum CredentialKey: String, CaseIterable, Sendable {
        case imgurClientId = "imgur_client_id"
        case imgurBearerToken = "imgur_bearer_token"
        case vgymeUserKey = "vgyme_user_key"
        case pastebinDevKey = "pastebin_api_dev_key"
        case pastebinUserKey = "pastebin_api_user_key"
        case githubGistToken = "github_gist_token"
        case bitlyAccessToken = "bitly_access_token"
        case dropboxAccessToken = "dropbox_access_token"
        case nextcloudWebDavUrl = "nextcloud_webdav_url"
        case nextcloudUsername = "nextcloud_username"
        case nextcloudPassword = "nextcloud_password"
        case s3PresignedUrl = "s3_presigned_url"
        case s3PublicBaseUrl = "s3_public_base_url"
        case customHeadersJson = "custom_headers_json"
        case customParametersJson = "custom_parameters_json"
    }

    public init() {}

    @discardableResult
    public func setSecret(_ value: String, for key: CredentialKey) -> Bool {
        setRawSecret(value, account: key.rawValue)
    }

    public func getSecret(for key: CredentialKey) -> String? {
        getRawSecret(account: key.rawValue)
    }

    @discardableResult
    public func deleteSecret(for key: CredentialKey) -> Bool {
        deleteRawSecret(account: key.rawValue)
    }

    @discardableResult
    public func setRawSecret(_ value: String, account: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return deleteRawSecret(account: account)
        }
        guard let data = trimmed.data(using: .utf8) else { return false }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]

        let attributesToUpdate: [String: Any] = [
            kSecValueData as String: data
        ]

        let updateStatus = SecItemUpdate(query as CFDictionary, attributesToUpdate as CFDictionary)
        if updateStatus == errSecSuccess {
            return true
        }

        var addQuery = query
        addQuery[kSecValueData as String] = data
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        return addStatus == errSecSuccess
    }

    public func getRawSecret(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    public func deleteRawSecret(account: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    public func resolveCredentials(gistPublic: Bool = false) -> ResolvedCredentials {
        let headers: [String: String] = {
            guard let raw = getSecret(for: .customHeadersJson),
                  let data = raw.data(using: .utf8),
                  let dict = try? JSONDecoder().decode([String: String].self, from: data) else {
                return [:]
            }
            return dict
        }()

        let params: [String: String] = {
            guard let raw = getSecret(for: .customParametersJson),
                  let data = raw.data(using: .utf8),
                  let dict = try? JSONDecoder().decode([String: String].self, from: data) else {
                return [:]
            }
            return dict
        }()

        return ResolvedCredentials(
            imgur_client_id: getSecret(for: .imgurClientId),
            imgur_bearer_token: getSecret(for: .imgurBearerToken),
            vgyme_user_key: getSecret(for: .vgymeUserKey),
            pastebin_api_dev_key: getSecret(for: .pastebinDevKey),
            pastebin_api_user_key: getSecret(for: .pastebinUserKey),
            github_gist_token: getSecret(for: .githubGistToken),
            github_gist_public: gistPublic,
            bitly_access_token: getSecret(for: .bitlyAccessToken),
            dropbox_access_token: getSecret(for: .dropboxAccessToken),
            nextcloud_webdav_url: getSecret(for: .nextcloudWebDavUrl),
            nextcloud_username: getSecret(for: .nextcloudUsername),
            nextcloud_password: getSecret(for: .nextcloudPassword),
            s3_presigned_url: getSecret(for: .s3PresignedUrl),
            s3_public_base_url: getSecret(for: .s3PublicBaseUrl),
            custom_headers: headers,
            custom_parameters: params
        )
    }
}
