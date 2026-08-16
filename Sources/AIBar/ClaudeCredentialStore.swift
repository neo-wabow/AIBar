import Foundation

/// Reads a config dir's Claude login from wherever the CLI actually put it.
///
/// Claude Code used to keep every login in the Keychain. Newer versions write it to
/// `<config dir>/.credentials.json` instead and leave the Keychain item behind as an
/// empty husk — the entry still exists, but `accessToken` is `""`, `expiresAt` is `0`
/// and `refreshToken` is `""`. Reading only the Keychain therefore makes a perfectly
/// well logged-in account look absent: its card freezes on the last cached quota and
/// it disappears from the account picker, so the user cannot even add it back.
///
/// So: read both, take whichever actually carries a token, and remember which one it
/// was — a rotated token has to go back where the CLI will look for it.
enum ClaudeCredentialStore {
    enum Location: Equatable {
        case keychain(service: String, account: String)
        case file(URL)
    }

    struct Credential {
        var root: [String: Any]
        var oauth: [String: Any]
        var accessToken: String
        var location: Location
    }

    /// The credential file for a config dir; nil means the default `~/.claude`.
    static func fileURL(
        configDir: String?,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        let directory = configDir.map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? home.appendingPathComponent(".claude", isDirectory: true)
        return directory.appendingPathComponent(".credentials.json")
    }

    /// The login for a config dir, or nil when there is none to be had. Keychain first,
    /// since that is where an account the user logged in long ago still lives.
    static func read(
        configDir: String?,
        service: String? = nil,
        account: String? = nil
    ) -> Credential? {
        let locations: [Location] = [
            .keychain(
                service: service ?? ClaudeKeychain.serviceName(configDir: configDir),
                account: account ?? ClaudeKeychain.accountName()
            ),
            .file(fileURL(configDir: configDir))
        ]
        return locations.lazy.compactMap(read(at:)).first
    }

    static func read(at location: Location) -> Credential? {
        let data: Data?
        switch location {
        case let .keychain(service, account):
            data = ClaudeKeychain.read(service: service, account: account).map { Data($0.utf8) }
        case let .file(url):
            data = try? Data(contentsOf: url)
        }

        guard
            let data,
            let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
            let oauth = root["claudeAiOauth"] as? [String: Any],
            let accessToken = oauth["accessToken"] as? String,
            // An emptied-out husk is not a login, and treating it as one is what let a
            // logged-in account read as missing.
            !accessToken.isEmpty
        else {
            return nil
        }

        return Credential(root: root, oauth: oauth, accessToken: accessToken, location: location)
    }

    /// Writes rotated credentials back to the store they came from. Sending them
    /// anywhere else would leave the CLI holding a refresh token that we have already
    /// spent, which costs the user a re-login.
    static func write(_ root: [String: Any], to location: Location) -> Bool {
        guard let data = try? JSONSerialization.data(withJSONObject: root) else { return false }
        switch location {
        case let .keychain(service, account):
            return ClaudeKeychain.write(service: service, account: account, json: root)
        case let .file(url):
            do {
                try data.write(to: url, options: .atomic)
                // An atomic write lands a fresh inode, so re-apply the CLI's own 0600.
                try? FileManager.default.setAttributes(
                    [.posixPermissions: 0o600],
                    ofItemAtPath: url.path
                )
                return true
            } catch {
                return false
            }
        }
    }
}
