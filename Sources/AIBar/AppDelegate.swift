import AppKit
import Combine
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private let store = UsageStore()
    private let accountsStore = ClaudeAccountsStore()
    private let popover = NSPopover()
    private var statusItem: NSStatusItem?
    private var statusView: MenuBarStatusItemView?
    private var cancellables = Set<AnyCancellable>()
    private var popoverMonitors: [Any] = []
    private var appBeforePopover: NSRunningApplication?

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupStatusItem()
        setupPopover()
        bindStore()
        observeSystemWake()
        updateStatusItem()

        Task {
            await store.refresh()
        }
    }

    // The periodic timer does not fire while the Mac is asleep, so refresh immediately on
    // wake instead of waiting up to a full interval for stale data to update.
    private func observeSystemWake() {
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { await self?.store.refresh() }
        }
    }

    func popoverDidShow(_ notification: Notification) {
        startPopoverMonitors()
    }

    func popoverDidClose(_ notification: Notification) {
        statusView?.isHighlighted = false
        stopPopoverMonitors()

        // Opening the popover activated AIBar; once it closes by Esc or the icon, hand
        // focus back to the app the user was in. Keep the app while the accounts window
        // is up, so coming back from it still returns there.
        guard !AccountsWindowController.shared.isVisible else { return }
        if NSApp.isActive {
            appBeforePopover?.activate(options: [])
        }
        appBeforePopover = nil
    }

    // Esc closes the popover. Clicks that go to other apps close it too: a transient
    // popover only notices those while AIBar is active, and the system may decline the
    // activation when it opens.
    private func startPopoverMonitors() {
        guard popoverMonitors.isEmpty else { return }

        if let escape = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { [weak self] event in
            guard event.keyCode == 53, let self, self.popover.isShown else { return event }
            self.popover.performClose(nil)
            return nil
        }) {
            popoverMonitors.append(escape)
        }

        if let outsideClick = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown],
            handler: { [weak self] _ in
                guard let self else { return }
                // A global monitor shouldn't see clicks on AIBar's own windows; check
                // anyway, so a click on the popover or the icon never counts as outside.
                let location = NSEvent.mouseLocation
                let ownFrames = [self.popover.contentViewController?.view.window?.frame, self.statusView?.window?.frame]
                guard !ownFrames.contains(where: { $0?.contains(location) == true }) else { return }
                self.popover.performClose(nil)
            }
        ) {
            popoverMonitors.append(outsideClick)
        }
    }

    private func stopPopoverMonitors() {
        popoverMonitors.forEach(NSEvent.removeMonitor)
        popoverMonitors.removeAll()
    }

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let thickness = NSStatusBar.system.thickness
        let view = MenuBarStatusItemView(frame: NSRect(x: 0, y: 0, width: 84, height: thickness))
        view.translatesAutoresizingMaskIntoConstraints = false
        view.target = self
        view.action = #selector(togglePopover(_:))

        item.length = view.preferredWidth

        if let button = item.button {
            button.title = ""
            button.image = nil
            button.addSubview(view)

            NSLayoutConstraint.activate([
                view.leadingAnchor.constraint(equalTo: button.leadingAnchor),
                view.trailingAnchor.constraint(equalTo: button.trailingAnchor),
                view.topAnchor.constraint(equalTo: button.topAnchor),
                view.bottomAnchor.constraint(equalTo: button.bottomAnchor)
            ])
        }

        statusItem = item
        statusView = view
    }

    private func setupPopover() {
        popover.behavior = .transient
        popover.delegate = self
        popover.contentSize = store.popoverSize
        popover.contentViewController = NSHostingController(
            rootView: UsagePopover(store: store, onManageAccounts: { [weak self] in
                self?.showAccountsWindow()
            })
            .frame(width: store.popoverSize.width)
        )
    }

    private func showAccountsWindow() {
        AccountsWindowController.shared.show(store: accountsStore) { [weak self] in
            self?.accountsStore.load()
            Task { await self?.store.refresh() }
        }
    }

    private func bindStore() {
        store.objectWillChange
            .sink { [weak self] _ in
                DispatchQueue.main.async {
                    self?.updateStatusItem()
                }
            }
            .store(in: &cancellables)
    }

    private func updateStatusItem() {
        guard let statusItem, let statusView else { return }
        statusView.lines = store.menuBarLines
        statusView.toolTip = store.menuBarTitle
        statusItem.length = statusView.preferredWidth
        updatePopoverSize()
    }

    private func updatePopoverSize() {
        popover.contentSize = store.popoverSize
    }

    @objc private func togglePopover(_ sender: Any?) {
        if popover.isShown {
            popover.performClose(sender)
            statusView?.isHighlighted = false
            return
        }

        guard let statusView else { return }
        statusView.isHighlighted = true
        updatePopoverSize()

        // Key presses only reach an active app, and clicking the menu bar icon doesn't
        // activate an accessory app — so activate it, or Esc would go to the app behind.
        if let front = NSWorkspace.shared.frontmostApplication, front != .current {
            appBeforePopover = front
        }
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: statusView.bounds, of: statusView, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()

        Task {
            await store.refresh()
        }
    }
}
