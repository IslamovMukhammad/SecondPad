import AppKit
import Combine
import SwiftUI

/// The menu-bar item. A click opens a small window (popover): add a task, run the Pomodoro and the
/// Quick timer. The task list itself is on the tablet.
final class MenuBarController: NSObject {

    private let model: AppModel
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let popover = NSPopover()
    private var settingsWindow: NSWindow?
    private let promptPanel: PromptPanel
    private var linkWatch: AnyCancellable?

    init(model: AppModel) {
        self.model = model
        promptPanel = PromptPanel { yes in model.pomodoro.answer(yes) }
        super.init()
        popover.behavior = .transient
        popover.animates = true
        popover.appearance = NSAppearance(named: .darkAqua)
        item.button?.toolTip = "SecondPad"
        item.button?.target = self
        item.button?.action = #selector(toggle)
        updateIcon(model.link.status)
        linkWatch = model.$linkStatus.sink { [weak self] status in self?.updateIcon(status) }
        model.onPromptUI = { [weak self] prompt in self?.promptPanel.show(prompt) }
    }

    private func updateIcon(_ status: TabletLink.Status) {
        if case .linked = status {
            item.button?.image = IconArt.menuBarImage(linked: true)
        } else {
            item.button?.image = IconArt.menuBarImage(linked: false)
        }
    }

    @objc private func toggle() {
        if popover.isShown { popover.performClose(nil); return }
        showPopover()
    }

    func showPopover() {
        guard let button = item.button else { return }
        let host = NSHostingController(rootView: PopoverView(
            model: model,
            openSettings: { [weak self] in self?.showSettings() },
            close: { [weak self] in self?.popover.performClose(nil) }))
        // The popover takes the view's real size (otherwise it opened shorter and cut the header off).
        host.sizingOptions = [.preferredContentSize]
        host.view.layoutSubtreeIfNeeded()
        popover.contentSize = host.view.fittingSize
        popover.contentViewController = host
        NSApp.activate()
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }

    // MARK: - Settings

    func showSettings() {
        if settingsWindow == nil {
            let window = NSWindow(contentViewController: NSHostingController(rootView: SettingsView(model: model, liveUsage: model.liveUsage)))
            window.title = "SecondPad Settings"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            settingsWindow = window
        }
        model.refreshHookState()
        NSApp.activate()
        settingsWindow?.center()
        settingsWindow?.makeKeyAndOrderFront(nil)
    }
}
