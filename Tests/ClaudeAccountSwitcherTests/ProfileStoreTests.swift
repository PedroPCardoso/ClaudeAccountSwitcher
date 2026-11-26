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
        // Hermético: o shell de quem roda os testes exporta CLAUDE_CONFIG_DIR do perfil real (cas-env.sh), e o
        // launcher respeita um CLAUDE_CONFIG_DIR externo. Os testes que precisam dele o passam explicitamente.
        unsetenv("CLAUDE_CONFIG_DIR")
        let tests: [(String, () async throws -> Void)] = [
            ("profile JSON round trip", testProfileRoundTrip),
            ("mcp list parser maps every status marker", testMCPListParser),
            ("login item is only registered from a packaged .app outside .build", testLoginItemCanRegister),
            ("mcp login error keeps the last readable line and drops ANSI and URLs", testMCPLoginErrorLine),
            ("mcp auth candidates include renewable remote servers, not stdio nor connected claude.ai", testMCPAuthCandidates),
            ("cursor feature hidden disables monitoring regardless of preference", testCursorFeatureHidden),
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
            ,("cursor light fetch makes one RPC and reuses models/daily of the same cycle", testCursorLightFetchReusesDetails)
            ,("refresh planner: scheduled cycle skips the CLI and idle profiles", testRefreshPlannerScheduled)
            ,("refresh planner: auth TTL, retry throttle, manual and on-demand scopes", testRefreshPlannerAuthAndScopes)
            ,("refresh planner: cursor details only on their own interval", testRefreshPlannerCursorDetails)
            ,("token usage caches unmodified files", testTokenUsageCachesUnmodifiedFiles)
            ,("token usage reads only appended bytes and dedups across the boundary", testTokenUsageIncrementalAppend)
            ,("token usage waits for a half-written trailing line", testTokenUsagePartialTrailingLine)
            ,("token usage rereads a rewritten file", testTokenUsageRereadsRewrittenFile)
            ,("history incremental append matches a full parse", testHistoryIncrementalAppend)
            ,("daily usage buckets tokens by day and profile", testDailyUsageBucketsByDayAndProfile)
            ,("daily usage aggregates only the profiles it receives", testDailyUsageRespectsSelection)
            ,("daily usage skips invalid lines and empty files", testDailyUsageRobustness)
            ,("daily usage reuses cache for unmodified files", testDailyUsageCachesUnmodifiedFiles)
            ,("daily usage deduplicates streaming chunks by message/request id", testDailyUsageDeduplicatesStreamingChunks)
            ,("token usage deduplicates streaming chunks by message/request id", testTokenUsageDeduplicatesStreamingChunks)
            ,("model pricing weights cache tokens by type", testModelPricingWeightsCacheTokensByType)
            ,("daily usage preserves token breakdown and estimates cost", testDailyUsagePreservesBreakdownAndCost)
            ,("analysis selection defaults to all and honors a saved subset", testAnalysisSelection)
            ,("plan recommendation classifies fabricated series", testPlanRecommendationVerdicts)
            ,("activation skips desktop sync when disabled", testActivationSkipsDesktopWhenDisabled)
            ,("paseo integration is not detected without a config file", testPaseoNotDetectedWithoutConfig)
            ,("paseo symlink re-targets atomically on repeated switches", testPaseoSymlinkRetargets)
            ,("paseo integrate points the claude provider at the symlink and preserves other providers", testPaseoIntegrateSetsClaudeProviderEnv)
            ,("paseo integrate backs up the original config before writing", testPaseoIntegrateBacksUpOriginal)
            ,("activation updates the paseo symlink alongside launchd", testActivationUpdatesPaseoSymlink)
            ,("usage tier maps percent to the same thresholds as the usage view", testUsageTierForPercent)
            ,("status bar label reads the five-hour quota by stable kind", testStatusBarUsageLabel)
            ,("cursor period usage parses cents, millis dates, and computed percent", testCursorParsePeriodUsage)
            ,("cursor aggregated usage parses string token fields per model", testCursorParseAggregated)
            ,("cursor daily spend parses series sorted by day", testCursorParseDaily)
            ,("cursor model family classifies claude/gpt/composer/gemini/grok/other", testCursorModelFamilyClassify)
            ,("cursor fetch degrades gracefully when aggregate fails", testCursorFetchDegradesOnAggregateFailure)
            ,("cursor fetch does not retry on 401", testCursorFetchDoesNotRetryUnauthorized)
            ,("cursor fetch retries on 503", testCursorFetchRetriesOnServerError)
            ,("cursor budget alert fires once per cycle and rearms on new cycle", testCursorBudgetAlertTracker)
            ,("cursor budget threshold falls back to default when invalid", testCursorBudgetAlertThreshold)
            ,("status bar segments honor source off/claude/cursor/both", testStatusBarUsageSegments)
            ,("status bar source migrates legacy showUsageInMenuBar Bool", testStatusBarUsageSourceMigration)
            ,("cursor usage store round-trips a snapshot", testCursorUsageStoreRoundTrip)
            ,("cas resolves a profile by exact name, by email, not found, and ambiguous", testCASProfileResolver)
            ,("cas parses list/current/switch and rejects unknown or missing args", testCASParser)
            ,("cas switch activates the resolved profile and pushes its directory to launchd", testCASSwitchActivatesResolvedProfile)
            ,("cas is installed into the managed bin and removed on cleanup", testShellIntegrationInstallsCAS)
            ,("env script exports the active profile in sh/zsh/bash and follows a switch", testShellEnvScriptExportsActiveProfile)
            ,("activation preserves edits made after the menu snapshot (no lost update)", testActivationPreservesConcurrentEdits)
            ,("store update merges concurrent writers field by field", testStoreUpdateMergesConcurrentWriters)
            ,("launcher stays consistent under rapid concurrent switches", testLauncherSurvivesConcurrentSwitches)
            ,("launcher and env script fail closed on corrupt or dangling active state", testLauncherFailsClosedOnCorruptState)
            ,("store ignores stale temp files and keeps state files private", testStoreIgnoresStaleTemporaryFiles)
            ,("migration imports the global ~/.claude.json into the profile", testMigrationImportsGlobalConfig)
            ,("session activity reports only live claude processes of a profile", testSessionActivityDetectsLiveProcesses)
            ,("active state repair prefers the launchd directory, then the most recently used", testActiveStateRepairSuggestion)
            ,("keychain services parse from a dump and stale ones are those of unknown directories", testKeychainServiceParsingAndStale)
            ,("desktop copy refuses while the app runs and stages the copy atomically", testDesktopCopyRefusesWhileRunningAndStages)
            ,("import directory brings the global config for ~/.claude and rejects symlinks cleanly", testImportDirectory)
            ,("conversation locator finds a session across profiles by id, slug and cwd", testConversationLocator)
            ,("maintenance scan lists old backups, stale temp files and orphans; apply removes them", testMaintenanceScanAndApply)
            ,("desktop activator waits the configured quit timeout without force quitting", testDesktopActivatorQuitTimeout)
            ,("launcher --resume follows the profile that owns the conversation", testLauncherResumeFollowsConversationProfile)
            ,("launcher keeps a CLAUDE_CONFIG_DIR chosen outside the managed root", testLauncherKeepsForeignConfigDir)
            ,("launcher keeps the inherited CLAUDE_CONFIG_DIR of a session it launched itself", testLauncherKeepsInheritedDirOfLaunchedSession)
            ,("paseo revert removes only the launcher command and symlink env, with backup", testPaseoRevertRemovesOnlyOurFields)
            ,("paseo integrate points the claude provider command at the launcher", testPaseoIntegrateSetsCommandToLauncher)
            ,("session archive parses file locations, message lines and search queries", testSessionArchiveModel)
            ,("session archive copies incrementally, keeps rewrites and deletions, searches and restores byte for byte", testSessionArchiveSyncSearchRestore)
            ,("cas parses sync/search/restore/db", testCASArchiveCommands)
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

    static func testUsageTierForPercent() throws {
        try check(UsageTier.forPercent(0) == .ok, "0% should be ok")
        try check(UsageTier.forPercent(69) == .ok, "69% should be ok")
        try check(UsageTier.forPercent(70) == .warning, "70% should be warning")
        try check(UsageTier.forPercent(89) == .warning, "89% should be warning")
        try check(UsageTier.forPercent(90) == .critical, "90% should be critical")
        try check(UsageTier.forPercent(100) == .critical, "100% should be critical")
    }

    static func testStatusBarUsageLabel() throws {
        try check(StatusBarUsage.label(activeUsage: nil) == nil, "nil usage should produce no label")
        let fiveHour = ClaudeUsageSnapshot(quotas: [ClaudeQuota(kind: .fiveHour, key: "Janela 5h", usedPercent: 71.6)], source: "test")
        try check(StatusBarUsage.label(activeUsage: fiveHour) == "72%", "71.6% should round to 72%")
        let weeklyOnly = ClaudeUsageSnapshot(quotas: [ClaudeQuota(kind: .sevenDay, key: "Semanal", usedPercent: 40)], source: "test")
        try check(StatusBarUsage.label(activeUsage: weeklyOnly) == nil, "a snapshot without a five-hour quota should produce no label")
    }

    // MARK: - Cursor usage monitoring

    private static let fakeCursorCredentials = CursorCredentials(
        accessToken: "fake.jwt.token",
        email: "user@example.com",
        membershipType: "pro")

    private static func cursorHTTPResponse(_ status: Int, method: String = "GetCurrentPeriodUsage") -> HTTPURLResponse {
        HTTPURLResponse(
            url: URL(string: "https://api2.cursor.sh/aiserver.v1.DashboardService/\(method)")!,
            statusCode: status, httpVersion: nil, headerFields: nil)!
    }

    private static func periodUsageJSON(spend: Int = 288, limit: Int = 2000, autoPercentUsed: Double = 0.83) -> Data {
        Data("""
        {"billingCycleStart":"1784996555000","billingCycleEnd":"1787674955000",
         "planUsage":{"totalSpend":\(spend),"includedSpend":\(spend),"remaining":\(limit - spend),"limit":\(limit),
           "autoPercentUsed":\(autoPercentUsed),"apiPercentUsed":5.0,"totalPercentUsed":2.5}}
        """.utf8)
    }

    private static func aggregatedJSON() -> Data {
        Data("""
        {"aggregations":[
          {"modelIntent":"claude-opus-5-thinking-high","inputTokens":"54","outputTokens":"24341",
           "cacheWriteTokens":"164315","cacheReadTokens":"1939091","totalCents":260.53},
          {"modelIntent":"gpt-5.3-codex","inputTokens":"100","outputTokens":"200",
           "cacheWriteTokens":"0","cacheReadTokens":"50","totalCents":1.5}
        ]}
        """.utf8)
    }

    private static func dailyJSON() -> Data {
        Data("""
        {"dailySpend":[
          {"day":"1785024000000","category":"composer-2.5-fast","spendCents":50,"totalTokens":"1000"},
          {"day":"1784937600000","category":"claude-opus-5-thinking-high","spendCents":261,"totalTokens":"2127801"}
        ]}
        """.utf8)
    }

    static func testCursorParsePeriodUsage() throws {
        let plan = CursorUsageService.parsePeriodUsage(periodUsageJSON())!
        try check(plan.totalSpendCents == 288, "spend should be 288 cents")
        try check(plan.limitCents == 2000, "limit should be 2000 cents")
        try check(abs(plan.usedPercent - 14.4) < 0.01, "usedPercent should be spend/limit*100=14.4, got \(plan.usedPercent)")
        // Página "Included in Pro": Cursor Models = autoPercentUsed, Other Models = apiPercentUsed.
        try check(plan.cursorModelsPercent == 0.83, "autoPercentUsed should map to the Cursor Models bar")
        try check(plan.otherModelsPercent == 5.0, "apiPercentUsed should map to the Other Models bar")
        try check(plan.dashboardUsedPercent == 5.0, "dashboardUsedPercent is max of the two bars")
        try check(plan.billingCycleStart.timeIntervalSince1970 == 1_784_996_555, "start ms mismatch")
        try check(plan.billingCycleEnd.timeIntervalSince1970 == 1_787_674_955, "end ms mismatch")
    }

    static func testCursorParseAggregated() throws {
        let models = CursorUsageService.parseAggregated(aggregatedJSON())
        try check(models.count == 2, "expected 2 models")
        let claude = models.first { $0.modelIntent.hasPrefix("claude") }!
        try check(claude.input == 54 && claude.output == 24341, "string token fields should parse as Int")
        try check(claude.cacheWrite == 164315 && claude.cacheRead == 1_939_091, "cache tokens mismatch")
        try check(abs(claude.costCents - 260.53) < 0.01, "cost cents mismatch")
    }

    static func testCursorParseDaily() throws {
        let daily = CursorUsageService.parseDaily(dailyJSON())
        try check(daily.count == 2, "expected 2 daily rows")
        try check(daily[0].day < daily[1].day, "daily should be sorted ascending by day")
        try check(daily[0].modelIntent.hasPrefix("claude"), "first day should be the earlier claude row")
        try check(daily[0].totalTokens == 2_127_801, "totalTokens as string should parse")
    }

    static func testCursorModelFamilyClassify() throws {
        try check(CursorModelFamily.classify("claude-opus-5-thinking-high") == .claude, "claude")
        try check(CursorModelFamily.classify("gpt-5.3-codex") == .gpt, "gpt")
        try check(CursorModelFamily.classify("composer-2.5-fast") == .composer, "composer")
        try check(CursorModelFamily.classify("default") == .composer, "default → composer")
        try check(CursorModelFamily.classify("gemini-2.5-pro") == .gemini, "gemini")
        try check(CursorModelFamily.classify("grok-4.5") == .grok, "grok")
        try check(CursorModelFamily.classify("mystery-model") == .other, "unknown")
    }

    static func testCursorFetchDegradesOnAggregateFailure() async throws {
        let counter = CallCounter()
        let service = CursorUsageService(
            retry: UsageRetryPolicy(maxAttempts: 1, baseDelay: 0),
            transport: { request in
                _ = counter.increment()
                let path = request.url?.lastPathComponent ?? ""
                if path == "GetCurrentPeriodUsage" {
                    return (periodUsageJSON(), cursorHTTPResponse(200, method: path))
                }
                // Aggregate and daily fail — snapshot should still have planUsage.
                return (Data(), cursorHTTPResponse(500, method: path))
            },
            credentialProvider: { fakeCursorCredentials })
        let snapshot = try await service.fetch()
        try check(snapshot.planUsage != nil, "planUsage must survive aggregate failure")
        try check(abs((snapshot.planUsage?.usedPercent ?? 0) - 14.4) < 0.01, "percent mismatch")
        try check(snapshot.models.isEmpty, "models should be empty on aggregate failure")
        try check(snapshot.daily.isEmpty, "daily should be empty on daily failure")
        try check(snapshot.email == "user@example.com", "email from credentials")
        try check(snapshot.plan == "pro", "plan from credentials")
    }

    static func testCursorLightFetchReusesDetails() async throws {
        let counter = CallCounter()
        let service = CursorUsageService(
            retry: UsageRetryPolicy(maxAttempts: 1, baseDelay: 0),
            transport: { request in
                _ = counter.increment()
                let path = request.url?.lastPathComponent ?? ""
                switch path {
                case "GetCurrentPeriodUsage": return (periodUsageJSON(), cursorHTTPResponse(200, method: path))
                case "GetAggregatedUsageEvents": return (aggregatedJSON(), cursorHTTPResponse(200, method: path))
                default: return (dailyJSON(), cursorHTTPResponse(200, method: path))
                }
            },
            credentialProvider: { fakeCursorCredentials })
        let full = try await service.fetch()
        try check(counter.count == 3 && !full.models.isEmpty && !full.daily.isEmpty, "full fetch should make 3 RPCs, got \(counter.count)")
        let light = try await service.fetch(includeDetails: false, previous: full)
        try check(counter.count == 4, "light fetch should add exactly 1 RPC, got \(counter.count - 3)")
        try check(light.models == full.models && light.daily == full.daily, "light fetch must reuse models/daily")
        // Sem `previous`, o modo leve não tem o que reaproveitar: busca os detalhes.
        _ = try await service.fetch(includeDetails: false, previous: nil)
        try check(counter.count == 7, "without a previous snapshot the details must still be fetched, got \(counter.count - 4)")
    }

    static func testCursorFetchDoesNotRetryUnauthorized() async throws {
        let counter = CallCounter()
        let service = CursorUsageService(
            retry: UsageRetryPolicy(maxAttempts: 5, baseDelay: 0),
            transport: { _ in _ = counter.increment(); return (Data(), cursorHTTPResponse(401)) },
            credentialProvider: { fakeCursorCredentials })
        do {
            _ = try await service.fetch()
            try check(false, "expected unauthorized to throw")
        } catch CursorUsageError.unauthorized {
            try check(counter.count == 1, "401 must not be retried, got \(counter.count)")
        }
    }

    static func testCursorFetchRetriesOnServerError() async throws {
        let counter = CallCounter()
        let service = CursorUsageService(
            retry: UsageRetryPolicy(maxAttempts: 3, baseDelay: 0),
            transport: { request in
                let attempt = counter.increment()
                let path = request.url?.lastPathComponent ?? ""
                if path == "GetCurrentPeriodUsage" {
                    if attempt < 3 { return (Data(), cursorHTTPResponse(503, method: path)) }
                    return (periodUsageJSON(), cursorHTTPResponse(200, method: path))
                }
                // After period succeeds, aggregate/daily get empty success bodies.
                return (Data(#"{}"#.utf8), cursorHTTPResponse(200, method: path))
            },
            credentialProvider: { fakeCursorCredentials })
        let snapshot = try await service.fetch()
        try check(snapshot.planUsage != nil, "should succeed after retries")
        try check(counter.count >= 3, "expected at least 3 period attempts, got \(counter.count)")
    }

    static func testCursorBudgetAlertTracker() throws {
        var tracker = CursorBudgetAlertTracker()
        let cycle1 = Date(timeIntervalSince1970: 1_800_000_000)
        let cycle2 = Date(timeIntervalSince1970: 1_810_000_000)
        try check(tracker.evaluate(usedPercent: 50, threshold: 80, billingCycleEnd: cycle1) == false, "below threshold")
        try check(tracker.evaluate(usedPercent: 80, threshold: 80, billingCycleEnd: cycle1) == true, "first crossing")
        try check(tracker.evaluate(usedPercent: 90, threshold: 80, billingCycleEnd: cycle1) == false, "same cycle no re-fire")
        try check(tracker.evaluate(usedPercent: 85, threshold: 80, billingCycleEnd: cycle2) == true, "new cycle rearms")
        try check(tracker.evaluate(usedPercent: 50, threshold: 80, billingCycleEnd: nil) == false, "nil cycle end")
    }

    static func testCursorBudgetAlertThreshold() throws {
        try check(CursorBudgetAlertThreshold.resolve(80) == 80, "valid")
        try check(CursorBudgetAlertThreshold.resolve(0) == CursorBudgetAlertThreshold.default, "zero → default")
        try check(CursorBudgetAlertThreshold.resolve(-1) == CursorBudgetAlertThreshold.default, "negative → default")
        try check(CursorBudgetAlertThreshold.resolve(101) == CursorBudgetAlertThreshold.default, "over 100 → default")
    }

    static func testStatusBarUsageSegments() throws {
        let claude = ClaudeUsageSnapshot(quotas: [ClaudeQuota(kind: .fiveHour, key: "Janela 5h", usedPercent: 72)], source: "t")
        let cursor = CursorUsageSnapshot(planUsage: CursorPlanUsage(
            totalSpendCents: 288, includedSpendCents: 288, limitCents: 2000, remainingCents: 1712,
            billingCycleStart: .distantPast, billingCycleEnd: .distantFuture,
            cursorModelsPercent: 1.0, otherModelsPercent: 19.4))
        try check(StatusBarUsage.segments(source: .off, activeClaude: claude, cursor: cursor).isEmpty, "off → empty")
        let cOnly = StatusBarUsage.segments(source: .claude, activeClaude: claude, cursor: cursor)
        try check(cOnly.count == 1 && cOnly[0].text == "72%", "claude only")
        let uOnly = StatusBarUsage.segments(source: .cursor, activeClaude: claude, cursor: cursor)
        try check(uOnly.count == 1 && uOnly[0].text == "19%", "cursor badge uses max dashboard bar (19), not spend/limit")
        let both = StatusBarUsage.segments(source: .both, activeClaude: claude, cursor: cursor)
        try check(both.count == 2 && both[0].text == "C 72%" && both[1].text == "⌘ 19%", "both segments")
    }

    static func testStatusBarUsageSourceMigration() throws {
        let suite = "cas-test-statusbar-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: StatusBarUsageSource.legacyDefaultsKey)
        let migrated = StatusBarUsageSource.resolve(defaults)
        try check(migrated == .claude, "true legacy → claude")
        try check(defaults.string(forKey: StatusBarUsageSource.defaultsKey) == "claude", "should persist migration")
        // Second read uses the new key.
        defaults.set(false, forKey: StatusBarUsageSource.legacyDefaultsKey)
        try check(StatusBarUsageSource.resolve(defaults) == .claude, "new key wins over legacy")
    }

    static func testCursorUsageStoreRoundTrip() throws {
        let store = try CursorUsageStore(root: try temporaryRoot())
        try check(try store.load() == nil, "empty store")
        let snapshot = CursorUsageSnapshot(
            email: "a@b.com",
            plan: "pro",
            planUsage: CursorPlanUsage(
                totalSpendCents: 100, includedSpendCents: 100, limitCents: 2000, remainingCents: 1900,
                billingCycleStart: Date(timeIntervalSince1970: 1_000),
                billingCycleEnd: Date(timeIntervalSince1970: 2_000)),
            models: [CursorModelUsage(modelIntent: "gpt-5", input: 1, output: 2, cacheWrite: 0, cacheRead: 0, costCents: 0.5)],
            daily: [CursorDailySpend(day: Date(timeIntervalSince1970: 1_500), modelIntent: "gpt-5", spendCents: 0.5, totalTokens: 3)])
        try store.save(snapshot)
        let loaded = try store.load()!
        try check(loaded.email == "a@b.com" && loaded.plan == "pro", "identity")
        try check(loaded.models.count == 1 && loaded.daily.count == 1, "collections")
        try check(loaded.planUsage?.totalSpendCents == 100, "plan usage")
    }

    static func temporaryRoot() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func testMCPListParser() throws {
        let output = """
        Checking MCP server health…

        claude.ai Slack: https://mcp.slack.com/mcp - ! Needs authentication
        claude.ai Gmail: https://gmailmcp.googleapis.com/mcp/v1 - ✔ Connected
        whatsapp: http://127.0.0.1:47821/mcp (HTTP) - ✘ Failed to connect — ECONNREFUSED: Unable to connect.
        local: npx -y some-pkg - ⏸ Pending approval
        sentry: /usr/bin/npx -y @sentry/mcp-server --host=a-b - ✔ Connected
        """
        let servers = MCPListParser.parse(output)
        try check(servers.count == 5, "expected 5 servers, got \(servers.count)")
        try check(servers[0] == MCPServerStatus(name: "claude.ai Slack", target: "https://mcp.slack.com/mcp", state: .needsAuthentication), "slack needs auth: \(servers[0])")
        try check(servers[1].state == .connected, "gmail connected")
        try check(servers[2].name == "whatsapp" && servers[2].state == .failed, "whatsapp failed (colon inside message must not break name)")
        try check(servers[3].state == .pendingApproval, "pending approval")
        try check(servers[4].name == "sentry" && servers[4].state == .connected, "sentry connected")
        try check(servers.filter(\.needsAuthentication).map(\.name) == ["claude.ai Slack"], "only slack needs auth")
    }

    static func testMCPAuthCandidates() throws {
        let servers = MCPListParser.parse("""
        claude.ai Slack: https://mcp.slack.com/mcp - ! Needs authentication
        claude.ai Gmail: https://gmailmcp.googleapis.com/mcp/v1 - ✔ Connected
        plugin:datadog:mcp: https://mcp.datadoghq.com/v1/mcp?toolsets= (HTTP) - ✔ Connected
        agz-contabil: https://portal.example.com/api/v1/mcp/contabil (HTTP) - ✔ Connected
        whatsapp: http://127.0.0.1:47821/mcp (HTTP) - ✘ Failed to connect — ECONNREFUSED
        playwright: npx -y @playwright/mcp@latest - ✔ Connected
        local: https://x.example.com/mcp (HTTP) - ⏸ Pending approval
        """)
        let candidates = MCPAuthCandidates.select(servers)
        try check(candidates.map(\.server.name) == ["claude.ai Slack", "plugin:datadog:mcp", "agz-contabil", "whatsapp"], "candidates: \(candidates.map(\.server.name))")
        try check(candidates.map(\.preselected) == [true, false, false, false], "only pending preselected")
    }

    static func testMCPLoginErrorLine() throws {
        let raw = "\u{1B}[2KStarting authentication…\r\n  \u{1B}]8;;https://auth.example.com/x?state=SECRET\u{07}https://auth.example.com/x?state=SECRET\u{1B}]8;;\u{07}\r\n\u{1B}[31mCouldn't complete authentication\u{1B}[0m\r\n"
        let line = ClaudeMCPService.lastMeaningfulLine(raw)
        try check(line == "Couldn't complete authentication", "got: \(line)")
        try check(!line.contains("SECRET"), "never leaks the OAuth URL")
    }

    static func testLoginItemCanRegister() throws {
        try check(LoginItemService.canRegister(bundleURL: URL(fileURLWithPath: "/Users/x/Applications/Claude Account Switcher.app")), "installed app registers")
        try check(!LoginItemService.canRegister(bundleURL: URL(fileURLWithPath: "/Users/x/Develop/CAS/.build/arm64-apple-macosx/debug")), "bare swift run binary never registers")
        try check(!LoginItemService.canRegister(bundleURL: URL(fileURLWithPath: "/Users/x/Develop/CAS/.build/release/Foo.app")), "app inside .build never registers")
    }

    static func testCursorFeatureHidden() throws {
        let defaults = UserDefaults(suiteName: "cas-test-\(UUID().uuidString)")!
        defaults.set(true, forKey: CursorMonitoring.defaultsKey)
        try check(CursorMonitoring.isEnabled(defaults, featureVisible: false) == false, "hidden feature never monitors")
        try check(CursorMonitoring.isEnabled(defaults, featureVisible: true) == true, "visible feature honours preference")
    }

    static func testSessionArchiveModel() throws {
        let main = SessionFileLocation.parse(relativePath: "projects/-Users-me-app/abc-123.jsonl")
        try check(main == SessionFileLocation(relativePath: "projects/-Users-me-app/abc-123.jsonl", projectSlug: "-Users-me-app", sessionID: "abc-123", parentSessionID: nil), "main session location")
        let sub = SessionFileLocation.parse(relativePath: "projects/-Users-me-app/abc-123/subagents/agent-x.jsonl")
        try check(sub?.sessionID == "agent-x" && sub?.parentSessionID == "abc-123" && sub?.resumeID == "abc-123", "subagent location resumes the parent")
        try check(SessionFileLocation.parse(relativePath: "projects/x.jsonl") == nil, "file directly under projects is ignored")
        try check(SessionFileLocation.parse(relativePath: "todos/a/b.jsonl") == nil, "files outside projects are ignored")
        try check(SessionFileLocation.parse(relativePath: "projects/a/b.json") == nil, "non-jsonl ignored")

        let user = SessionLineParser.parse(Data(#"{"type":"user","uuid":"u1","timestamp":"2026-11-01T10:00:00Z","cwd":"/tmp/p","message":{"role":"user","content":"  como faço deploy?  "}}"#.utf8))
        try check(user?.type == "user" && user?.text == "como faço deploy?" && user?.cwd == "/tmp/p", "user string content")
        let assistant = SessionLineParser.parse(Data(#"{"type":"assistant","requestId":"r1","message":{"id":"m1","model":"claude-opus-5-5","content":[{"type":"thinking","thinking":"segredo"},{"type":"text","text":"Use o script"},{"type":"tool_use","name":"Bash","input":{}}],"usage":{"input_tokens":10,"output_tokens":20,"cache_read_input_tokens":30,"cache_creation_input_tokens":40}}}"#.utf8))
        try check(assistant?.text == "Use o script", "only text blocks are indexed (no thinking/tool_use)")
        try check(assistant?.model == "claude-opus-5-5" && assistant?.messageID == "m1" && assistant?.requestID == "r1", "assistant ids")
        try check(assistant?.inputTokens == 10 && assistant?.outputTokens == 20 && assistant?.cacheReadTokens == 30 && assistant?.cacheCreationTokens == 40, "token usage")
        let meta = SessionLineParser.parse(Data(#"{"type":"user","isMeta":true,"message":{"content":"<caveat>"}}"#.utf8))
        try check(meta?.text == "", "meta lines keep metadata but no text")
        let toolResult = SessionLineParser.parse(Data(#"{"type":"user","message":{"content":[{"type":"tool_result","content":"huge output"}]}}"#.utf8))
        try check(toolResult?.text == "", "tool results are not indexed")
        try check(SessionLineParser.parse(Data(#"{"type":"attachment"}"#.utf8)) == nil, "non-message lines are skipped")
        try check(SessionLineParser.parse(Data("not json".utf8)) == nil, "invalid json is skipped")

        try check(SessionSearchQuery.ftsExpression("  deploy  prod-1 ") == #""deploy" "prod-1""#, "each word becomes a quoted term")
        try check(SessionSearchQuery.ftsExpression(#"say "hi""#) == #""say" """hi""""#, "quotes are escaped")
        try check(SessionSearchQuery.ftsExpression("   ") == nil, "blank query")
    }

    static func testSessionArchiveSyncSearchRestore() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let profileDir = root.appendingPathComponent("Profiles/P1/config", isDirectory: true)
        let project = profileDir.appendingPathComponent("projects/-tmp-app", isDirectory: true)
        let subagents = project.appendingPathComponent("sess-1/subagents", isDirectory: true)
        try FileManager.default.createDirectory(at: subagents, withIntermediateDirectories: true)
        let profile = Profile(name: "Work", email: "w@x.com", directory: profileDir)
        let mainFile = project.appendingPathComponent("sess-1.jsonl")
        let subFile = subagents.appendingPathComponent("agent-a.jsonl")
        let bigBlob = String(repeating: "lorem ipsum dolor ", count: 200)
        let lines = [
            #"{"type":"user","uuid":"u1","timestamp":"2026-11-01T10:00:00Z","cwd":"/tmp/app","sessionId":"sess-1","message":{"role":"user","content":"Configurar o pipeline kubernetes"}}"#,
            #"{"type":"attachment","blob":"\#(bigBlob)"}"#,
            #"{"type":"assistant","uuid":"a1","timestamp":"2026-11-01T10:00:05Z","cwd":"/tmp/app","requestId":"r1","message":{"id":"m1","model":"claude-opus-5-5","content":[{"type":"text","text":"Vamos usar helm"}],"usage":{"input_tokens":5,"output_tokens":7}}}"#,
        ]
        let original = lines.joined(separator: "\n") + "\n"
        try original.write(to: mainFile, atomically: true, encoding: .utf8)
        let subContents = #"{"type":"assistant","uuid":"s1","message":{"content":[{"type":"text","text":"subagente analisou terraform"}]}}"# + "\n"
        try subContents.write(to: subFile, atomically: true, encoding: .utf8)
        try "ignore".write(to: project.appendingPathComponent("notes.txt"), atomically: true, encoding: .utf8)

        let archive = SessionArchive(appSupport: root)
        var report = try archive.sync(profiles: [profile])
        try check(report.errors.isEmpty, "first sync errors: \(report.errors)")
        try check(report.filesSeen == 2 && report.filesUpdated == 2 && report.linesAdded == 4, "first sync copies every line: \(report)")

        report = try archive.sync(profiles: [profile])
        try check(report.filesUpdated == 0 && report.linesAdded == 0, "unchanged files are skipped: \(report)")

        // Append: uma linha completa e uma escrita em andamento (sem \n, JSON incompleto).
        let appended = #"{"type":"user","uuid":"u2","timestamp":"2026-11-01T10:01:00Z","message":{"content":"agora o rollback"}}"# + "\n"
        let handle = try FileHandle(forWritingTo: mainFile)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data((appended + #"{"type":"user","mess"#).utf8))
        try handle.close()
        report = try archive.sync(profiles: [profile])
        try check(report.linesAdded == 1 && report.revisionsCreated == 0, "append reads only the new complete line: \(report)")

        let hits = try archive.search("kubernetes")
        try check(hits.count == 1 && hits[0].resumeID == "sess-1" && hits[0].profileName == "Work" && hits[0].cwd == "/tmp/app", "search finds the user message: \(hits)")
        try check(hits[0].snippet.contains("[kubernetes]"), "snippet highlights the match: \(hits[0].snippet)")
        let subHits = try archive.search("terraform")
        try check(subHits.first?.resumeID == "sess-1", "subagent hits resume the parent session")
        try check(try archive.search("thinking-nao-indexado").isEmpty, "unknown words find nothing")

        // Restore num perfil vazio: bytes idênticos (sem a linha incompleta) + subagente.
        let restoreDir = root.appendingPathComponent("Restore", isDirectory: true)
        let candidates = try archive.candidates(sessionPrefix: "sess")
        try check(candidates == [SessionArchive.SessionCandidate(sessionID: "sess-1", profileID: profile.id.uuidString)], "prefix lookup: \(candidates)")
        var result = try archive.restore(sessionID: "sess-1", fromProfileID: profile.id.uuidString, into: restoreDir)
        try check(result.written.count == 2 && result.alreadyPresent.isEmpty && result.cwd == "/tmp/app", "restore result: \(result)")
        let restoredMain = try String(contentsOf: restoreDir.appendingPathComponent("projects/-tmp-app/sess-1.jsonl"), encoding: .utf8)
        try check(restoredMain == original + appended, "restored main session is byte for byte (compressed line included)")
        let restoredSub = try String(contentsOf: restoreDir.appendingPathComponent("projects/-tmp-app/sess-1/subagents/agent-a.jsonl"), encoding: .utf8)
        try check(restoredSub == subContents, "restored subagent transcript")
        result = try archive.restore(sessionID: "sess-1", fromProfileID: profile.id.uuidString, into: restoreDir)
        try check(result.written.isEmpty && result.alreadyPresent.count == 2, "restore never overwrites existing files")

        // Reescrita (início diferente) vira nova revisão; o conteúdo antigo continua no banco.
        // A última linha é JSON completo SEM `\n` e com espaços finais: o restore tem que devolvê-la igual.
        let rewritten = #"{"type":"user","uuid":"n1","message":{"content":"conversa compactada"}}"# + "\n" + #"{"type":"system"}"# + "  "
        try rewritten.write(to: mainFile, atomically: true, encoding: .utf8)
        report = try archive.sync(profiles: [profile])
        try check(report.revisionsCreated == 1 && report.linesAdded == 2, "rewrite creates a revision: \(report)")
        try check(try archive.search("kubernetes").count == 1, "old revision stays searchable")
        let latestDir = root.appendingPathComponent("Latest", isDirectory: true)
        _ = try archive.restore(sessionID: "sess-1", fromProfileID: profile.id.uuidString, into: latestDir)
        let latest = try String(contentsOf: latestDir.appendingPathComponent("projects/-tmp-app/sess-1.jsonl"), encoding: .utf8)
        try check(latest == rewritten, "restore uses the latest revision")

        // Apagado do disco (limpeza de 30 dias do CLI): marcado, nunca removido do banco.
        try FileManager.default.removeItem(at: mainFile)
        report = try archive.sync(profiles: [profile])
        try check(report.filesMarkedDeleted == 1, "deleted file is marked: \(report)")
        let afterDelete = try archive.search("compactada")
        try check(afterDelete.count == 1 && afterDelete[0].deleted, "deleted sessions stay searchable and flagged")
        try check(try archive.sync(profiles: [profile]).filesMarkedDeleted == 0, "deletion is marked only once")
    }

    static func testCASArchiveCommands() throws {
        try check(CASParser.parse(["sync"]) == .sync, "sync")
        try check(CASParser.parse(["sync", "x"]) == .help(exitCode: 1), "sync takes no args")
        try check(CASParser.parse(["search", "deploy", "prod"]) == .search("deploy prod", limit: 20), "search joins words")
        try check(CASParser.parse(["search", "--limit", "5", "deploy"]) == .search("deploy", limit: 5), "search --limit")
        try check(CASParser.parse(["search"]) == .help(exitCode: 1), "search needs text")
        try check(CASParser.parse(["search", "x", "--limit", "0"]) == .help(exitCode: 1), "limit must be positive")
        try check(CASParser.parse(["restore", "abc"]) == .restore("abc", profile: nil), "restore id")
        try check(CASParser.parse(["restore", "abc", "--profile", "Work"]) == .restore("abc", profile: "Work"), "restore --profile")
        try check(CASParser.parse(["restore"]) == .help(exitCode: 1), "restore needs id")
        try check(CASParser.parse(["restore", "a", "b"]) == .help(exitCode: 1), "restore takes one id")
        try check(CASParser.parse(["db"]) == .db([]), "db")
        try check(CASParser.parse(["db", "select 1"]) == .db(["select 1"]), "db passes sql through")
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
        let id = UUID()
        let profile = Profile(id: id, name: "Remover", directory: try store.createManagedDirectory(id: id))
        try store.save(profile)
        // A sessão do app nativo vive no irmão `desktop`; remover o perfil tem de levá-la junto
        // (o alerta promete apagar "sessões e credencial", e cookies logados não podem sobrar).
        try FileManager.default.createDirectory(at: profile.desktopDirectory, withIntermediateDirectories: true)
        try "cookie-bytes".write(to: profile.desktopDirectory.appendingPathComponent("Cookies"), atomically: true, encoding: .utf8)
        try store.remove(profile)
        try check(try store.list().isEmpty, "removed profile remains in metadata")
        try check(!FileManager.default.fileExists(atPath: profile.directory.path), "removed profile directory still exists")
        try check(!FileManager.default.fileExists(atPath: profile.desktopDirectory.path), "desktop session of the removed profile was left on disk")
        try check(!FileManager.default.fileExists(atPath: profile.directory.deletingLastPathComponent().path), "Profiles/<uuid> container was left behind")
        try check(try store.orphanedProfileDirectories().isEmpty, "removal must not create an orphan for maintenance to find")
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

    static func testCASProfileResolver() throws {
        let personal = Profile(name: "Personal", email: "me@example.com", directory: URL(fileURLWithPath: "/tmp/a"))
        let work = Profile(name: "Work", email: "work@example.com", directory: URL(fileURLWithPath: "/tmp/b"))
        // Exato por nome.
        guard case .found(let byName) = ProfileResolver.resolve([personal, work], query: "Personal") else { throw TestFailure.failed("expected an exact name match") }
        try check(byName.id == personal.id, "name match returned the wrong profile")
        // Exato por email.
        guard case .found(let byEmail) = ProfileResolver.resolve([personal, work], query: "work@example.com") else { throw TestFailure.failed("expected an exact email match") }
        try check(byEmail.id == work.id, "email match returned the wrong profile")
        // Não encontrado.
        guard case .notFound = ProfileResolver.resolve([personal, work], query: "nope") else { throw TestFailure.failed("expected notFound for an unknown query") }
        // Ambíguo: dois perfis com o mesmo nome.
        let personalTwo = Profile(name: "Personal", email: "other@example.com", directory: URL(fileURLWithPath: "/tmp/c"))
        guard case .ambiguous(let matches) = ProfileResolver.resolve([personal, personalTwo], query: "Personal") else { throw TestFailure.failed("expected ambiguous for a duplicated name") }
        try check(matches.count == 2, "ambiguous resolution should return every match")
    }

    static func testCASParser() throws {
        try check(CASParser.parse(["list"]) == .list, "list was not parsed")
        try check(CASParser.parse(["current"]) == .current, "current was not parsed")
        try check(CASParser.parse(["switch", "work"]) == .switchProfile("work"), "switch <target> was not parsed")
        // Ajuda explícita sai com 0; uso incorreto sai com código ≠ 0.
        guard case .help(let helpCode) = CASParser.parse(["--help"]), helpCode == 0 else { throw TestFailure.failed("--help should exit 0") }
        guard case .help(let noArgCode) = CASParser.parse([]), noArgCode != 0 else { throw TestFailure.failed("no arguments should map to usage with a non-zero exit") }
        guard case .help(let unknownCode) = CASParser.parse(["bogus"]), unknownCode != 0 else { throw TestFailure.failed("an unknown command should map to usage with a non-zero exit") }
        guard case .help(let switchCode) = CASParser.parse(["switch"]), switchCode != 0 else { throw TestFailure.failed("switch without a target should map to usage with a non-zero exit") }
    }

    static func testCASSwitchActivatesResolvedProfile() async throws {
        let root = try temporaryRoot(); let store = try ProfileStore(root: root); let fake = FakeLaunchd()
        let directory = root.appendingPathComponent("config"); try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let profile = Profile(name: "Work", email: "work@example.com", directory: directory)
        try store.save(profile)
        // Resolve exatamente como a CLI faz, depois ativa pelo mesmo serviço injetável.
        guard case .found(let target) = ProfileResolver.resolve(try store.list(), query: "work@example.com") else { throw TestFailure.failed("expected an exact email match") }
        let service = ActivationService(store: store, launchd: fake)
        _ = try await service.activate(target, syncDesktopApp: false)
        try check(try store.active()?.id == profile.id, "switch did not set the resolved profile as active")
        try check(fake.values.contains(directory.path), "switch did not push the profile directory to launchd")
    }

    static func testShellIntegrationInstallsCAS() throws {
        let home = try temporaryRoot(); let app = home.appendingPathComponent("support")
        let manager = ShellIntegrationManager(appSupport: app)
        let casBinary = home.appendingPathComponent("cas-binary")
        try "#!/bin/sh\n".write(to: casBinary, atomically: true, encoding: .utf8)
        try manager.install(home: home, officialBinary: URL(fileURLWithPath: "/bin/echo"), casBinary: casBinary)
        let installed = app.appendingPathComponent("bin/cas")
        try check(FileManager.default.fileExists(atPath: installed.path), "install did not place cas in the managed bin")
        try check((try FileManager.default.destinationOfSymbolicLink(atPath: installed.path)) == casBinary.path, "cas symlink did not point at the provided binary")
        // Reinstalar não deve falhar por symlink já existente (idempotência).
        try manager.install(home: home, officialBinary: URL(fileURLWithPath: "/bin/echo"), casBinary: casBinary)
        try check(FileManager.default.fileExists(atPath: installed.path), "reinstall dropped the cas symlink")
        try manager.remove(home: home)
        try check((try? FileManager.default.destinationOfSymbolicLink(atPath: installed.path)) == nil, "remove did not delete cas from the managed bin")
    }

    static func testShellEnvScriptExportsActiveProfile() throws {
        let root = try temporaryRoot(); let app = root.appendingPathComponent("app-support")
        let store = try ProfileStore(root: app)
        let firstDir = root.appendingPathComponent("first profile"); let secondDir = root.appendingPathComponent("second profile")
        try FileManager.default.createDirectory(at: firstDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: secondDir, withIntermediateDirectories: true)
        let first = Profile(name: "First", directory: firstDir); let second = Profile(name: "Second", directory: secondDir)
        try store.save(first); try store.save(second); try store.setActive(ActiveProfile(id: first.id, directory: first.directory))
        let shell = ShellIntegrationManager(appSupport: app); let home = root.appendingPathComponent("home"); try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try shell.install(home: home, officialBinary: URL(fileURLWithPath: "/usr/bin/env"))
        let script = shell.envScriptURL()
        try check(FileManager.default.fileExists(atPath: script.path), "install did not write the env script")
        // O bloco instalado precisa sourcear o script (é ele que leva a variável ao shell).
        let zshrc = try String(contentsOf: home.appendingPathComponent(".zshrc"), encoding: .utf8)
        try check(zshrc.contains(". '\(script.path)'"), "zshrc block does not source the env script")
        let fish = home.appendingPathComponent(".config/fish/config.fish")
        try check(!FileManager.default.fileExists(atPath: fish.path) && FileManager.default.fileExists(atPath: shell.fishEnvScriptURL().path), "fish script should exist even when config.fish is absent")
        // Sourceado em sh, zsh e bash, exporta o diretório do perfil ativo.
        for interpreter in ["/bin/sh", "/bin/zsh", "/bin/bash"] {
            let result = try ProcessRunner().run(executable: URL(fileURLWithPath: interpreter), arguments: ["-c", ". \"$1\"; printf '%s' \"$CLAUDE_CONFIG_DIR\"", "cas", script.path])
            try check(result.stdout == firstDir.path, "\(interpreter) did not export the active profile: stdout=\(result.stdout) stderr=\(result.stderr)")
        }
        // Após uma troca, o refresh de prompt reexporta (o mtime do estado muda).
        try store.setActive(ActiveProfile(id: second.id, directory: second.directory))
        for (index, interpreter) in ["/bin/zsh", "/bin/bash"].enumerated() {
            // Força um mtime diferente do visto no source (a troca real pode cair no mesmo segundo);
            // um timestamp por interpretador, senão o segundo veria o mtime que o primeiro já deixou.
            let body = ". \"$1\"; CLAUDE_CONFIG_DIR=stale; /usr/bin/touch -t 2020010\(index + 1)0000 \"$2\"; _cas_env_refresh; printf '%s' \"$CLAUDE_CONFIG_DIR\""
            let result = try ProcessRunner().run(executable: URL(fileURLWithPath: interpreter), arguments: ["-c", body, "cas", script.path, store.activeURL.path])
            try check(result.stdout == secondDir.path, "\(interpreter) refresh did not follow the switch: stdout=\(result.stdout) stderr=\(result.stderr)")
        }
        try shell.remove(home: home)
        try check(!FileManager.default.fileExists(atPath: script.path) && !FileManager.default.fileExists(atPath: shell.fishEnvScriptURL().path), "remove did not delete the env scripts")
    }

    // MARK: - Troca de perfil: perda/corrupção de estado

    static func testActivationPreservesConcurrentEdits() async throws {
        let root = try temporaryRoot(); let store = try ProfileStore(root: root)
        let dir = root.appendingPathComponent("config"); try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let stale = Profile(name: "Old name", directory: dir); try store.save(stale)
        // Entre montar o menu (snapshot `stale`) e o clique, o refresh de 60s gravou uso/email
        // novos e o usuário renomeou o perfil. A ativação não pode reverter nada disso.
        var fresh = stale; fresh.name = "New name"; fresh.email = "me@example.com"
        fresh.usage = ClaudeUsageSnapshot(quotas: [ClaudeQuota(kind: .fiveHour, key: "Janela 5h", usedPercent: 42)], source: "test")
        try store.save(fresh)
        let service = ActivationService(store: store, launchd: FakeLaunchd())
        let result = try await service.activate(stale, syncDesktopApp: false)
        let persisted = try store.list().first(where: { $0.id == stale.id })
        try check(persisted?.name == "New name", "activation reverted a rename made after the menu snapshot")
        try check(persisted?.email == "me@example.com", "activation reverted the email refreshed after the menu snapshot")
        try check(persisted?.usage?.quotas.first?.usedPercent == 42, "activation wiped the usage snapshot fetched after the menu snapshot")
        try check(persisted?.lastUsedAt != nil && persisted?.health == .ready, "activation did not record lastUsedAt/health")
        try check(result.profile.name == "New name", "activation result should carry the fresh record, not the stale one")
        try check(try store.active()?.id == stale.id, "profile was not activated")
    }

    static func testStoreUpdateMergesConcurrentWriters() throws {
        let root = try temporaryRoot(); let store = try ProfileStore(root: root)
        let dir = root.appendingPathComponent("config"); try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let profile = Profile(name: "", directory: dir); try store.save(profile)
        // 100 escritores concorrentes, cada um lendo-modificando-gravando via update(id:).
        // Com save(struct inteiro) alguns incrementos se perderiam; com update nenhum.
        let group = DispatchGroup(); let errors = NSLock(); var failures = 0
        for _ in 0..<100 {
            DispatchQueue.global().async(group: group) {
                do { _ = try store.update(id: profile.id) { $0.name += "x" } }
                catch { errors.lock(); failures += 1; errors.unlock() }
            }
        }
        group.wait()
        try check(failures == 0, "update threw for an existing profile")
        try check(try store.list().first(where: { $0.id == profile.id })?.name.count == 100, "lost update: expected 100 merged writes, got \(try store.list().first(where: { $0.id == profile.id })?.name.count ?? -1)")
        var threw = false
        do { _ = try store.update(id: UUID()) { $0.name = "ghost" } } catch StoreError.missingProfile { threw = true }
        try check(threw, "update must fail for an unknown profile instead of creating one")
        try check(try store.list().count == 1, "update created a profile for an unknown id")
    }

    static func testLauncherSurvivesConcurrentSwitches() async throws {
        let root = try temporaryRoot(); let app = root.appendingPathComponent("app-support")
        let store = try ProfileStore(root: app)
        let firstDir = root.appendingPathComponent("first profile"); let secondDir = root.appendingPathComponent("second profile")
        try FileManager.default.createDirectory(at: firstDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: secondDir, withIntermediateDirectories: true)
        let first = Profile(name: "First", directory: firstDir); let second = Profile(name: "Second", directory: secondDir)
        try store.save(first); try store.save(second)
        let shell = ShellIntegrationManager(appSupport: app); let home = root.appendingPathComponent("home"); try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try shell.install(home: home, officialBinary: URL(fileURLWithPath: "/usr/bin/env"))
        let service = ActivationService(store: store, launchd: FakeLaunchd())
        _ = try await service.activate(first, syncDesktopApp: false)
        // Troca 60 vezes em background enquanto o launcher é invocado repetidamente: cada
        // invocação deve resolver UM dos dois diretórios — nunca JSON parcial (exit 78) nem
        // um caminho misturado. Também confere que o estado final é coerente.
        let switching = Task.detached {
            for i in 0..<60 { _ = try await service.activate(i % 2 == 0 ? second : first, syncDesktopApp: false) }
        }
        var seen = Set<String>()
        for _ in 0..<40 {
            let result: ProcessResult
            do { result = try ProcessRunner().run(executable: shell.launcherURL()) }
            catch { throw TestFailure.failed("launcher failed mid-switch: \(error)") }
            guard let line = result.stdout.split(separator: "\n").first(where: { $0.hasPrefix("CLAUDE_CONFIG_DIR=") }) else { throw TestFailure.failed("launcher did not export CLAUDE_CONFIG_DIR") }
            let value = String(line.dropFirst("CLAUDE_CONFIG_DIR=".count))
            try check(value == firstDir.path || value == secondDir.path, "launcher resolved an inconsistent directory: \(value)")
            seen.insert(value)
        }
        try await switching.value
        let active = try store.active()
        try check(active?.id == first.id, "final active profile should be First after an even number of switches")
        let final = try ProcessRunner().run(executable: shell.launcherURL())
        try check(final.stdout.contains("CLAUDE_CONFIG_DIR=\(firstDir.path)"), "launcher disagrees with the store after the switch storm")
        try check(try store.list().count == 2, "switch storm corrupted profiles.json")
        _ = seen
    }

    static func testLauncherFailsClosedOnCorruptState() throws {
        let root = try temporaryRoot(); let app = root.appendingPathComponent("app-support")
        let store = try ProfileStore(root: app)
        let dir = root.appendingPathComponent("config"); try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let profile = Profile(name: "P", directory: dir); try store.save(profile); try store.setActive(ActiveProfile(id: profile.id, directory: dir))
        let shell = ShellIntegrationManager(appSupport: app); let home = root.appendingPathComponent("home"); try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try shell.install(home: home, officialBinary: URL(fileURLWithPath: "/usr/bin/env"))
        func launcherExit() -> Int32? {
            do { _ = try ProcessRunner().run(executable: shell.launcherURL()); return 0 }
            catch ProcessRunnerError.failed(let result) { return result.exitCode }
            catch { return nil }
        }
        func envScriptExport() throws -> String {
            // Começa sem a variável: o script não pode exportar lixo nem herdar valor antigo.
            let result = try ProcessRunner().run(executable: URL(fileURLWithPath: "/usr/bin/env"), arguments: ["-u", "CLAUDE_CONFIG_DIR", "/bin/sh", "-c", ". \"$1\"; printf '%s' \"${CLAUDE_CONFIG_DIR:-unset}\"", "cas", shell.envScriptURL().path])
            return result.stdout
        }
        try check(launcherExit() == 0, "precondition: launcher should work with a valid state")
        // 1) JSON truncado (gravação interrompida sem rename atômico, ou edição manual).
        try "{\"id\": \"".write(to: store.activeURL, atomically: true, encoding: .utf8)
        try check(launcherExit() == 78, "launcher must fail closed (exit 78) on a corrupt state file, never fall back to ~/.claude")
        try check(try envScriptExport() == "unset", "env script exported something from a corrupt state file")
        var threw = false
        do { _ = try store.active() } catch StoreError.corruptState { threw = true }
        try check(threw, "store must surface a corrupt active-profile.json instead of returning nil silently")
        // 2) Estado válido apontando para um diretório que já não existe (perfil apagado por fora).
        let gone = root.appendingPathComponent("gone"); try FileManager.default.createDirectory(at: gone, withIntermediateDirectories: true)
        try store.setActive(ActiveProfile(id: profile.id, directory: gone)); try FileManager.default.removeItem(at: gone)
        try check(launcherExit() == 78, "launcher must refuse a dangling profile directory")
        try check(try envScriptExport() == "unset", "env script exported a dangling directory")
        // 3) Estado ausente.
        try FileManager.default.removeItem(at: store.activeURL)
        try check(launcherExit() == 78, "launcher must refuse to run without an active profile")
        try check(try envScriptExport() == "unset", "env script exported without an active profile")
        try check(try store.active() == nil, "store should report no active profile when the file is absent")
    }

    static func testStoreIgnoresStaleTemporaryFiles() throws {
        let root = try temporaryRoot(); let store = try ProfileStore(root: root)
        let id = UUID(); let dir = try store.createManagedDirectory(id: id)
        let profile = Profile(id: id, name: "P", directory: dir); try store.save(profile)
        // Restos de um atomicWrite interrompido (crash entre write e rename) e lixo não-UUID em
        // Profiles/ não podem afetar a leitura nem aparecer como órfãos.
        try "garbage".write(to: root.appendingPathComponent("profiles.json.tmp-DEAD"), atomically: true, encoding: .utf8)
        try "garbage".write(to: root.appendingPathComponent("active-profile.json.tmp-DEAD"), atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(at: store.profilesDirectory.appendingPathComponent("not-a-uuid"), withIntermediateDirectories: true)
        try check(try store.list().count == 1, "stale temp files affected profile listing")
        try check(try store.orphanedProfileDirectories().isEmpty, "non-UUID junk was reported as an orphaned profile")
        // Arquivos de estado preexistentes com permissão larga (versões antigas gravavam 644)
        // devem voltar a 600 na próxima gravação — contêm o caminho das credenciais.
        try store.setActive(ActiveProfile(id: profile.id, directory: dir))
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: store.activeURL.path)
        try store.setActive(ActiveProfile(id: profile.id, directory: dir))
        let perms = (try FileManager.default.attributesOfItem(atPath: store.activeURL.path)[.posixPermissions] as? Int) ?? -1
        try check(perms == 0o600, "active-profile.json kept permissions \(String(perms, radix: 8)) after rewrite; expected 600")
    }

    static func testMigrationImportsGlobalConfig() throws {
        let home = try temporaryRoot(); let source = home.appendingPathComponent(".claude")
        try FileManager.default.createDirectory(at: source.appendingPathComponent("projects"), withIntermediateDirectories: true)
        // Sem CLAUDE_CONFIG_DIR o Claude Code guarda `~/.claude.json` FORA de `~/.claude`
        // (MCP servers de usuário, projetos confiáveis, onboarding). Com o perfil ativo ele passa a
        // ler `<perfil>/.claude.json`; importar só a pasta perde tudo isso.
        try "{\"mcpServers\":{}}".write(to: home.appendingPathComponent(".claude.json"), atomically: true, encoding: .utf8)
        let store = try ProfileStore(root: home.appendingPathComponent("managed"))
        let plan = try MigrationService(store: store).preview(home: home)
        let report = try MigrationService(store: store).execute(plan)
        let copied = report.imported[0].appendingPathComponent(".claude.json")
        try check(try String(contentsOf: copied, encoding: .utf8) == "{\"mcpServers\":{}}", "global ~/.claude.json was not imported into the profile")
        try check(FileManager.default.fileExists(atPath: home.appendingPathComponent(".claude.json").path), "source ~/.claude.json was moved instead of copied")
        // Quando a pasta já traz o seu próprio .claude.json (ex.: ~/.claude-work usado via
        // CLAUDE_CONFIG_DIR), o arquivo da pasta vence e o global não o sobrescreve.
        let work = home.appendingPathComponent(".claude-work"); try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        try "own".write(to: work.appendingPathComponent(".claude.json"), atomically: true, encoding: .utf8)
        let store2 = try ProfileStore(root: home.appendingPathComponent("managed-2"))
        let report2 = try MigrationService(store: store2).execute(try MigrationService(store: store2).preview(home: home))
        let workImported = report2.imported.first(where: { (try? String(contentsOf: $0.appendingPathComponent(".claude.json"), encoding: .utf8)) == "own" })
        try check(workImported != nil, "a source with its own .claude.json must keep it")
    }

    static func testSessionActivityDetectsLiveProcesses() throws {
        let root = try temporaryRoot(); let sessions = root.appendingPathComponent("sessions")
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        try check(SessionActivity.runningSessions(in: root).isEmpty, "empty sessions directory should report nothing")
        // Processo vivo (este teste) e um pid que já terminou (filho encerrado).
        let dead = Process(); dead.executableURL = URL(fileURLWithPath: "/usr/bin/true"); try dead.run(); dead.waitUntilExit()
        let me = ProcessInfo.processInfo.processIdentifier
        try "{\"pid\":\(me),\"sessionId\":\"abc\",\"cwd\":\"/tmp/work\",\"status\":\"idle\"}".write(to: sessions.appendingPathComponent("\(me).json"), atomically: true, encoding: .utf8)
        try "{\"pid\":\(dead.processIdentifier),\"sessionId\":\"dead\"}".write(to: sessions.appendingPathComponent("\(dead.processIdentifier).json"), atomically: true, encoding: .utf8)
        try "not json".write(to: sessions.appendingPathComponent("garbage.json"), atomically: true, encoding: .utf8)
        try "{}".write(to: sessions.appendingPathComponent("\(me).deadbeef.key"), atomically: true, encoding: .utf8)
        let live = SessionActivity.runningSessions(in: root)
        try check(live.count == 1, "expected exactly one live session, got \(live.count)")
        try check(live.first?.pid == me && live.first?.sessionID == "abc" && live.first?.cwd == "/tmp/work", "live session fields were not parsed")
        try check(SessionActivity.runningSessions(in: root.appendingPathComponent("missing")).isEmpty, "missing profile directory should report nothing")
    }

    static func testActiveStateRepairSuggestion() throws {
        let a = Profile(name: "A", directory: URL(fileURLWithPath: "/tmp/cas/a/config"), lastUsedAt: Date(timeIntervalSince1970: 100))
        let b = Profile(name: "B", directory: URL(fileURLWithPath: "/tmp/cas/b/config"), lastUsedAt: Date(timeIntervalSince1970: 200))
        let c = Profile(name: "C", directory: URL(fileURLWithPath: "/tmp/cas/c/config"))
        try check(ActiveStateRepair.suggestion(profiles: [a, b, c], launchdDirectory: "/tmp/cas/a/config/")?.id == a.id, "launchd directory should win even with a trailing slash")
        try check(ActiveStateRepair.suggestion(profiles: [a, b, c], launchdDirectory: "/elsewhere")?.id == b.id, "unknown launchd directory should fall back to the most recently used")
        try check(ActiveStateRepair.suggestion(profiles: [a, b, c], launchdDirectory: nil)?.id == b.id, "nil launchd should pick the most recently used")
        try check(ActiveStateRepair.suggestion(profiles: [], launchdDirectory: nil) == nil, "no profiles → no suggestion")
    }

    static func testKeychainServiceParsingAndStale() throws {
        let dirA = URL(fileURLWithPath: "/tmp/cas/a/config"); let dirB = URL(fileURLWithPath: "/tmp/cas/b/config")
        let a = KeychainCredentials.serviceName(for: dirA); let b = KeychainCredentials.serviceName(for: dirB)
        try check(a.hasPrefix("Claude Code-credentials-") && a.count == "Claude Code-credentials-".count + 8 && a != b, "service name must be prefix + 8 hex chars, distinct per directory")
        try check(KeychainCredentials.serviceName(for: URL(fileURLWithPath: "/tmp/cas/a/config/")) == a, "trailing slash must not change the service name")
        let dump = """
        keychain: "/Users/x/Library/Keychains/login.keychain-db"
            "svce"<blob>="\(a)"
            "acct"<blob>="x"
            "svce"<blob>="Claude Code-credentials"
            "svce"<blob>="Claude Code-credentials-deadbeef"
            "svce"<blob>="Cursor Safe Storage"
            "svce"<blob>="\(a)"
        """
        let services = KeychainCredentials.parseServices(dump: dump)
        try check(services == [a, "Claude Code-credentials-deadbeef"].sorted(), "parse should keep only suffixed Claude Code services, deduplicated: \(services)")
        // Só credenciais de diretórios órfãos do PRÓPRIO app podem ser apagadas. Uma credencial de
        // pasta externa (~/.claude-work, pasta de outro app) não é "de perfil que já não existe":
        // apagá-la destruiria um login que o usuário ainda usa fora do switcher.
        let orphanContainer = URL(fileURLWithPath: "/tmp/cas/Profiles/DEADBEEF-0000-0000-0000-000000000000")
        let orphanService = KeychainCredentials.serviceName(for: orphanContainer.appendingPathComponent("config"))
        let external = KeychainCredentials.serviceName(for: URL(fileURLWithPath: "/Users/x/.claude-work"))
        let candidates = [a, orphanService, external, "Claude Code-credentials-deadbeef"]
        try check(KeychainCredentials.stale(services: candidates, orphanedProfileDirectories: [orphanContainer]) == [orphanService], "stale must list only services of orphaned managed directories")
        try check(KeychainCredentials.stale(services: candidates, orphanedProfileDirectories: []).isEmpty, "no orphans → nothing to delete, even with unknown services present")
    }

    static func testDesktopCopyRefusesWhileRunningAndStages() throws {
        let home = try temporaryRoot()
        let source = home.appendingPathComponent("Library/Application Support/Claude")
        try FileManager.default.createDirectory(at: source.appendingPathComponent("Local Storage/leveldb"), withIntermediateDirectories: true)
        try "cookie-bytes".write(to: source.appendingPathComponent("Cookies"), atomically: true, encoding: .utf8)
        try "log".write(to: source.appendingPathComponent("Local Storage/leveldb/000001.log"), atomically: true, encoding: .utf8)
        let store = try ProfileStore(root: home.appendingPathComponent("managed"))
        let id = UUID(); let dir = try store.createManagedDirectory(id: id); let profile = Profile(id: id, name: "P", directory: dir)
        var threw = false
        do { _ = try MigrationService(store: store).copyDefaultDesktopSessionIfAvailable(into: profile, home: home, isDesktopRunning: { true }) }
        catch MigrationError.desktopAppRunning { threw = true }
        try check(threw, "copy must refuse while the desktop app is running")
        try check(!FileManager.default.fileExists(atPath: profile.desktopDirectory.path), "nothing may be created when the copy is refused")
        let copied = try MigrationService(store: store).copyDefaultDesktopSessionIfAvailable(into: profile, home: home, isDesktopRunning: { false })
        try check(copied && MigrationService.hasRealDesktopSession(at: profile.desktopDirectory), "copy did not produce a real session")
        let siblings = try FileManager.default.contentsOfDirectory(atPath: dir.deletingLastPathComponent().path)
        try check(!siblings.contains(where: { $0.hasPrefix(".desktop.tmp-") }), "staging directory was left behind: \(siblings)")
        // Um `desktop` pré-existente mas sem sessão real (pasta vazia criada pelo sync) não bloqueia a cópia.
        let other = Profile(id: UUID(), name: "Q", directory: try store.createManagedDirectory(id: UUID()))
        try FileManager.default.createDirectory(at: other.desktopDirectory, withIntermediateDirectories: true)
        try check(try MigrationService(store: store).copyDefaultDesktopSessionIfAvailable(into: other, home: home), "empty pre-existing desktop dir must be replaced by the copy")
        try check(MigrationService.hasRealDesktopSession(at: other.desktopDirectory), "copy into a pre-existing empty desktop dir failed")
    }

    static func testImportDirectory() throws {
        let home = try temporaryRoot()
        let dotClaude = home.appendingPathComponent(".claude"); try FileManager.default.createDirectory(at: dotClaude.appendingPathComponent("projects"), withIntermediateDirectories: true)
        try "global".write(to: home.appendingPathComponent(".claude.json"), atomically: true, encoding: .utf8)
        let store = try ProfileStore(root: home.appendingPathComponent("managed"))
        let imported = try MigrationService(store: store).importDirectory(dotClaude, home: home)
        try check(try String(contentsOf: imported.directory.appendingPathComponent(".claude.json"), encoding: .utf8) == "global", "import of ~/.claude must bring ~/.claude.json")
        try check(FileManager.default.fileExists(atPath: imported.directory.appendingPathComponent("projects").path), "import did not copy the folder contents")
        try check(try store.list().count == 1 && imported.name == ".claude", "imported profile not saved with the folder name")
        // Outra pasta qualquer: não recebe o global; symlink dentro aborta sem deixar diretório gerenciado órfão.
        let other = home.appendingPathComponent("other"); try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        try "own".write(to: other.appendingPathComponent("settings.json"), atomically: true, encoding: .utf8)
        let plain = try MigrationService(store: store).importDirectory(other, home: home, name: "Other")
        try check(!FileManager.default.fileExists(atPath: plain.directory.appendingPathComponent(".claude.json").path) && plain.name == "Other", "non-default folder must not receive the global config")
        let linked = home.appendingPathComponent("linked"); try FileManager.default.createDirectory(at: linked, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: linked.appendingPathComponent("evil"), withDestinationURL: home)
        var threw = false
        do { _ = try MigrationService(store: store).importDirectory(linked, home: home) } catch MigrationError.symlinkNotImported { threw = true }
        try check(threw, "symlinks must be rejected")
        try check(try store.list().count == 2 && (try store.orphanedProfileDirectories()).isEmpty, "a failed import must not leave an orphaned managed directory")
    }

    static func testConversationLocator() throws {
        let root = try temporaryRoot()
        func profile(_ name: String, slug: String, session: String, cwd: String?) throws -> Profile {
            let dir = root.appendingPathComponent(name).appendingPathComponent("config")
            let project = dir.appendingPathComponent("projects/\(slug)"); try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
            var lines = ["{\"type\":\"queue-operation\",\"sessionId\":\"\(session)\"}"]
            if let cwd { lines.append("{\"type\":\"user\",\"cwd\":\"\(cwd)\",\"sessionId\":\"\(session)\"}") }
            try lines.joined(separator: "\n").write(to: project.appendingPathComponent("\(session).jsonl"), atomically: true, encoding: .utf8)
            return Profile(name: name, directory: dir)
        }
        let work = try profile("Work", slug: "-Users-me-Develop-api", session: "aaaa1111-0000-0000-0000-000000000000", cwd: "/Users/me/Develop/api")
        let personal = try profile("Personal", slug: "-Users-me--dotfiles", session: "bbbb2222-0000-0000-0000-000000000000", cwd: nil)
        let byID = ConversationLocator.find(query: "AAAA1111", profiles: [work, personal])
        try check(byID.count == 1 && byID[0].profile.id == work.id && byID[0].cwd == "/Users/me/Develop/api", "lookup by session id prefix failed: \(byID)")
        // Sem `cas switch`: o launcher resume-aware já abre a conversa no perfil dono, e trocar o perfil
        // global da máquina só para retomar uma conversa era efeito colateral indesejado.
        try check(byID[0].resumeCommand == "cd '/Users/me/Develop/api' && claude --resume aaaa1111-0000-0000-0000-000000000000", "unexpected resume command: \(byID[0].resumeCommand)")
        let byCwd = ConversationLocator.find(query: "develop/api", profiles: [work, personal])
        try check(byCwd.count == 1 && byCwd[0].profile.id == work.id, "lookup by cwd fragment failed")
        let bySlug = ConversationLocator.find(query: "/Users/me/.dotfiles", profiles: [work, personal])
        try check(bySlug.count == 1 && bySlug[0].profile.id == personal.id && bySlug[0].cwd == nil, "lookup by folder slug (dots → dashes) failed: \(bySlug)")
        try check(bySlug[0].resumeCommand == "claude --resume bbbb2222-0000-0000-0000-000000000000", "resume command without cwd should be just the resume")
        try check(ConversationLocator.find(query: "   ", profiles: [work, personal]).isEmpty, "blank query must return nothing")
        try check(ConversationLocator.find(query: "nope", profiles: [work, personal]).isEmpty, "unrelated query must return nothing")
    }

    static func testMaintenanceScanAndApply() throws {
        let root = try temporaryRoot(); let store = try ProfileStore(root: root)
        let id = UUID(); let dir = try store.createManagedDirectory(id: id); try store.save(Profile(id: id, name: "P", directory: dir))
        let backups = root.appendingPathComponent("Backups"); try FileManager.default.createDirectory(at: backups, withIntermediateDirectories: true)
        for stamp in 1...8 { try "x".write(to: backups.appendingPathComponent("shell-\(1000 + stamp)-.zshrc"), atomically: true, encoding: .utf8) }
        for stamp in 1...3 { try "x".write(to: backups.appendingPathComponent("shell-\(2000 + stamp)-.zprofile"), atomically: true, encoding: .utf8) }
        try "keep".write(to: backups.appendingPathComponent("paseo-config-1.json"), atomically: true, encoding: .utf8)
        let old = dir.appendingPathComponent(".claude.json.tmp.111.aaa"); try "".write(to: old, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -30 * 24 * 3600)], ofItemAtPath: old.path)
        let recent = dir.appendingPathComponent(".claude.json.tmp.222.bbb"); try "".write(to: recent, atomically: true, encoding: .utf8)
        try "real".write(to: dir.appendingPathComponent(".claude.json"), atomically: true, encoding: .utf8)
        let orphan = try store.createManagedDirectory(id: UUID())
        let service = MaintenanceService(store: store, appSupport: root)
        let report = try service.scan(keepShellBackupsPerFile: 5)
        try check(report.shellBackups.map(\.lastPathComponent).sorted() == ["shell-1001-.zshrc", "shell-1002-.zshrc", "shell-1003-.zshrc"], "should prune only the oldest .zshrc backups beyond 5 per file: \(report.shellBackups.map(\.lastPathComponent))")
        try check(report.claudeTempFiles.map { $0.resolvingSymlinksInPath().path } == [old.resolvingSymlinksInPath().path], "only temp files older than 7 days may be listed: \(report.claudeTempFiles)")
        try check(report.orphanedDirectories.map { $0.resolvingSymlinksInPath().path } == [orphan.deletingLastPathComponent().resolvingSymlinksInPath().path], "orphan directory not listed: \(report.orphanedDirectories)")
        try check(report.staleKeychainServices.isEmpty, "no keychain client → no keychain work")
        let removed = service.apply(report)
        try check(removed == 5, "expected 5 removals, got \(removed)")
        try check(!FileManager.default.fileExists(atPath: old.path) && FileManager.default.fileExists(atPath: recent.path), "apply removed the wrong temp file")
        try check(FileManager.default.fileExists(atPath: dir.appendingPathComponent(".claude.json").path), "apply must never touch the real .claude.json")
        try check(FileManager.default.fileExists(atPath: backups.appendingPathComponent("shell-1008-.zshrc").path) && FileManager.default.fileExists(atPath: backups.appendingPathComponent("paseo-config-1.json").path), "apply removed a backup that should be kept")
        try check(!FileManager.default.fileExists(atPath: orphan.path), "orphan directory was not removed")
        try check(try service.scan(keepShellBackupsPerFile: 5).isEmpty, "a second scan right after apply should be clean")
    }

    static func testDesktopActivatorQuitTimeout() async throws {
        let client = FakeDesktopAppClient()
        let activator = DesktopAppActivator(client: client, quitTimeout: 42)
        _ = await activator.sync(to: Profile(name: "W", directory: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("cas-quit/\(UUID().uuidString)/config")))
        try check(client.lastTerminateTimeout == 42, "activator must pass its quit timeout to the client")
        try check(DesktopAppActivator.defaultQuitTimeout >= 15, "default graceful quit timeout should be generous (was 5 s and fell into forceTerminate)")
        client.terminateSucceeds = false; client.running = true
        let result = await activator.sync(to: Profile(name: "W", directory: URL(fileURLWithPath: "/tmp/cas-quit/x/config")))
        guard case .failed(let message) = result, message.contains("close it manually") else { throw TestFailure.failed("expected a failed sync with manual-close guidance, got \(result)") }
    }

    static func testLauncherResumeFollowsConversationProfile() throws {
        let root = try temporaryRoot(); let app = root.appendingPathComponent("app-support"); let store = try ProfileStore(root: app)
        let idA = UUID(); let dirA = try store.createManagedDirectory(id: idA); let a = Profile(id: idA, name: "A", directory: dirA)
        let idB = UUID(); let dirB = try store.createManagedDirectory(id: idB); let b = Profile(id: idB, name: "B", directory: dirB)
        try store.save(a); try store.save(b); try store.setActive(ActiveProfile(id: a.id, directory: dirA))
        let onlyInB = "882affa8-d8e4-47b2-854e-8c5c57e9bdec", onlyInA = "11111111-2222-3333-4444-555555555555", inBoth = "99999999-aaaa-bbbb-cccc-dddddddddddd"
        for (dir, ids) in [(dirA, [onlyInA, inBoth]), (dirB, [onlyInB, inBoth])] {
            let project = dir.appendingPathComponent("projects/-Users-me-proj"); try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
            for id in ids { try "{}".write(to: project.appendingPathComponent("\(id).jsonl"), atomically: true, encoding: .utf8) }
        }
        let shell = ShellIntegrationManager(appSupport: app); let home = root.appendingPathComponent("home"); try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        // `/usr/bin/env` rejeitaria `-r`; um binário falso que ignora argumentos e ecoa a variável.
        let fakeOfficial = root.appendingPathComponent("fake-claude")
        try "#!/bin/sh\nprintf 'CLAUDE_CONFIG_DIR=%s\\n' \"$CLAUDE_CONFIG_DIR\"\n".write(to: fakeOfficial, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeOfficial.path)
        try shell.install(home: home, officialBinary: fakeOfficial)
        func configDir(_ args: [String]) throws -> (dir: String, stderr: String) {
            let result = try ProcessRunner().run(executable: shell.launcherURL(), arguments: args)
            guard let line = result.stdout.split(separator: "\n").first(where: { $0.hasPrefix("CLAUDE_CONFIG_DIR=") }) else { throw TestFailure.failed("no CLAUDE_CONFIG_DIR for \(args)") }
            return (String(line.dropFirst("CLAUDE_CONFIG_DIR=".count)), result.stderr)
        }
        // A conversa nasceu em B; com A ativo, `--resume` deve usar B (todas as grafias do flag).
        for args in [["--resume=\(onlyInB)"], ["--resume", onlyInB], ["-r", onlyInB], ["--model", "opus", "--resume=\(onlyInB)", "--verbose"]] {
            let r = try configDir(args)
            try check(r.dir == dirB.path, "\(args) should resolve to the owning profile B, got \(r.dir)")
            try check(r.stderr.contains(onlyInB), "launcher should tell on stderr that it redirected the resume: \(r.stderr)")
        }
        // Sessão do próprio perfil ativo, ou presente nos dois: fica no ativo, sem aviso.
        for id in [onlyInA, inBoth] {
            let r = try configDir(["--resume", id]); try check(r.dir == dirA.path && r.stderr.isEmpty, "\(id) should stay on the active profile")
        }
        // Id desconhecido, `--resume` sem id, `--continue`, ou argumentos suspeitos: perfil ativo, sem redirecionar.
        for args in [["--resume", "deadbeef-0000-0000-0000-000000000000"], ["--resume"], ["--continue"], ["--resume", "--verbose"], ["-r", "../../etc"], ["chat", "-r"]] {
            let r = try configDir(args); try check(r.dir == dirA.path, "\(args) should stay on the active profile, got \(r.dir)")
        }
        try check(try configDir([]).dir == dirA.path, "plain launch should use the active profile")
    }

    /// Um app com pasta Claude própria (ex.: bots do Operaí) chama `claude` pelo PATH e cai no launcher: sobrescrever o
    /// CLAUDE_CONFIG_DIR dele punha as sessões e limpezas desse app dentro do perfil pessoal. Só valores do próprio app
    /// (perfil exportado pelo cas-env.sh, mesmo desatualizado, e o symlink active-config-dir) seguem o perfil ativo.
    static func testLauncherKeepsForeignConfigDir() throws {
        let root = try temporaryRoot(); let app = root.appendingPathComponent("app-support"); let store = try ProfileStore(root: app)
        let idA = UUID(); let dirA = try store.createManagedDirectory(id: idA); let a = Profile(id: idA, name: "A", directory: dirA)
        let idB = UUID(); let dirB = try store.createManagedDirectory(id: idB); let b = Profile(id: idB, name: "B", directory: dirB)
        try store.save(a); try store.save(b); try store.setActive(ActiveProfile(id: a.id, directory: dirA))
        let shell = ShellIntegrationManager(appSupport: app); let home = root.appendingPathComponent("home"); try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let fakeOfficial = root.appendingPathComponent("fake-claude")
        try "#!/bin/sh\nprintf 'CLAUDE_CONFIG_DIR=%s\\n' \"$CLAUDE_CONFIG_DIR\"\n".write(to: fakeOfficial, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeOfficial.path)
        try shell.install(home: home, officialBinary: fakeOfficial)
        func launched(with inherited: String, _ args: [String] = []) throws -> String {
            let result = try ProcessRunner().run(executable: shell.launcherURL(), arguments: args, environment: ["CLAUDE_CONFIG_DIR": inherited])
            guard let line = result.stdout.split(separator: "\n").first(where: { $0.hasPrefix("CLAUDE_CONFIG_DIR=") }) else { throw TestFailure.failed("no CLAUDE_CONFIG_DIR for \(inherited): \(result.stderr)") }
            return String(line.dropFirst("CLAUDE_CONFIG_DIR=".count))
        }
        // Pasta própria de outro app: respeitada, inclusive num --resume (a conversa é dele, não de um perfil).
        let foreign = root.appendingPathComponent("operai-teste/claude").path
        try check(try launched(with: foreign) == foreign, "a config dir outside the managed root must be kept")
        try check(try launched(with: foreign, ["--resume", "882affa8-d8e4-47b2-854e-8c5c57e9bdec"]) == foreign, "resume must keep a foreign config dir")
        // Valores do próprio app seguem o perfil ativo: perfil B exportado antes de uma troca, symlink do Paseo, vazio.
        for inherited in [dirB.path, app.appendingPathComponent("active-config-dir").path, ""] {
            let got = try launched(with: inherited)
            try check(got == dirA.path, "\(inherited.isEmpty ? "unset" : inherited) should resolve to the active profile, got \(got)")
        }
        // Um prefixo parecido com a raiz gerenciada não conta como dentro dela.
        let lookalike = app.path + "-copia/config"
        try check(try launched(with: lookalike) == lookalike, "a sibling folder that only shares the prefix is foreign")
    }

    static func testLauncherKeepsInheritedDirOfLaunchedSession() throws {
        let root = try temporaryRoot(); let app = root.appendingPathComponent("app-support"); let store = try ProfileStore(root: app)
        let idA = UUID(); let dirA = try store.createManagedDirectory(id: idA); let a = Profile(id: idA, name: "A", directory: dirA)
        let idB = UUID(); let dirB = try store.createManagedDirectory(id: idB); let b = Profile(id: idB, name: "B", directory: dirB)
        try store.save(a); try store.save(b); try store.setActive(ActiveProfile(id: a.id, directory: dirA))
        let shell = ShellIntegrationManager(appSupport: app); let home = root.appendingPathComponent("home"); try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let fakeOfficial = root.appendingPathComponent("fake-claude")
        try "#!/bin/sh\nprintf 'CLAUDE_CONFIG_DIR=%s\\n' \"$CLAUDE_CONFIG_DIR\"\nprintf 'CAS_LAUNCHED_DIR=%s\\n' \"${CAS_LAUNCHED_DIR:-}\"\n".write(to: fakeOfficial, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeOfficial.path)
        try shell.install(home: home, officialBinary: fakeOfficial)
        func launched(env: [String: String]) throws -> (config: String, mark: String) {
            let result = try ProcessRunner().run(executable: shell.launcherURL(), environment: env)
            func value(_ key: String) -> String {
                result.stdout.split(separator: "\n").first(where: { $0.hasPrefix(key + "=") }).map { String($0.dropFirst(key.count + 1)) } ?? ""
            }
            return (value("CLAUDE_CONFIG_DIR"), value("CAS_LAUNCHED_DIR"))
        }
        // 1ª invocação: resolve o ativo e deixa a marca para os filhos.
        let first = try launched(env: [:])
        try check(first.config == dirA.path && first.mark == dirA.path, "launcher must export CAS_LAUNCHED_DIR equal to the chosen dir: \(first)")
        // Sessão viva em A (lançada pelo launcher) enquanto o ativo virou B: um `claude` filho dela fica em A.
        try store.setActive(ActiveProfile(id: b.id, directory: dirB))
        let child = try launched(env: ["CLAUDE_CONFIG_DIR": dirA.path, "CAS_LAUNCHED_DIR": dirA.path])
        try check(child.config == dirA.path, "a child of a launched session must keep its parent's profile, got \(child.config)")
        // Valor herdado só do cas-env.sh (sem marca) ou com marca divergente segue o ativo.
        try check(try launched(env: ["CLAUDE_CONFIG_DIR": dirA.path]).config == dirB.path, "env-script value without the mark must follow the active profile")
        try check(try launched(env: ["CLAUDE_CONFIG_DIR": dirA.path, "CAS_LAUNCHED_DIR": dirB.path]).config == dirB.path, "a mark that does not match the inherited value must not pin the profile")
        // Marca apontando para diretório que já não existe (perfil removido) não pode travar: segue o ativo.
        let gone = app.appendingPathComponent("Profiles/00000000-0000-0000-0000-000000000000/config").path
        try check(try launched(env: ["CLAUDE_CONFIG_DIR": gone, "CAS_LAUNCHED_DIR": gone]).config == dirB.path, "a missing inherited dir must fall back to the active profile")
    }

    static func testPaseoRevertRemovesOnlyOurFields() throws {
        let root = try temporaryRoot()
        let paseoHome = root.appendingPathComponent(".paseo"); try FileManager.default.createDirectory(at: paseoHome, withIntermediateDirectories: true)
        let app = root.appendingPathComponent("app-support")
        let paseo = PaseoIntegration(appSupport: app, paseoHome: paseoHome)
        let original = """
        {"agents":{"providers":{"claude":{"env":{"CLAUDE_CONFIG_DIR":"/custom/dir","FOO":"bar"}},"claude-agi":{"extends":"claude","command":["/x/claude-agi"]}}},"other":1}
        """
        try original.data(using: .utf8)!.write(to: paseoHome.appendingPathComponent("config.json"))
        // Nada nosso no arquivo: revert não escreve nem faz backup.
        try check(try paseo.revert() == nil, "revert on a config we never touched must be a no-op")
        try check(try String(contentsOf: paseoHome.appendingPathComponent("config.json"), encoding: .utf8) == original, "no-op revert must not rewrite the file")
        try paseo.integrate()
        try check(paseo.isConfigured(), "precondition: integrated")
        let backup = try paseo.revert()
        try check(backup != nil && FileManager.default.fileExists(atPath: backup!.path), "revert must back up before writing")
        let raw = try Data(contentsOf: paseoHome.appendingPathComponent("config.json"))
        let rootObject = try JSONSerialization.jsonObject(with: raw) as! [String: Any]
        let providers = ((rootObject["agents"] as! [String: Any])["providers"] as! [String: Any])
        let claude = providers["claude"] as! [String: Any]
        try check(claude["command"] == nil, "launcher command must be removed: \(String(describing: claude["command"]))")
        let env = claude["env"] as? [String: Any]
        try check(env?["CLAUDE_CONFIG_DIR"] == nil && env?["FOO"] as? String == "bar", "only our env key may be removed: \(String(describing: env))")
        try check((providers["claude-agi"] as? [String: Any])?["command"] as? [String] == ["/x/claude-agi"] && rootObject["other"] as? Int == 1, "unrelated providers and keys must be preserved")
        try check(!paseo.isConfigured(), "after revert the integration must read as not configured")
    }

    static func testPaseoIntegrateSetsCommandToLauncher() throws {
        let root = try temporaryRoot()
        let paseoHome = root.appendingPathComponent(".paseo"); try FileManager.default.createDirectory(at: paseoHome, withIntermediateDirectories: true)
        let app = root.appendingPathComponent("app-support")
        // Config já integrado pela versão anterior (só env): deve pedir reconfiguração.
        let legacy = """
        {"agents":{"providers":{"claude":{"env":{"CLAUDE_CONFIG_DIR":"\(app.appendingPathComponent("active-config-dir").path)"}},"claude-agi":{"extends":"claude","command":["/x/claude-agi"]}}}}
        """
        try legacy.data(using: .utf8)!.write(to: paseoHome.appendingPathComponent("config.json"))
        let paseo = PaseoIntegration(appSupport: app, paseoHome: paseoHome)
        try check(!paseo.isConfigured(), "env-only integration must count as not configured so the UI offers to reconfigure")
        try paseo.integrate()
        try check(paseo.isConfigured(), "should be configured after integrate()")
        let raw = try Data(contentsOf: paseoHome.appendingPathComponent("config.json"))
        let providers = (((try JSONSerialization.jsonObject(with: raw) as! [String: Any])["agents"] as! [String: Any])["providers"] as! [String: Any])
        let claude = providers["claude"] as! [String: Any]
        try check(claude["command"] as? [String] == [ShellIntegrationManager(appSupport: app).launcherURL().path], "claude provider command must be the managed launcher: \(String(describing: claude["command"]))")
        try check((claude["env"] as? [String: Any])?["CLAUDE_CONFIG_DIR"] as? String == paseo.activeConfigDirSymlink.path, "env symlink must be kept")
        try check((providers["claude-agi"] as? [String: Any])?["command"] as? [String] == ["/x/claude-agi"], "other providers' commands must not be touched")
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
        // Com o app nativo aberto a cópia é recusada antes de importar qualquer coisa (LevelDB em escrita).
        var refused = false
        do { _ = try service.execute(plan, desktopTarget: source, isDesktopRunning: { true }) } catch MigrationError.desktopAppRunning { refused = true }
        try check(refused, "execute must refuse to copy the desktop session while the app runs")
        try check(try store.list().isEmpty, "a refused migration must not import profiles halfway")

        let report = try service.execute(plan, desktopTarget: source)

        let importedDesktopDir = report.imported[0].deletingLastPathComponent().appendingPathComponent("desktop")
        try check(FileManager.default.fileExists(atPath: importedDesktopDir.appendingPathComponent("Cookies").path), "desktop session was not copied into the target profile's desktop directory")
        try check(FileManager.default.fileExists(atPath: desktopDir.appendingPathComponent("Cookies").path), "original desktop app data was modified or removed")
        let siblings = try FileManager.default.contentsOfDirectory(atPath: report.imported[0].deletingLastPathComponent().path)
        try check(!siblings.contains(where: { $0.hasPrefix(".desktop.tmp-") }), "staging directory was left behind: \(siblings)")
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

    private static func plannerProfile(health: ProfileHealth = .ready, hasUsage: Bool = true) -> Profile {
        let usage = hasUsage ? ClaudeUsageSnapshot(quotas: [], source: "t") : nil
        return Profile(name: "p", directory: URL(fileURLWithPath: "/tmp/p"), health: health, usage: usage)
    }

    static func testRefreshPlannerScheduled() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let recent = now.addingTimeInterval(-60)
        // Perfil ativo, saudável, auth checado há 1 min: busca uso, NÃO sobe o CLI.
        let active = RefreshPlanner.plan(profile: plannerProfile(), isActive: true, scope: .scheduled, now: now, lastUsageFetch: recent, lastAuthCheck: recent)
        try check(active.fetchUsage && !active.checkAuth, "active profile: usage yes, CLI no — got \(active)")
        // Inativo atualizado há 1 min: nada a fazer neste ciclo.
        let idle = RefreshPlanner.plan(profile: plannerProfile(), isActive: false, scope: .scheduled, now: now, lastUsageFetch: recent, lastAuthCheck: recent)
        try check(!idle.fetchUsage && !idle.checkAuth, "inactive fresh profile must be skipped — got \(idle)")
        // Inativo com uso defasado (> 5 min): busca uso.
        let stale = RefreshPlanner.plan(profile: plannerProfile(), isActive: false, scope: .scheduled, now: now, lastUsageFetch: now.addingTimeInterval(-301), lastAuthCheck: recent)
        try check(stale.fetchUsage, "inactive profile past 5 min must refresh usage")
        // Inativo sem uso conhecido: busca (popula a primeira exibição).
        let blank = RefreshPlanner.plan(profile: plannerProfile(hasUsage: false), isActive: false, scope: .scheduled, now: now, lastUsageFetch: recent, lastAuthCheck: recent)
        try check(blank.fetchUsage, "profile without usage must fetch")
        // Primeiro ciclo do app (nada registrado): tudo é devido.
        let first = RefreshPlanner.plan(profile: plannerProfile(), isActive: true, scope: .scheduled, now: now, lastUsageFetch: nil, lastAuthCheck: nil)
        try check(first.fetchUsage && first.checkAuth, "first cycle must do everything")
    }

    static func testRefreshPlannerAuthAndScopes() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        func plan(_ health: ProfileHealth = .ready, scope: RefreshScope = .scheduled, authAgo: TimeInterval, usageAgo: TimeInterval = 10, active: Bool = false) -> ProfileRefreshPlan {
            RefreshPlanner.plan(profile: plannerProfile(health: health), isActive: active, scope: scope, now: now, lastUsageFetch: now.addingTimeInterval(-usageAgo), lastAuthCheck: now.addingTimeInterval(-authAgo))
        }
        try check(!plan(authAgo: 29 * 60).checkAuth, "healthy profile within 30 min must not spawn the CLI")
        try check(plan(authAgo: 31 * 60).checkAuth, "healthy profile past 30 min must re-check")
        try check(!plan(.expired, authAgo: 4 * 60).checkAuth, "expired profile within 5 min must not re-check")
        try check(plan(.expired, authAgo: 6 * 60).checkAuth, "expired profile past 5 min must re-check")
        try check(plan(authAgo: 60).authRetryAllowed == false && plan(authAgo: 6 * 60).authRetryAllowed, "token-failure retry is throttled to 5 min")
        let manual = plan(scope: .manual, authAgo: 5, usageAgo: 5)
        try check(manual.checkAuth && manual.fetchUsage, "manual refresh re-checks auth and usage")
        let onDemand = plan(scope: .onDemand, authAgo: 5, usageAgo: 5)
        try check(onDemand.fetchUsage && !onDemand.checkAuth, "opening a window refreshes usage of every profile but not the CLI")
    }

    static func testRefreshPlannerCursorDetails() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        try check(RefreshPlanner.shouldFetchCursorDetails(scope: .scheduled, now: now, lastFetch: nil), "no previous fetch → fetch details")
        try check(!RefreshPlanner.shouldFetchCursorDetails(scope: .scheduled, now: now, lastFetch: now.addingTimeInterval(-9 * 60)), "within 10 min → skip details")
        try check(RefreshPlanner.shouldFetchCursorDetails(scope: .scheduled, now: now, lastFetch: now.addingTimeInterval(-11 * 60)), "past 10 min → fetch details")
        try check(RefreshPlanner.shouldFetchCursorDetails(scope: .onDemand, now: now, lastFetch: now.addingTimeInterval(-5)), "opening a window → fetch details")
    }

    private static func assistantLine(id: String, request: String, input: Int, output: Int, timestamp: String = "2026-11-10T12:00:00.000Z") -> String {
        #"{"type":"assistant","timestamp":"\#(timestamp)","requestId":"\#(request)","message":{"id":"\#(id)","usage":{"input_tokens":\#(input),"output_tokens":\#(output)}}}"# + "\n"
    }

    private static func append(_ text: String, to url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd(); try handle.write(contentsOf: Data(text.utf8))
    }

    static func testTokenUsageIncrementalAppend() throws {
        let profile = try temporaryRoot()
        let dir = profile.appendingPathComponent("projects/proj"); try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let jsonl = dir.appendingPathComponent("s.jsonl")
        // Linha irrelevante (tool-result) no meio: deve ser ignorada sem quebrar o offset.
        try (assistantLine(id: "m1", request: "r1", input: 10, output: 1)
             + #"{"type":"user","message":{"content":"x"}}"# + "\n").write(to: jsonl, atomically: true, encoding: .utf8)
        let service = ClaudeUsageService()
        let first = service.tokenUsage(profileDirectory: profile)
        try check(first.input == 10 && first.messageCount == 1, "first read wrong: \(first)")

        // Novo chunk da MESMA mensagem (o último vence) + uma mensagem nova.
        try append(assistantLine(id: "m1", request: "r1", input: 10, output: 5) + assistantLine(id: "m2", request: "r2", input: 20, output: 2), to: jsonl)
        let second = service.tokenUsage(profileDirectory: profile)
        try check(second.input == 30 && second.output == 7 && second.messageCount == 2,
                  "dedup across the saved offset failed: \(second)")

        // Equivalente a ler o arquivo do zero com um serviço sem cache.
        let fresh = ClaudeUsageService().tokenUsage(profileDirectory: profile)
        try check(second == fresh, "incremental total differs from a full parse: \(second) vs \(fresh)")
    }

    static func testTokenUsagePartialTrailingLine() throws {
        let profile = try temporaryRoot()
        let dir = profile.appendingPathComponent("projects/proj"); try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let jsonl = dir.appendingPathComponent("s.jsonl")
        let whole = assistantLine(id: "m2", request: "r2", input: 20, output: 2)
        // Corte logo após um `}` interno: termina em `}` mas é um objeto incompleto.
        let cut = whole.index(after: whole.range(of: #"}"#, options: .backwards, range: whole.startIndex..<whole.index(whole.endIndex, offsetBy: -3))!.lowerBound)
        try (assistantLine(id: "m1", request: "r1", input: 10, output: 1) + String(whole[..<cut])).write(to: jsonl, atomically: true, encoding: .utf8)
        let service = ClaudeUsageService()
        let partial = service.tokenUsage(profileDirectory: profile)
        try check(partial.input == 10 && partial.messageCount == 1, "half-written line must not be counted: \(partial)")
        try append(String(whole[cut...]), to: jsonl)
        let done = service.tokenUsage(profileDirectory: profile)
        try check(done.input == 30 && done.messageCount == 2, "completed line must be counted exactly once: \(done)")
    }

    static func testTokenUsageRereadsRewrittenFile() throws {
        let profile = try temporaryRoot()
        let dir = profile.appendingPathComponent("projects/proj"); try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let jsonl = dir.appendingPathComponent("s.jsonl")
        try assistantLine(id: "m1", request: "r1", input: 10, output: 1).write(to: jsonl, atomically: true, encoding: .utf8)
        let service = ClaudeUsageService()
        _ = service.tokenUsage(profileDirectory: profile)
        // Reescrita (ex.: compactação) com conteúdo diferente e MAIOR: o offset antigo não vale.
        try (assistantLine(id: "n1", request: "q1", input: 7, output: 1) + assistantLine(id: "n2", request: "q2", input: 8, output: 1)).write(to: jsonl, atomically: true, encoding: .utf8)
        let after = service.tokenUsage(profileDirectory: profile)
        try check(after.input == 15 && after.messageCount == 2, "rewritten file must be reparsed from the start: \(after)")
    }

    static func testHistoryIncrementalAppend() throws {
        let root = try temporaryRoot()
        let directory = root.appendingPathComponent("a/config")
        let dir = directory.appendingPathComponent("projects/proj"); try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let jsonl = dir.appendingPathComponent("s.jsonl")
        try assistantLine(id: "m1", request: "r1", input: 10, output: 1).write(to: jsonl, atomically: true, encoding: .utf8)
        let profile = Profile(name: "a", directory: directory)
        let service = UsageHistoryService()
        let now = ISO8601DateFormatter().date(from: "2026-11-12T12:00:00Z")!
        _ = service.dailyUsage(profiles: [profile], now: now)
        try append(assistantLine(id: "m1", request: "r1", input: 10, output: 4) + assistantLine(id: "m2", request: "r2", input: 5, output: 1, timestamp: "2026-11-11T12:00:00.000Z"), to: jsonl)
        let incremental = service.dailyUsage(profiles: [profile], now: now)
        let fresh = UsageHistoryService().dailyUsage(profiles: [profile], now: now)
        try check(incremental == fresh, "incremental history differs from a full parse")
        try check(incremental.reduce(0) { (sum: Int, day: DailyTokenUsage) in sum + day.total } == 20, "expected deduplicated total 20, got \(incremental)")
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

    /// Linha `assistant` com `message.id` + `requestId` (formato atual do Claude Code) para exercitar
    /// a deduplicação de chunks de streaming.
    private static func keyedAssistantLine(_ timestamp: String, id: String, req: String, input: Int = 0, output: Int = 0, cacheRead: Int = 0, cacheCreation: Int = 0) -> String {
        #"{"type":"assistant","timestamp":"\#(timestamp)","requestId":"\#(req)","message":{"id":"\#(id)","usage":{"input_tokens":\#(input),"output_tokens":\#(output),"cache_read_input_tokens":\#(cacheRead),"cache_creation_input_tokens":\#(cacheCreation)}}}"#
    }

    /// Linha `assistant` com `model` e o split de escrita de cache 1h/5m, para exercitar a
    /// quebra por tipo e o custo estimado.
    private static func pricedAssistantLine(_ timestamp: String, model: String, id: String, req: String, input: Int = 0, output: Int = 0, cacheRead: Int = 0, cacheCreation1h: Int = 0, cacheCreation5m: Int = 0) -> String {
        let creation = cacheCreation1h + cacheCreation5m
        return #"{"type":"assistant","timestamp":"\#(timestamp)","requestId":"\#(req)","message":{"id":"\#(id)","model":"\#(model)","usage":{"input_tokens":\#(input),"output_tokens":\#(output),"cache_read_input_tokens":\#(cacheRead),"cache_creation_input_tokens":\#(creation),"cache_creation":{"ephemeral_1h_input_tokens":\#(cacheCreation1h),"ephemeral_5m_input_tokens":\#(cacheCreation5m)}}}}"#
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

    static func testDailyUsageDeduplicatesStreamingChunks() throws {
        let root = try temporaryRoot()
        // Mensagem A: 3 chunks idênticos (msg1/req1, 150 tokens) → deve contar 1x.
        // Mensagem B: distinta (msg2/req2, 200 tokens). Total correto = 350, não 3*150+200.
        let contents = [
            keyedAssistantLine("2026-06-01T12:00:00.000Z", id: "msg1", req: "req1", input: 100, output: 50),
            keyedAssistantLine("2026-06-01T12:00:01.000Z", id: "msg1", req: "req1", input: 100, output: 50),
            keyedAssistantLine("2026-06-01T12:00:02.000Z", id: "msg1", req: "req1", input: 100, output: 50),
            keyedAssistantLine("2026-06-01T12:00:03.000Z", id: "msg2", req: "req2", input: 200)
        ].joined(separator: "\n")
        let a = try makeAnalysisProfile(root: root, name: "A", file: "s.jsonl", contents: contents)
        let now = ClaudeUsageService.parseResetDate("2026-06-10T00:00:00Z")!
        let series = UsageHistoryService().dailyUsage(profiles: [a], now: now)
        try check(series.count == 1 && series[0].total == 350, "streaming chunks devem contar uma vez: esperado 350, veio \(series.first?.total ?? -1)")

        // Dedup também ENTRE arquivos da mesma conta: a mesma msg1/req1 num segundo arquivo
        // (ex.: sessão retomada que copia o histórico) não deve recontar.
        let proj2 = a.directory.appendingPathComponent("projects/proj2")
        try FileManager.default.createDirectory(at: proj2, withIntermediateDirectories: true)
        try keyedAssistantLine("2026-06-01T12:00:00.000Z", id: "msg1", req: "req1", input: 100, output: 50)
            .data(using: .utf8)!.write(to: proj2.appendingPathComponent("dup.jsonl"))
        let series2 = UsageHistoryService().dailyUsage(profiles: [a], now: now)
        try check(series2.count == 1 && series2[0].total == 350, "duplicata cross-file de msg1/req1 não pode recontar: esperado 350, veio \(series2.first?.total ?? -1)")
    }

    static func testTokenUsageDeduplicatesStreamingChunks() throws {
        let profile = try temporaryRoot()
        let projects = profile.appendingPathComponent("projects/proj"); try FileManager.default.createDirectory(at: projects, withIntermediateDirectories: true)
        // msg1/req1 repetido 2x (100/50) + msg2/req2 distinto (10/5). Correto: input 110, output 55, 2 mensagens.
        let contents = [
            keyedAssistantLine("2026-06-01T12:00:00.000Z", id: "msg1", req: "req1", input: 100, output: 50),
            keyedAssistantLine("2026-06-01T12:00:01.000Z", id: "msg1", req: "req1", input: 100, output: 50),
            keyedAssistantLine("2026-06-01T12:00:02.000Z", id: "msg2", req: "req2", input: 10, output: 5)
        ].joined(separator: "\n")
        try contents.data(using: .utf8)!.write(to: projects.appendingPathComponent("s.jsonl"))
        let usage = ClaudeUsageService().tokenUsage(profileDirectory: profile)
        try check(usage.input == 110 && usage.output == 55, "chunk duplicado contado duas vezes: input=\(usage.input) output=\(usage.output)")
        try check(usage.messageCount == 2, "messageCount deve contar mensagens deduplicadas, veio \(usage.messageCount)")
    }

    static func testModelPricingWeightsCacheTokensByType() throws {
        // Família reconhecida pelo id do modelo.
        try check(ModelPricing.family(for: "claude-sonnet-4-5-20990101") == .sonnet, "sonnet id should map to sonnet")
        try check(ModelPricing.family(for: "claude-opus-4-1") == .opus, "opus id should map to opus")
        try check(ModelPricing.family(for: "claude-3-5-haiku-20241022") == .haiku, "haiku id should map to haiku")
        try check(ModelPricing.family(for: "gpt-4o") == nil, "unknown model should have no family")

        // Sonnet (por milhão): input 3, output 15, cache lido 0,30, cache escrito 5m 3,75, 1h 6.
        // 1M de cada → 3 + 15 + 0,30 + 3,75 + 6 = 28,05.
        let m = 1_000_000
        let tokens = TokenBreakdown(input: m, output: m, cacheRead: m, cacheCreation5m: m, cacheCreation1h: m)
        let cost = ModelPricing.costUSD(model: "claude-sonnet-4-5", tokens: tokens)
        try check(cost != nil && abs(cost! - 28.05) < 1e-6, "sonnet cost should be 28.05, got \(cost as Any)")
        // Leitura de cache é MUITO mais barata que escrita 1h (0,30 vs 6 por milhão → 20x).
        let read = ModelPricing.costUSD(model: "sonnet", tokens: TokenBreakdown(cacheRead: m))!
        let write1h = ModelPricing.costUSD(model: "sonnet", tokens: TokenBreakdown(cacheCreation1h: m))!
        try check(abs(write1h - read * 20) < 1e-6, "1h cache write should cost 20x a cache read")
        // Modelo desconhecido → nil (não precificado, nunca custo 0 disfarçado).
        try check(ModelPricing.costUSD(model: "gpt-4o", tokens: tokens) == nil, "unknown model must not be priced")
    }

    static func testDailyUsagePreservesBreakdownAndCost() throws {
        let root = try temporaryRoot()
        let m = 1_000_000
        // Uma mensagem Sonnet com todos os tipos (1M cada) + uma linha de modelo desconhecido
        // (só input, 500 tokens): entra no volume mas NÃO no custo.
        let contents = [
            pricedAssistantLine("2026-06-01T12:00:00.000Z", model: "claude-sonnet-4-5", id: "msg1", req: "req1",
                                input: m, output: m, cacheRead: m, cacheCreation1h: m, cacheCreation5m: m),
            keyedAssistantLine("2026-06-01T13:00:00.000Z", id: "msg2", req: "req2", input: 500) // sem model → cost nil
        ].joined(separator: "\n")
        let a = try makeAnalysisProfile(root: root, name: "A", file: "s.jsonl", contents: contents)
        let now = ClaudeUsageService.parseResetDate("2026-06-10T00:00:00Z")!
        let series = UsageHistoryService().dailyUsage(profiles: [a], now: now)
        try check(series.count == 1, "expected a single day, got \(series.count)")
        let b = series[0].breakdownPerProfile[a.id]
        try check(b != nil, "profile A must have a breakdown")
        try check(b!.cacheRead == m && b!.cacheCreation5m == m && b!.cacheCreation1h == m, "cache split wrong: \(String(describing: b))")
        try check(b!.input == m + 500 && b!.output == m, "input/output wrong: \(String(describing: b))")
        // Custo = só a mensagem Sonnet (28,05); a linha de modelo desconhecido não soma.
        let cost = series[0].costPerProfile[a.id]
        try check(cost != nil && abs(cost! - 28.05) < 1e-6, "day cost should be 28.05 (unknown model excluded), got \(cost as Any)")
        try check(abs(series[0].totalCostUSD - 28.05) < 1e-6, "totalCostUSD should aggregate to 28.05")
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
        var lastTerminateTimeout: TimeInterval?
        var launchedWith: (bundleURL: URL, userDataDirectory: URL)?

        func locateBundle() -> URL? { bundleURL }
        func isRunning() -> Bool { running }
        func terminate(timeout: TimeInterval) -> Bool { terminateCallCount += 1; lastTerminateTimeout = timeout; if terminateSucceeds { running = false }; return terminateSucceeds }
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
