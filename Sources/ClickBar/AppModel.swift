import AppKit
import SwiftUI
import ClickBarCore
import ServiceManagement
@preconcurrency import ApplicationServices

struct AppRow: Identifiable {
    let id: String
    let name: String
    let icon: NSImage?
    let running: Bool
}

@MainActor
final class AppModel: ObservableObject {
    static let ownID = "local.chan.ClickBar"
    @Published var groups: [String: IconGroup] = [:]
    @Published var apps: [AppRow] = []
    @Published var state: RevealState = .collapsed
    @Published var enabled = false
    @Published var issue: String?
    @Published var search = ""
    @Published var accessibilityGranted = AXIsProcessTrusted()
    @Published var launchAtLogin = false
    @Published var loginItemNeedsApproval = false
    @Published var loginItemError: String?
    private(set) var notificationCenterSuspended = false
    var onChange: (() -> Void)?
    private let restriction = Restriction()
    private var observation: NSKeyValueObservation?
    private var wakeObserver: NSObjectProtocol?
    private var refreshWork: DispatchWorkItem?
    private var names: [String: String] = [:]
    private var runningIDs: Set<String> = []
    private let defaults: UserDefaults
    private var errorMessage: String?

    convenience init() { self.init(defaults: .standard) }
    init(defaults: UserDefaults) {
        self.defaults = defaults
        // A separate argument leaves room for a test domain without touching user preferences.
        if let data = defaults.data(forKey: "groups"),
           let saved = try? JSONDecoder().decode([String: IconGroup].self, from: data) {
            groups = saved
        }
        names = defaults.dictionary(forKey: "names") as? [String: String] ?? [:]
        enabled = defaults.bool(forKey: "enabled")
        restriction.onFailure = { [weak self] message in
            guard let self else { return }
            self.errorMessage = message
            self.issue = message
            self.state = .collapsed
            self.onChange?()
        }
        refresh()
        observation = NSWorkspace.shared.observe(\.runningApplications) { [weak self] _, _ in
            DispatchQueue.main.async { self?.scheduleRefresh() }
        }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.restriction.clear(); self?.scheduleRefresh() }
        }
    }

    var filteredApps: [AppRow] {
        apps.filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search)
            || $0.id.localizedCaseInsensitiveContains(search) }
    }
    var panelApps: [AppRow] {
        let members = VisibilityPolicy.panelMembers(running: runningIDs, groups: groups,
                                                    state: state, ownID: Self.ownID)
        return apps.filter { members.contains($0.id) }
    }
    var hasActiveHiding: Bool { enabled && issue == nil && restriction.isActive }
    func setNotificationCenterSuspended(_ suspended: Bool) {
        notificationCenterSuspended = suspended
        apply()
    }
    func checkAccessibility() { accessibilityGranted = AXIsProcessTrusted() }
    func refreshLoginItem() {
        let status = SMAppService.mainApp.status
        launchAtLogin = status == .enabled
        loginItemNeedsApproval = status == .requiresApproval
    }
    func setLaunchAtLogin(_ enabled: Bool) {
        loginItemError = nil
        do {
            if enabled {
                if SMAppService.mainApp.status != .enabled && SMAppService.mainApp.status != .requiresApproval {
                    try SMAppService.mainApp.register()
                }
            } else if SMAppService.mainApp.status == .enabled || SMAppService.mainApp.status == .requiresApproval {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            loginItemError = error.localizedDescription
        }
        refreshLoginItem()
    }
    func openLoginItemSettings() { SMAppService.openSystemSettingsLoginItems() }
    func requestAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        accessibilityGranted = AXIsProcessTrustedWithOptions(options)
        if !accessibilityGranted,
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }
    func group(for id: String) -> IconGroup { groups[id] ?? .always }
    func setGroup(_ group: IconGroup, for id: String) {
        guard id != Self.ownID else { return }
        groups[id] = group
        if let data = try? JSONEncoder().encode(groups) { defaults.set(data, forKey: "groups") }
        apply()
    }
    func setEnabled(_ value: Bool) {
        enabled = value
        defaults.set(value, forKey: "enabled")
        errorMessage = nil
        state = .collapsed
        apply()
    }
    func click(count: Int) {
        guard enabled else { return }
        errorMessage = nil
        state = state.clicked(count: count)
        apply()
    }
    func reveal(_ value: RevealState) {
        errorMessage = nil
        state = value
        apply()
    }
    func restoreAll() {
        setEnabled(false)
    }
    func shutdown() {
        refreshWork?.cancel()
        observation = nil
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
        restriction.clear()
    }
    func refresh() {
        checkAccessibility()
        refreshLoginItem()
        let running = NSWorkspace.shared.runningApplications
        // Include even background bundles in the allowlist; unconfigured items must
        // never disappear just because their owning app has no Dock icon.
        runningIDs = Set(running.compactMap(\.bundleIdentifier))
        var live: [String: NSRunningApplication] = [:]
        for app in running where app.activationPolicy != .prohibited {
            guard let id = app.bundleIdentifier, id != Self.ownID,
                  !id.hasPrefix("com.apple.") else { continue }
            live[id] = app
            names[id] = app.localizedName ?? id
        }
        let ids = Set(live.keys).union(groups.keys).subtracting([Self.ownID])
            .filter { !$0.hasPrefix("com.apple.") }
        apps = ids.map { id in
            let app = live[id]
            let url = app?.bundleURL ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: id)
            return AppRow(id: id, name: names[id] ?? app?.localizedName ?? id,
                          icon: app?.icon ?? url.map { NSWorkspace.shared.icon(forFile: $0.path) },
                          running: runningIDs.contains(id))
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        defaults.set(names, forKey: "names")
        apply()
    }
    private func scheduleRefresh() {
        refreshWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.refresh() }
        refreshWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: work)
    }
    private func apply() {
        let conflicts = NSWorkspace.shared.runningApplications.filter {
            ["Thaw", "Ice", "Bartender", "Stash", "Hidden Bar", "SmartHiddenBar"].contains($0.localizedName ?? "")
        }.compactMap(\.localizedName)
        if !enabled || notificationCenterSuspended {
            issue = nil
            restriction.clear()
        } else if !conflicts.isEmpty {
            issue = "Hiding paused: quit \(conflicts.joined(separator: ", ")) before using ClickBar"
            restriction.clear()
        } else if !restriction.available {
            issue = "Menu bar hiding is unavailable on this macOS version."
            restriction.clear()
        } else if let errorMessage {
            issue = errorMessage
            restriction.clear()
        } else if let registered = NSWorkspace.shared.urlForApplication(withBundleIdentifier: Self.ownID),
                  registered.standardizedFileURL != Bundle.main.bundleURL.standardizedFileURL {
            issue = "Open the installed copy of ClickBar: \(registered.path)"
            restriction.clear()
        } else {
            issue = nil
            let hidden = VisibilityPolicy.hiddenOnMenuBar(running: runningIDs, groups: groups, ownID: Self.ownID)
            restriction.apply(allowed: hidden.isEmpty ? nil : VisibilityPolicy.allowing(
                running: runningIDs, hidden: hidden, ownID: Self.ownID))
        }
        onChange?()
    }
}
