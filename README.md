# Claude Account Switcher 1.3.0

<img src="docs/assets/claude-account-switcher-logo.png" alt="Claude Account Switcher logo" width="180">

Native macOS menu bar app for switching between isolated Claude Code profiles. The selected profile applies to new sessions; already-open sessions remain unchanged.

Current release: **1.3.0**. The distributed DMG contains a universal Apple Silicon and Intel binary when built on a macOS environment with both targets available.

Direct download: [Claude-Account-Switcher-1.3.0.dmg](https://github.com/PedroPCardoso/ClaudeAccountSwitcher/raw/main/dist/Claude-Account-Switcher-1.3.0.dmg)

### What's new in 1.3.0

- **5-hour usage alert.** A native notification fires once when the active account crosses a configurable threshold (default 80%) of its 5-hour window, telling you when the window frees up. Threshold and sound are set in Preferences.
- **Native app relaunch is now optional and off by default.** Switching accounts no longer reopens the desktop Claude app; enable it in Preferences if you want that behavior.
- **Fix:** usage reset times (`resets_at`) now parse correctly — the endpoint returns fractional-second timestamps that the previous parser rejected, so reset times never displayed.

### Real Pro/Max usage

In Preferences and in the account menu bar tooltip, the app queries Claude Code OAuth usage directly, including the 5-hour and weekly windows. Each profile uses only the credential stored in the Keychain for its own `CLAUDE_CONFIG_DIR`; no 9router installation or other gateway is required. This is a consumer endpoint and may change without notice.

The **View Claude usage…** menu opens an internal window with per-account cards, visual progress bars, usage percentages, and reset times.

The app also sums tokens recorded in each profile's local sessions (input, output, and cache). This represents Claude Code activity recorded locally, not a subscription token limit.

### Account selector

Clicking the menu bar icon shows each account's usage directly in the selector:

![Account selector example with quotas and tokens](docs/assets/menu-usage-example.png)

## Current status

The project includes profile management, atomic persistence, Claude Code discovery, authentication through `claude auth`, a launcher, rollback-safe activation, migration, login-item support, and the menu bar interface. The build environment uses Swift Command Line Tools; the package therefore includes an executable test runner.

In **Preferences…**, you can view each account's email and status, activate, rename, remove, or re-authenticate a profile. When opened, the app refreshes authentication data using the official `claude auth status` command.

## Build and test

```zsh
cd /path/to/ClaudeAccountSwitcher
swift run ClaudeAccountSwitcherTests
swift build -c release --product ClaudeAccountSwitcher
./Scripts/build-app.sh
./Scripts/build-dmg.sh
```

The runner prints `N tests passed`. The build creates `build/Claude Account Switcher.app`, locally ad-hoc signed.
`./Scripts/build-dmg.sh` also creates `build/Claude-Account-Switcher.dmg`, ready to drag into `Applications`.

## Installation

```zsh
./Scripts/install-dev.sh
```

The script builds, copies, and opens the app. It does not migrate accounts, modify `.zprofile`, or remove aliases.

## First use

Open the app, import `~/.claude` and `~/.claude-work` through the interface, and confirm the backup before removing aliases. To add an account, choose Claude Pro/Max or Anthropic Console; the official browser login opens and the profile is stored separately.

Profiles are stored in `~/Library/Application Support/Claude Account Switcher/Profiles/`. Metadata and active state are stored alongside them. Tokens are not read from profile files by the app; Claude Code and the macOS Keychain remain responsible for credential storage.

## Integration

When repairing integration, the app installs a launcher at `~/Library/Application Support/Claude Account Switcher/bin/claude` and adds a delimited block to `~/.zprofile`. The launcher preserves all `claude` arguments and injects the active profile's `CLAUDE_CONFIG_DIR`. The app also updates the launchd environment for new graphical applications.

The default shortcut is `⌥⌘C`. Applications that were already open may need to be restarted to receive the new environment.

## Recovery

Before any migration, the app creates backups with a manifest. If switching fails, the previous active state is restored. Profile removal can be recovered from `Recently Removed`. To remove integration, use the repair/remove action in the app; only the delimited block is edited.

## Development

The core is in `Sources/ClaudeAccountSwitcherCore`, the UI is in `Sources/ClaudeAccountSwitcherApp`, and the runner is in `Tests/ClaudeAccountSwitcherTests`. For XCTest and development signing, install Xcode while keeping the same modules and interfaces.
