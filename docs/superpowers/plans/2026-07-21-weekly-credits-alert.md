# Weekly Credits Available Alert Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fire a native macOS notification when any configured account (active or not) is within 24 hours of its weekly ("Semanal") quota renewal while still having at least a configurable percentage of credits available (default 30%), so the user notices unused credits before they reset. This is the inverse of the existing 5-hour alert (which warns about scarcity on the active account only); this one warns about surplus, across all accounts.

**Architecture:** A new `WeeklyCreditsAlertTracker` struct (in `FiveHourAlert.swift`, alongside the existing 5-hour alert types) tracks, per profile UUID, which `resetAt` has already fired an alert — so each weekly renewal alerts at most once per account. `MenuBarController.refreshProfileMetadata()` evaluates this tracker for *every* profile (not just the active one) inside its existing per-profile loop, collects any hits from the cycle, and fires a single combined `NSUserNotification` at the end of the cycle if the list is non-empty. The alert reuses the existing 5-hour alert's sound preference. A new `Stepper` in `PreferencesView` controls the credits-available threshold.

**Tech Stack:** Swift 6, Swift Package Manager, AppKit (`NSUserNotification`), SwiftUI (`@AppStorage`), the project's custom executable test runner (no XCTest).

## Global Constraints

- macOS 13 Ventura minimum, Apple Silicon and Intel (existing `Package.swift` / design doc).
- Only the `"Semanal"` quota key is evaluated — per-model weekly quotas (`"Semanal <Modelo>"`) and the 5-hour quota (`"Janela 5h"`) are out of scope (spec scope).
- All configured profiles are evaluated, not just the active one (spec scope, acceptance criterion 3).
- If multiple profiles qualify in the same 60s refresh cycle, exactly one combined notification is sent, never one per profile (spec scope, acceptance criterion 4).
- The alert reuses the existing `fiveHourAlertSoundName()` sound preference — no new sound picker (spec scope).
- No persistence of alert state across app restarts — volatile in-memory state only, same as the 5-hour alert (spec scope).
- New public types live in `ClaudeAccountSwitcherCore` (no UI dependencies); UI wiring lives in `ClaudeAccountSwitcherApp`.
- Tests are added to `Tests/ClaudeAccountSwitcherTests/ProfileStoreTests.swift` by appending new `static func test...()` cases to the `tests` array in `ProfileStoreTests.main()` — this project has one flat test file/runner, not per-file suites.
- Run tests with `swift run ClaudeAccountSwitcherTests` from `/Users/pedrocardoso/Develop/ClaudeAccountSwitcher/.worktrees/claude-account-switcher`.
- All user-facing strings go through `AppStrings.t(pt, en)`, matching every other string in `MenuBarController.swift` and `PreferencesView.swift`.

---

## Task 1: `WeeklyCreditsAlertTracker` and `WeeklyCreditsAlertThreshold`

**Files:**
- Modify: `Sources/ClaudeAccountSwitcherCore/Domain/FiveHourAlert.swift`
- Test: `Tests/ClaudeAccountSwitcherTests/ProfileStoreTests.swift`

**Interfaces:**
- Produces: `WeeklyCreditsAlertTracker` (struct, `Sendable`) with `init()` and `mutating func evaluate(profileID: UUID, usedPercent: Double, resetAt: Date?, availableThreshold: Double, now: Date = .now) -> Bool`. Used by `MenuBarController` (Task 2).
- Produces: `WeeklyCreditsAlertThreshold` (enum) with `static let defaultsKey: String = "weeklyCreditsAlertThreshold"`, `static let default: Double = 30`, `static func resolve(_ raw: Double) -> Double`. Used by `MenuBarController` (Task 2) and `PreferencesView` (Task 3).

- [ ] **Step 1: Write the failing tests**

Add these cases to the `tests` array in `ProfileStoreTests.main()`, right after the existing 5h alert test entries (`"5h alert sound falls back to default when unknown"`):

```swift
,("weekly credits alert fires within 24h of reset when credits remain above threshold", testWeeklyCreditsAlertTracker)
,("weekly credits alert does not fire outside the 24h window", testWeeklyCreditsAlertOutsideWindow)
,("weekly credits alert does not fire below the credits threshold", testWeeklyCreditsAlertBelowThreshold)
,("weekly credits alert rearms when resetAt changes", testWeeklyCreditsAlertRearmsOnRenewal)
,("weekly credits alert tracks profiles independently", testWeeklyCreditsAlertPerProfile)
,("weekly credits threshold falls back to default when invalid", testWeeklyCreditsAlertThreshold)
```

Add these test functions to `ProfileStoreTests`, near `testFiveHourAlertThreshold()`:

```swift
static func testWeeklyCreditsAlertTracker() throws {
    var tracker = WeeklyCreditsAlertTracker()
    let now = Date()
    let resetIn12h = now.addingTimeInterval(12 * 3600)
    try check(tracker.evaluate(profileID: UUID(), usedPercent: 60, resetAt: resetIn12h, availableThreshold: 30, now: now) == true, "should fire when within 24h and 40% available >= 30% threshold")
}

static func testWeeklyCreditsAlertOutsideWindow() throws {
    var tracker = WeeklyCreditsAlertTracker()
    let now = Date()
    let resetIn48h = now.addingTimeInterval(48 * 3600)
    try check(tracker.evaluate(profileID: UUID(), usedPercent: 60, resetAt: resetIn48h, availableThreshold: 30, now: now) == false, "should not fire more than 24h before reset")
    let resetInPast = now.addingTimeInterval(-3600)
    try check(tracker.evaluate(profileID: UUID(), usedPercent: 60, resetAt: resetInPast, availableThreshold: 30, now: now) == false, "should not fire once reset has already passed")
    try check(tracker.evaluate(profileID: UUID(), usedPercent: 60, resetAt: nil, availableThreshold: 30, now: now) == false, "should not fire without a resetAt")
}

static func testWeeklyCreditsAlertBelowThreshold() throws {
    var tracker = WeeklyCreditsAlertTracker()
    let now = Date()
    let resetIn12h = now.addingTimeInterval(12 * 3600)
    try check(tracker.evaluate(profileID: UUID(), usedPercent: 85, resetAt: resetIn12h, availableThreshold: 30, now: now) == false, "15% available should not clear a 30% threshold")
}

static func testWeeklyCreditsAlertRearmsOnRenewal() throws {
    var tracker = WeeklyCreditsAlertTracker()
    let id = UUID()
    let now = Date()
    let firstReset = now.addingTimeInterval(12 * 3600)
    try check(tracker.evaluate(profileID: id, usedPercent: 60, resetAt: firstReset, availableThreshold: 30, now: now) == true, "first crossing should fire")
    try check(tracker.evaluate(profileID: id, usedPercent: 60, resetAt: firstReset, availableThreshold: 30, now: now) == false, "same resetAt should not fire twice")
    let secondReset = firstReset.addingTimeInterval(7 * 24 * 3600)
    let laterNow = firstReset.addingTimeInterval(1)
    try check(tracker.evaluate(profileID: id, usedPercent: 60, resetAt: secondReset, availableThreshold: 30, now: laterNow) == true, "a new resetAt after renewal should rearm and fire again")
}

static func testWeeklyCreditsAlertPerProfile() throws {
    var tracker = WeeklyCreditsAlertTracker()
    let now = Date()
    let reset = now.addingTimeInterval(12 * 3600)
    let profileA = UUID(); let profileB = UUID()
    try check(tracker.evaluate(profileID: profileA, usedPercent: 60, resetAt: reset, availableThreshold: 30, now: now) == true, "profile A should fire")
    try check(tracker.evaluate(profileID: profileB, usedPercent: 60, resetAt: reset, availableThreshold: 30, now: now) == true, "profile B should fire independently of profile A's state")
    try check(tracker.evaluate(profileID: profileA, usedPercent: 60, resetAt: reset, availableThreshold: 30, now: now) == false, "profile A should not fire again for the same resetAt")
}

static func testWeeklyCreditsAlertThreshold() throws {
    try check(WeeklyCreditsAlertThreshold.resolve(0) == 30, "zero should fall back to default")
    try check(WeeklyCreditsAlertThreshold.resolve(150) == 30, "out-of-range should fall back to default")
    try check(WeeklyCreditsAlertThreshold.resolve(45) == 45, "valid threshold should be kept")
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift run ClaudeAccountSwitcherTests` (from `/Users/pedrocardoso/Develop/ClaudeAccountSwitcher/.worktrees/claude-account-switcher`)

Expected: build FAILS with "cannot find type 'WeeklyCreditsAlertTracker' in scope" (and similarly for `WeeklyCreditsAlertThreshold`).

- [ ] **Step 3: Implement `WeeklyCreditsAlertTracker` and `WeeklyCreditsAlertThreshold`**

Append to `Sources/ClaudeAccountSwitcherCore/Domain/FiveHourAlert.swift`:

```swift
/// Tracks, per profile, which `resetAt` of the weekly window has already
/// fired a "credits available" alert, so each renewal alerts at most once.
public struct WeeklyCreditsAlertTracker: Sendable {
    private var alertedResetAt: [UUID: Date] = [:]

    public init() {}

    @discardableResult
    public mutating func evaluate(profileID: UUID, usedPercent: Double, resetAt: Date?, availableThreshold: Double, now: Date = .now) -> Bool {
        guard let resetAt else { return false }
        let hoursUntilReset = resetAt.timeIntervalSince(now) / 3600
        guard hoursUntilReset > 0, hoursUntilReset <= 24 else {
            alertedResetAt[profileID] = nil
            return false
        }
        guard (100 - usedPercent) >= availableThreshold else { return false }
        guard alertedResetAt[profileID] != resetAt else { return false }
        alertedResetAt[profileID] = resetAt
        return true
    }
}

public enum WeeklyCreditsAlertThreshold {
    public static let defaultsKey = "weeklyCreditsAlertThreshold"
    public static let `default`: Double = 30

    public static func resolve(_ raw: Double) -> Double {
        (raw > 0 && raw <= 100) ? raw : `default`
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift run ClaudeAccountSwitcherTests`
Expected: all tests print `PASS`, including the six new ones, ending with `N tests passed` and no `FAIL` lines.

- [ ] **Step 5: Commit**

```bash
git add Sources/ClaudeAccountSwitcherCore/Domain/FiveHourAlert.swift Tests/ClaudeAccountSwitcherTests/ProfileStoreTests.swift
git commit -m "feat: add weekly credits alert tracker and threshold"
```

---

## Task 2: Wire the alert into `MenuBarController`

**Files:**
- Modify: `Sources/ClaudeAccountSwitcherApp/MenuBarController.swift`

**Interfaces:**
- Consumes: `WeeklyCreditsAlertTracker` and `WeeklyCreditsAlertThreshold` (from Task 1); `Profile` (`id: UUID`, `name: String`); `ClaudeUsageSnapshot.quotas: [ClaudeQuota]`; `ClaudeQuota.key: String`, `.usedPercent: Double`, `.resetAt: Date?` (all pre-existing); the private `resetDescription(_ date: Date) -> String` and `fiveHourAlertSoundName() -> String?` already defined in this file.
- Produces: no new public interface — this task only changes app-level wiring. `checkWeeklyCreditsAlert` and `notifyWeeklyCreditsAlert` are private to `MenuBarController`.

This task has no automated test of its own — `MenuBarController` is a `@MainActor` AppKit class exercised by the existing manual test plan, consistent with how the 5-hour alert's `MenuBarController` wiring (`checkFiveHourAlert`, `notifyFiveHourAlert`) was added without a unit test in `7ae345f`. The tracker's logic itself is fully covered by Task 1.

- [ ] **Step 1: Add the tracker property**

In `Sources/ClaudeAccountSwitcherApp/MenuBarController.swift`, find:

```swift
    private var fiveHourAlert = FiveHourAlertTracker()
```

Replace with:

```swift
    private var fiveHourAlert = FiveHourAlertTracker()
    private var weeklyCreditsAlert = WeeklyCreditsAlertTracker()
```

- [ ] **Step 2: Evaluate every profile inside `refreshProfileMetadata()` and collect hits**

Find the current body of `refreshProfileMetadata()`:

```swift
    private func refreshProfileMetadata() {
        let profiles = (try? store.list()) ?? []
        let activeID = try? store.active()?.id
        Task.detached(priority: .utility) { [weak self] in
            guard let self else { return }
            for profile in profiles {
                guard let status = try? self.auth.status(profileDirectory: profile.directory) else { continue }
                var updated = profile
                updated.email = status.email ?? profile.email
                updated.organization = status.organization ?? profile.organization
                updated.kind = status.kind
                updated.health = status.isAuthenticated ? .ready : .expired
                try? self.store.save(updated)
                if let snapshot = try? await self.usage.fetch(profileDirectory: profile.directory) {
                    var snapshot = snapshot
                    snapshot = ClaudeUsageSnapshot(fetchedAt: snapshot.fetchedAt, plan: snapshot.plan, quotas: snapshot.quotas, source: snapshot.source, tokens: self.usage.tokenUsage(profileDirectory: profile.directory))
                    updated.usage = snapshot
                    try? self.store.save(updated)
                    if updated.id == activeID {
                        let active = updated; let snap = snapshot
                        await MainActor.run { self.checkFiveHourAlert(profile: active, snapshot: snap) }
                    }
                }
            }
            await MainActor.run { self.rebuildMenu(); self.refreshPreferences() }
        }
    }
```

Replace with:

```swift
    private func refreshProfileMetadata() {
        let profiles = (try? store.list()) ?? []
        let activeID = try? store.active()?.id
        Task.detached(priority: .utility) { [weak self] in
            guard let self else { return }
            var weeklyCreditsHits: [WeeklyCreditsAlertHit] = []
            for profile in profiles {
                guard let status = try? self.auth.status(profileDirectory: profile.directory) else { continue }
                var updated = profile
                updated.email = status.email ?? profile.email
                updated.organization = status.organization ?? profile.organization
                updated.kind = status.kind
                updated.health = status.isAuthenticated ? .ready : .expired
                try? self.store.save(updated)
                if let snapshot = try? await self.usage.fetch(profileDirectory: profile.directory) {
                    var snapshot = snapshot
                    snapshot = ClaudeUsageSnapshot(fetchedAt: snapshot.fetchedAt, plan: snapshot.plan, quotas: snapshot.quotas, source: snapshot.source, tokens: self.usage.tokenUsage(profileDirectory: profile.directory))
                    updated.usage = snapshot
                    try? self.store.save(updated)
                    if updated.id == activeID {
                        let active = updated; let snap = snapshot
                        await MainActor.run { self.checkFiveHourAlert(profile: active, snapshot: snap) }
                    }
                    let current = updated; let snap = snapshot
                    if let hit = await MainActor.run(body: { self.checkWeeklyCreditsAlert(profile: current, snapshot: snap) }) {
                        weeklyCreditsHits.append(hit)
                    }
                }
            }
            if !weeklyCreditsHits.isEmpty {
                let hits = weeklyCreditsHits
                await MainActor.run { self.notifyWeeklyCreditsAlert(hits) }
            }
            await MainActor.run { self.rebuildMenu(); self.refreshPreferences() }
        }
    }
```

- [ ] **Step 3: Add `WeeklyCreditsAlertHit`, `checkWeeklyCreditsAlert`, and `notifyWeeklyCreditsAlert`**

Find:

```swift
    /// Fires a native alert once when the active account crosses the configured 5-hour usage
    /// threshold, telling the user when the window frees up so they know how long to wait.
    private func checkFiveHourAlert(profile: Profile, snapshot: ClaudeUsageSnapshot) {
```

Insert this new struct and two functions directly above it:

```swift
    private struct WeeklyCreditsAlertHit {
        let profileName: String
        let availablePercent: Int
        let resetAt: Date?
    }

    /// Fires once per profile per weekly renewal, when that profile is within 24h of its
    /// "Semanal" reset and still has at least the configured percentage of credits available.
    /// Runs for every profile, not just the active one, so idle accounts with spare credits
    /// are surfaced too.
    private func checkWeeklyCreditsAlert(profile: Profile, snapshot: ClaudeUsageSnapshot) -> WeeklyCreditsAlertHit? {
        guard let quota = snapshot.quotas.first(where: { $0.key == "Semanal" }) else { return nil }
        let threshold = WeeklyCreditsAlertThreshold.resolve(UserDefaults.standard.double(forKey: WeeklyCreditsAlertThreshold.defaultsKey))
        guard weeklyCreditsAlert.evaluate(profileID: profile.id, usedPercent: quota.usedPercent, resetAt: quota.resetAt, availableThreshold: threshold) else { return nil }
        return WeeklyCreditsAlertHit(profileName: profile.name, availablePercent: Int((100 - quota.usedPercent).rounded()), resetAt: quota.resetAt)
    }

    private func notifyWeeklyCreditsAlert(_ hits: [WeeklyCreditsAlertHit]) {
        let message: String
        if hits.count == 1, let hit = hits.first {
            let resetPart = hit.resetAt.map { resetDescription($0) } ?? AppStrings.t("em breve", "soon")
            message = AppStrings.t(
                "💳 \(hit.profileName) ainda tem \(hit.availablePercent)% dos créditos semanais — renova \(resetPart)",
                "💳 \(hit.profileName) still has \(hit.availablePercent)% of weekly credits — renews \(resetPart)")
        } else {
            let list = hits.map { "\($0.profileName) (\($0.availablePercent)%)" }.joined(separator: ", ")
            message = AppStrings.t(
                "💳 Créditos semanais disponíveis: \(list) — aproveite antes da renovação",
                "💳 Weekly credits available: \(list) — use them before renewal")
        }
        let n = NSUserNotification(); n.title = "Claude Account Switcher"; n.informativeText = message
        n.soundName = fiveHourAlertSoundName()
        NSUserNotificationCenter.default.deliver(n)
    }

```

- [ ] **Step 4: Build to verify it compiles**

Run: `swift build` (from `/Users/pedrocardoso/Develop/ClaudeAccountSwitcher/.worktrees/claude-account-switcher`)
Expected: `Build complete!` with no errors.

- [ ] **Step 5: Run the full test suite to verify no regressions**

Run: `swift run ClaudeAccountSwitcherTests`
Expected: all tests still print `PASS`, ending with `N tests passed`.

- [ ] **Step 6: Commit**

```bash
git add Sources/ClaudeAccountSwitcherApp/MenuBarController.swift
git commit -m "feat: evaluate weekly credits alert for every profile on each usage refresh"
```

---

## Task 3: Add the threshold `Stepper` to `PreferencesView`

**Files:**
- Modify: `Sources/ClaudeAccountSwitcherApp/PreferencesView.swift`

**Interfaces:**
- Consumes: `WeeklyCreditsAlertThreshold.defaultsKey`, `WeeklyCreditsAlertThreshold.default` (from Task 1).
- Produces: nothing consumed by later tasks — this is the last task in the plan.

- [ ] **Step 1: Add the `@AppStorage` property**

Find:

```swift
    @AppStorage(FiveHourAlertThreshold.defaultsKey) private var fiveHourThreshold: Double = FiveHourAlertThreshold.default
    @AppStorage(FiveHourAlertSound.defaultsKey) private var fiveHourSoundRaw: String = FiveHourAlertSound.default.rawValue
```

Replace with:

```swift
    @AppStorage(FiveHourAlertThreshold.defaultsKey) private var fiveHourThreshold: Double = FiveHourAlertThreshold.default
    @AppStorage(FiveHourAlertSound.defaultsKey) private var fiveHourSoundRaw: String = FiveHourAlertSound.default.rawValue
    @AppStorage(WeeklyCreditsAlertThreshold.defaultsKey) private var weeklyCreditsThreshold: Double = WeeklyCreditsAlertThreshold.default
```

- [ ] **Step 2: Add the `Stepper` next to the existing 5h alert controls**

Find:

```swift
            Divider()
            HStack(spacing: 16) {
                Stepper(value: $fiveHourThreshold, in: 1...100, step: 5) {
                    Text(AppStrings.t("Alertar em \(Int(fiveHourThreshold))% da janela de 5h", "Alert at \(Int(fiveHourThreshold))% of the 5-hour window"))
                }
                Picker(AppStrings.t("Som:", "Sound:"), selection: $fiveHourSoundRaw) {
                    ForEach(FiveHourAlertSound.allCases, id: \.self) { Text(soundLabel($0)).tag($0.rawValue) }
                }
                .fixedSize()
                Spacer()
            }
```

Replace with:

```swift
            Divider()
            HStack(spacing: 16) {
                Stepper(value: $fiveHourThreshold, in: 1...100, step: 5) {
                    Text(AppStrings.t("Alertar em \(Int(fiveHourThreshold))% da janela de 5h", "Alert at \(Int(fiveHourThreshold))% of the 5-hour window"))
                }
                Picker(AppStrings.t("Som:", "Sound:"), selection: $fiveHourSoundRaw) {
                    ForEach(FiveHourAlertSound.allCases, id: \.self) { Text(soundLabel($0)).tag($0.rawValue) }
                }
                .fixedSize()
                Spacer()
            }
            HStack(spacing: 16) {
                Stepper(value: $weeklyCreditsThreshold, in: 1...100, step: 5) {
                    Text(AppStrings.t("Avisar quando restarem \(Int(weeklyCreditsThreshold))% ou mais dos créditos semanais no dia da renovação", "Alert when \(Int(weeklyCreditsThreshold))% or more of weekly credits remain on renewal day"))
                }
                Spacer()
            }
```

- [ ] **Step 3: Build to verify it compiles**

Run: `swift build` (from `/Users/pedrocardoso/Develop/ClaudeAccountSwitcher/.worktrees/claude-account-switcher`)
Expected: `Build complete!` with no errors.

- [ ] **Step 4: Run the full test suite to verify no regressions**

Run: `swift run ClaudeAccountSwitcherTests`
Expected: all tests still print `PASS`, ending with `N tests passed`.

- [ ] **Step 5: Manual verification**

Run: `swift run ClaudeAccountSwitcherApp` (from `/Users/pedrocardoso/Develop/ClaudeAccountSwitcher/.worktrees/claude-account-switcher`)
- Open Preferences from the menu bar icon and confirm the new "Avisar quando restarem N% ou mais dos créditos semanais..." stepper appears below the 5-hour alert row, adjustable in steps of 5 from 1 to 100.
- Confirm changing it does not require restarting the app (the label updates immediately as the stepper is adjusted).

- [ ] **Step 6: Commit**

```bash
git add Sources/ClaudeAccountSwitcherApp/PreferencesView.swift
git commit -m "feat: add weekly credits alert threshold to Preferences"
```

---

## Self-Review Notes

- **Spec coverage:** scope §"Semanal only" → Task 2 Step 3 (`quotas.first(where: { $0.key == "Semanal" })`); "all profiles, not just active" → Task 2 Step 2 (loop unconditionally calls `checkWeeklyCreditsAlert`); "configurable threshold, default 30%" → Task 1 (`WeeklyCreditsAlertThreshold`) + Task 3 (Stepper); "combined single notification for multiple hits" → Task 2 Step 3 (`notifyWeeklyCreditsAlert` branches on `hits.count`); "reuse 5h alert sound" → Task 2 Step 3 (`fiveHourAlertSoundName()`); "no restart needed for threshold changes" → Task 3 Step 5 (manual check); "once per resetAt per profile" → Task 1's `evaluate` + tests `testWeeklyCreditsAlertRearmsOnRenewal`/`testWeeklyCreditsAlertPerProfile`.
- **Type consistency:** `WeeklyCreditsAlertTracker.evaluate` signature matches between Task 1 (definition) and Task 2 (call site: `profileID:usedPercent:resetAt:availableThreshold:`). `WeeklyCreditsAlertThreshold.resolve`/`.default`/`.defaultsKey` used identically in Task 2 and Task 3.
- **No placeholders:** all steps contain complete code, exact commands, and expected output.
