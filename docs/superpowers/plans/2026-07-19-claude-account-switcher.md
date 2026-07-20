# Claude Account Switcher Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a native macOS menu-bar app that manages unlimited isolated Claude Code profiles and makes the selected profile apply to new `claude` processes without account-specific aliases.

**Architecture:** A Swift Package produces a menu-bar executable and a test target. Core profile, migration, activation, shell integration, process, and login-item services are platform-separated and injected into the UI. A small launcher script reads the active-profile file, sets `CLAUDE_CONFIG_DIR`, resolves the official Claude binary, and `exec`s it; the app also updates the user launchd environment for newly launched GUI applications.

**Tech Stack:** Swift 6.3, Swift Package Manager, macOS 13+, AppKit, SwiftUI, ServiceManagement, Carbon hot-key API, XCTest, `/bin/zsh`, `launchctl`, `xcodebuild`/`swift build`.

## Global Constraints

- Aplicativo nativo em Swift e SwiftUI, executado como menu-bar app sem ícone permanente no Dock.
- Compatibilidade mínima com macOS 13 Ventura e Macs Apple Silicon.
- Perfis ilimitados e totalmente isolados por diretório `CLAUDE_CONFIG_DIR`.
- O app nunca lê, copia ou grava tokens diretamente; autenticação permanece com Claude Code e Keychain.
- A troca afeta somente novos processos; sessões abertas permanecem intactas.
- Migração cria backup e mantém os diretórios originais até confirmação explícita.
- Nenhuma automação de teste toca nos perfis reais, Keychain ou shell real.
- Logs não podem conter tokens, prompts, conteúdo de conversa ou saída integral de autenticação.
- O atalho padrão é `⌥⌘C`; o usuário pode alterá-lo.
- “Iniciar com o Mac” começa habilitado e é reversível.

---

## File Map

- Create: `Package.swift` — targets e plataforma mínima.
- Create: `Sources/ClaudeAccountSwitcher/AppMain.swift` — entry point e composição das dependências.
- Create: `Sources/ClaudeAccountSwitcher/Domain/Profile.swift` — modelos Codable de perfil e estado ativo.
- Create: `Sources/ClaudeAccountSwitcher/Infrastructure/ProfileStore.swift` — persistência atômica e diretórios gerenciados.
- Create: `Sources/ClaudeAccountSwitcher/Infrastructure/ProcessRunner.swift` — processo async com ambiente sanitizado e saída limitada.
- Create: `Sources/ClaudeAccountSwitcher/Infrastructure/ClaudeLocator.swift` — descoberta segura do binário oficial.
- Create: `Sources/ClaudeAccountSwitcher/Infrastructure/ClaudeAuthService.swift` — login/status e parsing sanitizado.
- Create: `Sources/ClaudeAccountSwitcher/Infrastructure/LaunchdEnvironment.swift` — `launchctl setenv`/unset com rollback.
- Create: `Sources/ClaudeAccountSwitcher/Infrastructure/ShellIntegration.swift` — launcher e bloco idempotente do shell.
- Create: `Sources/ClaudeAccountSwitcher/Infrastructure/ActivationService.swift` — ativação serializada e rollback.
- Create: `Sources/ClaudeAccountSwitcher/Infrastructure/MigrationService.swift` — pré-visualização, cópia, checksums e aliases.
- Create: `Sources/ClaudeAccountSwitcher/Infrastructure/LoginItemService.swift` — wrapper de `SMAppService`.
- Create: `Sources/ClaudeAccountSwitcher/UI/MenuBarController.swift` — status item e menu SwiftUI/AppKit.
- Create: `Sources/ClaudeAccountSwitcher/UI/QuickSwitcher.swift` — janela de busca `⌥⌘C`.
- Create: `Sources/ClaudeAccountSwitcher/UI/PreferencesView.swift` — preferências, diagnóstico e integração.
- Create: `Resources/claude-launcher` — launcher POSIX instalado pelo app.
- Create: `Tests/ClaudeAccountSwitcherTests/ProfileStoreTests.swift` — persistência e isolamento.
- Create: `Tests/ClaudeAccountSwitcherTests/ProcessAndAuthTests.swift` — runner, locator e parsing.
- Create: `Tests/ClaudeAccountSwitcherTests/ShellIntegrationTests.swift` — shell/launcher idempotência.
- Create: `Tests/ClaudeAccountSwitcherTests/ActivationMigrationTests.swift` — ativação, rollback e migração.
- Create: `Scripts/build-app.sh` — build release e criação de `.app`.
- Create: `Scripts/install-dev.sh` — instalação local do app e launcher, sem migrar contas.
- Create: `README.md` — build, instalação, comportamento e recuperação.

### Task 1: Scaffold Swift Package and Profile Domain — completed

**Files:** `Package.swift`, `Sources/ClaudeAccountSwitcher/Domain/Profile.swift`, `Sources/ClaudeAccountSwitcher/AppMain.swift`, `Tests/ClaudeAccountSwitcherTests/ProfileStoreTests.swift`

**Interfaces:**

- `Profile(id:name:email:organization:color:icon:kind:directory:createdAt:lastUsedAt:health)` is Codable and Identifiable.
- `ProfileKind` values are `.claudeSubscription`, `.anthropicConsole`, `.custom`.
- `ProfileHealth` values are `.unknown`, `.ready`, `.expired`, `.unavailable`.
- `ActiveProfile(id:updatedAt)` is Codable.
- `ProfileStore` is injected later; this task only establishes the package and models.

- [ ] **Step 1: Write the failing model round-trip test**

```swift
func testProfileRoundTripsThroughJSON() throws {
    let profile = Profile(id: UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!, name: "Work", email: "work@example.com", organization: "Acme", color: "blue", icon: "briefcase", kind: .custom, directory: URL(fileURLWithPath: "/tmp/work"), createdAt: .distantPast, lastUsedAt: nil, health: .ready)
    let data = try JSONEncoder().encode(profile)
    let decoded = try JSONDecoder().decode(Profile.self, from: data)
    XCTAssertEqual(decoded, profile)
}
```

- [ ] **Step 2: Run `swift test --filter ProfileStoreTests/testProfileRoundTripsThroughJSON` and verify it fails because the package/target is absent.**
- [ ] **Step 3: Add `Package.swift` with macOS 13 platform, executable target, test target, and `Profile.swift` implementing the exact Codable types above.**
- [ ] **Step 4: Add a minimal `AppMain.swift` with `@main struct ClaudeAccountSwitcherApp` and run the focused test; expected PASS.**
- [ ] **Step 5: Commit `git add Package.swift Sources Tests && git commit -m 'build: scaffold Swift package and profile domain'`.**

### Task 2: Implement Atomic ProfileStore — completed

**Files:** `Sources/ClaudeAccountSwitcher/Infrastructure/ProfileStore.swift`, `Tests/ClaudeAccountSwitcherTests/ProfileStoreTests.swift`

**Interfaces:**

- `ProfileStore(root: FileManager = .default)` exposes `profilesDirectory`, `metadataURL`, `activeURL`.
- `func list() throws -> [Profile]`, `func save(_:) throws`, `func remove(_:) throws`, `func active() throws -> ActiveProfile?`, `func setActive(_:) throws`.
- `func createManagedDirectory(id:) throws -> URL` creates `Profiles/<uuid>/config` with user-only permissions.
- Writes use a same-directory temp file followed by replace/move; malformed JSON is reported as `StoreError.corruptState`.

- [ ] **Step 1: Add tests for empty store, atomic metadata round-trip, active profile, managed directory permissions, and corrupt JSON.**
- [ ] **Step 2: Run `swift test --filter ProfileStoreTests` and verify the new tests fail.**
- [ ] **Step 3: Implement directory creation, Codable arrays, atomic writes, and error enum; never follow symlinks when creating managed profile config.**
- [ ] **Step 4: Run the test target and verify all store tests pass.**
- [ ] **Step 5: Commit `git add Sources/ClaudeAccountSwitcher/Infrastructure/ProfileStore.swift Tests && git commit -m 'feat: add atomic profile store'`.**

### Task 3: ProcessRunner, ClaudeLocator, and Auth Service — completed

**Files:** `Sources/ClaudeAccountSwitcher/Infrastructure/ProcessRunner.swift`, `ClaudeLocator.swift`, `ClaudeAuthService.swift`, `Tests/ClaudeAccountSwitcherTests/ProcessAndAuthTests.swift`

**Interfaces:**

- `ProcessRunner.run(executable:arguments:environment:cwd:) async throws -> ProcessResult`, where result has exit code, stdout and stderr truncated to 64 KiB.
- `ClaudeLocator.locate() throws -> URL` rejects the app launcher itself and only returns executable regular files.
- `ClaudeAuthService.status(profileDirectory:) async throws -> AuthStatus`; `AuthStatus` contains `isAuthenticated`, `email`, `organization`, `baseURL`, and `kind` but no token.
- `ClaudeAuthService.login(profileDirectory:kind:email:) async throws` invokes `auth login --claudeai` or `--console` with inherited browser environment.

- [ ] **Step 1: Create a fake executable fixture and tests asserting environment includes `CLAUDE_CONFIG_DIR`, arguments are preserved, output is capped, and status JSON never maps token fields.**
- [ ] **Step 2: Run focused tests and verify failure.**
- [ ] **Step 3: Implement `ProcessRunner` with `Process`, pipe reading, timeout cancellation, and sanitized error descriptions.**
- [ ] **Step 4: Implement locator search order (`~/.local/share/claude/versions/*/claude`, `~/.local/bin/claude` only when it is not the managed launcher, then user-selected path).**
- [ ] **Step 5: Implement status decoding with `JSONDecoder`, explicit field allowlist, and login command construction.**
- [ ] **Step 6: Run all process/auth tests and commit `feat: add Claude process and auth services`.**

### Task 4: Shell Integration and Launcher — completed

**Files:** `Sources/ClaudeAccountSwitcher/Infrastructure/ShellIntegration.swift`, `Resources/claude-launcher`, `Tests/ClaudeAccountSwitcherTests/ShellIntegrationTests.swift`

**Interfaces:**

- `ShellIntegrationManager.install(launcherSource:home:) throws` writes launcher to `~/Library/Application Support/Claude Account Switcher/bin/claude` and inserts markers `# >>> Claude Account Switcher >>>` / `# <<< Claude Account Switcher <<<` into `.zprofile`.
- `remove(home:) throws` removes only the marked block and leaves unrelated content byte-for-byte unchanged.
- `renderLauncher(stateURL:officialBinary:) -> String` produces a POSIX script that reads the active directory from the state JSON with macOS `plutil`, validates it, exports `CLAUDE_CONFIG_DIR`, and `exec`s the official binary.
- Shell edits create `Backups/shell-<timestamp>.zprofile` before replacement.

- [ ] **Step 1: Add tests for install into a temporary home, idempotent second install, removal preserving unrelated aliases, backup creation, and launcher arguments.**
- [ ] **Step 2: Run focused tests and verify failure.**
- [ ] **Step 3: Implement marker replacement with exact newline handling, restricted permissions, and no shell interpolation of user paths.**
- [ ] **Step 4: Add the launcher script; make it fail with a clear stderr message if state is missing/corrupt or official binary is absent.**
- [ ] **Step 5: Run shell integration tests and commit `feat: add safe Claude launcher integration`.**

### Task 5: Launchd Environment and Activation — completed

**Files:** `LaunchdEnvironment.swift`, `ActivationService.swift`, `Tests/ClaudeAccountSwitcherTests/ActivationMigrationTests.swift`

**Interfaces:**

- `LaunchdEnvironment.setConfigDirectory(_:) async throws` calls `/bin/launchctl setenv CLAUDE_CONFIG_DIR path`; `restore(_:)` restores an optional prior value or unsets it.
- `ActivationService.activate(profile:) async throws` validates directory, persists `ActiveProfile`, updates launchd, and returns `ActivationResult` with previous/new profile and `needsAppRestartHint`.
- On any launchd failure, metadata and active state are restored before throwing `ActivationError.rolledBack`.
- A per-instance actor or lock serializes activation requests.

- [ ] **Step 1: Add fake launchd tests for success, failure rollback, concurrent activation serialization, and missing directory rejection.**
- [ ] **Step 2: Run focused tests and verify failure.**
- [ ] **Step 3: Implement command abstraction so tests never invoke real `launchctl`; implement production runner and actor-based activation.**
- [ ] **Step 4: Run activation tests and commit `feat: activate profiles with rollback`.**

### Task 6: Migration Service — completed

**Files:** `MigrationService.swift`, `Tests/ClaudeAccountSwitcherTests/ActivationMigrationTests.swift`

**Interfaces:**

- `MigrationService.preview(home:) throws -> MigrationPlan` detects `.claude`, `.claude-work`, aliases in `.zshrc`, and `.claude-swap-backup` without reading secret file contents into memory beyond copy operations.
- `execute(plan:) async throws -> MigrationReport` copies directories without following symlinks, writes a manifest/checksums, validates destination, and leaves sources untouched.
- `cleanupRecognizedAliases(home:) throws` edits only exact aliases after explicit UI confirmation; it is idempotent.
- `MigrationReport` lists imported profile IDs, backups, aliases found, and warnings.

- [ ] **Step 1: Add temporary-home fixtures for both profiles, recognized aliases, symlink rejection, checksum mismatch, and source preservation.**
- [ ] **Step 2: Run focused tests and verify failure.**
- [ ] **Step 3: Implement preview, copy with `copyItem`/symlink checks, SHA-256 manifest using CryptoKit, and validation.**
- [ ] **Step 4: Implement exact alias removal only after the caller passes `confirmed: true`.**
- [ ] **Step 5: Run migration tests and commit `feat: migrate existing Claude profiles safely`.**

### Task 7: Login Item and Menu-Bar UI — completed

**Files:** `LoginItemService.swift`, `UI/MenuBarController.swift`, `UI/QuickSwitcher.swift`, `UI/PreferencesView.swift`, `AppMain.swift`

**Interfaces:**

- `LoginItemService.status: Bool`, `setEnabled(_:) throws` wraps `SMAppService.mainApp`, with a protocol for test doubles.
- `MenuBarController` owns `NSStatusItem`, menu lifecycle, and injected `ProfileStore`, `ActivationService`, `ClaudeAuthService`, `MigrationService`, and `ShellIntegrationManager`.
- `QuickSwitcher` presents a searchable list and calls `activate(profile:)` on selection.
- UI actions use async tasks and show success/failure `NSAlert`/notification without exposing raw process output.

- [ ] **Step 1: Add pure view-model tests for profile ordering/search, active checkmark, disabled states during activation, and default shortcut configuration.**
- [ ] **Step 2: Run UI model tests and verify failure.**
- [ ] **Step 3: Implement status item menu with active identity, unlimited profile list, Add Account, Import, Manage, Preferences, Diagnostics, and Quit.**
- [ ] **Step 4: Implement `QuickSwitcher` using an `NSPanel` and Carbon `RegisterEventHotKey` for default `⌥⌘C`; persist customizable key/modifier values.**
- [ ] **Step 5: Implement Add Account flow: create temporary profile, run auth login, poll status, promote directory, and discard on cancel/failure.**
- [ ] **Step 6: Implement migration wizard and Preferences with launch item, shell repair/removal, Claude path, notifications, and shortcut controls.**
- [ ] **Step 7: Build and run tests; commit `feat: add menu bar profile switcher UI`.**

### Task 8: Build, Install Scripts, Documentation, and Verification — completed

**Files:** `Scripts/build-app.sh`, `Scripts/install-dev.sh`, `README.md`, `Tests/ClaudeAccountSwitcherTests/EndToEndTests.swift`

**Interfaces:**

- `Scripts/build-app.sh` runs `swift build -c release`, creates `Claude Account Switcher.app/Contents/{MacOS,Resources}`, copies executable/resources, writes `Info.plist` with `LSUIElement=true`, `LSMinimumSystemVersion=13.0`, and code-signs ad hoc with `codesign --deep --force --sign -`.
- `Scripts/install-dev.sh` installs only the built app and launcher integration helper; it must print that it does not migrate or alter accounts.
- README includes build, launch, migration, rollback, uninstall, and troubleshooting commands with absolute paths and a warning to test on copies first.

- [ ] **Step 1: Add an end-to-end test using a temporary home and fake Claude executable; assert import → activate → launcher invocation selects the new profile.**
- [ ] **Step 2: Run the test and verify failure.**
- [ ] **Step 3: Add executable build/install scripts with `set -euo pipefail`, path validation, and no destructive commands.**
- [ ] **Step 4: Add README and diagnostic commands (`swift test`, `swift build -c release`, `./Scripts/build-app.sh`).**
- [ ] **Step 5: Run `swift test`, `swift build -c release`, `./Scripts/build-app.sh`, inspect app bundle with `file` and `plutil`, and run the launcher fixture manually.**
- [ ] **Step 6: Commit `feat: package Claude Account Switcher for macOS`.**

## Self-Review Checklist

- [x] Every design requirement maps to Tasks 1–8.
- [x] No production test accesses the real home, Keychain, aliases, or Claude sessions.
- [x] Launcher and `launchctl` both apply the same active profile while preserving process arguments.
- [x] Status parsing has an allowlist and no token field.
- [x] Migration preserves originals and supports rollback/restore.
- [x] The plan contains no unspecified placeholder or vague error-handling step.

## Environment Adaptation

The machine used for implementation has Swift Command Line Tools but no Xcode/XCTest runtime. The implementation therefore uses `ClaudeAccountSwitcherTests`, an executable Swift test runner invoked with `swift run ClaudeAccountSwitcherTests`; the core interfaces remain library-based and can be moved to an XCTest target when Xcode is installed.
