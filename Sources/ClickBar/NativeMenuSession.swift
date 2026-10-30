import AppKit
import CoreGraphics

/// Keeps a popover's real status item available until its native window closes.
/// The saved group is never changed.
@MainActor
final class NativeMenuSession {
    private weak var model: AppModel?
    private var timer: Timer?
    private var pid: pid_t = 0
    private var baseline: Set<CGWindowID> = []
    private var appeared = false
    private var opening = false
    private var lastVisible: TimeInterval = 0

    init(model: AppModel) { self.model = model }

    func begin(appID: String) -> Bool {
        stop()
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: appID).first else { return false }
        pid = app.processIdentifier
        baseline = windowIDs()
        appeared = false
        opening = true
        lastVisible = ProcessInfo.processInfo.systemUptime
        model?.setNativeMenuApp(appID)
        let timer = Timer(timeInterval: 0.2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
        return true
    }

    private func tick() {
        guard model?.enabled == true, let app = NSRunningApplication(processIdentifier: pid),
              !app.isTerminated else { stop(); return }
        let now = ProcessInfo.processInfo.systemUptime
        if !windowIDs().subtracting(baseline).isEmpty {
            appeared = true
            lastVisible = now
        } else if !opening && now - lastVisible >= (appeared ? 0.5 : 5.0) {
            stop()
        }
    }

    func finishOpening() {
        opening = false
        lastVisible = ProcessInfo.processInfo.systemUptime
    }

    private func windowIDs() -> Set<CGWindowID> {
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
        return Set(windows.compactMap { info in
            guard info[kCGWindowOwnerPID as String] as? pid_t == pid,
                  let bounds = info[kCGWindowBounds as String] as? [String: Any],
                  let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary),
                  rect.width > 100, rect.height > 60 else { return nil }
            return info[kCGWindowNumber as String] as? CGWindowID
        })
    }

    func stop() {
        guard timer != nil else { return }
        timer?.invalidate()
        timer = nil
        model?.setNativeMenuApp(nil)
    }
}
