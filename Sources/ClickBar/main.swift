import AppKit
import SwiftUI
import ClickBarCore
import ApplicationServices
import OSLog

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var model: AppModel!
    private var item: NSStatusItem!
    private var settings: NSWindow?
    private var iconPanel: IconPanel!
    private var clickTimer: Timer?
    private var recognizer = ClickRecognizer()
    private let interactionLog = Logger(subsystem: "local.chan.ClickBar", category: "Interaction")

    func applicationDidFinishLaunching(_ notification: Notification) {
        if CommandLine.arguments.contains("--diagnose") {
            let restriction = Restriction()
            print("backendAvailable=\(restriction.available)")
            print("accessibilityGranted=\(AXIsProcessTrusted())")
            print("bundleID=\(Bundle.main.bundleIdentifier ?? "none")")
            print("registeredPath=\(NSWorkspace.shared.urlForApplication(withBundleIdentifier: AppModel.ownID)?.path ?? "none")")
            NSApp.terminate(nil)
            return
        }
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: AppModel.ownID)
            .filter { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
        if let other = others.first { other.activate(); NSApp.terminate(nil); return }
        NSApp.setActivationPolicy(.accessory)
        installMainMenu()
        UserDefaults.standard.register(defaults: ["NSStatusItem Preferred Position ClickBarControl": 0])
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.autosaveName = "ClickBarControl"
        item.button?.target = self
        item.button?.action = #selector(clicked)
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        model = AppModel()
        iconPanel = IconPanel(model: model)
        iconPanel.onSettings = { [weak self] in self?.showSettings() }
        model.onChange = { [weak self] in self?.render() }
        render()
        showSettings()
    }

    func applicationDidBecomeActive(_ notification: Notification) { model?.refresh() }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showSettings(); return true
    }
    func applicationWillTerminate(_ notification: Notification) {
        cancelClick()
        iconPanel?.dismiss()
        model?.shutdown()
    }
    @objc private func clicked() {
        let event = NSApp.currentEvent
        iconPanel.setAnchor(NSEvent.mouseLocation)
        let now = ProcessInfo.processInfo.systemUptime
        let freshEvent = event.map { abs(now - $0.timestamp) < 0.3 } ?? false
        if (freshEvent && event?.type == .rightMouseUp) || NSEvent.modifierFlags.contains(.control) {
            cancelClick(); showMenu(); return
        }
        if !model.enabled { cancelClick(); showSettings(); return }
        clickTimer?.invalidate()
        // All activations follow the same timing path, including MenuBarAgent
        // callbacks with stale/missing NSEvents and Accessibility Press actions.
        let incoming = freshEvent && (event?.type == .leftMouseUp || event?.type == .leftMouseDown)
            ? max(1, event?.clickCount ?? 1) : 1
        let pending = recognizer.deadline != nil
        interactionLog.info("control received eventCount=\(incoming) pending=\(pending) freshEvent=\(freshEvent)")
        let count = recognizer.receive(count: incoming, now: now, interval: NSEvent.doubleClickInterval)
        if let count {
            interactionLog.info("control resolved clicks=\(count)")
            model.click(count: count)
            return
        }
        guard recognizer.deadline != nil else { return }
        let timer = Timer(timeInterval: NSEvent.doubleClickInterval + 0.01, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if let count = self.recognizer.flush(now: ProcessInfo.processInfo.systemUptime) {
                    self.interactionLog.info("control resolved clicks=\(count)")
                    self.model.click(count: count)
                }
            }
        }
        clickTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }
    private func cancelClick() {
        clickTimer?.invalidate(); clickTimer = nil; recognizer.cancel()
    }
    private func installMainMenu() {
        let root = NSMenu()
        let appMenu = NSMenu(title: "ClickBar")
        add("Settings…", #selector(showSettings), to: appMenu)
        appMenu.items.last?.keyEquivalent = ","
        appMenu.addItem(.separator())
        add("Show first group", #selector(showSingle), to: appMenu)
        add("Show both groups", #selector(showAll), to: appMenu)
        add("Close icon panel", #selector(collapse), to: appMenu)
        appMenu.addItem(.separator())
        add("Quit ClickBar", #selector(quit), to: appMenu)
        appMenu.items.last?.keyEquivalent = "q"
        let appRoot = NSMenuItem()
        appRoot.submenu = appMenu
        root.addItem(appRoot)
        let editMenu = NSMenu(title: "Edit")
        for (title, action, key) in [
            ("Undo", "undo:", "z"), ("Cut", "cut:", "x"),
            ("Copy", "copy:", "c"), ("Paste", "paste:", "v"),
            ("Select All", "selectAll:", "a")
        ] {
            editMenu.addItem(withTitle: title, action: NSSelectorFromString(action), keyEquivalent: key)
        }
        let editRoot = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
        editRoot.submenu = editMenu
        root.addItem(editRoot)
        NSApp.mainMenu = root
    }
    private func render() {
        item.button?.image = NSImage(systemSymbolName: "ellipsis", accessibilityDescription: "ClickBar")
        item.button?.image?.isTemplate = true
        item.button?.toolTip = model.issue ?? "ClickBar · \(model.state.title)\nSingle click: first group · Double click: both groups · Right-click: settings"
        iconPanel.sync()
    }
    @objc private func showSettings() {
        iconPanel?.dismiss()
        if settings == nil {
            let controller = NSHostingController(rootView: SettingsView(model: model))
            let window = NSWindow(contentViewController: controller)
            window.title = "ClickBar — Settings"
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            window.setContentSize(NSSize(width: 850, height: 700))
            window.minSize = NSSize(width: 800, height: 640)
            window.isReleasedWhenClosed = false
            window.center()
            settings = window
        }
        model.refresh()
        settings?.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }
    private func showMenu() {
        let menu = NSMenu()
        add("Settings…", #selector(showSettings), to: menu)
        menu.addItem(.separator())
        add("Show first group", #selector(showSingle), to: menu)
        add("Show both groups", #selector(showAll), to: menu)
        add("Close icon panel", #selector(collapse), to: menu)
        add("Disable hiding and restore all icons", #selector(restoreAll), to: menu)
        menu.addItem(.separator())
        add("Quit ClickBar and restore icons", #selector(quit), to: menu)
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }
    private func add(_ title: String, _ action: Selector, to menu: NSMenu) {
        menu.addItem(withTitle: title, action: action, keyEquivalent: "").target = self
    }
    @objc private func showSingle() { model.reveal(.single) }
    @objc private func showAll() { model.reveal(.all) }
    @objc private func restoreAll() { model.restoreAll() }
    @objc private func collapse() { model.reveal(.collapsed) }
    @objc private func quit() { iconPanel.dismiss(); model.shutdown(); NSApp.terminate(nil) }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
