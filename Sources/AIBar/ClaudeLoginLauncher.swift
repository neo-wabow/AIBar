import AppKit

/// Opens Terminal on a Claude CLI login. Writes a `.command` script and opens it:
/// opening a document launches Terminal without AIBar needing the Automation
/// ("control Terminal") permission that AppleScript would require.
enum ClaudeLoginLauncher {
    /// First login into a fresh `~/<configDirName>`; `claude` in an empty config dir
    /// starts the browser OAuth flow.
    static func openNewAccountLogin(configDirName: String) {
        let script = """
        #!/bin/bash
        echo "———————————————————————————————————————————"
        echo " 用你要新增的 Claude 帳號在瀏覽器登入。"
        echo " 登入完成後,關閉這個視窗、切回 AIBar —"
        echo " 新帳號會用它的 Email 自動加入監看。"
        echo "———————————————————————————————————————————"
        CLAUDE_CONFIG_DIR="$HOME/\(configDirName)" claude
        """
        open(script, named: "login-\(configDirName)")
    }

    /// Signs an existing config dir back in after its login expired. The email is
    /// prefilled so the browser's current session does not quietly sign a different
    /// account into this dir.
    static func openRelogin(_ target: ClaudeReloginTarget) {
        let name = target.configDir.map { ($0 as NSString).lastPathComponent } ?? "default"
        open(reloginScript(for: target), named: "relogin-\(name)")
    }

    static func reloginScript(for target: ClaudeReloginTarget) -> String {
        // The default dir must run without CLAUDE_CONFIG_DIR: setting it, even to
        // ~/.claude, makes the CLI use a hashed Keychain item instead of the bare one.
        let environment = target.configDir.map { "CLAUDE_CONFIG_DIR=\(quoted($0)) " } ?? ""
        let who = target.email.map { "用 \($0) " } ?? "用原本的帳號"
        let emailFlag = target.email.map { " --email \(quoted($0))" } ?? ""
        return """
        #!/bin/bash
        echo "———————————————————————————————————————————"
        echo " 這個資料夾的 Claude 登入已過期。"
        echo \(quoted(" 請在瀏覽器\(who)重新登入。"))
        echo " 登入完成後關閉這個視窗即可,AIBar 會自動恢復。"
        echo "———————————————————————————————————————————"
        \(environment)claude auth login --claudeai\(emailFlag)
        """
    }

    private static func open(_ script: String, named name: String) {
        let directory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".ai-usage", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("\(name).command")
        do {
            try script.write(to: file, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
        } catch {
            return
        }
        NSWorkspace.shared.open(file)
    }

    /// Single-quotes a value for bash, so a path or email is passed through verbatim.
    private static func quoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
