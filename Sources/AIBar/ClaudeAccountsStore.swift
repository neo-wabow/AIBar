import Foundation
import Combine

/// One entry in `~/.ai-usage/claude-accounts.json`. Shared by the settings UI
/// (which writes it) and the collector (which reads it on a background thread).
struct ClaudeAccountEntry: Codable, Identifiable, Equatable {
    var label: String
    /// `CLAUDE_CONFIG_DIR` path; nil means the default `~/.claude`.
    var configDir: String?
    /// Optional escape hatches, rarely needed.
    var keychainService: String?
    var account: String?

    var id: String { configDir ?? "__default__" }
}

struct ClaudeAccountsFile: Codable {
    var accounts: [ClaudeAccountEntry]
}

/// Reads and writes the monitored-accounts file for the settings UI.
@MainActor
final class ClaudeAccountsStore: ObservableObject {
    @Published private(set) var accounts: [ClaudeAccountEntry] = []

    static var fileURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".ai-usage", isDirectory: true)
            .appendingPathComponent("claude-accounts.json")
    }

    init() {
        load()
    }

    func load() {
        guard
            let data = try? Data(contentsOf: Self.fileURL),
            let file = try? JSONDecoder().decode(ClaudeAccountsFile.self, from: data)
        else {
            accounts = []
            return
        }
        accounts = file.accounts
    }

    func contains(configDir: String?) -> Bool {
        let target = ClaudeAccountEntry(label: "", configDir: configDir).id
        return accounts.contains { $0.id == target }
    }

    func add(_ entry: ClaudeAccountEntry) {
        guard !accounts.contains(where: { $0.id == entry.id }) else { return }
        accounts.append(entry)
        save()
    }

    func remove(_ entry: ClaudeAccountEntry) {
        accounts.removeAll { $0.id == entry.id }
        save()
    }

    func rename(_ entry: ClaudeAccountEntry, to label: String) {
        guard let index = accounts.firstIndex(where: { $0.id == entry.id }) else { return }
        accounts[index].label = label
        save()
    }

    private func save() {
        let directory = Self.fileURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(ClaudeAccountsFile(accounts: accounts)) else { return }

        if accounts.isEmpty {
            // Removing the file restores AIBar's default statusline-only behaviour.
            try? FileManager.default.removeItem(at: Self.fileURL)
        } else {
            try? data.write(to: Self.fileURL, options: .atomic)
        }
    }
}
