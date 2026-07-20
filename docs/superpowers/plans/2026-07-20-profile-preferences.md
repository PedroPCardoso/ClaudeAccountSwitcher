# Profile Preferences Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Add a native preferences window that lists profiles, marks the active profile, supports activation and renaming, and safely removes profiles.

**Architecture:** `PreferencesView` renders the profile list and delegates mutations through async closures. `MenuBarController` owns the existing store and activation service, presents the window, and applies the rule that deleting the active profile first activates the next available profile. `ProfileStore.remove` deletes only managed profile directories after metadata removal.

**Tech Stack:** SwiftUI, AppKit, Foundation, Swift concurrency, executable XCTest-style regression tests.

## Global Constraints

- Keep profile credentials isolated per managed directory.
- Never delete a profile without user confirmation.
- When deleting the active profile, activate another profile first; refuse to delete the only profile.
- Do not delete paths outside the switcher’s managed `Profiles` directory.
- Preserve universal Apple Silicon and Intel builds.

---

### Task 1: Make profile removal safe

**Files:**
- Modify: `Sources/ClaudeAccountSwitcherCore/Infrastructure/ProfileStore.swift`
- Test: `Tests/ClaudeAccountSwitcherTests/ProfileStoreTests.swift`

- [ ] Add a failing regression test that removes a profile and asserts metadata and its managed directory are gone.
- [ ] Implement guarded directory deletion under `profilesDirectory` after atomically updating metadata.
- [ ] Reject deletion of directories outside the managed root.

### Task 2: Build the preferences profile list

**Files:**
- Modify: `Sources/ClaudeAccountSwitcherApp/PreferencesView.swift`
- Create: `Sources/ClaudeAccountSwitcherApp/PreferencesWindowController.swift`
- Modify: `Sources/ClaudeAccountSwitcherApp/MenuBarController.swift`

- [ ] Render every profile with name, email/type, active badge, and buttons to activate, rename, or remove.
- [ ] Add confirmation before removal and show an error for the only remaining active profile.
- [ ] Wire activation and removal to `ProfileStore` and `ActivationService`, refreshing the list after each mutation.
- [ ] Replace the informational alert with the native preferences window.

### Task 3: Verify and publish

- [ ] Run all tests and release build.
- [ ] Rebuild the universal DMG and verify architectures.
- [ ] Commit and push the updated main branch and `v1.0.0` tag.

