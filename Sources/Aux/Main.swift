import AppKit
import SwiftUI
import Combine
import AuxCore

@main
struct AuxEntry {
    @MainActor static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
        withExtendedLifetime(delegate) {}
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    let model: AppModel
    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private var settingsWindow: NSWindow?
    private var previewWindow: NSWindow?
    private var subscription: AnyCancellable?
    private var terminating = false

    override init() {
        let args = ProcessInfo.processInfo.arguments
        model = AppModel(preview: args.contains("--preview"))
        super.init()
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        let args = ProcessInfo.processInfo.arguments
        if !model.isPreview {
            let others = NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "com.zayd.aux").filter { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
            if !others.isEmpty { others.first?.activate(); NSApp.terminate(nil); return }
        }
        installMenu()
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.target = self
        statusItem.button?.action = #selector(togglePanel)
        statusItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        popover = NSPopover()
        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self
        let root = PanelView(model: model, openSettings: { [weak self] in self?.showSettings() }, quit: { NSApp.terminate(nil) })
        let host = NSHostingController(rootView: root)
        host.sizingOptions = [.preferredContentSize]
        popover.contentViewController = host
        popover.contentSize = NSSize(width: 368, height: 580)
        updateStatusItem()
        subscription = model.objectWillChange.sink { [weak self] _ in DispatchQueue.main.async { self?.updateStatusItem() } }
        NSApp.appearance = nil
        model.start()
        if model.isPreview || args.contains("--window") {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 368, height: 580), styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.title = model.isPreview ? "Aux · Design preview" : "Aux"
            window.contentViewController = NSHostingController(rootView: root)
            window.isReleasedWhenClosed = false
            window.center(); window.makeKeyAndOrderFront(nil)
            previewWindow = window
            NSApp.activate(ignoringOtherApps: true)
            model.panelVisible = true
        } else if !model.settings.didLaunchBefore || args.contains("--show") {
            DispatchQueue.main.async { self.showPanel() }
        }
        model.settings.markLaunched()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showPanel(); return false
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if terminating { return .terminateNow }
        terminating = true
        Task { await model.shutdown(); NSApp.reply(toApplicationShouldTerminate: true) }
        return .terminateLater
    }
    private func installMenu() {
        let main = NSMenu()
        let item = NSMenuItem(); let menu = NSMenu(title: "Aux")
        menu.addItem(withTitle: "Settings…", action: #selector(showSettings), keyEquivalent: ",").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Aux", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item.submenu = menu; main.addItem(item); NSApp.mainMenu = main
    }
    @objc private func togglePanel() {
        if NSApp.currentEvent?.type == .rightMouseUp {
            let menu = NSMenu()
            menu.addItem(withTitle: model.settings.sharingEnabled ? "Turn sharing off" : "Turn sharing on", action: #selector(toggleSharing), keyEquivalent: "").target = self
            menu.addItem(withTitle: "Settings…", action: #selector(showSettings), keyEquivalent: ",").target = self
            menu.addItem(.separator())
            menu.addItem(withTitle: "Quit Aux", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
            statusItem.menu = menu
            statusItem.button?.performClick(nil)
            statusItem.menu = nil
        } else if popover.isShown { popover.performClose(nil) } else { showPanel() }
    }
    private func showPanel() {
        guard let button = statusItem?.button else { return }
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
        NSApp.activate(ignoringOtherApps: true)
        model.panelVisible = true
        model.requestRefresh()
    }
    func popoverDidClose(_ notification: Notification) { model.panelVisible = false }
    @objc private func toggleSharing() { model.settings.sharingEnabled.toggle() }
    private func updateStatusItem() {
        guard let button = statusItem?.button else { return }
        let symbol: String
        if !model.settings.sharingEnabled { symbol = "waveform.slash" }
        else if model.permissionDenied { symbol = "exclamationmark.circle" }
        else if model.isSharing { symbol = "waveform.circle.fill" }
        else { symbol = "waveform" }
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Aux: \(model.statusTitle)")
        image?.isTemplate = true
        button.image = image
        button.toolTip = "Aux · \(model.statusTitle)" + (model.snapshot.track.map { "\n\($0.title) — \($0.artist)" } ?? "")
        button.setAccessibilityLabel("Aux")
        button.setAccessibilityValue(model.statusTitle)
    }
    @objc func showSettings() {
        popover?.performClose(nil)
        if settingsWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 540, height: 680), styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
            window.title = "Aux Settings"
            window.titlebarAppearsTransparent = true
            window.contentViewController = NSHostingController(rootView: SettingsView(model: model))
            window.isReleasedWhenClosed = false
            window.center()
            settingsWindow = window
        }
        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
