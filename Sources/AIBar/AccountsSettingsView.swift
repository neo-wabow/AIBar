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
    }

    private var monitoredSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("監看中")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)

            if store.accounts.isEmpty {
                Text("尚未加入額外帳號。目前只顯示預設 CLI 帳號(statusline)。")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            } else {
                ForEach(store.accounts) { entry in
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
    }

    private var addSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("加入帳號")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                if isScanning {
                    ProgressView().controlSize(.small)
                }
                Spacer()
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
            !store.accounts.contains { $0.id == ClaudeAccountEntry(label: "", configDir: account.configDir).id }
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
