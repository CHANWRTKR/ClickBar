# Unreleased

- Start quietly after initial setup instead of opening Settings on every launch, including at login.
- Let a single native clock click open Notification Center by pausing hiding while hovering the clock and while the panel is open. Resume hiding after both the pointer and panel have left.
- Use the clock’s actual Accessibility bounds on each display so hovering Control Center does not reveal hidden icons.

Validation: release build succeeded, 36/36 core checks passed, and the user confirmed single-click Notification Center opening and the narrower hover area on the installed build. The core checks do not exercise macOS Notification Center interactions.

# ClickBar v0.2.3

- Add a manual Check for Updates button in Settings. It checks published GitHub releases, including pre-releases, and opens the release page when a newer version is available. It does not automatically download or install updates.
- Reduce possible menu bar icon flicker when the hiding configuration changes by keeping the previous restriction active until the new one is confirmed.

Requires an Apple Silicon Mac running macOS 27 or later. This build is ad-hoc signed and not notarized, so macOS may require approval to open it. After replacing an older build, you may need to remove and re-add ClickBar in Privacy & Security's Device Control and Data Access settings.

Validation: 36/36 core checks passed, and the update check was exercised against GitHub. The intermittent flicker fix needs further observation during everyday use.
