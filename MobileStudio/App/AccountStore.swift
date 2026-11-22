import Foundation
import Security

/// Roblox credentials kept in the Keychain (port of net/Accounts.kt): an Open Cloud API key the
/// user pastes in Settings and/or the session cookie from signing in through the web view.
final class AccountStore: ObservableObject {
    static let shared = AccountStore()

    @Published private(set) var apiKey: String?
    @Published private(set) var cookie: String?
    /// The user's own Anthropic API key for the AI Assistant (Keychain, this device only).
    @Published private(set) var anthropicKey: String?
    @Published var userName: String?
    @Published var userId: Int64?

    private let service = "com.exampletest.mobilestudio.roblox"

    init() {
        apiKey = read("apiKey")
        cookie = read("cookie")
        anthropicKey = read("anthropicKey")
        userName = UserDefaults.standard.string(forKey: "robloxUserName")
        let id = UserDefaults.standard.object(forKey: "robloxUserId") as? Int64
        userId = id
    }

    var isSignedIn: Bool { !(cookie ?? "").isEmpty }

    func setApiKey(_ k: String?) {
        apiKey = k?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        write("apiKey", apiKey)
    }

    func setSession(cookie c: String?, userName: String?, userId: Int64?) {
        cookie = c?.nilIfEmpty
        write("cookie", cookie)
        self.userName = userName
        self.userId = userId
        UserDefaults.standard.set(userName, forKey: "robloxUserName")
        UserDefaults.standard.set(userId, forKey: "robloxUserId")
    }

    func setAnthropicKey(_ k: String?) {
        anthropicKey = k?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        write("anthropicKey", anthropicKey)
    }

    func signOut() { setSession(cookie: nil, userName: nil, userId: nil) }

    private func read(_ account: String) -> String? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: account, kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }

    private func write(_ account: String, _ value: String?) {
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                   kSecAttrAccount as String: account]
        SecItemDelete(base as CFDictionary)
        guard let value else { return }
        var add = base
        add[kSecValueData as String] = Data(value.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(add as CFDictionary, nil)
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
