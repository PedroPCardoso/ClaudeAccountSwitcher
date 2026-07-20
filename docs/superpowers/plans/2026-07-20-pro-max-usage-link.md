# Pro/Max Usage Link Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Add a clear, official usage action for the selected Pro/Max profile without scraping private APIs or storing additional credentials.

**Architecture:** The menu bar app adds a profile-scoped “Ver uso no Claude…” action. It opens Anthropic’s official Settings > Usage page in the user’s default browser; the app does not calculate or cache limits because Anthropic does not expose individual Pro/Max quota data through a public API.

**Tech Stack:** Swift, AppKit, Foundation, XCTest-style executable tests.

## Global Constraints

- Support macOS on Apple Silicon and Intel.
- Do not use private Anthropic endpoints, browser scraping, or local usage estimates.
- Do not add or persist API keys.
- Keep existing profile switching and rename behavior unchanged.

---

### Task 1: Add the official usage action

**Files:**
- Modify: `Sources/ClaudeAccountSwitcherApp/MenuBarController.swift`

**Interfaces:**
- Consumes: the existing active profile menu state.
- Produces: `openUsage()` action that opens `https://claude.ai/settings/usage` with `NSWorkspace`.

- [ ] Add a menu item titled `Ver uso no Claude…` after profile management actions and target it at the controller.
- [ ] Implement `openUsage()` using `NSWorkspace.shared.open`, showing an error alert only if the system cannot open the URL.
- [ ] Keep the label explicit that the page is official and account usage is shared across Claude surfaces.

### Task 2: Verify and package

**Files:**
- Test: `Tests/ClaudeAccountSwitcherTests/ProfileStoreTests.swift` (existing regression suite)
- Modify: `dist/Claude-Account-Switcher-1.0.0.dmg`

**Interfaces:**
- Consumes: the menu implementation from Task 1.
- Produces: a tested universal DMG.

- [ ] Run `swift run ClaudeAccountSwitcherTests` and confirm all tests pass.
- [ ] Run `swift build -c release --product ClaudeAccountSwitcher`.
- [ ] Run `./Scripts/build-dmg.sh` and copy the resulting DMG to `dist/Claude-Account-Switcher-1.0.0.dmg`.
- [ ] Verify the app binary contains `x86_64 arm64` with `lipo -info`.
- [ ] Commit with a generic open-source author, push `main`, and update tag `v1.0.0`.

