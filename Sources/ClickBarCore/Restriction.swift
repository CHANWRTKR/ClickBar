import Foundation
import MenuBarShim

/// This is only a menu-bar allowlist, not a full device assessment session.
/// Never changes another app's defaults or creates a persistent system setting.
@MainActor
public final class Restriction {
    private var token: AnyObject?
    private var applied: Set<String>?
    private var pendingToken: AnyObject?
    private var pendingAllowed: Set<String>?
    private var desired: Set<String>?
    private var generation = 0
    private var timeout: Timer?
    public var onFailure: ((String) -> Void)?
    public init() {}
    public var available: Bool { STMenuBarShim.isAvailable() }

    public func apply(allowed: Set<String>?) {
        guard let allowed else { clear(); return }
        guard available else { clear(); onFailure?("Menu bar hiding is unavailable on this macOS version."); return }
        desired = allowed
        // Wait for the current activation to finish before starting another one.
        // Retain only the latest requested allowlist while it is in flight.
        guard pendingToken == nil, applied != allowed else { return }
        generation += 1
        let request = generation
        pendingAllowed = allowed
        let created = STMenuBarShim.activate(
            withAllowedBundleIdentifiers: allowed.sorted(),
            allowedSystemItems: (0...255).map { NSNumber(value: $0) }
        ) { [weak self] error in
            let message = error?.localizedDescription
            // Always queue: even an immediate callback must wait until the
            // returned token has been stored below.
            DispatchQueue.main.async {
                guard let self, self.generation == request, let replacement = self.pendingToken else { return }
                self.timeout?.invalidate()
                self.timeout = nil
                if let message {
                    self.clear()
                    self.onFailure?("Hiding failed: \(message) — all icons have been restored.")
                    return
                }
                let old = self.token
                self.token = replacement
                self.applied = self.pendingAllowed
                self.pendingToken = nil
                self.pendingAllowed = nil
                // Keep the old assertion alive until the new one is confirmed.
                STMenuBarShim.invalidate(old)
                if let desired = self.desired, desired != self.applied {
                    self.apply(allowed: desired)
                }
            }
        } as AnyObject?
        guard let created else {
            clear()
            onFailure?("Could not start hiding — all icons have been restored.")
            return
        }
        pendingToken = created
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
        let pending = pendingToken
        token = nil
        applied = nil
        pendingToken = nil
        pendingAllowed = nil
        desired = nil
        STMenuBarShim.invalidate(pending)
        STMenuBarShim.invalidate(old)
    }
}
