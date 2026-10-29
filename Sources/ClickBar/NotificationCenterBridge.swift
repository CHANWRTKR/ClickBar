import AppKit
import CoreGraphics
import ApplicationServices
import OSLog

// macOS blocks Notification Center while the menu-bar restriction is active.
// Release it before the user's click. AXPress on the macOS 27 clock can send
// both an open and a close request, so this bridge must never replay clicks.
// Window visibility detection follows SmartHiddenBar (MIT); see its bundled license.
@MainActor
final class NotificationCenterBridge {
    private weak var model: AppModel?
    private var monitor: Any?
    private var timer: Timer?
    private var lastActivity: TimeInterval = 0
    private var clockFrames: [CGRect] = []
    private var lastProbe: TimeInterval = -.infinity
    private var probeInFlight = false
    private var stopped = false
    private let log = Logger(subsystem: "local.chan.ClickBar", category: "NotificationCenter")

    init(model: AppModel) {
        self.model = model
        monitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDown]) { [weak self] _ in
            self?.pointerChanged()
        }
        refreshClockFrames()
        pointerChanged()
    }

    private func nearClock() -> Bool {
        let point = NSEvent.mouseLocation
        return clockFrames.contains { $0.contains(point) }
    }

    private func pointerChanged() {
        guard let model, model.enabled else { return }
        let point = NSEvent.mouseLocation
        if NSScreen.screens.contains(where: {
            NSMouseInRect(point, $0.frame, false) && point.y >= $0.frame.maxY - NSStatusBar.system.thickness - 4
        }) { refreshClockFrames() }
        guard nearClock() else { return }
        lastActivity = ProcessInfo.processInfo.systemUptime
        guard model.hasActiveHiding, !model.notificationCenterSuspended else { return }
        model.setNotificationCenterSuspended(true)
        log.info("Pointer approached clock; hiding suspended without replaying a click")
        timer?.invalidate()
        let timer = Timer(timeInterval: 0.2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func refreshClockFrames() {
        let now = ProcessInfo.processInfo.systemUptime
        guard !stopped, !probeInFlight, now - lastProbe >= 2 else { return }
        lastProbe = now
        probeInFlight = true
        let primaryTop = NSScreen.screens.first?.frame.maxY ?? 0
        let points = NSScreen.screens.map {
            CGPoint(x: $0.frame.maxX - 24, y: primaryTop - $0.frame.maxY + NSStatusBar.system.thickness / 2)
        }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let frames = points.compactMap { Self.clockFrame(at: $0) }.map {
                CGRect(x: $0.minX, y: primaryTop - $0.maxY, width: $0.width, height: $0.height)
            }
            DispatchQueue.main.async { [weak self] in
                guard let self, !self.stopped else { return }
                self.probeInFlight = false
                if self.clockFrames != frames {
                    self.log.info("Updated clock hover bounds: \(frames.map { NSStringFromRect($0) }.joined(separator: ","), privacy: .public)")
                }
                self.clockFrames = frames
                self.pointerChanged()
            }
        }
    }

    nonisolated private static func clockFrame(at point: CGPoint) -> CGRect? {
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.2)
        var found: AXUIElement?
        guard AXUIElementCopyElementAtPosition(system, Float(point.x), Float(point.y), &found) == .success,
              let found else { return nil }
        var identifier: CFTypeRef?
        guard AXUIElementCopyAttributeValue(found, kAXIdentifierAttribute as CFString, &identifier) == .success,
              identifier as? String == "com.apple.menuextra.clock" else { return nil }
        var position: CFTypeRef?
        var size: CFTypeRef?
        guard AXUIElementCopyAttributeValue(found, kAXPositionAttribute as CFString, &position) == .success,
              AXUIElementCopyAttributeValue(found, kAXSizeAttribute as CFString, &size) == .success,
              let position, let size,
              CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
        var origin = CGPoint.zero
        var dimensions = CGSize.zero
        guard AXValueGetValue(unsafeDowncast(position, to: AXValue.self), .cgPoint, &origin),
              AXValueGetValue(unsafeDowncast(size, to: AXValue.self), .cgSize, &dimensions),
              dimensions.width > 0, dimensions.height > 0 else { return nil }
        return CGRect(origin: origin, size: dimensions)
    }

    private func tick() {
        guard let model else { stop(); return }
        guard model.enabled else { resumeHiding(); return }
        if nearClock() || notificationCenterVisible() {
            lastActivity = ProcessInfo.processInfo.systemUptime
            return
        }
        // Keep the opening/closing animation from causing a brief re-hide.
        guard ProcessInfo.processInfo.systemUptime - lastActivity >= 0.8 else { return }
        resumeHiding()
    }

    private func resumeHiding() {
        timer?.invalidate()
        timer = nil
        model?.setNotificationCenterSuspended(false)
        log.info("Pointer left clock and Notification Center is closed; restoring hiding")
    }

    private func notificationCenterVisible() -> Bool {
        let pids = Set(NSWorkspace.shared.runningApplications
            .filter { $0.bundleIdentifier == "com.apple.notificationcenterui" }
            .map(\.processIdentifier))
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
        return windows.contains { pids.contains($0[kCGWindowOwnerPID as String] as? pid_t ?? 0) }
    }

    func stop() {
        stopped = true
        timer?.invalidate()
        timer = nil
        if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
        model?.setNotificationCenterSuspended(false)
    }
}
