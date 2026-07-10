import Foundation
import CryptoKit

/// Centralised access to the Claude Code OAuth credentials stored in the macOS
/// Keychain. Reads/writes shell out to `/usr/bin/security` on purpose: the items
/// are created by the CLI with an ACL that trusts the `security` tool, so going
/// through it avoids the authorization prompt a direct Security-framework call
/// would trigger for a separate app.
enum ClaudeKeychain {
    /// Keychain service name for a config dir, mirroring Claude Code's `g5()`:
    /// the default `~/.claude` uses the bare base; any other dir appends
    /// `-<first 8 hex of sha256(NFC path)>`.
    static func serviceName(configDir: String?) -> String {
        let base = "Claude Code-credentials"
        guard let configDir, !configDir.isEmpty else { return base }
        let defaultDir = (NSHomeDirectory() as NSString).appendingPathComponent(".claude")
        if (configDir as NSString).standardizingPath == (defaultDir as NSString).standardizingPath {
            return base
        }
        let normalized = configDir.precomposedStringWithCanonicalMapping // NFC
        let hash = SHA256.hash(data: Data(normalized.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
            .prefix(8)
        return "\(base)-\(hash)"
    }

    /// Keychain account (`-a`), mirroring the CLI: `$USER`, sanitised.
    static func accountName() -> String {
        let name = ProcessInfo.processInfo.environment["USER"] ?? NSUserName()
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
        return !name.isEmpty && name.unicodeScalars.allSatisfy(allowed.contains) ? name : "claude-code-user"
    }

    static func read(service: String, account: String) -> String? {
        let result = runSecurity(["find-generic-password", "-a", account, "-w", "-s", service])
        guard result.status == 0 else { return nil }
        let trimmed = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    static func write(service: String, account: String, json: [String: Any]) -> Bool {
        guard let data = try? JSONSerialization.data(withJSONObject: json) else { return false }
        let hex = data.map { String(format: "%02x", $0) }.joined()
        return runSecurity(["add-generic-password", "-U", "-a", account, "-s", service, "-X", hex]).status == 0
    }

    private static func runSecurity(_ arguments: [String]) -> (status: Int32, stdout: String, stderr: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = arguments
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        do {
            try process.run()
        } catch {
            return (-1, "", error.localizedDescription)
        }
        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (
            process.terminationStatus,
            String(decoding: outData, as: UTF8.self),
            String(decoding: errData, as: UTF8.self)
        )
    }
}
