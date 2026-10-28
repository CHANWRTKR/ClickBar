import Foundation
import MenuBarShim

/// This is only a menu-bar allowlist, not a full device assessment session.
/// Never changes another app's defaults or creates a persistent system setting.
@MainActor
public final class Restriction {
    private var token: AnyObject?
    private var generation = 0
    private var timeout: Timer?
    private var applied: Set<String>?
    public var onFailure: ((String) -> Void)?
    public init() {}
    public var available: Bool { STMenuBarShim.isAvailable() }

    public func apply(allowed: Set<String>?) {
        guard let allowed else { clear(); return }
        guard available else { clear(); onFailure?("Menu bar hiding is unavailable on this macOS version."); return }
        guard applied != allowed else { return }
        generation += 1
        let request = generation
        timeout?.invalidate()
        let old = token
        let created = STMenuBarShim.activate(
            withAllowedBundleIdentifiers: allowed.sorted(),
            allowedSystemItems: (0...255).map { NSNumber(value: $0) }
        ) { [weak self] error in
            let message = error?.localizedDescription
            // Always queue: even an immediate private-API callback must wait until
            // the returned token has been stored below.
            DispatchQueue.main.async {
                guard let self, self.generation == request else { return }
                self.timeout?.invalidate()
                self.timeout = nil
                if let message {
                    self.clear()
                    self.onFailure?("Hiding failed: \(message) — all icons have been restored.")
                }
            }
        } as AnyObject?
        token = created
        STMenuBarShim.invalidate(old)
        guard created != nil else {
            clear()
            onFailure?("Could not start hiding — all icons have been restored.")
            return
        }
        applied = allowed
        timeout = Timer.scheduledTimer(withTimeInterval: 4, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.generation == request else { return }
                self.clear()
                self.onFailure?("The system did not respond. All icons have been restored. Please try again.")
            }
        }
    }

    public func clear() {
        generation += 1
        timeout?.invalidate()
        timeout = nil
        let old = token
        token = nil
        applied = nil
        STMenuBarShim.invalidate(old)
    }
}
