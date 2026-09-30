import CryptoKit
import Foundation
import LocalAuthentication
import Security

enum CodexQuotaError: Error, Equatable {
    case noCredential, unreadableCredential, unsupportedAuthentication, unsupportedConfiguration
    case network, invalidResponse, http(Int)

    var userMessage: String {
        switch self {
        case .noCredential: return "找不到這台 Mac 已儲存的 Codex 登入狀態"
        case .unreadableCredential: return "無法讀取這台 Mac 的 Codex 登入狀態"
        case .unsupportedAuthentication: return "本機 Codex 登入方式未提供 ChatGPT 訂閱額度"
        case .unsupportedConfiguration: return "目前的 Codex 設定需要由本機 Codex 程式查詢"
        case .network: return "暫時無法連線至 ChatGPT 額度服務"
        case .invalidResponse: return "ChatGPT 未回傳可辨識的 Codex 額度"
        case .http(401): return "本機 Codex 授權目前無法查詢額度；等待 Codex 更新既有登入狀態"
        case .http(429): return "ChatGPT 額度服務暫時限流，稍後自動重試"
        case .http(let status): return "ChatGPT 額度查詢失敗（HTTP \(status)）"
        }
    }
}

/// Read-only access to the login Codex already owns. Never copies, refreshes,
/// rewrites, or deletes credentials. The installed app-server handles refresh.
struct CodexCredentialStore {
    struct Credential {
        let accessToken: String
        let accountID: String?
    }

    let home: URL
    var readKeychain: (String) throws -> Data? = Self.keychainData

    static func homeURL(environment: [String: String], userHome: URL) -> URL {
        guard let raw = environment["CODEX_HOME"]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else { return userHome.appendingPathComponent(".codex") }
        if raw == "~" { return userHome }
        if raw.hasPrefix("~/") { return userHome.appendingPathComponent(String(raw.dropFirst(2))) }
        return URL(fileURLWithPath: raw, isDirectory: true).standardizedFileURL
    }

    static func keychainAccount(home: URL) -> String {
        let canonical = home.standardizedFileURL.resolvingSymlinksInPath().path
        let digest = SHA256.hash(data: Data(canonical.utf8))
            .map { String(format: "%02x", $0) }.joined()
        return "cli|" + digest.prefix(16)
    }

    func read() throws -> Credential {
        let configURL = home.appendingPathComponent("config.toml")
        var config: [String: String] = [:]
        if FileManager.default.fileExists(atPath: configURL.path) {
            guard let text = try? String(contentsOf: configURL, encoding: .utf8) else {
                throw CodexQuotaError.unreadableCredential
            }
            config = Self.authSettings(text)
        }
        if let base = config["chatgpt_base_url"],
           !["https://chatgpt.com", "https://chatgpt.com/backend-api"].contains(base.trimmingCharacters(in: CharacterSet(charactersIn: "/"))) {
            throw CodexQuotaError.unsupportedConfiguration
        }
        if config["forced_login_method"] == "api" { throw CodexQuotaError.unsupportedAuthentication }
        let mode = config["cli_auth_credentials_store"] ?? "file"
        let data: Data
        switch mode {
        case "file": data = try fileData()
        case "auto", "keyring":
            guard config["cli_auth_keyring_backend"] == nil || config["cli_auth_keyring_backend"] == "direct" else {
                throw CodexQuotaError.unsupportedConfiguration
            }
            let stored: Data?
            do { stored = try readKeychain(Self.keychainAccount(home: home)) }
            catch {
                if mode == "keyring" { throw CodexQuotaError.unreadableCredential }
                stored = nil
            }
            if let stored { data = stored }
            else if mode == "auto" { data = try fileData() }
            else { throw CodexQuotaError.noCredential }
        default: throw CodexQuotaError.unsupportedConfiguration
        }
        let credential = try Self.parse(data)
        if let workspace = config["forced_chatgpt_workspace_id"], credential.accountID != workspace {
            throw CodexQuotaError.unsupportedConfiguration
        }
        return credential
    }

    private func fileData() throws -> Data {
        let url = home.appendingPathComponent("auth.json")
        guard FileManager.default.fileExists(atPath: url.path) else { throw CodexQuotaError.noCredential }
        guard let data = try? Data(contentsOf: url) else { throw CodexQuotaError.unreadableCredential }
        return data
    }

    static func parse(_ data: Data) throws -> Credential {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CodexQuotaError.unreadableCredential
        }
        if let mode = root["auth_mode"] as? String, mode != "chatgpt" {
            throw CodexQuotaError.unsupportedAuthentication
        }
        if root["auth_mode"] == nil, let key = root["OPENAI_API_KEY"] as? String, !key.isEmpty {
            throw CodexQuotaError.unsupportedAuthentication
        }
        guard let tokens = root["tokens"] as? [String: Any],
              let token = tokens["access_token"] as? String, !token.isEmpty,
              !token.contains("\r"), !token.contains("\n") else { throw CodexQuotaError.noCredential }
        let account = (tokens["account_id"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        guard account?.contains("\r") != true, account?.contains("\n") != true else {
            throw CodexQuotaError.unreadableCredential
        }
        return Credential(accessToken: token, accountID: account)
    }

    // Only root-level scalar settings affect this fallback. Full configuration
    // resolution remains the responsibility of the installed Codex app-server.
    static func authSettings(_ text: String) -> [String: String] {
        let keys: Set<String> = ["cli_auth_credentials_store", "cli_auth_keyring_backend", "chatgpt_base_url", "forced_login_method", "forced_chatgpt_workspace_id"]
        var result: [String: String] = [:]
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") { break }
            let pair = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard pair.count == 2, keys.contains(pair[0]) else { continue }
            let value = pair[1]
            guard let quote = value.first, quote == "\"" || quote == "'",
                  let end = value.dropFirst().firstIndex(of: quote) else {
                result[pair[0]] = "unsupported"
                continue
            }
            result[pair[0]] = String(value[value.index(after: value.startIndex)..<end])
        }
        return result
    }

    private static func keychainData(account: String) throws -> Data? {
        let context = LAContext()
        context.interactionNotAllowed = true
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "Codex Auth",
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecUseAuthenticationContext as String: context
        ]
        var value: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &value)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = value as? Data else {
            throw CodexQuotaError.unreadableCredential
        }
        return data
    }
}

/// Uses the same read-only usage endpoint as Codex's backend client.
/// Credentials go only to this fixed HTTPS origin; redirects are never followed.
struct CodexQuotaClient {
    static let usageURL = URL(string: "https://chatgpt.com/backend-api/wham/usage")!
    let credentials: CodexCredentialStore
    var now = Date()
    var send: (URLRequest) throws -> (Data, Int) = CodexQuotaHTTP.send

    func fetch() throws -> CodexLiveLimits {
        let credential = try credentials.read()
        var request = URLRequest(url: Self.usageURL)
        request.timeoutInterval = 10
        request.setValue("Bearer " + credential.accessToken, forHTTPHeaderField: "Authorization")
        request.setValue(credential.accountID, forHTTPHeaderField: "ChatGPT-Account-Id")
        request.setValue("codex-cli", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, status) = try send(request)
        guard status == 200 else { throw CodexQuotaError.http(status) }
        return try Self.parse(data, now: now)
    }

    static func parse(_ data: Data, now: Date) throws -> CodexLiveLimits {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let limits = root["rate_limit"] as? [String: Any] else { throw CodexQuotaError.invalidResponse }
        func window(_ value: Any?) -> RateWindow? {
            guard let value = value as? [String: Any],
                  let used = value["used_percent"] as? NSNumber, CFGetTypeID(used) != CFBooleanGetTypeID(),
                  used.doubleValue.isFinite, (0...100).contains(used.doubleValue) else { return nil }
            let seconds = (value["limit_window_seconds"] as? NSNumber)?.doubleValue
            let reset = (value["reset_at"] as? NSNumber)?.doubleValue
            let duration = seconds.flatMap { $0.isFinite && $0 > 0 && $0 < 315_360_000 ? Int($0 / 60) : nil }
            let date = reset.flatMap { $0.isFinite && $0 > 0 ? Date(timeIntervalSince1970: $0) : nil }
            return RateWindow(usedPercent: used.doubleValue, windowMinutes: duration,
                              resetsAt: date, isExpired: date.map { $0 <= now } ?? false)
        }
        let primary = window(limits["primary_window"])
        let secondary = window(limits["secondary_window"])
        guard primary != nil || secondary != nil else { throw CodexQuotaError.invalidResponse }
        return CodexLiveLimits(primary: primary, secondary: secondary,
                               planType: root["plan_type"] as? String, accountEmail: root["email"] as? String)
    }
}

private final class CodexQuotaHTTP: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }

    static func send(_ request: URLRequest) throws -> (Data, Int) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        let session = URLSession(configuration: configuration, delegate: CodexQuotaHTTP(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let response = Response()
        let ready = DispatchSemaphore(value: 0)
        let task = session.dataTask(with: request) { data, result, _ in
            response.lock.lock()
            if let data, data.count < 1_048_576, let result = result as? HTTPURLResponse {
                response.value = (data, result.statusCode)
            }
            response.lock.unlock()
            ready.signal()
        }
        task.resume()
        guard ready.wait(timeout: .now() + 12) == .success else { throw CodexQuotaError.network }
        response.lock.lock()
        defer { response.lock.unlock() }
        guard let value = response.value else { throw CodexQuotaError.network }
        return value
    }

    private final class Response: @unchecked Sendable {
        let lock = NSLock()
        var value: (Data, Int)?
    }
}
