# Native App Profile Sync Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Keep the native Claude desktop app (Electron, `com.anthropic.claudefordesktop`) synced with the profile active in Claude Account Switcher, by giving each profile a second `desktop/` data directory and quitting/relaunching the app with `--user-data-dir` pointed at it on every profile switch.

**Architecture:** A new `DesktopAppClient` protocol (implemented by `SystemDesktopAppClient` using `NSWorkspace`/`NSRunningApplication`) is wrapped by a `DesktopAppActivator` actor that quits the running desktop app and relaunches it against the target profile's `desktop/` directory. `ActivationService.activate(_:)` calls it after the existing CLI-side activation succeeds, and its result never rolls back the CLI switch. `MigrationService` gains a step to detect a real existing session in the default desktop app data directory and copy it into a chosen profile's `desktop/` folder.

**Tech Stack:** Swift 6, Swift Package Manager, AppKit (`NSWorkspace`, `NSRunningApplication`), the project's custom executable test runner (no XCTest).

## Global Constraints

- macOS 13 Ventura minimum, Apple Silicon and Intel (from the existing `Package.swift` and design doc).
- No AppleScript / `osascript` / Apple Events — use `NSWorkspace`/`NSRunningApplication` only, so no Automation permission prompt is ever shown (spec acceptance criterion 5).
- A failure to quit/relaunch the desktop app must never roll back or block the CLI-side profile switch (spec acceptance criterion 3).
- Absence of the installed desktop app must never block or error the CLI-side profile switch (spec acceptance criterion 2).
- Managed directories use `0o700` permissions, matching `ProfileStore.createManagedDirectory` (existing convention).
- All new/changed public types live in `ClaudeAccountSwitcherCore` (the target with no UI dependencies); UI wiring lives in `ClaudeAccountSwitcherApp`.
- Tests are added to `Tests/ClaudeAccountSwitcherTests/ProfileStoreTests.swift` by appending new `static func test...()` cases to the `tests` array in `ProfileStoreTests.main()` — this project has one flat test file/runner, not per-file suites.
- Run tests with `swift run ClaudeAccountSwitcherTests` from `/Users/pedrocardoso/Develop/ClaudeAccountSwitcher/.worktrees/claude-account-switcher`.

---

## Task 1: `Profile.desktopDirectory`

**Files:**
- Modify: `Sources/ClaudeAccountSwitcherCore/Domain/Profile.swift`
- Test: `Tests/ClaudeAccountSwitcherTests/ProfileStoreTests.swift`

**Interfaces:**
- Produces: `Profile.desktopDirectory: URL` — sibling of `directory`, `directory.deletingLastPathComponent().appendingPathComponent("desktop", isDirectory: true)`. Used by `DesktopAppActivator` (Task 3) and `MigrationService` (Task 5).

- [ ] **Step 1: Write the failing test**

Add this case to the `tests` array in `ProfileStoreTests.main()` (near `testProfileRoundTrip`):

```swift
("profile derives a sibling desktop directory from its config directory", testDesktopDirectory),
```

Add the test function:

```swift
static func testDesktopDirectory() throws {
    let configDir = URL(fileURLWithPath: "/tmp/Profiles/AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA/config")
    let profile = Profile(name: "Work", directory: configDir)
    try check(profile.desktopDirectory.path == "/tmp/Profiles/AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA/desktop", "desktop directory was not derived as a sibling of the config directory")
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift run ClaudeAccountSwitcherTests`
Expected: `FAIL profile derives a sibling desktop directory from its config directory: ...` (compile error, since `desktopDirectory` doesn't exist yet — that's an acceptable "fails" for this step since the property is genuinely missing)

- [ ] **Step 3: Write minimal implementation**

In `Sources/ClaudeAccountSwitcherCore/Domain/Profile.swift`, add this computed property inside `public struct Profile`, after the `usage` field declaration and before `public init`:

```swift
    public var desktopDirectory: URL { directory.deletingLastPathComponent().appendingPathComponent("desktop", isDirectory: true) }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift run ClaudeAccountSwitcherTests`
Expected: `N tests passed` with no `FAIL` lines, including `PASS profile derives a sibling desktop directory from its config directory`

- [ ] **Step 5: Commit**

```bash
git add Sources/ClaudeAccountSwitcherCore/Domain/Profile.swift Tests/ClaudeAccountSwitcherTests/ProfileStoreTests.swift
git commit -m "feat: derive desktop app data directory from profile config directory"
```

---

## Task 2: `DesktopAppClient` protocol + fake for tests

**Files:**
- Create: `Sources/ClaudeAccountSwitcherCore/Infrastructure/DesktopAppClient.swift`
- Test: `Tests/ClaudeAccountSwitcherTests/ProfileStoreTests.swift`

**Interfaces:**
- Consumes: nothing new (only `Foundation`/`AppKit`).
- Produces:
  - `public protocol DesktopAppClient: Sendable { func locateBundle() -> URL?; func isRunning() -> Bool; func terminate(timeout: TimeInterval) -> Bool; func launch(bundleURL: URL, userDataDirectory: URL) throws }`
  - `public struct SystemDesktopAppClient: DesktopAppClient` (production implementation, bundle identifier `"com.anthropic.claudefordesktop"`)
  - Used by `DesktopAppActivator` (Task 3).

This task only adds the protocol and the real (system) implementation. The fake implementation used by tests is written in Task 3, alongside the tests that exercise it, since a fake with no consumer is dead code.

- [ ] **Step 1: Write the failing test**

Add this case to the `tests` array in `ProfileStoreTests.main()`:

```swift
("system desktop app client resolves the bundle identifier constant", testSystemDesktopAppClientBundleIdentifier),
```

Add the test function. This only checks the constant is correct and stable — actually launching/terminating the real desktop app is out of scope for automated tests (covered by manual validation in Task 6):

```swift
static func testSystemDesktopAppClientBundleIdentifier() throws {
    try check(SystemDesktopAppClient.bundleIdentifier == "com.anthropic.claudefordesktop", "desktop app bundle identifier changed unexpectedly")
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift run ClaudeAccountSwitcherTests`
Expected: compile failure — `SystemDesktopAppClient` does not exist yet.

- [ ] **Step 3: Write minimal implementation**

Create `Sources/ClaudeAccountSwitcherCore/Infrastructure/DesktopAppClient.swift`:

```swift
import AppKit
import Foundation

public protocol DesktopAppClient: Sendable {
    func locateBundle() -> URL?
    func isRunning() -> Bool
    func terminate(timeout: TimeInterval) -> Bool
    func launch(bundleURL: URL, userDataDirectory: URL) throws
}

public struct SystemDesktopAppClient: DesktopAppClient {
    public static let bundleIdentifier = "com.anthropic.claudefordesktop"
    public init() {}

    public func locateBundle() -> URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: Self.bundleIdentifier)
    }

    public func isRunning() -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleIdentifier).isEmpty
    }

    public func terminate(timeout: TimeInterval) -> Bool {
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleIdentifier)
        guard !running.isEmpty else { return true }
        running.forEach { $0.terminate() }
        if waitUntilTerminated(within: timeout) { return true }
        NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleIdentifier).forEach { $0.forceTerminate() }
        return waitUntilTerminated(within: 2)
    }

    private func waitUntilTerminated(within timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleIdentifier).isEmpty { return true }
            Thread.sleep(forTimeInterval: 0.2)
        }
        return NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleIdentifier).isEmpty
    }

    public func launch(bundleURL: URL, userDataDirectory: URL) throws {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.arguments = ["--user-data-dir=\(userDataDirectory.path)"]
        configuration.createsNewApplicationInstance = true
        let semaphore = DispatchSemaphore(value: 0)
        var launchError: Error?
        NSWorkspace.shared.openApplication(at: bundleURL, configuration: configuration) { _, error in
            launchError = error
            semaphore.signal()
        }
        semaphore.wait()
        if let launchError { throw launchError }
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift run ClaudeAccountSwitcherTests`
Expected: `N tests passed`, including `PASS system desktop app client resolves the bundle identifier constant`

- [ ] **Step 5: Commit**

```bash
git add Sources/ClaudeAccountSwitcherCore/Infrastructure/DesktopAppClient.swift Tests/ClaudeAccountSwitcherTests/ProfileStoreTests.swift
git commit -m "feat: add DesktopAppClient protocol and NSWorkspace-based implementation"
```

---

## Task 3: `DesktopAppActivator` actor

**Files:**
- Create: `Sources/ClaudeAccountSwitcherCore/Infrastructure/DesktopAppActivator.swift`
- Test: `Tests/ClaudeAccountSwitcherTests/ProfileStoreTests.swift`

**Interfaces:**
- Consumes: `DesktopAppClient` (Task 2), `Profile.desktopDirectory` (Task 1).
- Produces:
  - `public enum DesktopAppSkipReason: Equatable, Sendable { case appNotInstalled }`
  - `public enum DesktopAppSyncResult: Equatable, Sendable { case synced; case skipped(DesktopAppSkipReason); case failed(String) }`
  - `public actor DesktopAppActivator { public init(client: DesktopAppClient = SystemDesktopAppClient()); public func sync(to profile: Profile) -> DesktopAppSyncResult }`
  - Used by `ActivationService` (Task 4).

- [ ] **Step 1: Write the failing tests**

Add these four cases to the `tests` array in `ProfileStoreTests.main()`:

```swift
("desktop activator skips when the app is not installed", testDesktopActivatorSkipsWhenAppMissing),
("desktop activator terminates the running app then launches with the profile directory", testDesktopActivatorTerminatesAndLaunches),
("desktop activator reports failure when termination times out", testDesktopActivatorReportsTerminationFailure),
("desktop activator reports failure when launch throws", testDesktopActivatorReportsLaunchFailure),
```

Add a fake client and the test functions:

```swift
final class FakeDesktopAppClient: DesktopAppClient, @unchecked Sendable {
    var bundleURL: URL? = URL(fileURLWithPath: "/Applications/Claude.app")
    var running = true
    var terminateSucceeds = true
    var launchError: Error?
    var terminateCallCount = 0
    var launchedWith: (bundleURL: URL, userDataDirectory: URL)?

    func locateBundle() -> URL? { bundleURL }
    func isRunning() -> Bool { running }
    func terminate(timeout: TimeInterval) -> Bool { terminateCallCount += 1; if terminateSucceeds { running = false }; return terminateSucceeds }
    func launch(bundleURL: URL, userDataDirectory: URL) throws {
        if let launchError { throw launchError }
        launchedWith = (bundleURL, userDataDirectory)
    }
}

static func testDesktopActivatorSkipsWhenAppMissing() async throws {
    let client = FakeDesktopAppClient(); client.bundleURL = nil
    let activator = DesktopAppActivator(client: client)
    let profile = Profile(name: "Work", directory: URL(fileURLWithPath: "/tmp/Profiles/id/config"))
    let result = await activator.sync(to: profile)
    try check(result == .skipped(.appNotInstalled), "expected skip when the desktop app is not installed")
    try check(client.launchedWith == nil, "launch should not be attempted when the app is not installed")
}

static func testDesktopActivatorTerminatesAndLaunches() async throws {
    let client = FakeDesktopAppClient(); client.running = true
    let activator = DesktopAppActivator(client: client)
    let profile = Profile(name: "Work", directory: URL(fileURLWithPath: "/tmp/Profiles/id/config"))
    let result = await activator.sync(to: profile)
    try check(result == .synced, "expected a successful sync")
    try check(client.terminateCallCount == 1, "the running instance was not terminated before relaunching")
    try check(client.launchedWith?.userDataDirectory.path == profile.desktopDirectory.path, "launch did not target the profile's desktop directory")
    try check(FileManager.default.fileExists(atPath: profile.desktopDirectory.path), "desktop directory was not created before launch")
    try? FileManager.default.removeItem(at: profile.desktopDirectory)
}

static func testDesktopActivatorReportsTerminationFailure() async throws {
    let client = FakeDesktopAppClient(); client.running = true; client.terminateSucceeds = false
    let activator = DesktopAppActivator(client: client)
    let profile = Profile(name: "Work", directory: URL(fileURLWithPath: "/tmp/Profiles/id/config"))
    let result = await activator.sync(to: profile)
    guard case .failed = result else { throw TestFailure.failed("expected a failure result when termination times out, got \(result)") }
    try check(client.launchedWith == nil, "launch should not be attempted when termination fails")
}

static func testDesktopActivatorReportsLaunchFailure() async throws {
    let client = FakeDesktopAppClient(); client.running = false; client.launchError = TestFailure.failed("boom")
    let activator = DesktopAppActivator(client: client)
    let profile = Profile(name: "Work", directory: URL(fileURLWithPath: "/tmp/Profiles/id/config"))
    let result = await activator.sync(to: profile)
    guard case .failed = result else { throw TestFailure.failed("expected a failure result when launch throws, got \(result)") }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift run ClaudeAccountSwitcherTests`
Expected: compile failure — `DesktopAppActivator`, `DesktopAppSyncResult`, `DesktopAppSkipReason` do not exist yet.

- [ ] **Step 3: Write minimal implementation**

Create `Sources/ClaudeAccountSwitcherCore/Infrastructure/DesktopAppActivator.swift`:

```swift
import Foundation

public enum DesktopAppSkipReason: Equatable, Sendable { case appNotInstalled }

public enum DesktopAppSyncResult: Equatable, Sendable {
    case synced
    case skipped(DesktopAppSkipReason)
    case failed(String)
}

public actor DesktopAppActivator {
    private let client: DesktopAppClient
    public init(client: DesktopAppClient = SystemDesktopAppClient()) { self.client = client }

    public func sync(to profile: Profile) -> DesktopAppSyncResult {
        guard let bundleURL = client.locateBundle() else { return .skipped(.appNotInstalled) }
        if client.isRunning() {
            guard client.terminate(timeout: 5) else { return .failed("timed out waiting for the desktop app to quit") }
        }
        let directory = profile.desktopDirectory
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try client.launch(bundleURL: bundleURL, userDataDirectory: directory)
            return .synced
        } catch {
            return .failed("\(error)")
        }
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift run ClaudeAccountSwitcherTests`
Expected: `N tests passed`, including all four new `DesktopAppActivator` tests.

- [ ] **Step 5: Commit**

```bash
git add Sources/ClaudeAccountSwitcherCore/Infrastructure/DesktopAppActivator.swift Tests/ClaudeAccountSwitcherTests/ProfileStoreTests.swift
git commit -m "feat: add DesktopAppActivator to quit/relaunch the desktop app for a profile"
```

---

## Task 4: Wire `DesktopAppActivator` into `ActivationService`

**Files:**
- Modify: `Sources/ClaudeAccountSwitcherCore/Infrastructure/ActivationService.swift`
- Test: `Tests/ClaudeAccountSwitcherTests/ProfileStoreTests.swift`

**Interfaces:**
- Consumes: `DesktopAppActivator.sync(to:)` (Task 3).
- Produces:
  - `public struct ActivationResult: Sendable, Equatable { public let profile: Profile; public let desktopSync: DesktopAppSyncResult }`
  - `ActivationService.activate(_:)` now returns `ActivationResult` instead of `Profile`, and is `async`. Consumed by `MenuBarController` (Task 6).

**Current file content** (for reference before editing):

```swift
import Foundation

public enum ActivationError: Error { case missingDirectory, rolledBack(Error) }

public actor ActivationService {
    private let store: ProfileStore
    private let launchd: LaunchdEnvironmentClient
    public init(store: ProfileStore, launchd: LaunchdEnvironmentClient = SystemLaunchdEnvironment()) { self.store = store; self.launchd = launchd }

    public func activate(_ profile: Profile) throws -> Profile {
        guard FileManager.default.fileExists(atPath: profile.directory.path) else { throw ActivationError.missingDirectory }
        let previous = try store.active()
        do {
            try store.setActive(ActiveProfile(id: profile.id, directory: profile.directory))
            try launchd.set(profile.directory.path)
            var updated = profile; updated.lastUsedAt = .now; updated.health = .ready; try store.save(updated)
            return updated
        } catch {
            if let previous { try? store.setActive(previous) }
            else { try? FileManager.default.removeItem(at: store.activeURL) }
            try? launchd.unset()
            throw ActivationError.rolledBack(error)
        }
    }
}
```

- [ ] **Step 1: Write the failing tests**

Add these two cases to the `tests` array in `ProfileStoreTests.main()`:

```swift
("activation syncs the desktop app after a successful CLI switch", testActivationSyncsDesktopApp),
("a desktop app sync failure does not roll back the CLI switch", testActivationDesktopFailureDoesNotRollBackCLI),
```

Add the test functions (they reuse `FakeLaunchd` from `testActivationRollback` and `FakeDesktopAppClient` from Task 3):

```swift
static func testActivationSyncsDesktopApp() async throws {
    let root = try temporaryRoot(); let store = try ProfileStore(root: root)
    let directory = root.appendingPathComponent("config"); try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let profile = Profile(name: "Work", directory: directory); try store.save(profile)
    let desktopClient = FakeDesktopAppClient()
    let service = ActivationService(store: store, launchd: FakeLaunchd(), desktopActivator: DesktopAppActivator(client: desktopClient))
    let result = try await service.activate(profile)
    try check(result.profile.id == profile.id, "activation result did not carry the activated profile")
    try check(result.desktopSync == .synced, "desktop sync did not run after a successful CLI activation")
    try check(desktopClient.launchedWith?.userDataDirectory.path == profile.desktopDirectory.path, "desktop app was not launched with the profile's desktop directory")
    try? FileManager.default.removeItem(at: profile.desktopDirectory)
}

static func testActivationDesktopFailureDoesNotRollBackCLI() async throws {
    let root = try temporaryRoot(); let store = try ProfileStore(root: root)
    let directory = root.appendingPathComponent("config"); try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let profile = Profile(name: "Work", directory: directory); try store.save(profile)
    let desktopClient = FakeDesktopAppClient(); desktopClient.launchError = TestFailure.failed("desktop launch boom")
    let service = ActivationService(store: store, launchd: FakeLaunchd(), desktopActivator: DesktopAppActivator(client: desktopClient))
    let result = try await service.activate(profile)
    guard case .failed = result.desktopSync else { throw TestFailure.failed("expected desktopSync to report failure") }
    try check(try store.active()?.id == profile.id, "CLI-side activation was rolled back after a desktop sync failure")
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift run ClaudeAccountSwitcherTests`
Expected: compile failure — `ActivationResult` doesn't exist and `ActivationService.init` doesn't accept `desktopActivator:` yet.

- [ ] **Step 3: Write minimal implementation**

Replace the full content of `Sources/ClaudeAccountSwitcherCore/Infrastructure/ActivationService.swift` with:

```swift
import Foundation

public enum ActivationError: Error { case missingDirectory, rolledBack(Error) }

public struct ActivationResult: Sendable, Equatable {
    public let profile: Profile
    public let desktopSync: DesktopAppSyncResult
}

public actor ActivationService {
    private let store: ProfileStore
    private let launchd: LaunchdEnvironmentClient
    private let desktopActivator: DesktopAppActivator
    public init(store: ProfileStore, launchd: LaunchdEnvironmentClient = SystemLaunchdEnvironment(), desktopActivator: DesktopAppActivator = DesktopAppActivator()) {
        self.store = store; self.launchd = launchd; self.desktopActivator = desktopActivator
    }

    public func activate(_ profile: Profile) async throws -> ActivationResult {
        guard FileManager.default.fileExists(atPath: profile.directory.path) else { throw ActivationError.missingDirectory }
        let previous = try store.active()
        let updated: Profile
        do {
            try store.setActive(ActiveProfile(id: profile.id, directory: profile.directory))
            try launchd.set(profile.directory.path)
            var candidate = profile; candidate.lastUsedAt = .now; candidate.health = .ready; try store.save(candidate)
            updated = candidate
        } catch {
            if let previous { try? store.setActive(previous) }
            else { try? FileManager.default.removeItem(at: store.activeURL) }
            try? launchd.unset()
            throw ActivationError.rolledBack(error)
        }
        let desktopSync = await desktopActivator.sync(to: updated)
        return ActivationResult(profile: updated, desktopSync: desktopSync)
    }
}
```

Note `Equatable` on `ActivationResult` requires `Profile` and `DesktopAppSyncResult` to already be `Equatable` — both already are (`Profile: Equatable` in Task 1's file, `DesktopAppSyncResult: Equatable` from Task 3).

- [ ] **Step 4: Run test to verify it passes**

Run: `swift run ClaudeAccountSwitcherTests`
Expected: `N tests passed`, including `PASS activation syncs the desktop app after a successful CLI switch` and `PASS a desktop app sync failure does not roll back the CLI switch`. The pre-existing `testActivationRollback` must still pass unchanged (it throws before reaching the desktop sync call).

- [ ] **Step 5: Commit**

```bash
git add Sources/ClaudeAccountSwitcherCore/Infrastructure/ActivationService.swift Tests/ClaudeAccountSwitcherTests/ProfileStoreTests.swift
git commit -m "feat: sync the desktop app after a successful profile activation"
```

---

## Task 5: `MigrationService` imports the existing desktop app session

**Files:**
- Modify: `Sources/ClaudeAccountSwitcherCore/Infrastructure/MigrationService.swift`
- Test: `Tests/ClaudeAccountSwitcherTests/ProfileStoreTests.swift`

**Interfaces:**
- Consumes: `ProfileStore.createManagedDirectory(id:)` (existing).
- Produces:
  - `MigrationPlan` gains `public let desktopSource: URL?` (defaults to `nil` via a new initializer parameter with default value, so `MigrationPlan(sources:aliases:)` call sites elsewhere keep compiling — check no other call site exists before assuming this, see Step 3 note).
  - `MigrationService.execute(_:desktopTarget:)` — new optional `desktopTarget: URL?` parameter (defaults to `nil`), naming which entry of `plan.sources` should receive the imported desktop session.
  - `MigrationService.preview(home:)` now also detects and returns `desktopSource`.

**Current file content** (for reference before editing):

```swift
import Foundation
import CryptoKit

public struct MigrationPlan: Sendable { public let sources: [URL]; public let aliases: [String]; public init(sources: [URL], aliases: [String]) { self.sources = sources; self.aliases = aliases } }
public struct MigrationReport: Sendable { public let imported: [URL]; public let backups: [URL]; public let aliases: [String] }

public struct MigrationService: Sendable {
    public let store: ProfileStore
    public init(store: ProfileStore) { self.store = store }
    public func preview(home: URL) throws -> MigrationPlan {
        let fm = FileManager.default
        let candidates = [home.appendingPathComponent(".claude"), home.appendingPathComponent(".claude-work")].filter { fm.fileExists(atPath: $0.path) }
        let zshrc = (try? String(contentsOf: home.appendingPathComponent(".zshrc"), encoding: .utf8)) ?? ""
        return MigrationPlan(sources: candidates, aliases: zshrc.components(separatedBy: .newlines).filter { $0.contains("alias claude-work=") || $0.contains("alias code-work=") || $0.contains("alias zed-work=") })
    }
    public func execute(_ plan: MigrationPlan) throws -> MigrationReport {
        let fm = FileManager.default; var imported: [URL] = []
        for source in plan.sources {
            let id = UUID(); let destination = try store.createManagedDirectory(id: id)
            let entries = try fm.contentsOfDirectory(at: source, includingPropertiesForKeys: [.isSymbolicLinkKey], options: [])
            for entry in entries {
                if (try entry.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true { throw NSError(domain: "ClaudeAccountSwitcher", code: 1001, userInfo: [NSLocalizedDescriptionKey: "symbolic links are not imported"]) }
                try fm.copyItem(at: entry, to: destination.appendingPathComponent(entry.lastPathComponent))
            }
            try store.save(Profile(id: id, name: source.lastPathComponent == ".claude" ? "Claude pessoal" : "Claude work", kind: .custom, directory: destination, health: .unknown))
            imported.append(destination)
        }
        return MigrationReport(imported: imported, backups: [], aliases: plan.aliases)
    }

    public func cleanupRecognizedAliases(home: URL, confirmed: Bool) throws {
        guard confirmed else { return }
        let file = home.appendingPathComponent(".zshrc")
        guard let content = try? String(contentsOf: file, encoding: .utf8) else { return }
        let lines = content.split(separator: "\n", omittingEmptySubsequences: false).filter { line in
            !(line.contains("alias claude-work=") || line.contains("alias code-work=") || line.contains("alias zed-work="))
        }
        try lines.joined(separator: "\n").data(using: .utf8)!.write(to: file, options: .atomic)
    }
}
```

- [ ] **Step 1: Write the failing tests**

Add these three cases to the `tests` array in `ProfileStoreTests.main()`:

```swift
("migration detects a real desktop app session but not an empty one", testMigrationDetectsDesktopSession),
("migration imports the desktop app session into the chosen profile", testMigrationImportsDesktopSession),
("migration preview finds no desktop session when the folder is absent", testMigrationNoDesktopSessionWhenAbsent),
```

Add the test functions:

```swift
static func testMigrationDetectsDesktopSession() throws {
    let home = try temporaryRoot()
    let desktopDir = home.appendingPathComponent("Library/Application Support/Claude")
    try FileManager.default.createDirectory(at: desktopDir, withIntermediateDirectories: true)
    try "config only, no session".write(to: desktopDir.appendingPathComponent("config.json"), atomically: true, encoding: .utf8)
    let emptyStore = try ProfileStore(root: home.appendingPathComponent("managed-empty"))
    let emptyPlan = try MigrationService(store: emptyStore).preview(home: home)
    try check(emptyPlan.desktopSource == nil, "a config.json-only directory should not be treated as a real session")

    try "cookie-bytes".write(to: desktopDir.appendingPathComponent("Cookies"), atomically: true, encoding: .utf8)
    let store = try ProfileStore(root: home.appendingPathComponent("managed"))
    let plan = try MigrationService(store: store).preview(home: home)
    try check(plan.desktopSource?.path == desktopDir.path, "a directory with a non-empty Cookies file should be treated as a real session")
}

static func testMigrationImportsDesktopSession() throws {
    let home = try temporaryRoot()
    let source = home.appendingPathComponent(".claude")
    try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
    try "cli config".write(to: source.appendingPathComponent(".claude.json"), atomically: true, encoding: .utf8)
    let desktopDir = home.appendingPathComponent("Library/Application Support/Claude")
    try FileManager.default.createDirectory(at: desktopDir, withIntermediateDirectories: true)
    try "cookie-bytes".write(to: desktopDir.appendingPathComponent("Cookies"), atomically: true, encoding: .utf8)

    let store = try ProfileStore(root: home.appendingPathComponent("managed"))
    let service = MigrationService(store: store)
    let plan = try service.preview(home: home)
    let report = try service.execute(plan, desktopTarget: source)

    let importedDesktopDir = report.imported[0].deletingLastPathComponent().appendingPathComponent("desktop")
    try check(FileManager.default.fileExists(atPath: importedDesktopDir.appendingPathComponent("Cookies").path), "desktop session was not copied into the target profile's desktop directory")
    try check(FileManager.default.fileExists(atPath: desktopDir.appendingPathComponent("Cookies").path), "original desktop app data was modified or removed")
}

static func testMigrationNoDesktopSessionWhenAbsent() throws {
    let home = try temporaryRoot()
    let store = try ProfileStore(root: home.appendingPathComponent("managed"))
    let plan = try MigrationService(store: store).preview(home: home)
    try check(plan.desktopSource == nil, "no desktop source should be found when the default data directory does not exist")
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift run ClaudeAccountSwitcherTests`
Expected: compile failure — `MigrationPlan.desktopSource` and `execute(_:desktopTarget:)` don't exist yet.

- [ ] **Step 3: Write minimal implementation**

First, confirm no other call site constructs `MigrationPlan(sources:aliases:)` directly (only `preview` does, inside this same file):

```bash
grep -rn "MigrationPlan(" Sources Tests
```

Expected: only the one inside `MigrationService.preview`. Then replace the full content of `Sources/ClaudeAccountSwitcherCore/Infrastructure/MigrationService.swift` with:

```swift
import Foundation
import CryptoKit

public struct MigrationPlan: Sendable {
    public let sources: [URL]
    public let aliases: [String]
    public let desktopSource: URL?
    public init(sources: [URL], aliases: [String], desktopSource: URL? = nil) { self.sources = sources; self.aliases = aliases; self.desktopSource = desktopSource }
}
public struct MigrationReport: Sendable { public let imported: [URL]; public let backups: [URL]; public let aliases: [String] }

public struct MigrationService: Sendable {
    public let store: ProfileStore
    public init(store: ProfileStore) { self.store = store }

    public func preview(home: URL) throws -> MigrationPlan {
        let fm = FileManager.default
        let candidates = [home.appendingPathComponent(".claude"), home.appendingPathComponent(".claude-work")].filter { fm.fileExists(atPath: $0.path) }
        let zshrc = (try? String(contentsOf: home.appendingPathComponent(".zshrc"), encoding: .utf8)) ?? ""
        let desktopAppData = home.appendingPathComponent("Library/Application Support/Claude")
        let desktopSource = MigrationService.hasRealDesktopSession(at: desktopAppData) ? desktopAppData : nil
        return MigrationPlan(sources: candidates, aliases: zshrc.components(separatedBy: .newlines).filter { $0.contains("alias claude-work=") || $0.contains("alias code-work=") || $0.contains("alias zed-work=") }, desktopSource: desktopSource)
    }

    static func hasRealDesktopSession(at directory: URL) -> Bool {
        let fm = FileManager.default
        let cookies = directory.appendingPathComponent("Cookies")
        if let attributes = try? fm.attributesOfItem(atPath: cookies.path), let size = attributes[.size] as? Int, size > 0 { return true }
        let localStorage = directory.appendingPathComponent("Local Storage/leveldb")
        if let entries = try? fm.contentsOfDirectory(atPath: localStorage.path), !entries.isEmpty { return true }
        return false
    }

    public func execute(_ plan: MigrationPlan, desktopTarget: URL? = nil) throws -> MigrationReport {
        let fm = FileManager.default; var imported: [URL] = []
        for source in plan.sources {
            let id = UUID(); let destination = try store.createManagedDirectory(id: id)
            let entries = try fm.contentsOfDirectory(at: source, includingPropertiesForKeys: [.isSymbolicLinkKey], options: [])
            for entry in entries {
                if (try entry.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true { throw NSError(domain: "ClaudeAccountSwitcher", code: 1001, userInfo: [NSLocalizedDescriptionKey: "symbolic links are not imported"]) }
                try fm.copyItem(at: entry, to: destination.appendingPathComponent(entry.lastPathComponent))
            }
            try store.save(Profile(id: id, name: source.lastPathComponent == ".claude" ? "Claude pessoal" : "Claude work", kind: .custom, directory: destination, health: .unknown))
            imported.append(destination)
            if let desktopSource = plan.desktopSource, source == desktopTarget {
                let desktopDestination = destination.deletingLastPathComponent().appendingPathComponent("desktop", isDirectory: true)
                try fm.createDirectory(at: desktopDestination, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                let desktopEntries = try fm.contentsOfDirectory(at: desktopSource, includingPropertiesForKeys: [.isSymbolicLinkKey], options: [])
                for entry in desktopEntries {
                    if (try entry.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true { throw NSError(domain: "ClaudeAccountSwitcher", code: 1001, userInfo: [NSLocalizedDescriptionKey: "symbolic links are not imported"]) }
                    try fm.copyItem(at: entry, to: desktopDestination.appendingPathComponent(entry.lastPathComponent))
                }
            }
        }
        return MigrationReport(imported: imported, backups: [], aliases: plan.aliases)
    }

    public func cleanupRecognizedAliases(home: URL, confirmed: Bool) throws {
        guard confirmed else { return }
        let file = home.appendingPathComponent(".zshrc")
        guard let content = try? String(contentsOf: file, encoding: .utf8) else { return }
        let lines = content.split(separator: "\n", omittingEmptySubsequences: false).filter { line in
            !(line.contains("alias claude-work=") || line.contains("alias code-work=") || line.contains("alias zed-work="))
        }
        try lines.joined(separator: "\n").data(using: .utf8)!.write(to: file, options: .atomic)
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift run ClaudeAccountSwitcherTests`
Expected: `N tests passed`, including the three new migration tests. The pre-existing `testMigration` must still pass unchanged.

- [ ] **Step 5: Commit**

```bash
git add Sources/ClaudeAccountSwitcherCore/Infrastructure/MigrationService.swift Tests/ClaudeAccountSwitcherTests/ProfileStoreTests.swift
git commit -m "feat: detect and import the existing desktop app session during migration"
```

---

## Task 6: Wire `MenuBarController` to the new `ActivationResult` and surface desktop sync outcome

**Files:**
- Modify: `Sources/ClaudeAccountSwitcherApp/MenuBarController.swift:78-81` (`selectProfile`)
- Modify: `Sources/ClaudeAccountSwitcherApp/MenuBarController.swift:237-242` (`activateFromPreferences`)
- Modify: `Sources/ClaudeAccountSwitcherApp/MenuBarController.swift:275-284` (`removeFromPreferences`)

**Interfaces:**
- Consumes: `ActivationService.activate(_:) async throws -> ActivationResult` (Task 4), `DesktopAppSyncResult` (Task 3).

This task has no new automated test: `MenuBarController` is `@MainActor` UI glue with no existing test coverage in this project (confirmed — `ProfileStoreTests` only covers `ClaudeAccountSwitcherCore`). It's covered by the manual validation checklist at the end of this task.

- [ ] **Step 1: Add a shared notification helper for activation results**

In `Sources/ClaudeAccountSwitcherApp/MenuBarController.swift`, add this private method right after the existing `notify(_:)` method (currently at line 310):

```swift
    private func notify(activationResult result: ActivationResult) {
        switch result.desktopSync {
        case .synced:
            notify(AppStrings.t("Perfil ativo: \(result.profile.name) (app nativo reaberto)", "Active profile: \(result.profile.name) (native app reopened)"))
        case .skipped:
            notify(AppStrings.t("Perfil ativo: \(result.profile.name)", "Active profile: \(result.profile.name)"))
        case .failed:
            notify(AppStrings.t("Perfil ativo: \(result.profile.name) — não consegui reabrir o app nativo, abra manualmente", "Active profile: \(result.profile.name) — could not reopen the native app, open it manually"))
        }
    }
```

- [ ] **Step 2: Update `selectProfile`**

Replace line 80:

```swift
        Task { do { _ = try await activation.activate(profile); rebuildMenu(); notify(AppStrings.t("Perfil ativo: \(profile.name)", "Active profile: \(profile.name)")) } catch { showError(error) } }
```

with:

```swift
        Task { do { let result = try await activation.activate(profile); rebuildMenu(); notify(activationResult: result) } catch { showError(error) } }
```

- [ ] **Step 3: Update `activateFromPreferences`**

Replace line 239:

```swift
            do { _ = try await activation.activate(profile); rebuildMenu(); refreshPreferences(); notify("Perfil ativo: \(profile.name)") }
```

with:

```swift
            do { let result = try await activation.activate(profile); rebuildMenu(); refreshPreferences(); notify(activationResult: result) }
```

- [ ] **Step 4: Update `removeFromPreferences`**

Line 278 (`_ = try await activation.activate(replacement)`) discards the result on purpose — removal already shows its own "Perfil removido" notification and switching the replacement profile's desktop app here would fire two competing notifications. Leave this line unchanged (`_ = try await activation.activate(replacement)`); it now returns `ActivationResult` instead of `Profile`, which still type-checks since the result is discarded.

- [ ] **Step 5: Build to verify everything type-checks**

Run: `swift build -c release --product ClaudeAccountSwitcher`
Expected: build succeeds with no errors.

Run: `swift run ClaudeAccountSwitcherTests`
Expected: `N tests passed` (full suite, unaffected by this UI-only task).

- [ ] **Step 6: Commit**

```bash
git add Sources/ClaudeAccountSwitcherApp/MenuBarController.swift
git commit -m "feat: surface desktop app sync outcome in profile switch notifications"
```

- [ ] **Step 7: Manual validation on the Mac**

Follow these steps against the real app (build first with `./Scripts/build-app.sh` and reinstall with `./Scripts/install-dev.sh` per the project README):

1. Switch profile from the menu bar and confirm the native Claude.app quits and reopens, landing on the chosen profile's `desktop/` directory (check via `ps -ww -p <pid> -o command=` that `--user-data-dir` points at `Profiles/<uuid>/desktop`).
2. Switch to a profile that has never had a desktop session — confirm the app opens on its normal login screen instead of erroring.
3. Temporarily rename `/Applications/Claude.app` and switch profiles — confirm the CLI-side switch still succeeds and a "could not reopen" notification appears, without the CLI switch being rolled back (verify with `claude auth status --json` in a new shell).
4. Run the first-use migration flow with a copy of a real `~/Library/Application Support/Claude` directory and confirm it's offered and imported as the `desktop/` folder of the chosen profile, without modifying the original directory.
5. Confirm no macOS Automation permission prompt ever appears for Claude Account Switcher controlling Claude.app.

---

## Self-Review Notes

- **Spec coverage:** acceptance criterion 1 (quit/relaunch on switch) → Tasks 3, 4, 6. Criterion 2 (missing app never blocks CLI) → Task 3 (`skipped(.appNotInstalled)` short-circuits before any CLI-affecting call) + Task 4 test `testActivationSyncsDesktopApp` pattern reused for the missing-app case is implicitly covered since `sync` never touches `store`/`launchd`. Criterion 3 (desktop failure never rolls back CLI) → Task 4's `testActivationDesktopFailureDoesNotRollBackCLI`. Criterion 4 (migration imports existing session) → Task 5. Criterion 5 (no Automation permission) → Task 2's `SystemDesktopAppClient` uses only `NSWorkspace`/`NSRunningApplication`, never `NSAppleScript`/`osascript`.
- **Placeholder scan:** none found; every step has literal code and exact commands.
- **Type consistency:** `Profile.desktopDirectory` (Task 1) is the single source of truth used identically in `DesktopAppActivator.sync` (Task 3) and `MigrationService.execute` (Task 5, which builds the same `desktop` sibling path manually since it operates on a managed directory URL before a `Profile` exists — verified both use `deletingLastPathComponent().appendingPathComponent("desktop", isDirectory: true)`). `ActivationResult` (Task 4) is consumed with matching field names (`profile`, `desktopSync`) in Task 6.
