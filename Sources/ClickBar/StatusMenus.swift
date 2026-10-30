import AppKit
import ApplicationServices
import CoreGraphics

// The AXExtrasMenuBar / mirrored-menu approach follows SmartHiddenBar by Roy
// Padina (MIT). See Resources/SmartHiddenBar-LICENSE.txt. All AX IPC stays off
// the main thread; a slow menu-owning app must not freeze ClickBar's controls.

private struct AXItem: @unchecked Sendable {
    let element: AXUIElement
    let label: String
}
private struct MenuNode: Sendable {
    let title: String
    let enabled: Bool
    let checked: Bool
    let path: [Int]
    let children: [MenuNode]
}
private struct MenuPick: @unchecked Sendable {
    let item: AXItem
    let path: [Int]
    let title: String
}
private enum MenuResult: @unchecked Sendable {
    case needsVisibility
    case choices([AXItem])
    case menu(AXItem, [MenuNode])
    case activated
    case unavailable(String)
}

private enum AXMenus {
    static func value(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var result: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &result) == .success else { return nil }
        return result
    }
    static func children(_ element: AXUIElement) -> [AXUIElement] {
        value(element, kAXChildrenAttribute) as? [AXUIElement] ?? []
    }
    static func text(_ element: AXUIElement, _ attribute: String) -> String {
        value(element, attribute) as? String ?? ""
    }
    static func menu(_ element: AXUIElement) -> AXUIElement? {
        children(element).first { text($0, kAXRoleAttribute) == kAXMenuRole }
    }
    static func items(pid: pid_t) -> [AXItem] {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.25)
        guard let raw = value(app, "AXExtrasMenuBar"), CFGetTypeID(raw) == AXUIElementGetTypeID() else { return [] }
        let bar = unsafeDowncast(raw, to: AXUIElement.self)
        return children(bar).enumerated().map { index, wrapper in
            var element = wrapper
            for _ in 0..<3 {
                var actions: CFArray?
                AXUIElementCopyActionNames(element, &actions)
                if !(actions as? [String] ?? []).isEmpty { break }
                guard let first = children(element).first else { break }
                element = first
            }
            AXUIElementSetMessagingTimeout(element, 0.15)
            let label = [kAXTitleAttribute, kAXDescriptionAttribute, kAXHelpAttribute]
                .map { text(element, $0).components(separatedBy: .newlines).first ?? "" }
                .first { !$0.isEmpty } ?? "Menu bar item \(index + 1)"
            return AXItem(element: element, label: label)
        }
    }
    static func isOpen(_ menu: AXUIElement) -> Bool {
        guard let raw = value(menu, kAXSizeAttribute), CFGetTypeID(raw) == AXValueGetTypeID() else { return false }
        let sizeValue = unsafeDowncast(raw, to: AXValue.self)
        var size = CGSize.zero
        return AXValueGetValue(sizeValue, .cgSize, &size) && size.width > 0 && size.height > 0
    }
    static func press(_ element: AXUIElement) -> AXError {
        AXUIElementPerformAction(element, kAXPressAction as CFString)
    }
    static func open(_ item: AXItem) -> AXUIElement? {
        AXUIElementSetMessagingTimeout(item.element, 0.05)
        _ = press(item.element)
        AXUIElementSetMessagingTimeout(item.element, 0.15)
        for _ in 0..<35 {
            if let root = menu(item.element), isOpen(root) { return root }
            Thread.sleep(forTimeInterval: 0.01)
        }
        return nil
    }
    static func close(_ root: AXUIElement, item: AXItem) {
        guard isOpen(root) else { return }
        AXUIElementPerformAction(root, kAXCancelAction as CFString)
        guard isOpen(root) else { return }
        // Some native menus advertise AXCancel but ignore it. Send Escape only
        // to the owning app, and only while its same menu is still open.
        var pid: pid_t = 0
        guard AXUIElementGetPid(item.element, &pid) == .success, pid > 0 else { return }
        for down in [true, false] {
            CGEvent(keyboardEventSource: nil, virtualKey: 53, keyDown: down)?.postToPid(pid)
        }
        for _ in 0..<15 {
            if !isOpen(root) { break }
            Thread.sleep(forTimeInterval: 0.01)
        }
    }
    static func snapshot(_ root: AXUIElement, path: [Int] = [], depth: Int = 0) -> [MenuNode] {
        guard depth < 8 else { return [] }
        return children(root).prefix(150).enumerated().map { index, entry in
            let next = path + [index]
            let sub = menu(entry)
            return MenuNode(title: text(entry, kAXTitleAttribute),
                enabled: value(entry, kAXEnabledAttribute) as? Bool ?? true,
                checked: !text(entry, "AXMenuItemMarkChar").isEmpty, path: next,
                children: sub.map { snapshot($0, path: next, depth: depth + 1) } ?? [])
        }
    }
    static func visibleWindows(pid: pid_t) -> Set<CGWindowID> {
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
        return Set(windows.compactMap { info in
            guard info[kCGWindowOwnerPID as String] as? pid_t == pid,
                  let bounds = info[kCGWindowBounds as String] as? [String: Any],
                  let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary),
                  rect.width > 100, rect.height > 60 else { return nil }
            return info[kCGWindowNumber as String] as? CGWindowID
        })
    }
    static func load(_ item: AXItem, pid: pid_t, revealed: Bool) -> MenuResult {
        if let root = menu(item.element), !isOpen(root), !children(root).isEmpty {
            return .menu(item, snapshot(root))
        }
        // Custom panels need a real anchor. Reveal before the first press,
        // rather than guessing whether a press on a hidden item worked and
        // accidentally toggling an already-open panel closed with a retry.
        guard revealed else { return .needsVisibility }
        let before = visibleWindows(pid: pid)
        guard let root = open(item) else {
            if !visibleWindows(pid: pid).subtracting(before).isEmpty { return .activated }
            return .unavailable("The app did not expose an accessible menu or panel. Try its menu bar icon directly.")
        }
        let nodes = snapshot(root)
        close(root, item: item)
        return .menu(item, nodes)
    }
    static func load(pid: pid_t, selectedIndex: Int?, revealed: Bool) -> MenuResult {
        let found = items(pid: pid)
        guard let first = found.first else {
            return revealed ? .unavailable("Could not access this app’s menu bar item, even while visible.") : .needsVisibility
        }
        if let selectedIndex {
            guard found.indices.contains(selectedIndex) else { return .unavailable("The menu bar items changed. Open this app’s menu again.") }
            return load(found[selectedIndex], pid: pid, revealed: revealed)
        }
        if found.count > 1 { return .choices(found) }
        return load(first, pid: pid, revealed: revealed)
    }
    static func execute(_ pick: MenuPick) -> Bool {
        guard let root = open(pick.item) else { return false }
        defer { close(root, item: pick.item) }
        var current = root
        for index in pick.path.dropLast() {
            let entries = children(current)
            guard entries.indices.contains(index), let sub = menu(entries[index]) else { return false }
            current = sub
        }
        let entries = children(current)
        guard let last = pick.path.last, entries.indices.contains(last),
              text(entries[last], kAXTitleAttribute) == pick.title,
              value(entries[last], kAXEnabledAttribute) as? Bool != false else { return false }
        return press(entries[last]) == .success
    }
}

@MainActor
final class StatusMenus: NSObject {
    var onFinish: (() -> Void)?
    var onNotice: ((String) -> Void)?
    var onRevealNeeded: ((String) -> Bool)?
    private var generation = 0
    private var anchorView: NSView?
    private var openMenu: NSMenu?
    private var appID: String?
    private var pid: pid_t = 0
    private var revealed = false
    private var selectedIndex: Int?
    private var choiceSelected = false

    func cancel() {
        generation += 1
        openMenu?.cancelTracking()
        openMenu = nil
        anchorView = nil
        appID = nil
    }
    func show(appID: String, below view: NSView) {
        guard AXIsProcessTrusted() else {
            onNotice?("Allow Accessibility in Settings to open menu bar menus here.")
            return
        }
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: appID).first else {
            onNotice?("This app is no longer running."); return
        }
        generation += 1
        let request = generation
        anchorView = view
        let pid = app.processIdentifier
        self.appID = appID
        self.pid = pid
        revealed = false
        selectedIndex = nil
        if appID == "pro.betterdisplay.BetterDisplay", let bundle = app.bundleURL,
           let window = view.window, let screen = window.screen ?? NSScreen.main {
            let anchor = window.convertToScreen(view.convert(view.bounds, to: nil))
            let visibleScreen = screen.visibleFrame
            let primaryTop = NSScreen.screens.first?.frame.maxY ?? screen.frame.maxY
            let executable = bundle.appendingPathComponent("Contents/MacOS/BetterDisplay")
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                let error = BetterDisplayMenu.open(executable: executable, pid: pid, anchor: anchor,
                                                  visibleScreen: visibleScreen, primaryTop: primaryTop)
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.generation == request else { return }
                    if let error { self.onNotice?(error) }
                    else { self.onFinish?() }
                }
            }
            return
        }
        load(request: request)
    }
    private func load(request: Int) {
        guard generation == request, let appID else { return }
        guard NSRunningApplication.runningApplications(withBundleIdentifier: appID).contains(where: { $0.processIdentifier == pid }) else {
            onNotice?("This app is no longer running.")
            return
        }
        let pid = pid, selectedIndex = selectedIndex, revealed = revealed
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = AXMenus.load(pid: pid, selectedIndex: selectedIndex, revealed: revealed)
            DispatchQueue.main.async { [weak self] in
                guard let self, self.generation == request else { return }
                self.present(result, request: request)
            }
        }
    }
    private func present(_ result: MenuResult, request: Int) {
        guard let anchorView, anchorView.window?.isVisible == true else { onFinish?(); return }
        switch result {
        case .needsVisibility:
            guard !revealed, let appID, onRevealNeeded?(appID) == true else {
                onNotice?("Could not make this app’s menu bar item available.")
                return
            }
            revealed = true
            // Read new AX elements after the visibility change; the old
            // wrappers may have been removed by the menu bar owner.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                guard let self, self.generation == request, self.anchorView?.window?.isVisible == true else { return }
                self.load(request: request)
            }
        case .activated:
            onFinish?()
        case .unavailable(let message):
            onNotice?(message)
        case .choices(let choices):
            let menu = NSMenu()
            choiceSelected = false
            for (index, choice) in choices.enumerated() {
                let entry = NSMenuItem(title: choice.label, action: #selector(chooseItem), keyEquivalent: "")
                entry.target = self
                entry.tag = index
                menu.addItem(entry)
            }
            pop(menu, at: anchorView)
            if !choiceSelected { onFinish?() }
        case .menu(let item, let nodes):
            guard !nodes.isEmpty else { onNotice?("This menu is empty."); return }
            pop(makeMenu(nodes, item: item), at: anchorView)
            onFinish?()
        }
    }
    private func pop(_ menu: NSMenu, at view: NSView) {
        openMenu = menu
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: -4), in: view)
        openMenu = nil
    }
    private func makeMenu(_ nodes: [MenuNode], item: AXItem) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        for node in nodes {
            if node.title.isEmpty && node.children.isEmpty { menu.addItem(.separator()); continue }
            let label = node.title.isEmpty && !node.children.isEmpty ? "More" : node.title
            let entry = NSMenuItem(title: label, action: #selector(pick), keyEquivalent: "")
            entry.target = self
            entry.isEnabled = node.enabled
            entry.state = node.checked ? .on : .off
            entry.representedObject = MenuPick(item: item, path: node.path, title: node.title)
            if !node.children.isEmpty { entry.submenu = makeMenu(node.children, item: item) }
            menu.addItem(entry)
        }
        return menu
    }
    @objc private func chooseItem(_ sender: NSMenuItem) {
        choiceSelected = true
        selectedIndex = sender.tag
        load(request: generation)
    }
    @objc private func pick(_ sender: NSMenuItem) {
        guard let pick = sender.representedObject as? MenuPick else { return }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let success = AXMenus.execute(pick)
            if !success {
                DispatchQueue.main.async { [weak self] in
                    self?.onNotice?("The menu changed or the app did not respond. Open it again to retry.")
                }
            }
        }
    }
}
