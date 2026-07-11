import AppKit
import SwiftUI

/// Settings pane for choosing which Claude accounts AIBar monitors. Opened from
/// the popover's "+" button. Lists monitored accounts (removable) and, below,
/// the accounts discovered on this machine plus a one-click login and a folder
/// picker. Shares the popover's light visual language for a consistent feel.
struct AccountsSettingsView: View {
    @ObservedObject var store: ClaudeAccountsStore
    var onChange: () -> Void

    @State private var discovered: [DiscoveredClaudeAccount] = []
    @State private var isScanning = false
    /// The config dir of an in-progress "登入新帳號" flow; once a login lands there,
    /// the account is added automatically using its email as the label.
    @State private var pendingLoginConfigDir: String?

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [AppColors.backgroundTop, AppColors.backgroundBottom],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            VStack(alignment: .leading, spacing: 16) {
                Text("Claude 帳號")
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(AppColors.ink)

                section(header: "監看中") { monitoredCard }

                section(header: "加入其他帳號") { addCard }

                Spacer(minLength: 0)

                Text("額外帳號需在其設定資料夾用 CLI 登入過一次,AIBar 才讀得到官方額度。")
                    .font(.system(size: 11))
                    .foregroundStyle(AppColors.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(18)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .environment(\.colorScheme, .light)
        .frame(minWidth: 440, minHeight: 480)
        .onAppear(perform: scan)
        .onReceive(NotificationCenter.default.publisher(for: .aibarAccountsRescan)) { _ in
            scan()
            onChange()
        }
    }

    // MARK: - Sections

    private var monitoredCard: some View {
        VStack(spacing: 0) {
            if defaultAccount == nil && configuredExtras.isEmpty {
                emptyRow(isScanning ? "掃描已登入帳號…" : "找不到已登入的 Claude 帳號。")
            }

            if let defaultAccount {
                accountRow(
                    title: defaultAccount.suggestedLabel,
                    subtitle: metadata(subscription: defaultAccount.subscriptionType, prefix: "預設"),
                    pathTooltip: "預設 ~/.claude"
                ) {
                    badge("自動")
                }
            }

            ForEach(Array(configuredExtras.enumerated()), id: \.element.id) { index, entry in
                if defaultAccount != nil || index > 0 {
                    rowDivider
                }
                accountRow(
                    title: entry.label,
                    subtitle: metadata(subscription: subscription(forConfigDir: entry.configDir), prefix: nil),
                    pathTooltip: entry.configDir
                ) {
                    iconButton(systemName: "xmark.circle.fill", tint: AppColors.tertiary, help: "移除") {
                        store.remove(entry)
                        onChange()
                        scan()
                    }
                }
            }
        }
    }

    private var addCard: some View {
        VStack(spacing: 0) {
            ForEach(Array(addableAccounts.enumerated()), id: \.element.id) { index, account in
                if index > 0 { rowDivider }
                accountRow(
                    title: account.suggestedLabel,
                    subtitle: metadata(subscription: account.subscriptionType, prefix: nil),
                    pathTooltip: account.configDir
                ) {
                    iconButton(systemName: "plus.circle.fill", tint: AppColors.claudeAccent, help: "加入監看") {
                        add(account)
                    }
                }
            }

            if addableAccounts.isEmpty {
                emptyRow(isScanning ? "掃描中…" : "沒有其他已登入的帳號。")
            }

            rowDivider

            HStack(spacing: 10) {
                Button(action: loginNewAccount) {
                    Label("登入新帳號", systemImage: "person.crop.circle.badge.plus")
                }
                .buttonStyle(.borderedProminent)
                .tint(AppColors.claudeAccent)
                .controlSize(.small)

                Button("選擇資料夾…", action: pickFolder)
                    .buttonStyle(.link)
                    .controlSize(.small)

                Spacer()

                if isScanning {
                    ProgressView().controlSize(.small)
                } else {
                    iconButton(systemName: "arrow.clockwise", tint: AppColors.secondary, help: "重新掃描", action: scan)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
        }
    }

    // MARK: - Reusable pieces

    private func section<Content: View>(header: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(header)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(AppColors.secondary)
            content()
                .background(AppColors.panel, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(AppColors.border.opacity(0.6), lineWidth: 1)
                )
        }
    }

    private func accountRow<Trailing: View>(
        title: String,
        subtitle: String,
        pathTooltip: String?,
        @ViewBuilder trailing: () -> Trailing
    ) -> some View {
        HStack(spacing: 11) {
            Image(systemName: "sparkles")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(AppColors.claudeAccent)
                .frame(width: 30, height: 30)
                .background(AppColors.claudeAccent.opacity(0.14), in: RoundedRectangle(cornerRadius: 8, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(AppColors.ink)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(AppColors.tertiary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            trailing()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .help(pathTooltip ?? "")
    }

    private func emptyRow(_ text: String) -> some View {
        HStack {
            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(AppColors.tertiary)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 12)
    }

    private var rowDivider: some View {
        Rectangle()
            .fill(AppColors.border.opacity(0.5))
            .frame(height: 1)
            .padding(.leading, 53)
    }

    private func badge(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(AppColors.claudeAccent)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(AppColors.claudeAccent.opacity(0.12), in: Capsule())
    }

    private func iconButton(systemName: String, tint: Color, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(tint)
        }
        .buttonStyle(.plain)
        .help(help)
    }

    // MARK: - Derived data

    /// The default `~/.claude` account, monitored automatically via statusline.
    private var defaultAccount: DiscoveredClaudeAccount? {
        discovered.first { $0.configDir == nil }
    }

    /// Extra (non-default) accounts the user has explicitly added.
    private var configuredExtras: [ClaudeAccountEntry] {
        store.accounts.filter { $0.configDir?.isEmpty == false }
    }

    private var addableAccounts: [DiscoveredClaudeAccount] {
        discovered.filter { account in
            account.configDir != nil
                && !store.accounts.contains { $0.id == ClaudeAccountEntry(label: "", configDir: account.configDir).id }
        }
    }

    private func subscription(forConfigDir configDir: String?) -> String? {
        discovered.first { $0.configDir == configDir }?.subscriptionType
    }

    private func metadata(subscription: String?, prefix: String?) -> String {
        [prefix, subscription?.isEmpty == false ? subscription : nil]
            .compactMap { $0 }
            .joined(separator: " · ")
            .ifEmpty("已加入")
    }

    // MARK: - Actions

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
        store.add(ClaudeAccountEntry(label: account.suggestedLabel, configDir: account.configDir))
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

private extension String {
    func ifEmpty(_ fallback: String) -> String {
        isEmpty ? fallback : self
    }
}
