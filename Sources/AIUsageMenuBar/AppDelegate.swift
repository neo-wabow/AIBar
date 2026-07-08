import AppKit
import Combine
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private let store = UsageStore()
    private let popover = NSPopover()
    private var statusItem: NSStatusItem?
    private var statusView: MenuBarStatusItemView?
    private var cancellables = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupStatusItem()
        setupPopover()
        bindStore()
        updateStatusItem()

        Task {
            await store.refresh()
        }
    }

    func popoverDidClose(_ notification: Notification) {
        statusView?.isHighlighted = false
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
        popover.contentSize = NSSize(width: 380, height: 214)
        popover.contentViewController = NSHostingController(
            rootView: UsagePopover(store: store)
                .frame(width: 380, height: 214)
        )
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
    }

    @objc private func togglePopover(_ sender: Any?) {
        if popover.isShown {
            popover.performClose(sender)
            statusView?.isHighlighted = false
            return
        }

        guard let statusView else { return }
        statusView.isHighlighted = true
        popover.show(relativeTo: statusView.bounds, of: statusView, preferredEdge: .minY)

        Task {
            await store.refresh()
        }
    }
}
