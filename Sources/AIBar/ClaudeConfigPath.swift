import Foundation

/// Translates between the two forms a `CLAUDE_CONFIG_DIR` takes in AIBar.
///
/// `claude-accounts.json` stores paths **home-relative** (`~/.claude-account`) so the
/// file survives being carried to another Mac or user account — an absolute path baked
/// in on one machine silently points at nothing on the next. Absolute paths written by
/// older builds still load unchanged.
///
/// Everything downstream wants the **expanded** path: the Keychain service name is a
/// hash of the dir the CLI was actually launched with, and existence checks need a real
/// path. So resolve on read, abbreviate on write.
enum ClaudeConfigPath {
    /// Expands a stored path. nil/empty stays nil, meaning the default `~/.claude`.
    static func resolve(
        _ stored: String?,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> String? {
        guard let stored, !stored.isEmpty else { return nil }
        guard stored.hasPrefix("~") else { return stored }
        let rest = stored.dropFirst().drop { $0 == "/" }
        return rest.isEmpty ? home.path : home.appendingPathComponent(String(rest)).path
    }

    /// Abbreviates an absolute path to `~/…` when it sits under this user's home;
    /// paths elsewhere (another user's home, an external volume) are kept verbatim,
    /// since there is nothing portable to say about them.
    static func store(
        _ absolute: String?,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> String? {
        guard let absolute, !absolute.isEmpty else { return nil }
        guard !absolute.hasPrefix("~") else { return absolute }
        let homePath = (home.path as NSString).standardizingPath
        let path = (absolute as NSString).standardizingPath
        // Not under this home (another user, an external volume): keep it, but keep it
        // standardized so one dir spelled two ways still yields one account identity.
        guard path.hasPrefix(homePath + "/") else { return path }
        return "~/" + path.dropFirst(homePath.count + 1)
    }
}
