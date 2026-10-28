import AppKit
import ApplicationServices
import OSLog

/// BetterDisplay's controls are a custom window, not an NSMenu. Use its own
/// documented appMenu command, then anchor that native window below our panel.
/// No display settings or integration preferences are changed.
enum BetterDisplayMenu {
    private static let log = Logger(subsystem: "local.chan.ClickBar", category: "BetterDisplay")

    static func open(executable: URL, pid: pid_t, anchor: CGRect, visibleScreen: CGRect,
                     primaryTop: CGFloat) -> String? {
        let process = Process()
        process.executableURL = executable
        process.arguments = ["set", "-appMenu=on"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        do { try process.run() }
        catch { return "Could not contact BetterDisplay: \(error.localizedDescription)" }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 3) {
            if process.isRunning { process.terminate() }
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let reply = String(data: data, encoding: .utf8) ?? ""
        guard process.terminationStatus == 0,
              !reply.localizedCaseInsensitiveContains("failed"),
              !reply.localizedCaseInsensitiveContains("disabled") else {
            log.error("appMenu command failed, exit=\(process.terminationStatus)")
            return "BetterDisplay did not accept the menu command. Enable CLI access in BetterDisplay → Settings → Application → Integration."
        }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.2)
        for _ in 0..<45 {
            let windows = attribute(app, kAXWindowsAttribute) as? [AXUIElement] ?? []
            for window in windows {
                guard let rect = frame(window), rect.width >= 140, rect.height >= 80 else { continue }
                let title = attribute(window, kAXTitleAttribute) as? String ?? ""
                guard !title.localizedCaseInsensitiveContains("settings"),
                      !title.localizedCaseInsensitiveContains("preferences") else { continue }
                var settable = DarwinBoolean(false)
                AXUIElementIsAttributeSettable(window, kAXPositionAttribute as CFString, &settable)
                if settable.boolValue {
                    let x = min(max(anchor.minX, visibleScreen.minX + 6), visibleScreen.maxX - rect.width - 6)
                    let top = max(visibleScreen.minY + min(rect.height, visibleScreen.height),
                                  min(anchor.minY - 6, visibleScreen.maxY - 6))
                    var point = CGPoint(x: x, y: primaryTop - top)
                    if let value = AXValueCreate(.cgPoint, &point) {
                        let result = AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, value)
                        log.info("native menu opened; position result=\(result.rawValue)")
                        if result == .success { return nil }
                    }
                }
                // Some versions position the native menu themselves and expose
                // no writable position. Accept it only when actually on screen.
                let cocoaRect = CGRect(x: rect.minX, y: primaryTop - rect.maxY,
                                       width: rect.width, height: rect.height)
                if cocoaRect.intersects(visibleScreen) {
                    log.info("native menu opened at BetterDisplay's own on-screen position")
                    return nil
                }
            }
            Thread.sleep(forTimeInterval: 0.025)
        }
        log.error("appMenu command returned, but no visible control window was found")
        return "BetterDisplay did not show its controls. Check CLI access in BetterDisplay’s Integration settings, then try again."
    }

    private static func attribute(_ element: AXUIElement, _ key: String) -> CFTypeRef? {
        var result: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, key as CFString, &result) == .success else { return nil }
        return result
    }
    private static func frame(_ window: AXUIElement) -> CGRect? {
        guard let position = attribute(window, kAXPositionAttribute), CFGetTypeID(position) == AXValueGetTypeID(),
              let size = attribute(window, kAXSizeAttribute), CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero, dimensions = CGSize.zero
        guard AXValueGetValue(unsafeDowncast(position, to: AXValue.self), .cgPoint, &point),
              AXValueGetValue(unsafeDowncast(size, to: AXValue.self), .cgSize, &dimensions) else { return nil }
        return CGRect(origin: point, size: dimensions)
    }
}
