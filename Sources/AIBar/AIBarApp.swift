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
    }

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}
