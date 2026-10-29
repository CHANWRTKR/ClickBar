# ClickBar v0.2.3

- Add a manual Check for Updates button in Settings. It checks published GitHub releases, including pre-releases, and opens the release page when a newer version is available. It does not automatically download or install updates.
- Reduce possible menu bar icon flicker when the hiding configuration changes by keeping the previous restriction active until the new one is confirmed.

Requires an Apple Silicon Mac running macOS 27 or later. This build is ad-hoc signed and not notarized, so macOS may require approval to open it. After replacing an older build, you may need to remove and re-add ClickBar in Privacy & Security's Device Control and Data Access settings.

Validation: 36/36 core checks passed, and the update check was exercised against GitHub. The intermittent flicker fix needs further observation during everyday use.
