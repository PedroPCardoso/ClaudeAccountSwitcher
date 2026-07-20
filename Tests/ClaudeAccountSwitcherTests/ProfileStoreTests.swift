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
            ("managed directory permissions", testManagedDirectory)
            ,("process runner preserves environment", testProcessRunner)
            ,("shell integration is idempotent", testShellIntegration)
            ,("activation rolls back on launchd failure", testActivationRollback)
            ,("migration preserves hidden Claude files", testMigration)
            ,("legacy active state is migrated", testLegacyActiveState)
            ,("launcher selects active profile", testLauncher)
        ]
        var failures = 0
        for (name, test) in tests {
            do { try await test(); print("PASS \(name)") }
            catch { failures += 1; print("FAIL \(name): \(error)") }
        }
        if failures > 0 { print("\(failures) test(s) failed"); Darwin.exit(1) }
        print("\(tests.count) tests passed")
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
}
