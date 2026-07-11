import AppKit
import SwiftUI

extension Notification.Name {
    /// Posted when the accounts window regains focus, so the pane rescans and
    /// picks up an account the user just logged into via the Terminal flow.
    static let aibarAccountsRescan = Notification.Name("aibarAccountsRescan")
}

/// Hosts the accounts settings pane in a small standalone window, opened from the
/// popover. A menu-bar (accessory) app has no normal window, so this activates the
/// app and brings the window forward explicitly.
@MainActor
final class AccountsWindowController: NSObject, NSWindowDelegate {
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
        window.setContentSize(NSSize(width: 460, height: 520))
        window.center()
        window.delegate = self
        self.window = window

        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func windowDidBecomeKey(_ notification: Notification) {
        NotificationCenter.default.post(name: .aibarAccountsRescan, object: nil)
    }
}
