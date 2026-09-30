import Foundation

final class CodexQuotaTests {
    private var directory: URL!
    private let fixture = Data(#"{"auth_mode":"chatgpt","tokens":{"access_token":"test-token","account_id":"test-workspace","refresh_token":"do-not-touch"},"extra":"preserve"}"#.utf8)
    private let quota = Data(#"{"email":"test@example.invalid","plan_type":"pro","rate_limit":{"primary_window":{"used_percent":14,"limit_window_seconds":604800,"reset_at":2000000000},"secondary_window":null},"additional_rate_limits":[{"rate_limit":{"primary_window":{"used_percent":99}}}]}"#.utf8)

    func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func tearDownWithError() throws {
        try FileManager.default.removeItem(at: directory)
    }

    func testExistingLoginWorksWithoutCodexExecutableAndIsUnchanged() throws {
        let auth = directory.appendingPathComponent("auth.json")
        try fixture.write(to: auth)
        var client = CodexQuotaClient(credentials: CodexCredentialStore(home: directory), now: Date(timeIntervalSince1970: 1_900_000_000))
        client.send = { request in
            try expectEqual(request.url, CodexQuotaClient.usageURL)
            try expectEqual(request.httpMethod, "GET")
            try expectEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-token")
            try expectEqual(request.value(forHTTPHeaderField: "ChatGPT-Account-Id"), "test-workspace")
            try expectNil(request.httpBody)
            return (self.quota, 200)
        }
        let result = try client.fetch()
        try expectEqual(result.primary?.remainingPercent, 86)
        try expectEqual(result.primary?.windowMinutes, 10080)
        try expectEqual(result.primary?.isExpired, false)
        try expectNil(result.secondary)
        try expectEqual(result.accountEmail, "test@example.invalid")
        try expectEqual(try Data(contentsOf: auth), fixture)
    }

    func testConfiguredHomeNeverFallsBackToAnotherAccount() throws {
        let selected = CodexCredentialStore.homeURL(environment: ["CODEX_HOME": "~/selected-codex"], userHome: directory)
        try expectEqual(selected, directory.appendingPathComponent("selected-codex"))
        try fixture.write(to: directory.appendingPathComponent("auth.json"))
        try expectThrows(try CodexCredentialStore(home: selected).read()) {
            try expectEqual($0 as? CodexQuotaError, .noCredential)
        }
    }

    func testKeyringModeUsesExistingKeychainAccountAndIgnoresOldFile() throws {
        try "cli_auth_credentials_store = 'keyring'\n".write(to: directory.appendingPathComponent("config.toml"), atomically: true, encoding: .utf8)
        try Data(#"{"tokens":{"access_token":"old-account"}}"#.utf8).write(to: directory.appendingPathComponent("auth.json"))
        let store = CodexCredentialStore(home: directory, readKeychain: { account in
            try expectEqual(account, CodexCredentialStore.keychainAccount(home: self.directory))
            return self.fixture
        })
        try expectEqual(try store.read().accessToken, "test-token")
        let absent = CodexCredentialStore(home: directory, readKeychain: { _ in nil })
        try expectThrows(try absent.read()) { try expectEqual($0 as? CodexQuotaError, .noCredential) }
    }

    func testAutoStoreFallsBackToFileAndIgnoresProfileSettings() throws {
        try fixture.write(to: directory.appendingPathComponent("auth.json"))
        try "cli_auth_credentials_store = \"auto\" # comment\n[profiles.other]\ncli_auth_credentials_store = \"ephemeral\"\n".write(to: directory.appendingPathComponent("config.toml"), atomically: true, encoding: .utf8)
        let store = CodexCredentialStore(home: directory, readKeychain: { _ in nil })
        try expectEqual(try store.read().accountID, "test-workspace")
    }

    func testAPIKeyDoesNotUseLeftoverChatGPTTokens() throws {
        for json in [#"{"auth_mode":"apikey","tokens":{"access_token":"old"}}"#,
                     #"{"OPENAI_API_KEY":"test-key","tokens":{"access_token":"old"}}"#] {
            try expectThrows(try CodexCredentialStore.parse(Data(json.utf8))) {
                try expectEqual($0 as? CodexQuotaError, .unsupportedAuthentication)
            }
        }
    }

    func testUnauthorizedNeverRefreshesOrChangesCredential() throws {
        let auth = directory.appendingPathComponent("auth.json")
        try fixture.write(to: auth)
        var count = 0
        var client = CodexQuotaClient(credentials: CodexCredentialStore(home: directory))
        client.send = { _ in count += 1; return (Data(), 401) }
        try expectThrows(try client.fetch()) { try expectEqual($0 as? CodexQuotaError, .http(401)) }
        try expectEqual(count, 1)
        try expectEqual(try Data(contentsOf: auth), fixture)
    }

    func testUnknownQuotaIsNotReportedAsFullAndExpiryIsPreserved() throws {
        for json in [#"{}"#, #"{"rate_limit":null}"#,
                     #"{"rate_limit":{"primary_window":{"used_percent":true}}}"#,
                     #"{"rate_limit":{"primary_window":{"used_percent":-1}}}"#] {
            try expectThrows(try CodexQuotaClient.parse(Data(json.utf8), now: Date()))
        }
        let expired = try CodexQuotaClient.parse(quota, now: Date(timeIntervalSince1970: 2_000_000_001))
        try expectEqual(expired.primary?.isExpired, true)
    }

    func testCustomBackendNeverReceivesStoredCredentials() throws {
        try fixture.write(to: directory.appendingPathComponent("auth.json"))
        try "chatgpt_base_url = 'https://example.invalid'".write(to: directory.appendingPathComponent("config.toml"), atomically: true, encoding: .utf8)
        var client = CodexQuotaClient(credentials: CodexCredentialStore(home: directory))
        client.send = { _ in throw TestFailure(message: "Must not send credentials") }
        try expectThrows(try client.fetch()) { try expectEqual($0 as? CodexQuotaError, .unsupportedConfiguration) }
    }
}

struct TestFailure: Error { let message: String }
func expectEqual<T: Equatable>(_ actual: @autoclosure () throws -> T, _ expected: T) throws {
    guard try actual() == expected else { throw TestFailure(message: "Expected values to match") }
}
func expectNil<T>(_ value: T?) throws {
    guard value == nil else { throw TestFailure(message: "Expected nil") }
}
func expectThrows<T>(_ operation: @autoclosure () throws -> T, check: (Error) throws -> Void = { _ in }) throws {
    do { _ = try operation() } catch { try check(error); return }
    throw TestFailure(message: "Expected operation to fail")
}

let checks: [(String, (CodexQuotaTests) throws -> Void)] = [
    ("testExistingLoginWorksWithoutCodexExecutableAndIsUnchanged", { try $0.testExistingLoginWorksWithoutCodexExecutableAndIsUnchanged() }),
    ("testConfiguredHomeNeverFallsBackToAnotherAccount", { try $0.testConfiguredHomeNeverFallsBackToAnotherAccount() }),
    ("testKeyringModeUsesExistingKeychainAccountAndIgnoresOldFile", { try $0.testKeyringModeUsesExistingKeychainAccountAndIgnoresOldFile() }),
    ("testAutoStoreFallsBackToFileAndIgnoresProfileSettings", { try $0.testAutoStoreFallsBackToFileAndIgnoresProfileSettings() }),
    ("testAPIKeyDoesNotUseLeftoverChatGPTTokens", { try $0.testAPIKeyDoesNotUseLeftoverChatGPTTokens() }),
    ("testUnauthorizedNeverRefreshesOrChangesCredential", { try $0.testUnauthorizedNeverRefreshesOrChangesCredential() }),
    ("testUnknownQuotaIsNotReportedAsFullAndExpiryIsPreserved", { try $0.testUnknownQuotaIsNotReportedAsFullAndExpiryIsPreserved() }),
    ("testCustomBackendNeverReceivesStoredCredentials", { try $0.testCustomBackendNeverReceivesStoredCredentials() })
]
for (name, check) in checks {
    let suite = CodexQuotaTests()
    do {
        try suite.setUpWithError()
        try check(suite)
        try suite.tearDownWithError()
        print("PASS \(name)")
    } catch {
        try? suite.tearDownWithError()
        print("FAIL \(name): \(error)")
        exit(1)
    }
}
print("Passed \(checks.count) Codex quota checks")
