import Foundation

/// A Claude account that AIBar found logged in on this machine — a config dir
/// whose Keychain entry holds a `claudeAiOauth` login. Used to populate the
/// "add account" picker so users choose from a list instead of typing paths.
struct DiscoveredClaudeAccount: Identifiable, Equatable {
    /// `CLAUDE_CONFIG_DIR` path; nil means the default `~/.claude`.
    var configDir: String?
    var keychainService: String
    var email: String?
    var organizationName: String?
    var subscriptionType: String?

    var id: String { configDir ?? "__default__" }

    /// Best label to seed the account entry with.
    var suggestedLabel: String {
        if let email, !email.isEmpty { return email }
        guard let configDir else { return "default" }
        let name = (configDir as NSString).lastPathComponent
        return name.isEmpty ? "account" : name
    }
}

/// Best-effort scan for logged-in Claude accounts. The Keychain suffix is a
/// one-way hash of the config-dir path, so we can't enumerate accounts from the
/// Keychain directly; instead we probe likely config dirs (the default plus
/// `~/.claude*` siblings) and keep the ones that carry a Claude login.
struct ClaudeAccountDiscovery {
    private let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    func discover() -> [DiscoveredClaudeAccount] {
        let account = ClaudeKeychain.accountName()
        let client = ClaudeCloudClient(now: Date())
        var results: [DiscoveredClaudeAccount] = []

        for configDir in candidateConfigDirs() {
            let service = ClaudeKeychain.serviceName(configDir: configDir)
            guard
                let blob = ClaudeKeychain.read(service: service, account: account),
                let root = (try? JSONSerialization.jsonObject(with: Data(blob.utf8))) as? [String: Any],
                let oauth = root["claudeAiOauth"] as? [String: Any],
                let accessToken = oauth["accessToken"] as? String,
                !accessToken.isEmpty
            else {
                continue
            }

            // /api/oauth/profile is authoritative for which account this token
            // belongs to; ~/.claude.json's oauthAccount can be stale. Fall back to
            // it only when the profile call is unavailable (e.g. offline/expired).
            let profile = client.fetchProfile(accessToken: accessToken)
            let fallback = authIdentity(configDir: configDir)
            results.append(
                DiscoveredClaudeAccount(
                    configDir: configDir,
                    keychainService: service,
                    email: profile?.email ?? fallback?.email,
                    organizationName: profile?.organizationName ?? fallback?.organizationName,
                    subscriptionType: oauth["subscriptionType"] as? String
                )
            )
        }

        return results
    }

    /// The default `~/.claude` (represented as nil) plus any `~/.claude*` sibling
    /// directories that look like alternate config dirs.
    private func candidateConfigDirs() -> [String?] {
        var candidates: [String?] = [nil]
        let home = fileManager.homeDirectoryForCurrentUser
        let defaultDir = home.appendingPathComponent(".claude", isDirectory: true).path

        // List by name so dot-directories are included, then keep `~/.claude*`
        // siblings that are real directories other than the default.
        let names = (try? fileManager.contentsOfDirectory(atPath: home.path)) ?? []
        var seen = Set<String>([defaultDir])
        for name in names.sorted() where name.hasPrefix(".claude") {
            let url = home.appendingPathComponent(name, isDirectory: true)
            var isDir: ObjCBool = false
            guard fileManager.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else { continue }
            guard seen.insert(url.path).inserted else { continue }
            candidates.append(url.path)
        }
        return candidates
    }

    private func authIdentity(configDir: String?) -> (email: String?, organizationName: String?)? {
        // The default account's config lives at ~/.claude.json (in home, not inside
        // ~/.claude); a custom config dir carries its own .claude.json.
        let configFile: URL
        if let configDir {
            configFile = URL(fileURLWithPath: configDir).appendingPathComponent(".claude.json")
        } else {
            configFile = fileManager.homeDirectoryForCurrentUser.appendingPathComponent(".claude.json")
        }
        guard
            let data = try? Data(contentsOf: configFile),
            let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
            let oauth = object["oauthAccount"] as? [String: Any]
        else {
            return nil
        }
        return (
            email: oauth["emailAddress"] as? String,
            organizationName: oauth["organizationName"] as? String
        )
    }
}
