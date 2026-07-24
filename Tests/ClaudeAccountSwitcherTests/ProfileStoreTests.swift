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
            ,("process runner drains large output without deadlock", testProcessRunnerLargeOutput)
            ,("process runner enforces timeout with kill", testProcessRunnerTimeout)
            ,("shell integration is idempotent", testShellIntegration)
            ,("shell integration supports bash and fish", testShellIntegrationBashAndFish)
            ,("activation rolls back on launchd failure", testActivationRollback)
            ,("activation rollback restores the previously active profile", testActivationRollbackRestoresPreviousActive)
            ,("activation propagates paseo symlink failure and rolls back", testActivationPropagatesSymlinkFailure)
            ,("remove keeps metadata when directory deletion fails", testRemoveKeepsMetadataWhenDirectoryDeletionFails)
            ,("store lists orphaned profile directories", testOrphanedProfileDirectories)
            ,("migration preserves hidden Claude files", testMigration)
            ,("legacy active state is migrated", testLegacyActiveState)
            ,("launcher selects active profile", testLauncher)
            ,("launcher escapes single quotes in paths", testLauncherEscapesQuoteInPath)
            ,("cleanup backs up .zshrc before rewriting", testCleanupAliasesBacksUpZshrc)
            ,("locator sorts claude versions semantically", testClaudeLocatorSortsVersionsSemantically)
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
            ,("quota kind decodes legacy snapshot by label", testQuotaKindDecodesLegacySnapshotByLabel)
            ,("quota kind is stable across label change", testQuotaKindIsStableAcrossLabelChange)
            ,("usage fetch retries on 5xx and succeeds", testUsageRetriesOnServerError)
            ,("usage fetch does not retry on 401", testUsageDoesNotRetryUnauthorized)
            ,("token usage caches unmodified files", testTokenUsageCachesUnmodifiedFiles)
            ,("daily usage buckets tokens by day and profile", testDailyUsageBucketsByDayAndProfile)
            ,("daily usage aggregates only the profiles it receives", testDailyUsageRespectsSelection)
            ,("daily usage skips invalid lines and empty files", testDailyUsageRobustness)
            ,("daily usage reuses cache for unmodified files", testDailyUsageCachesUnmodifiedFiles)
            ,("analysis selection defaults to all and honors a saved subset", testAnalysisSelection)
            ,("plan recommendation classifies fabricated series", testPlanRecommendationVerdicts)
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

    static func testProcessRunnerLargeOutput() throws {
        // Filho que despeja >64KB em stderr deve terminar sem deadlock de pipe.
        let script = FileManager.default.temporaryDirectory.appendingPathComponent("claude-test-\(UUID().uuidString).sh")
        try "#!/bin/sh\nyes x | head -c 200000 1>&2\nprintf 'ok'".data(using: .utf8)!.write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        defer { try? FileManager.default.removeItem(at: script) }
        let result = try ProcessRunner(outputLimit: 64 * 1024, timeout: 15).run(executable: script)
        try check(result.stdout == "ok", "runner lost stdout while stderr filled the pipe buffer")
        try check(result.stderr.utf8.count <= 64 * 1024, "runner did not honor outputLimit")
    }

    static func testProcessRunnerTimeout() throws {
        // Processo que dorme além do timeout deve ser morto e lançar timedOut.
        let script = FileManager.default.temporaryDirectory.appendingPathComponent("claude-test-\(UUID().uuidString).sh")
        try "#!/bin/sh\nsleep 30".data(using: .utf8)!.write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        defer { try? FileManager.default.removeItem(at: script) }
        do {
            _ = try ProcessRunner(timeout: 1).run(executable: script)
            try check(false, "runner did not time out")
        } catch ProcessRunnerError.timedOut {
            // esperado
        }
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

    static func testShellIntegrationBashAndFish() throws {
        let home = try temporaryRoot(); let app = home.appendingPathComponent("support")
        let manager = ShellIntegrationManager(appSupport: app)
        // Usuário já usa bash e fish: os arquivos existem.
        let bashrc = home.appendingPathComponent(".bashrc")
        let fishConfig = home.appendingPathComponent(".config/fish/config.fish")
        try "export KEEP=1\n".write(to: bashrc, atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(at: fishConfig.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "set -gx KEEP 1\n".write(to: fishConfig, atomically: true, encoding: .utf8)

        try manager.install(home: home, officialBinary: URL(fileURLWithPath: "/bin/echo"))

        let bash = try String(contentsOf: bashrc, encoding: .utf8)
        try check(bash.contains("export PATH=") && bash.contains("export KEEP=1"), "bashrc did not get the POSIX PATH block while preserving content")
        let fish = try String(contentsOf: fishConfig, encoding: .utf8)
        try check(fish.contains("set -gx PATH ") && fish.contains("set -gx KEEP 1"), "config.fish did not get the fish PATH block while preserving content")
        // Não deve criar dotfiles para shells que o usuário não usa.
        try check(!FileManager.default.fileExists(atPath: home.appendingPathComponent(".bash_profile").path), ".bash_profile should not be created when absent")

        // Idempotência: uma segunda instalação não duplica o bloco.
        try manager.install(home: home, officialBinary: URL(fileURLWithPath: "/bin/echo"))
        let fish2 = try String(contentsOf: fishConfig, encoding: .utf8)
        try check(fish2.components(separatedBy: ShellIntegrationManager.startMarker).count == 2, "fish install was not idempotent")
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

    static func testActivationRollbackRestoresPreviousActive() async throws {
        let root = try temporaryRoot(); let store = try ProfileStore(root: root); let fake = FakeLaunchd()
        let dirA = root.appendingPathComponent("a"); let dirB = root.appendingPathComponent("b")
        try FileManager.default.createDirectory(at: dirA, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dirB, withIntermediateDirectories: true)
        let a = Profile(name: "A", directory: dirA); let b = Profile(name: "B", directory: dirB)
        try store.save(a); try store.save(b)
        let service = ActivationService(store: store, launchd: fake)
        _ = try await service.activate(a, syncDesktopApp: false)
        try check(try store.active()?.id == a.id, "precondition: A should be active")
        // Ativar B falha no launchd → rollback deve restaurar A como ativo (não deixar nil).
        fake.shouldFail = true
        do { _ = try await service.activate(b, syncDesktopApp: false); throw TestFailure.failed("activation unexpectedly succeeded") }
        catch ActivationError.rolledBack { }
        try check(try store.active()?.id == a.id, "rollback did not restore the previously active profile")
    }

    static func testActivationPropagatesSymlinkFailure() async throws {
        let root = try temporaryRoot(); let store = try ProfileStore(root: root)
        let dir = root.appendingPathComponent("config"); try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let profile = Profile(name: "P", directory: dir); try store.save(profile)
        // appSupport do Paseo sob um caminho não-criável (um arquivo no lugar de um diretório pai)
        // → updateSymlink lança. Antes, o `try?` engolia esse erro e a ativação seguia.
        let blocker = root.appendingPathComponent("blocker"); try "x".write(to: blocker, atomically: true, encoding: .utf8)
        let paseo = PaseoIntegration(appSupport: blocker.appendingPathComponent("sub"), paseoHome: root.appendingPathComponent(".paseo"))
        let service = ActivationService(store: store, launchd: FakeLaunchd(), paseoIntegration: paseo)
        do { _ = try await service.activate(profile, syncDesktopApp: false); throw TestFailure.failed("activation should have failed on symlink error") }
        catch ActivationError.rolledBack { }
        try check(try store.active() == nil, "activation did not roll back after the symlink failure was propagated")
    }

    static func testRemoveKeepsMetadataWhenDirectoryDeletionFails() throws {
        let store = try ProfileStore(root: try temporaryRoot())
        let id = UUID(); let dir = try store.createManagedDirectory(id: id)
        let profile = Profile(id: id, name: "X", directory: dir); try store.save(profile)
        // Torna o pai (Profiles/<id>) somente-leitura → apagar o config falha por permissão.
        let parent = dir.deletingLastPathComponent()
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: parent.path)
        var threw = false
        do { try store.remove(profile) } catch { threw = true }
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: parent.path)
        try check(threw, "remove should fail when the credentials directory cannot be deleted")
        try check(try store.list().contains(where: { $0.id == id }), "metadata must survive a failed directory deletion (no orphan)")
        try check(FileManager.default.fileExists(atPath: dir.path), "credentials directory should remain instead of being silently orphaned")
    }

    static func testOrphanedProfileDirectories() throws {
        let store = try ProfileStore(root: try temporaryRoot())
        let known = UUID(); let knownDir = try store.createManagedDirectory(id: known)
        try store.save(Profile(id: known, name: "Known", directory: knownDir))
        let orphan = UUID(); _ = try store.createManagedDirectory(id: orphan)   // diretório sem metadata
        let found = try store.orphanedProfileDirectories()
        try check(found.count == 1 && found[0].lastPathComponent == orphan.uuidString, "orphan scan did not find exactly the unbacked directory")
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

    static func testQuotaKindDecodesLegacySnapshotByLabel() throws {
        // Snapshot antigo (sem o campo `kind`) deve inferir o tipo pelo rótulo legado,
        // em vez de falhar o decode — o que derrubaria todo o profiles.json.
        let legacy = #"{"key":"Semanal","usedPercent":40}"#
        let weekly = try JSONDecoder().decode(ClaudeQuota.self, from: Data(legacy.utf8))
        try check(weekly.kind == .sevenDay, "legacy 'Semanal' should infer .sevenDay")
        let legacyModel = #"{"key":"Semanal Opus","usedPercent":10}"#
        try check(try JSONDecoder().decode(ClaudeQuota.self, from: Data(legacyModel.utf8)).kind == .sevenDayModel, "legacy 'Semanal <modelo>' should infer .sevenDayModel")
        let legacyFive = #"{"key":"Janela 5h","usedPercent":80}"#
        try check(try JSONDecoder().decode(ClaudeQuota.self, from: Data(legacyFive.utf8)).kind == .fiveHour, "legacy 'Janela 5h' should infer .fiveHour")
    }

    static func testQuotaKindIsStableAcrossLabelChange() throws {
        // A seleção de cota para alertas casa por `kind`, não pelo rótulo: renomear o `key`
        // (ex.: tradução) não pode impedir o alerta de encontrar a cota semanal/5h.
        let translated = ClaudeQuota(kind: .sevenDay, key: "Weekly (renamed)", usedPercent: 55)
        let roundTripped = try JSONDecoder().decode(ClaudeQuota.self, from: JSONEncoder().encode(translated))
        try check(roundTripped.kind == .sevenDay, "kind must survive round-trip regardless of label")
        let quotas = [ClaudeQuota(kind: .fiveHour, key: "X", usedPercent: 1), translated]
        try check(quotas.first(where: { $0.kind == .sevenDay })?.usedPercent == 55, "kind-based lookup should find the weekly quota under any label")
    }

    final class CallCounter: @unchecked Sendable {
        private let lock = NSLock(); private var value = 0
        func increment() -> Int { lock.lock(); defer { lock.unlock() }; value += 1; return value }
        var count: Int { lock.lock(); defer { lock.unlock() }; return value }
    }

    private static func httpResponse(_ status: Int) -> HTTPURLResponse {
        HTTPURLResponse(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!, statusCode: status, httpVersion: nil, headerFields: nil)!
    }

    static func testUsageRetriesOnServerError() async throws {
        let body = Data(#"{"five_hour":{"utilization":42}}"#.utf8)
        let counter = CallCounter()
        let service = ClaudeUsageService(
            retry: UsageRetryPolicy(maxAttempts: 3, baseDelay: 0),
            transport: { _ in
                let attempt = counter.increment()
                return attempt < 3 ? (Data(), httpResponse(503)) : (body, httpResponse(200))
            },
            tokenProvider: { _ in "fake-token" })
        let snapshot = try await service.fetch(profileDirectory: URL(fileURLWithPath: "/tmp/p"))
        try check(counter.count == 3, "expected 3 attempts (2 failures + 1 success), got \(counter.count)")
        try check(snapshot.quotas.first?.usedPercent == 42, "did not parse the retried success response")
    }

    static func testUsageDoesNotRetryUnauthorized() async throws {
        let counter = CallCounter()
        let service = ClaudeUsageService(
            retry: UsageRetryPolicy(maxAttempts: 5, baseDelay: 0),
            transport: { _ in _ = counter.increment(); return (Data(), httpResponse(401)) },
            tokenProvider: { _ in "fake-token" })
        do {
            _ = try await service.fetch(profileDirectory: URL(fileURLWithPath: "/tmp/p"))
            try check(false, "expected unauthorized to throw")
        } catch ClaudeUsageError.unauthorized {
            try check(counter.count == 1, "401 must not be retried, got \(counter.count) attempts")
        }
    }

    static func testTokenUsageCachesUnmodifiedFiles() throws {
        let profile = try temporaryRoot()
        let projects = profile.appendingPathComponent("projects/proj"); try FileManager.default.createDirectory(at: projects, withIntermediateDirectories: true)
        let jsonl = projects.appendingPathComponent("session.jsonl")
        let line = #"{"type":"assistant","message":{"usage":{"input_tokens":100,"output_tokens":50}}}"#
        try line.data(using: .utf8)!.write(to: jsonl)
        // Fixa o mtime a um valor determinístico antes da primeira leitura, para que a
        // assinatura cacheada e a restaurada mais adiante sejam idênticas byte a byte.
        let fixedMtime = Date(timeIntervalSince1970: 1_000_000)
        try FileManager.default.setAttributes([.modificationDate: fixedMtime], ofItemAtPath: jsonl.path)
        let service = ClaudeUsageService()
        let first = service.tokenUsage(profileDirectory: profile)
        try check(first.input == 100 && first.output == 50, "did not parse tokens on first read")

        // Sobrescreve o conteúdo com lixo do MESMO tamanho e restaura o mesmo mtime fixo.
        // Se o cache por (mtime, tamanho) funcionar, o total permanece; se relesse, o
        // conteúdo inválido zeraria a contagem.
        let garbage = String(repeating: "x", count: line.utf8.count)
        try garbage.data(using: .utf8)!.write(to: jsonl)
        try FileManager.default.setAttributes([.modificationDate: fixedMtime], ofItemAtPath: jsonl.path)
        let cached = service.tokenUsage(profileDirectory: profile)
        try check(cached == first, "cache did not reuse the unmodified file (mtime+size unchanged)")
    }

    // MARK: - Aggregate usage analysis (#34)

    /// Cria um perfil cujo diretório contém `projects/proj/<file>.jsonl` com o conteúdo dado.
    private static func makeAnalysisProfile(root: URL, name: String, file: String, contents: String) throws -> Profile {
        let directory = root.appendingPathComponent(name).appendingPathComponent("config")
        let projects = directory.appendingPathComponent("projects/proj")
        try FileManager.default.createDirectory(at: projects, withIntermediateDirectories: true)
        try contents.data(using: .utf8)!.write(to: projects.appendingPathComponent(file))
        return Profile(name: name, directory: directory)
    }

    private static func assistantLine(_ timestamp: String, input: Int = 0, output: Int = 0, cacheRead: Int = 0, cacheCreation: Int = 0) -> String {
        #"{"type":"assistant","timestamp":"\#(timestamp)","message":{"usage":{"input_tokens":\#(input),"output_tokens":\#(output),"cache_read_input_tokens":\#(cacheRead),"cache_creation_input_tokens":\#(cacheCreation)}}}"#
    }

    static func testDailyUsageBucketsByDayAndProfile() throws {
        let root = try temporaryRoot()
        let a = try makeAnalysisProfile(root: root, name: "A", file: "s.jsonl", contents: [
            assistantLine("2026-06-01T12:00:00.000Z", input: 100, output: 50),   // D1 = 150
            assistantLine("2026-06-02T12:00:00.000Z", input: 200),               // D2 = 200
            assistantLine("2026-06-03T12:00:00.000Z", input: 300, cacheRead: 100) // D3 = 400
        ].joined(separator: "\n"))
        let b = try makeAnalysisProfile(root: root, name: "B", file: "s.jsonl", contents: [
            assistantLine("2026-06-01T12:00:00.000Z", input: 10, output: 5),      // D1 = 15
            assistantLine("2026-06-03T12:00:00.000Z", output: 25)                 // D3 = 25
        ].joined(separator: "\n"))

        let now = ClaudeUsageService.parseResetDate("2026-06-10T00:00:00Z")!
        let series = UsageHistoryService().dailyUsage(profiles: [a, b], now: now)
        try check(series.count == 3, "expected 3 daily buckets, got \(series.count)")
        try check(series[0].perProfile[a.id] == 150 && series[0].perProfile[b.id] == 15 && series[0].total == 165, "D1 breakdown wrong: \(series[0].perProfile)")
        try check(series[1].perProfile[a.id] == 200 && series[1].perProfile[b.id] == nil && series[1].total == 200, "D2 breakdown wrong: \(series[1].perProfile)")
        try check(series[2].perProfile[a.id] == 400 && series[2].perProfile[b.id] == 25 && series[2].total == 425, "D3 breakdown wrong: \(series[2].perProfile)")
        try check(series[0].day < series[1].day && series[1].day < series[2].day, "buckets are not sorted ascending by day")
    }

    static func testDailyUsageRespectsSelection() throws {
        let root = try temporaryRoot()
        let a = try makeAnalysisProfile(root: root, name: "A", file: "s.jsonl", contents: assistantLine("2026-06-01T12:00:00.000Z", input: 100))
        let b = try makeAnalysisProfile(root: root, name: "B", file: "s.jsonl", contents: assistantLine("2026-06-01T12:00:00.000Z", input: 999))
        let now = ClaudeUsageService.parseResetDate("2026-06-10T00:00:00Z")!

        let onlyA = UsageHistoryService().dailyUsage(profiles: [a], now: now)
        try check(onlyA.count == 1 && onlyA[0].perProfile[b.id] == nil && onlyA[0].total == 100, "series should ignore the profile not passed by the caller")

        let none = UsageHistoryService().dailyUsage(profiles: [], now: now)
        try check(none.isEmpty, "empty profile list should yield an empty series")
    }

    static func testDailyUsageRobustness() throws {
        let root = try temporaryRoot()
        let mixed = [
            #"{"type":"user","timestamp":"2026-06-01T12:00:00.000Z","message":{"usage":{"input_tokens":500}}}"#, // non-assistant → skip
            #"{"type":"assistant","message":{"usage":{"input_tokens":700}}}"#,                                    // no timestamp → skip
            assistantLine("2026-06-01T12:00:00.000Z", input: 42),                                                 // valid
            "not json at all"                                                                                     // garbage → skip
        ].joined(separator: "\n")
        let valid = try makeAnalysisProfile(root: root, name: "V", file: "s.jsonl", contents: mixed)
        let empty = try makeAnalysisProfile(root: root, name: "E", file: "s.jsonl", contents: "")
        let now = ClaudeUsageService.parseResetDate("2026-06-10T00:00:00Z")!
        let series = UsageHistoryService().dailyUsage(profiles: [valid, empty], now: now)
        try check(series.count == 1 && series[0].total == 42 && series[0].perProfile[empty.id] == nil, "only the single valid assistant line should count; empty file contributes no bucket")
    }

    static func testDailyUsageCachesUnmodifiedFiles() throws {
        let root = try temporaryRoot()
        let profile = try makeAnalysisProfile(root: root, name: "C", file: "s.jsonl", contents: assistantLine("2026-06-01T12:00:00.000Z", input: 100, output: 50))
        let jsonl = profile.directory.appendingPathComponent("projects/proj/s.jsonl")
        // Fixa o mtime a um valor determinístico antes da 1ª leitura (padrão do teste de #24).
        let fixedMtime = Date(timeIntervalSince1970: 1_000_000)
        try FileManager.default.setAttributes([.modificationDate: fixedMtime], ofItemAtPath: jsonl.path)
        let now = ClaudeUsageService.parseResetDate("2026-06-10T00:00:00Z")!
        let service = UsageHistoryService()
        let first = service.dailyUsage(profiles: [profile], now: now)
        try check(first.count == 1 && first[0].total == 150, "did not bucket tokens on first read")

        // Sobrescreve com lixo do MESMO tamanho e restaura o mesmo mtime: se o cache por
        // (mtime, tamanho) funcionar, a série permanece; se relesse, o lixo zeraria a contagem.
        let original = assistantLine("2026-06-01T12:00:00.000Z", input: 100, output: 50)
        let garbage = String(repeating: "x", count: original.utf8.count)
        try garbage.data(using: .utf8)!.write(to: jsonl)
        try FileManager.default.setAttributes([.modificationDate: fixedMtime], ofItemAtPath: jsonl.path)
        let cached = service.dailyUsage(profiles: [profile], now: now)
        try check(cached == first, "cache did not reuse the unmodified file (mtime+size unchanged)")
    }

    static func testAnalysisSelection() throws {
        let a = Profile(name: "A", directory: URL(fileURLWithPath: "/tmp/a"))
        let b = Profile(name: "B", directory: URL(fileURLWithPath: "/tmp/b"))
        // Sem chave → todas selecionadas.
        try check(AnalysisSelection.selected(from: [a, b], savedRawIDs: nil).count == 2, "absent key should select all profiles")
        try check(AnalysisSelection.isSelected(a.id, savedRawIDs: nil), "absent key should mark every profile selected")
        // Subconjunto salvo → só esses.
        let subset = AnalysisSelection.selected(from: [a, b], savedRawIDs: [a.id.uuidString])
        try check(subset.count == 1 && subset[0].id == a.id, "a saved subset should select only its members")
        // ID inexistente salvo → ignorado sem quebrar.
        let withGhost = AnalysisSelection.selected(from: [a, b], savedRawIDs: [a.id.uuidString, UUID().uuidString])
        try check(withGhost.count == 1 && withGhost[0].id == a.id, "an unknown saved id must be ignored, not crash")
        // Seleção vazia (chave presente, sem ids conhecidos) → nada selecionado.
        try check(AnalysisSelection.selected(from: [a, b], savedRawIDs: []).isEmpty, "an explicit empty selection should select nothing")
    }

    static func testPlanRecommendationVerdicts() throws {
        let idA = UUID(); let idB = UUID()
        func day(_ i: Int, _ perProfile: [UUID: Int]) -> DailyTokenUsage {
            DailyTokenUsage(day: Date(timeIntervalSince1970: Double(i) * 86_400), perProfile: perProfile)
        }
        // Seleção vazia → inconclusivo.
        try check(PlanRecommendation.evaluate(series: [], selectedProfileCount: 0).verdict == .inconclusive, "empty selection should be inconclusive")
        // Histórico curto → inconclusivo.
        let short = (0..<3).map { day($0, [idA: 100]) }
        try check(PlanRecommendation.evaluate(series: short, selectedProfileCount: 2).verdict == .inconclusive, "too few active days should be inconclusive")
        // Uso raramente sobrepõe (uma conta por dia) → 1 Max provavelmente cobre.
        let solo = (0..<6).map { day($0, [$0 % 2 == 0 ? idA : idB: 100]) }
        try check(PlanRecommendation.evaluate(series: solo, selectedProfileCount: 2).verdict == .singleMaxLikelyEnough, "sporadic non-overlapping usage should favor a single Max")
        // Demanda simultânea recorrente em duas contas → múltiplos Pro justificados.
        let concurrent = (0..<6).map { day($0, [idA: 100, idB: 100]) }
        try check(PlanRecommendation.evaluate(series: concurrent, selectedProfileCount: 2).verdict == .multipleProJustified, "recurring concurrent demand should justify multiple Pro plans")
    }

    static func testLauncherEscapesQuoteInPath() throws {
        // Caminho com apóstrofo no diretório de app support (→ path do STATE no launcher).
        // Sem escaping de aspas simples, o `set -eu` do launcher quebraria a execução.
        let root = try temporaryRoot(); let app = root.appendingPathComponent("o'brien support").appendingPathComponent("app-support")
        let store = try ProfileStore(root: app)
        let profileDir = root.appendingPathComponent("profile")
        try FileManager.default.createDirectory(at: profileDir, withIntermediateDirectories: true)
        let profile = Profile(name: "P", directory: profileDir); try store.save(profile)
        try store.setActive(ActiveProfile(id: profile.id, directory: profile.directory))
        let shell = ShellIntegrationManager(appSupport: app); let home = root.appendingPathComponent("home")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try shell.install(home: home, officialBinary: URL(fileURLWithPath: "/usr/bin/env"))
        do {
            let result = try ProcessRunner().run(executable: shell.launcherURL())
            try check(result.stdout.contains("CLAUDE_CONFIG_DIR=\(profileDir.path)"), "launcher broke on a path containing a single quote")
        } catch {
            let script = String(data: (try? Data(contentsOf: shell.launcherURL())) ?? Data(), encoding: .utf8) ?? "script unavailable"
            throw TestFailure.failed("launcher failed on quoted path: \(error); script=\(script)")
        }
    }

    static func testCleanupAliasesBacksUpZshrc() throws {
        let root = try temporaryRoot(); let store = try ProfileStore(root: root.appendingPathComponent("app-support"))
        let home = root.appendingPathComponent("home"); try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let zshrc = home.appendingPathComponent(".zshrc")
        try "alias keep='echo keep'\nalias claude-work='claude'\n".write(to: zshrc, atomically: true, encoding: .utf8)
        try MigrationService(store: store).cleanupRecognizedAliases(home: home, confirmed: true)
        let after = try String(contentsOf: zshrc, encoding: .utf8)
        try check(after.contains("alias keep=") && !after.contains("alias claude-work="), "cleanup did not remove only the recognized alias")
        let backups = try FileManager.default.contentsOfDirectory(atPath: store.root.appendingPathComponent("Backups").path)
        try check(backups.contains(where: { $0.hasPrefix("zshrc-") }), "cleanup did not back up .zshrc before rewriting")
    }

    static func testClaudeLocatorSortsVersionsSemantically() throws {
        let home = try temporaryRoot()
        let versions = home.appendingPathComponent(".local/share/claude/versions")
        for name in ["1.9.0", "1.10.0", "1.2.0"] {
            let dir = versions.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let bin = dir.appendingPathComponent("claude")
            try "#!/bin/sh\necho \(name)".data(using: .utf8)!.write(to: bin)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: bin.path)
        }
        let located = try ClaudeLocator(home: home).locate()
        try check(located.deletingLastPathComponent().lastPathComponent == "1.10.0", "locator picked \(located.path) instead of the semantically newest 1.10.0")
        try check(ClaudeLocator.isVersion("1.10.0", newerThan: "1.9.0"), "1.10.0 should be newer than 1.9.0")
        try check(!ClaudeLocator.isVersion("1.2.0", newerThan: "1.10.0"), "1.2.0 should not be newer than 1.10.0")
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
