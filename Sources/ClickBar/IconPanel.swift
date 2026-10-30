import AppKit
import ClickBarCore

private final class IconPanelWindow: NSPanel {
    var onEscape: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override func cancelOperation(_ sender: Any?) { onEscape?() }
}

@MainActor
final class IconPanel: NSObject {
    private let model: AppModel
    private let window: IconPanelWindow
    private let menus = StatusMenus()
    private let nativeMenuSession: NativeMenuSession
    private var entries: [AppRow] = []
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var anchor = NSPoint.zero
    private var openingMenu = false
    private var renderedKey = ""
    private var noticeLabel: NSTextField?
    var onSettings: (() -> Void)?
    var isVisible: Bool { window.isVisible }

    init(model: AppModel) {
        self.model = model
        nativeMenuSession = NativeMenuSession(model: model)
        window = IconPanelWindow(contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        super.init()
        window.title = "ClickBar — Hidden icons"
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.level = .statusBar
        window.hidesOnDeactivate = false
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.onEscape = { [weak self] in self?.dismiss() }
        menus.onRevealNeeded = { [weak self] appID in
            self?.nativeMenuSession.begin(appID: appID) ?? false
        }
        menus.onFinish = { [weak self] in
            self?.nativeMenuSession.finishOpening()
            self?.openingMenu = false
            self?.dismiss()
        }
        menus.onNotice = { [weak self] message in
            guard let self else { return }
            self.openingMenu = false
            self.nativeMenuSession.stop()
            self.noticeLabel?.stringValue = message
            self.noticeLabel?.textColor = .secondaryLabelColor
        }
    }
    func setAnchor(_ point: NSPoint) { anchor = point }
    func sync() {
        guard model.enabled, model.issue == nil, model.state != .collapsed else { hide(); return }
        guard !openingMenu else { return }
        entries = model.panelApps
        let key = "\(model.state.rawValue)-\(model.accessibilityGranted)-" + entries.map(\.id).joined(separator: "|")
        if !window.isVisible || renderedKey != key {
            renderedKey = key
            rebuild()
        }
        position()
        window.orderFrontRegardless()
        monitorOutsideClicks()
    }
    func dismiss() {
        hide()
        if model.state != .collapsed { model.reveal(.collapsed) }
    }
    private func hide() {
        menus.cancel()
        if openingMenu { nativeMenuSession.stop() }
        openingMenu = false
        window.orderOut(nil)
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor); self.globalMonitor = nil }
        if let localMonitor { NSEvent.removeMonitor(localMonitor); self.localMonitor = nil }
    }
    private func rebuild() {
        let columns = min(max(entries.count, 1), 12)
        let rows = max(1, (entries.count + columns - 1) / columns)
        let width = max(360, CGFloat(columns) * 44 + 24)
        let footer: CGFloat = model.accessibilityGranted ? 36 : 58
        let height = 38 + CGFloat(rows) * 44 + footer
        let bg = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        bg.material = .popover
        bg.state = .active
        bg.blendingMode = .behindWindow
        bg.wantsLayer = true
        bg.layer?.cornerRadius = 12
        bg.layer?.borderWidth = 0.5
        bg.layer?.borderColor = NSColor.separatorColor.cgColor
        let heading = NSTextField(labelWithString: model.state == .all ? "All hidden groups" : "Single-click group")
        heading.font = .systemFont(ofSize: 12, weight: .semibold)
        heading.frame = NSRect(x: 14, y: height - 28, width: width - 95, height: 18)
        bg.addSubview(heading)
        let settings = NSButton(image: NSImage(systemSymbolName: "gearshape", accessibilityDescription: "Settings") ?? NSImage(), target: self, action: #selector(settingsPressed))
        settings.isBordered = false
        settings.frame = NSRect(x: width - 64, y: height - 32, width: 25, height: 25)
        settings.toolTip = "Settings"
        bg.addSubview(settings)
        let close = NSButton(image: NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close icon panel") ?? NSImage(), target: self, action: #selector(closePressed))
        close.isBordered = false
        close.frame = NSRect(x: width - 36, y: height - 32, width: 25, height: 25)
        bg.addSubview(close)
        for (index, app) in entries.enumerated() {
            let image = app.icon?.copy() as? NSImage ?? NSImage(systemSymbolName: "app", accessibilityDescription: app.name) ?? NSImage()
            image.size = NSSize(width: 26, height: 26)
            let button = NSButton(image: image, target: self, action: #selector(iconPressed))
            button.tag = index
            button.isBordered = false
            button.imageScaling = .scaleProportionallyDown
            button.frame = NSRect(x: 12 + CGFloat(index % columns) * 44,
                y: footer + CGFloat(rows - 1 - index / columns) * 44, width: 42, height: 42)
            button.toolTip = app.name
            button.setAccessibilityLabel("Open \(app.name) menu")
            bg.addSubview(button)
        }
        if entries.isEmpty {
            let empty = NSTextField(labelWithString: "No running apps assigned to this group.")
            empty.textColor = .secondaryLabelColor
            empty.font = .systemFont(ofSize: 12)
            empty.frame = NSRect(x: 14, y: footer + 12, width: width - 28, height: 20)
            bg.addSubview(empty)
        }
        let notice = NSTextField(wrappingLabelWithString: model.accessibilityGranted
            ? "Click an app icon to open its menu."
            : "Allow Accessibility to open menus here.\nIcons use each app’s image.")
        notice.font = .systemFont(ofSize: 10)
        notice.textColor = .secondaryLabelColor
        notice.frame = NSRect(x: 14, y: 9, width: width - (model.accessibilityGranted ? 28 : 128), height: footer - 12)
        bg.addSubview(notice)
        noticeLabel = notice
        if !model.accessibilityGranted {
            let grant = NSButton(title: "Allow Access…", target: self, action: #selector(grantPressed))
            grant.bezelStyle = .rounded
            grant.frame = NSRect(x: width - 114, y: 15, width: 100, height: 26)
            bg.addSubview(grant)
        }
        window.contentView = bg
        window.setContentSize(NSSize(width: width, height: height))
    }
    private func position() {
        let screen = NSScreen.screens.first { NSMouseInRect(anchor, $0.frame, false) } ?? NSScreen.main
        guard let screen else { return }
        let width = window.frame.width, height = window.frame.height
        let desiredX = anchor == .zero ? screen.visibleFrame.maxX - width - 16 : anchor.x - width / 2
        let x = min(max(desiredX, screen.visibleFrame.minX + 6), screen.visibleFrame.maxX - width - 6)
        window.setFrameOrigin(NSPoint(x: x, y: screen.visibleFrame.maxY - height - 6))
    }
    private func monitorOutsideClicks() {
        guard globalMonitor == nil else { return }
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown]) { [weak self] event in
            guard let self, !self.openingMenu else { return }
            if event.type == .keyDown {
                if event.keyCode == 53 { self.dismiss() }
                return
            }
            // MenuBarAgent owns the control's click. Keep state until ClickBar
            // receives that action, so single and double click can toggle it.
            let point = NSEvent.mouseLocation
            if let screen = NSScreen.screens.first(where: { NSMouseInRect(point, $0.frame, false) }),
               point.y >= screen.visibleFrame.maxY { return }
            self.dismiss()
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown]) { [weak self] event in
            guard let self, !self.openingMenu else { return event }
            if event.type == .keyDown && event.keyCode == 53 { self.dismiss(); return nil }
            if event.type != .keyDown && event.window !== self.window { self.dismiss() }
            return event
        }
    }
    @objc private func iconPressed(_ sender: NSButton) {
        guard entries.indices.contains(sender.tag) else { return }
        model.checkAccessibility()
        guard model.accessibilityGranted else {
            noticeLabel?.stringValue = "Use Allow Access to enable menu clicks."
            return
        }
        openingMenu = true
        noticeLabel?.stringValue = "Opening menu…"
        let appID = entries[sender.tag].id
        menus.show(appID: appID, below: sender)
    }
    @objc private func settingsPressed() { dismiss(); onSettings?() }
    @objc private func closePressed() { dismiss() }
    @objc private func grantPressed() { dismiss(); model.requestAccessibility() }
}
