import AppKit
import SwiftUI
import ClickBarCore

private struct GitHubRelease: Decodable {
    let tag_name: String
    let draft: Bool
}

@MainActor
final class UpdateChecker: ObservableObject {
    @Published private(set) var checking = false
    @Published private(set) var message = ""
    @Published private(set) var releaseURL: URL?
    var currentVersion: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "Unknown" }

    func check() {
        guard !checking else { return }
        checking = true
        message = "Checking GitHub…"
        releaseURL = nil
        let installed = currentVersion
        Task {
            defer { checking = false }
            guard let current = ReleaseVersion(installed) else {
                message = "Could not read the installed version."
                return
            }
            do {
                var request = URLRequest(url: URL(string: "https://api.github.com/repos/CHANWRTKR/ClickBar/releases?per_page=100")!)
                request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
                request.setValue("ClickBar", forHTTPHeaderField: "User-Agent")
                request.timeoutInterval = 15
                let (data, response) = try await URLSession.shared.data(for: request)
                guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                    throw URLError(.badServerResponse)
                }
                let releases = try JSONDecoder().decode([GitHubRelease].self, from: data)
                guard let latest = releases.filter({ !$0.draft }).compactMap({ release -> ReleaseVersion? in
                    guard let version = ReleaseVersion(release.tag_name), release.tag_name == "v\(version)" else { return nil }
                    return version
                }).max() else {
                    message = "No compatible releases found on GitHub."
                    return
                }
                if latest > current {
                    message = "Version \(latest) is available."
                    releaseURL = URL(string: "https://github.com/CHANWRTKR/ClickBar/releases/tag/v\(latest)")
                } else {
                    message = "You have the latest version."
                }
            } catch {
                message = "Could not check for updates. Check your connection and try again."
            }
        }
    }
    func openRelease() {
        if let releaseURL { NSWorkspace.shared.open(releaseURL) }
    }
}
