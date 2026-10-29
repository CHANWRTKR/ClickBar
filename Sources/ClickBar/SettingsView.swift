import AppKit
import SwiftUI
import ClickBarCore

struct SettingsView: View {
    @ObservedObject var model: AppModel
    @StateObject private var updates = UpdateChecker()
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("ClickBar").font(.system(size: 28, weight: .semibold))
                    Text("Choose groups. Click the three dots to open icons below the menu bar.")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Toggle("Enable hiding", isOn: Binding(get: { model.enabled }, set: model.setEnabled))
                    .toggleStyle(.switch)
                    .accessibilityIdentifier("enableHiding")
            }
            HStack(spacing: 16) {
                Label("Single click · first group", systemImage: "cursorarrow.click")
                Label("Double click · both groups", systemImage: "cursorarrow.click.2")
            }.font(.callout)
            Text("Click again to close • Right-click the three dots for settings")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Toggle("Open ClickBar at login", isOn: Binding(get: { model.launchAtLogin || model.loginItemNeedsApproval }, set: model.setLaunchAtLogin))
                    .toggleStyle(.switch)
                    .accessibilityIdentifier("launchAtLogin")
                Spacer()
                if model.loginItemNeedsApproval {
                    Button("Allow in Login Items…", action: model.openLoginItemSettings)
                }
            }
            if model.loginItemNeedsApproval {
                Text("Allow ClickBar in Login Items to finish enabling launch at login.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let error = model.loginItemError {
                Text("Could not change login setting: \(error)")
                    .font(.caption).foregroundStyle(.orange)
            }
            HStack {
                Text("Version \(updates.currentVersion)").font(.caption).foregroundStyle(.secondary)
                Button(updates.checking ? "Checking…" : "Check for Updates", action: updates.check)
                    .disabled(updates.checking)
                if !updates.message.isEmpty {
                    Text(updates.message).font(.caption).foregroundStyle(.secondary)
                }
                if updates.releaseURL != nil {
                    Button("Open Release", action: updates.openRelease)
                }
                Spacer()
            }
            HStack {
                Label(model.accessibilityGranted ? "Menu access enabled" : "Accessibility is needed to open menus from the icon panel",
                      systemImage: model.accessibilityGranted ? "checkmark.circle" : "hand.point.up.left")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                if !model.accessibilityGranted {
                    Button("Allow Accessibility…", action: model.requestAccessibility)
                }
                Button("Check Access", action: model.checkAccessibility)
            }
            if let issue = model.issue {
                Label(issue, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout).foregroundStyle(.orange)
                    .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                    .background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
            }
            HStack {
                TextField("Search apps…", text: $model.search)
                    .textFieldStyle(.roundedBorder)
                Button("Refresh", systemImage: "arrow.clockwise", action: model.refresh)
            }
            HStack {
                Text("Running and previously grouped apps").foregroundStyle(.secondary)
                Spacer()
                Text("\(model.filteredApps.count) apps").foregroundStyle(.secondary)
            }.font(.caption)
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(model.filteredApps) { app in
                        HStack(spacing: 10) {
                            if let icon = app.icon {
                                Image(nsImage: icon).resizable().frame(width: 28, height: 28)
                            } else {
                                Image(systemName: "app").frame(width: 28, height: 28)
                            }
                            VStack(alignment: .leading, spacing: 2) {
                                Text(app.name).lineLimit(1)
                                Text(app.running ? app.id : "Not running · \(app.id)")
                                    .font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                            }.frame(maxWidth: .infinity, alignment: .leading)
                            Picker("Group for \(app.name)", selection: Binding(
                                get: { model.group(for: app.id) },
                                set: { model.setGroup($0, for: app.id) }
                            )) {
                                ForEach(IconGroup.allCases, id: \.self) { group in
                                    Text(group.title).tag(group)
                                }
                            }.pickerStyle(.segmented).labelsHidden().frame(width: 345)
                                .accessibilityLabel("Group for \(app.name)")
                        }.padding(.horizontal, 12).padding(.vertical, 10)
                        Divider().padding(.leading, 50)
                    }
                    if model.filteredApps.isEmpty {
                        Text("No matching apps. Launch the app, then refresh.")
                            .foregroundStyle(.secondary).padding(32)
                    }
                }
            }.background(.background, in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(.separator.opacity(0.5)))
            HStack {
                Text(model.enabled ? model.state.title : "Hiding is off")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Restore all icons", action: model.restoreAll)
                Button("Preview panel") { model.reveal(.single) }.disabled(!model.enabled)
            }
            Text("Groups apply per app. The lower panel uses app icons. This list may include apps without a menu bar item. Apple system items stay visible.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }.padding(24).frame(minWidth: 800, idealWidth: 850, minHeight: 640, idealHeight: 700)
    }
}
