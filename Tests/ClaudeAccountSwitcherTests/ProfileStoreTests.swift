import Foundation
import ClaudeAccountSwitcherCore
import Darwin

enum TestFailure: Error, CustomStringConvertible {
    case failed(String)
    var description: String { if case .failed(let message) = self { return message }; return "test failed" }
}

@main
enum ProfileStoreTests {
    static func main() async {
        let tests: [(String, () async throws -> Void)] = [
            ("profile JSON round trip", testProfileRoundTrip),
            ("profile derives a sibling desktop directory from its config directory", testDesktopDirectory),
            ("store persists profiles and active profile", testStorePersists),
            ("store renames a profile without changing its identity", testRenameProfile),
            ("store removes profile data", testRemoveProfile),
            ("store serializes concurrent saves without losing profiles", testConcurrentSaves),
            ("managed directory permissions", testManagedDirectory)
            ,("process runner preserves environment", testProcessRunner)
            ,("shell integration is idempotent", testShellIntegration)
            ,("activation rolls back on launchd failure", testActivationRollback)
            ,("migration preserves hidden Claude files", testMigration)
            ,("legacy active state is migrated", testLegacyActiveState)
            ,("launcher selects active profile", testLauncher)
            ,("system desktop app client resolves the bundle identifier constant", testSystemDesktopAppClientBundleIdentifier)
            ,("desktop activator skips when the app is not installed", testDesktopActivatorSkipsWhenAppMissing)
            ,("desktop activator terminates the running app then launches with the profile directory", testDesktopActivatorTerminatesAndLaunches)
            ,("desktop activator reports failure when termination times out", testDesktopActivatorReportsTerminationFailure)
            ,("desktop activator reports failure when launch throws", testDesktopActivatorReportsLaunchFailure)
            ,("activation syncs the desktop app after a successful CLI switch", testActivationSyncsDesktopApp)
            ,("a desktop app sync failure does not roll back the CLI switch", testActivationDesktopFailureDoesNotRollBackCLI)
            ,("migration detects a real desktop app session but not an empty one", testMigrationDetectsDesktopSession)
            ,("migration imports the desktop app session into the chosen profile", testMigrationImportsDesktopSession)
            ,("migration preview finds no desktop session when the folder is absent", testMigrationNoDesktopSessionWhenAbsent)
            ,("copies the default desktop session into a profile that has none yet", testCopyDefaultDesktopSessionIntoFreshProfile)
            ,("does not overwrite a profile that already has a real desktop session", testCopyDefaultDesktopSessionSkipsExistingSession)
            ,("does not copy when the default desktop directory has no real session", testCopyDefaultDesktopSessionSkipsWhenSourceEmpty)
            ,("5h alert fires once per threshold crossing and rearms below it", testFiveHourAlertTracker)
            ,("5h alert threshold falls back to default when invalid", testFiveHourAlertThreshold)
            ,("5h alert sound falls back to default when unknown", testFiveHourAlertSound)
            ,("weekly credits alert fires within 24h of reset when credits remain above threshold", testWeeklyCreditsAlertTracker)
            ,("weekly credits alert does not fire outside the 24h window", testWeeklyCreditsAlertOutsideWindow)
            ,("weekly credits alert does not fire below the credits threshold", testWeeklyCreditsAlertBelowThreshold)
            ,("weekly credits alert rearms when resetAt changes", testWeeklyCreditsAlertRearmsOnRenewal)
            ,("weekly credits alert tracks profiles independently", testWeeklyCreditsAlertPerProfile)
            ,("weekly credits threshold falls back to default when invalid", testWeeklyCreditsAlertThreshold)
            ,("usage reset date parses fractional and plain ISO timestamps", testUsageResetDateParsing)
            ,("activation skips desktop sync when disabled", testActivationSkipsDesktopWhenDisabled)
            ,("paseo integration is not detected without a config file", testPaseoNotDetectedWithoutConfig)
            ,("paseo symlink re-targets atomically on repeated switches", testPaseoSymlinkRetargets)
            ,("paseo integrate points the claude provider at the symlink and preserves other providers", testPaseoIntegrateSetsClaudeProviderEnv)
            ,("paseo integrate backs up the original config before writing", testPaseoIntegrateBacksUpOriginal)
            ,("activation updates the paseo symlink alongside launchd", testActivationUpdatesPaseoSymlink)
        ]
        var failures = 0
        for (name, test) in tests {
            do { try await test(); print("PASS \(name)") }
            catch { failures += 1; print("FAIL \(name): \(error)") }
        }
        if failures > 0 { print("\(failures) test(s) failed"); Darwin.exit(1) }
        print("\(tests.count) tests passed")
    }

    static func testFiveHourAlertTracker() throws {
        var tracker = FiveHourAlertTracker()
        try check(tracker.evaluate(usedPercent: 50, threshold: 80) == false, "should not fire below threshold")
        try check(tracker.evaluate(usedPercent: 80, threshold: 80) == true, "should fire on first crossing")
        try check(tracker.evaluate(usedPercent: 92, threshold: 80) == false, "should not fire again while still above")
        try check(tracker.evaluate(usedPercent: 10, threshold: 80) == false, "dropping below only rearms")
        try check(tracker.evaluate(usedPercent: 85, threshold: 80) == true, "should fire again after rearming")
    }

    static func testFiveHourAlertThreshold() throws {
        try check(FiveHourAlertThreshold.resolve(0) == 80, "zero should fall back to default")
        try check(FiveHourAlertThreshold.resolve(150) == 80, "out-of-range should fall back to default")
        try check(FiveHourAlertThreshold.resolve(55) == 55, "valid threshold should be kept")
    }

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
        let laterNow = secondReset.addingTimeInterval(-12 * 3600)
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

    static func testFiveHourAlertSound() throws {
        try check(FiveHourAlertSound(defaultsValue: nil) == .standard, "missing sound should default")
        try check(FiveHourAlertSound(defaultsValue: "bogus") == .standard, "unknown sound should default")
        try check(FiveHourAlertSound(defaultsValue: "glass") == .glass, "known sound should be parsed")
    }

    static func testUsageResetDateParsing() throws {
        // The real endpoint sends microsecond fractional seconds, which the default formatter rejects.
        let fractional = ClaudeUsageService.parseResetDate("2026-07-20T22:40:00.121846+00:00")
        try check(fractional != nil, "fractional-second ISO timestamp should parse")
        let plain = ClaudeUsageService.parseResetDate("2026-07-20T22:40:00Z")
        try check(plain != nil, "plain ISO timestamp should still parse")
        try check(ClaudeUsageService.parseResetDate(nil) == nil, "nil should stay nil")
        try check(ClaudeUsageService.parseResetDate("not a date") == nil, "garbage should not parse")
    }

    static func testPaseoNotDetectedWithoutConfig() throws {
        let root = try temporaryRoot()
        let paseo = PaseoIntegration(appSupport: root.appendingPathComponent("app-support"), paseoHome: root.appendingPathComponent(".paseo"))
        try check(!paseo.isDetected(), "should not detect paseo without a config.json")
        try check(!paseo.isConfigured(), "should not report configured without a config.json")
    }

    static func testPaseoSymlinkRetargets() throws {
        let root = try temporaryRoot()
        let appSupport = root.appendingPathComponent("app-support")
        let paseo = PaseoIntegration(appSupport: appSupport, paseoHome: root.appendingPathComponent(".paseo"))
        let first = root.appendingPathComponent("profile-a"); try FileManager.default.createDirectory(at: first, withIntermediateDirectories: true)
        let second = root.appendingPathComponent("profile-b"); try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)
        try paseo.updateSymlink(to: first)
        try check(try FileManager.default.destinationOfSymbolicLink(atPath: paseo.activeConfigDirSymlink.path) == first.path, "symlink did not target the first profile")
        try paseo.updateSymlink(to: second)
        try check(try FileManager.default.destinationOfSymbolicLink(atPath: paseo.activeConfigDirSymlink.path) == second.path, "symlink did not re-target the second profile")
    }

    static func testPaseoIntegrateSetsClaudeProviderEnv() throws {
        let root = try temporaryRoot()
        let paseoHome = root.appendingPathComponent(".paseo"); try FileManager.default.createDirectory(at: paseoHome, withIntermediateDirectories: true)
        let original = """
        {"version":1,"agents":{"providers":{"claude-work":{"extends":"claude","env":{"CLAUDE_CONFIG_DIR":"/Users/x/.claude-work"}}}}}
        """
        try original.data(using: .utf8)!.write(to: paseoHome.appendingPathComponent("config.json"))
        let paseo = PaseoIntegration(appSupport: root.appendingPathComponent("app-support"), paseoHome: paseoHome)
        try check(!paseo.isConfigured(), "should not be configured before integrate() runs")
        try paseo.integrate()
        try check(paseo.isConfigured(), "should be configured after integrate() runs")
        let raw = try Data(contentsOf: paseoHome.appendingPathComponent("config.json"))
        let root2 = try JSONSerialization.jsonObject(with: raw) as! [String: Any]
        let providers = ((root2["agents"] as! [String: Any])["providers"] as! [String: Any])
        let claudeWorkEnv = ((providers["claude-work"] as! [String: Any])["env"] as! [String: Any])
        try check(claudeWorkEnv["CLAUDE_CONFIG_DIR"] as? String == "/Users/x/.claude-work", "existing claude-work provider was modified")
        let claudeEnv = ((providers["claude"] as! [String: Any])["env"] as! [String: Any])
        try check(claudeEnv["CLAUDE_CONFIG_DIR"] as? String == paseo.activeConfigDirSymlink.path, "claude provider was not pointed at the stable symlink")
    }

    static func testPaseoIntegrateBacksUpOriginal() throws {
        let root = try temporaryRoot()
        let paseoHome = root.appendingPathComponent(".paseo"); try FileManager.default.createDirectory(at: paseoHome, withIntermediateDirectories: true)
        let original = #"{"version":1}"#
        try original.data(using: .utf8)!.write(to: paseoHome.appendingPathComponent("config.json"))
        let appSupport = root.appendingPathComponent("app-support")
        let paseo = PaseoIntegration(appSupport: appSupport, paseoHome: paseoHome)
        let backup = try paseo.integrate()
        try check(FileManager.default.fileExists(atPath: backup.path), "backup file was not created")
        let backedUp = try String(contentsOf: backup, encoding: .utf8)
        try check(backedUp == original, "backup did not preserve the original content")
    }

    static func testActivationUpdatesPaseoSymlink() async throws {
        let root = try temporaryRoot(); let store = try ProfileStore(root: root)
        let directory = root.appendingPathComponent("config"); try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let profile = Profile(name: "Work", directory: directory); try store.save(profile)
        let paseo = PaseoIntegration(appSupport: root.appendingPathComponent("app-support"), paseoHome: root.appendingPathComponent(".paseo"))
        let desktopClient = FakeDesktopAppClient()
        let service = ActivationService(store: store, launchd: FakeLaunchd(), desktopActivator: DesktopAppActivator(client: desktopClient), paseoIntegration: paseo)
        _ = try await service.activate(profile)
        try check(try FileManager.default.destinationOfSymbolicLink(atPath: paseo.activeConfigDirSymlink.path) == directory.path, "activation did not update the paseo symlink")
        try? FileManager.default.removeItem(at: profile.desktopDirectory)
    }

    static func temporaryRoot() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func check(_ condition: Bool, _ message: String) throws {
        if !condition { throw TestFailure.failed(message) }
    }

    static func testProfileRoundTrip() throws {
        let profile = Profile(id: UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!, name: "Work", email: "work@example.com", organization: "Acme", color: "blue", icon: "briefcase", kind: .custom, directory: URL(fileURLWithPath: "/tmp/work"), createdAt: .distantPast, lastUsedAt: nil, health: .ready)
        let decoded = try JSONDecoder().decode(Profile.self, from: JSONEncoder().encode(profile))
        try check(decoded == profile, "profile did not round trip")
    }

    static func testDesktopDirectory() throws {
        let configDir = URL(fileURLWithPath: "/tmp/Profiles/AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA/config")
        let profile = Profile(name: "Work", directory: configDir)
        try check(profile.desktopDirectory.path == "/tmp/Profiles/AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA/desktop", "desktop directory was not derived as a sibling of the config directory")
    }

    static func testStorePersists() throws {
        let store = try ProfileStore(root: try temporaryRoot())
        let profile = Profile(name: "Personal", directory: URL(fileURLWithPath: "/tmp/personal"))
        try store.save(profile); try store.setActive(ActiveProfile(id: profile.id, directory: profile.directory))
        let stored = try store.list()
        try check(stored.count == 1 && stored[0].id == profile.id && stored[0].name == profile.name, "profile list mismatch")
        try check(store.active()?.id == profile.id, "active profile mismatch")
    }

    static func testManagedDirectory() throws {
        let store = try ProfileStore(root: try temporaryRoot())
        let url = try store.createManagedDirectory(id: UUID())
        let permissions = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
        try check(permissions?.intValue == 0o700, "managed directory is not user-only")
    }

    static func testRenameProfile() throws {
        let store = try ProfileStore(root: try temporaryRoot())
        let profile = Profile(name: "Conta antiga", email: "account@example.com", directory: URL(fileURLWithPath: "/tmp/account"))
        try store.save(profile)
        var renamed = profile
        renamed.name = "Conta pessoal"
        try store.save(renamed)
        let stored = try store.list()
        try check(stored.count == 1 && stored[0].id == profile.id && stored[0].name == "Conta pessoal" && stored[0].email == profile.email, "profile rename did not preserve identity")
    }

    static func testRemoveProfile() throws {
        let store = try ProfileStore(root: try temporaryRoot())
        let profile = Profile(id: UUID(), name: "Remover", directory: try store.createManagedDirectory(id: UUID()))
        try store.save(profile)
        try store.remove(profile)
        try check(try store.list().isEmpty, "removed profile remains in metadata")
        try check(!FileManager.default.fileExists(atPath: profile.directory.path), "removed profile directory still exists")
    }

    static func testConcurrentSaves() async throws {
        let store = try ProfileStore(root: try temporaryRoot())
        let profiles = (0..<50).map { Profile(name: "Concurrent \($0)", directory: URL(fileURLWithPath: "/tmp/concurrent-\($0)")) }

        // Distinct profiles saved concurrently must all survive: a read-modify-write race (issue #1)
        // drops whichever save's read predates another save's write.
        try await withThrowingTaskGroup(of: Void.self) { group in
            for profile in profiles { group.addTask { try store.save(profile) } }
            try await group.waitForAll()
        }
        let afterAdds = try store.list()
        try check(afterAdds.count == profiles.count, "concurrent saves lost profiles: expected \(profiles.count), got \(afterAdds.count)")
        for profile in profiles {
            try check(afterAdds.contains(where: { $0.id == profile.id }), "profile \(profile.id) missing after concurrent saves")
        }

        // Racing updates to the *same* profile alongside unrelated concurrent saves must not corrupt
        // the metadata file or change the total profile count, even though the final value of the
        // contended field is inherently a race (last write wins is acceptable; losing the row is not).
        try await withThrowingTaskGroup(of: Void.self) { group in
            for profile in profiles {
                group.addTask { var renamed = profile; renamed.name = "\(profile.name) renamed"; try store.save(renamed) }
                group.addTask { var reordered = profile; reordered.health = .expired; try store.save(reordered) }
            }
            try await group.waitForAll()
        }
        let afterUpdates = try store.list()
        try check(afterUpdates.count == profiles.count, "concurrent updates changed profile count: expected \(profiles.count), got \(afterUpdates.count)")
        for profile in profiles {
            try check(afterUpdates.contains(where: { $0.id == profile.id }), "profile \(profile.id) missing after concurrent updates")
        }
    }

    static func testProcessRunner() throws {
        let script = FileManager.default.temporaryDirectory.appendingPathComponent("claude-test-\(UUID().uuidString).sh")
        try "#!/bin/sh\nprintf '%s' \"$CLAUDE_CONFIG_DIR\"".data(using: .utf8)!.write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        defer { try? FileManager.default.removeItem(at: script) }
        let result = try ProcessRunner().run(executable: script, environment: ["CLAUDE_CONFIG_DIR": "/tmp/profile"])
        try check(result.stdout == "/tmp/profile", "runner did not pass environment")
    }

    static func testShellIntegration() throws {
        let home = try temporaryRoot(); let app = home.appendingPathComponent("support")
        let manager = ShellIntegrationManager(appSupport: app)
        let zprofile = home.appendingPathComponent(".zprofile")
        let zshrc = home.appendingPathComponent(".zshrc")
        try "alias keep='echo keep'\n".write(to: zprofile, atomically: true, encoding: .utf8)
        try "alias keep_rc='echo keep_rc'\n".write(to: zshrc, atomically: true, encoding: .utf8)
        try manager.install(home: home, officialBinary: URL(fileURLWithPath: "/bin/echo"))
        let first = try String(contentsOf: zprofile)
        let firstRC = try String(contentsOf: zshrc)
        try manager.install(home: home, officialBinary: URL(fileURLWithPath: "/bin/echo"))
        let second = try String(contentsOf: zprofile)
        let secondRC = try String(contentsOf: zshrc)
        try check(first == second && firstRC == secondRC && second.contains("alias keep") && secondRC.contains("alias keep_rc") && second.components(separatedBy: ShellIntegrationManager.startMarker).count == 2 && secondRC.components(separatedBy: ShellIntegrationManager.startMarker).count == 2, "shell install was not idempotent")
    }

    final class FakeLaunchd: LaunchdEnvironmentClient, @unchecked Sendable {
        var values: [String] = []; var shouldFail = false
        func set(_ value: String) throws { if shouldFail { throw TestFailure.failed("launchd failure") }; values.append(value) }
        func unset() throws { values.append("unset") }
    }

    static func testActivationRollback() async throws {
        let root = try temporaryRoot(); let store = try ProfileStore(root: root); let fake = FakeLaunchd(); fake.shouldFail = true
        let directory = root.appendingPathComponent("config"); try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let profile = Profile(name: "Failing", directory: directory)
        try store.save(profile)
        let service = ActivationService(store: store, launchd: fake)
        do { _ = try await service.activate(profile); throw TestFailure.failed("activation unexpectedly succeeded") }
        catch ActivationError.rolledBack { }
        try check(try store.active() == nil, "active profile was not rolled back")
    }

    static func testMigration() throws {
        let home = try temporaryRoot(); let source = home.appendingPathComponent(".claude")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try "secret-shaped config".write(to: source.appendingPathComponent(".claude.json"), atomically: true, encoding: .utf8)
        let store = try ProfileStore(root: home.appendingPathComponent("managed")); let plan = try MigrationService(store: store).preview(home: home)
        let report = try MigrationService(store: store).execute(plan)
        let copied = report.imported[0].appendingPathComponent(".claude.json")
        try check(FileManager.default.fileExists(atPath: copied.path), "hidden config was not migrated")
        try check(FileManager.default.fileExists(atPath: source.appendingPathComponent(".claude.json").path), "source was modified")
    }

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

    static func testLauncher() throws {
        let root = try temporaryRoot(); let app = root.appendingPathComponent("app-support")
        let store = try ProfileStore(root: app); let firstDir = root.appendingPathComponent("first profile"); let secondDir = root.appendingPathComponent("second profile")
        try FileManager.default.createDirectory(at: firstDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: secondDir, withIntermediateDirectories: true)
        let first = Profile(name: "First", directory: firstDir); let second = Profile(name: "Second", directory: secondDir)
        try store.save(first); try store.save(second); try store.setActive(ActiveProfile(id: second.id, directory: second.directory))
        let shell = ShellIntegrationManager(appSupport: app); let home = root.appendingPathComponent("home"); try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try shell.install(home: home, officialBinary: URL(fileURLWithPath: "/usr/bin/env"))
        do {
            let result = try ProcessRunner().run(executable: shell.launcherURL())
            try check(result.stdout.contains("CLAUDE_CONFIG_DIR=\(secondDir.path)"), "launcher did not select the active profile")
        } catch {
            let script = String(data: try Data(contentsOf: shell.launcherURL()), encoding: .utf8) ?? "script unavailable"
            throw TestFailure.failed("launcher failed: \(error); script=\(script)")
        }
    }

    static func testLegacyActiveState() throws {
        let root = try temporaryRoot(); let store = try ProfileStore(root: root.appendingPathComponent("app-support"))
        let profileDir = root.appendingPathComponent("profile with spaces")
        try FileManager.default.createDirectory(at: profileDir, withIntermediateDirectories: true)
        let profile = Profile(name: "Legacy", directory: profileDir); try store.save(profile)
        let legacy = "{\"id\":\"\(profile.id.uuidString)\",\"updatedAt\":\"2026-07-20T00:00:00Z\"}"
        try legacy.data(using: .utf8)!.write(to: store.activeURL)
        let active = try store.active()
        try check(active?.directory.path == profileDir.path, "legacy active profile was not resolved")
        let migrated = String(data: try Data(contentsOf: store.activeURL), encoding: .utf8) ?? ""
        try check(migrated.contains("profile with spaces") && !migrated.contains("%20"), "active path was not migrated to a plain path")
    }

    static func testSystemDesktopAppClientBundleIdentifier() throws {
        try check(SystemDesktopAppClient.bundleIdentifier == "com.anthropic.claudefordesktop", "desktop app bundle identifier changed unexpectedly")
    }

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

    static func testActivationSkipsDesktopWhenDisabled() async throws {
        let root = try temporaryRoot(); let store = try ProfileStore(root: root)
        let directory = root.appendingPathComponent("config"); try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let profile = Profile(name: "Work", directory: directory); try store.save(profile)
        let desktopClient = FakeDesktopAppClient()
        let service = ActivationService(store: store, launchd: FakeLaunchd(), desktopActivator: DesktopAppActivator(client: desktopClient))
        let result = try await service.activate(profile, syncDesktopApp: false)
        try check(result.desktopSync == .skipped(.disabledOnSwitch), "desktop sync should be skipped when disabled")
        try check(desktopClient.launchedWith == nil, "desktop app must not be launched when sync is disabled")
    }

    static func testCopyDefaultDesktopSessionIntoFreshProfile() throws {
        let home = try temporaryRoot()
        let defaultDesktopData = home.appendingPathComponent("Library/Application Support/Claude")
        try FileManager.default.createDirectory(at: defaultDesktopData, withIntermediateDirectories: true)
        try "cookie-bytes".write(to: defaultDesktopData.appendingPathComponent("Cookies"), atomically: true, encoding: .utf8)

        let store = try ProfileStore(root: home.appendingPathComponent("managed"))
        let directory = try store.createManagedDirectory(id: UUID())
        let profile = Profile(name: "Personal", directory: directory)

        let copied = try MigrationService(store: store).copyDefaultDesktopSessionIfAvailable(into: profile, home: home)
        try check(copied, "expected a copy to happen for a profile with no desktop session")
        try check(FileManager.default.fileExists(atPath: profile.desktopDirectory.appendingPathComponent("Cookies").path), "session was not copied into the profile's desktop directory")
        try check(FileManager.default.fileExists(atPath: defaultDesktopData.appendingPathComponent("Cookies").path), "original desktop app data was modified or removed")
    }

    static func testCopyDefaultDesktopSessionSkipsExistingSession() throws {
        let home = try temporaryRoot()
        let defaultDesktopData = home.appendingPathComponent("Library/Application Support/Claude")
        try FileManager.default.createDirectory(at: defaultDesktopData, withIntermediateDirectories: true)
        try "cookie-bytes".write(to: defaultDesktopData.appendingPathComponent("Cookies"), atomically: true, encoding: .utf8)

        let store = try ProfileStore(root: home.appendingPathComponent("managed"))
        let directory = try store.createManagedDirectory(id: UUID())
        let profile = Profile(name: "Personal", directory: directory)
        try FileManager.default.createDirectory(at: profile.desktopDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try "existing-session-cookie-bytes".write(to: profile.desktopDirectory.appendingPathComponent("Cookies"), atomically: true, encoding: .utf8)

        let copied = try MigrationService(store: store).copyDefaultDesktopSessionIfAvailable(into: profile, home: home)
        try check(!copied, "expected no copy when the profile already has a real desktop session")
        let preserved = try String(contentsOf: profile.desktopDirectory.appendingPathComponent("Cookies"), encoding: .utf8)
        try check(preserved == "existing-session-cookie-bytes", "existing desktop session was overwritten")
    }

    static func testCopyDefaultDesktopSessionSkipsWhenSourceEmpty() throws {
        let home = try temporaryRoot()
        let store = try ProfileStore(root: home.appendingPathComponent("managed"))
        let directory = try store.createManagedDirectory(id: UUID())
        let profile = Profile(name: "Personal", directory: directory)

        let copied = try MigrationService(store: store).copyDefaultDesktopSessionIfAvailable(into: profile, home: home)
        try check(!copied, "expected no copy when the default desktop directory has no real session")
        try check(!FileManager.default.fileExists(atPath: profile.desktopDirectory.path), "desktop directory should not be created when there is nothing to copy")
    }
}
