import AppKit
import SwiftUI

/// Settings pane for choosing which Claude accounts AIBar monitors. Opened from
/// the popover's "+" button. Lists monitored accounts (removable) and, under a
/// "+", the accounts discovered on this machine plus a folder picker for config
/// dirs in non-standard locations.
struct AccountsSettingsView: View {
    @ObservedObject var store: ClaudeAccountsStore
    var onChange: () -> Void

    @State private var discovered: [DiscoveredClaudeAccount] = []
    @State private var isScanning = false
    /// The config dir of an in-progress "登入新帳號" flow; once a login lands there,
    /// the account is added automatically using its email as the label.
    @State private var pendingLoginConfigDir: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Claude 帳號")
                .font(.system(size: 15, weight: .semibold))

            monitoredSection

            Divider()

            addSection

            Spacer(minLength: 0)

            Text("額外帳號需先在其 config dir 用 CLI 登入過一次,AIBar 才讀得到官方額度。")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(18)
        .frame(minWidth: 420, minHeight: 440, alignment: .topLeading)
        .onAppear(perform: scan)
        .onReceive(NotificationCenter.default.publisher(for: .aibarAccountsRescan)) { _ in
            scan()
            onChange()
        }
    }

    private var monitoredSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("監看中")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)

            if defaultAccount == nil && configuredExtras.isEmpty {
                Text(isScanning ? "掃描已登入帳號…" : "找不到已登入的 Claude 帳號。")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }

            // The default CLI account is always monitored via statusline.
            if let defaultAccount {
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(defaultAccount.suggestedLabel).font(.system(size: 13, weight: .medium))
                        Text(subtitle(for: defaultAccount))
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text("自動")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.secondary.opacity(0.15), in: Capsule())
                }
                .padding(.vertical, 3)
            }

            ForEach(configuredExtras) { entry in
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(entry.label).font(.system(size: 13, weight: .medium))
                        Text(entry.configDir ?? "預設 ~/.claude")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button {
                        store.remove(entry)
                        onChange()
                        scan()
                    } label: {
                        Image(systemName: "minus.circle.fill").foregroundStyle(.red)
                    }
                    .buttonStyle(.plain)
                    .help("移除")
                }
                .padding(.vertical, 3)
            }
        }
    }

    /// The default `~/.claude` account, monitored automatically via statusline.
    private var defaultAccount: DiscoveredClaudeAccount? {
        discovered.first { $0.configDir == nil }
    }

    /// Extra (non-default) accounts the user has explicitly added.
    private var configuredExtras: [ClaudeAccountEntry] {
        store.accounts.filter { ($0.configDir?.isEmpty == false) }
    }

    private var addSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text("加入帳號")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                if isScanning {
                    ProgressView().controlSize(.small)
                }
                Spacer()
                Button {
                    scan()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .controlSize(.small)
                .help("重新掃描")
                Button("登入新帳號…", action: loginNewAccount)
                    .controlSize(.small)
                Button("選擇資料夾…", action: pickFolder)
                    .controlSize(.small)
            }

            if addableAccounts.isEmpty && !isScanning {
                Text("沒有偵測到其他已登入的帳號。用「選擇資料夾…」加入非慣例位置的 config dir。")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }

            ForEach(addableAccounts) { (account: DiscoveredClaudeAccount) in
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(account.suggestedLabel).font(.system(size: 13, weight: .medium))
                        Text(subtitle(for: account))
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button {
                        add(account)
                    } label: {
                        Image(systemName: "plus.circle.fill").foregroundStyle(Color.accentColor)
                    }
                    .buttonStyle(.plain)
                    .help("加入")
                }
                .padding(.vertical, 3)
            }
        }
    }

    private var addableAccounts: [DiscoveredClaudeAccount] {
        discovered.filter { account in
            // Exclude the default account (already monitored automatically) and any
            // account the user has already added.
            account.configDir != nil
                && !store.accounts.contains { $0.id == ClaudeAccountEntry(label: "", configDir: account.configDir).id }
        }
    }

    private func subtitle(for account: DiscoveredClaudeAccount) -> String {
        let dir = account.configDir ?? "預設 ~/.claude"
        if let sub = account.subscriptionType, !sub.isEmpty {
            return "\(dir) · \(sub)"
        }
        return dir
    }

    private func scan() {
        isScanning = true
        Task {
            let found = await Task.detached(priority: .utility) {
                ClaudeAccountDiscovery().discover()
            }.value
            await MainActor.run {
                discovered = found
                isScanning = false
                // A just-finished "登入新帳號" flow: add it automatically, using the
                // account's email as the label.
                if
                    let pending = pendingLoginConfigDir,
                    let account = found.first(where: { $0.configDir == pending })
                {
                    store.add(ClaudeAccountEntry(label: account.suggestedLabel, configDir: pending))
                    pendingLoginConfigDir = nil
                    onChange()
                }
            }
        }
    }

    private func add(_ account: DiscoveredClaudeAccount) {
        store.add(
            ClaudeAccountEntry(
                label: account.suggestedLabel,
                configDir: account.configDir,
                keychainService: nil,
                account: nil
            )
        )
        onChange()
    }

    /// Opens Terminal running the CLI login for a fresh, auto-named config dir, so a
    /// web/desktop-only account can be authenticated once without typing anything.
    /// After login, the account is added automatically with its email as the label.
    private func loginNewAccount() {
        let (name, path) = freshConfigDir()
        pendingLoginConfigDir = path
        openTerminalLogin(configDirName: name)
    }

    /// Picks a `.claude-accountN` dir that doesn't exist yet and isn't already used.
    private func freshConfigDir() -> (name: String, path: String) {
        let home = FileManager.default.homeDirectoryForCurrentUser
        var index = 1
        while true {
            let name = index == 1 ? ".claude-account" : ".claude-account\(index)"
            let path = home.appendingPathComponent(name).path
            if !FileManager.default.fileExists(atPath: path) && !store.contains(configDir: path) {
                return (name, path)
            }
            index += 1
        }
    }

    private func openTerminalLogin(configDirName: String) {
        // Write a .command script and open it: opening a document launches Terminal
        // without AIBar needing the Automation ("control Terminal") permission that
        // AppleScript would require. `claude` in a fresh config dir starts the
        // browser OAuth login flow.
        let script = """
        #!/bin/bash
        echo "———————————————————————————————————————————"
        echo " 用你要新增的 Claude 帳號在瀏覽器登入。"
        echo " 登入完成後,關閉這個視窗、切回 AIBar —"
        echo " 新帳號會用它的 Email 自動加入監看。"
        echo "———————————————————————————————————————————"
        CLAUDE_CONFIG_DIR="$HOME/\(configDirName)" claude
        """
        let directory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".ai-usage", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("login-\(configDirName).command")
        do {
            try script.write(to: file, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
        } catch {
            return
        }
        NSWorkspace.shared.open(file)
    }

    private func pickFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "選擇"
        panel.message = "選擇該帳號的 CLAUDE_CONFIG_DIR 資料夾"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let path = url.path
        let label = (path as NSString).lastPathComponent
        store.add(ClaudeAccountEntry(label: label.isEmpty ? "account" : label, configDir: path))
        onChange()
        scan()
    }
}
