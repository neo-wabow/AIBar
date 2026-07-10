import AppKit
import SwiftUI

/// Hosts the accounts settings pane in a small standalone window, opened from the
/// popover. A menu-bar (accessory) app has no normal window, so this activates the
/// app and brings the window forward explicitly.
@MainActor
final class AccountsWindowController {
    static let shared = AccountsWindowController()

    private var window: NSWindow?

    func show(store: ClaudeAccountsStore, onChange: @escaping () -> Void) {
        if let window {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }

        let hosting = NSHostingController(
            rootView: AccountsSettingsView(store: store, onChange: onChange)
        )
        let window = NSWindow(contentViewController: hosting)
        window.title = "AIBar 帳號設定"
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.setContentSize(NSSize(width: 420, height: 460))
        window.center()
        self.window = window

        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }
}
