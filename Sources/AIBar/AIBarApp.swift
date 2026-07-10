import Foundation
import SwiftUI

@main
struct AIBarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    init() {
        if CommandLine.arguments.contains("--dump") {
            let snapshot = UsageCollector().collect()
            print(SnapshotText.render(snapshot))
            exit(snapshot.errors.isEmpty ? 0 : 1)
        }

        if CommandLine.arguments.contains("--discover-claude") {
            let accounts = ClaudeAccountDiscovery().discover()
            if accounts.isEmpty {
                print("No logged-in Claude accounts found")
            }
            for account in accounts {
                let dir = account.configDir ?? "(default ~/.claude)"
                let email = account.email ?? "?"
                let sub = account.subscriptionType ?? "?"
                print("• \(account.suggestedLabel)  dir=\(dir)  email=\(email)  sub=\(sub)  service=\(account.keychainService)")
            }
            exit(0)
        }
    }

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}
