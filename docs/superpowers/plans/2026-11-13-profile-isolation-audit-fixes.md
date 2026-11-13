# Correções da auditoria de isolamento de perfis (2026-11-13) — Plano de implementação

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Corrigir os 4 problemas e os 4 pontos menores encontrados na auditoria de 2026-11-13 sobre perda de sessão e mistura de dados entre perfis, sem mudar o comportamento normal de troca.

**Architecture:** Todas as mudanças ficam dentro dos módulos existentes (`ClaudeAccountSwitcherCore` para lógica + `ClaudeAccountSwitcherApp` para UI). Cada correção é uma tarefa independente com seu próprio teste no executável `ClaudeAccountSwitcherTests`. Nada de novos targets, dependências ou arquivos de UI.

**Tech Stack:** Swift 6.3 (swift-tools-version 6.0), macOS 13+, SwiftPM. Testes: executável próprio (sem XCTest), helpers `check(_:_:)` e `temporaryRoot()`.

## Global Constraints

- Idioma dos comentários de código: português (padrão do repositório). Strings de UI SEMPRE via `AppStrings.t(pt, en)` (`Sources/ClaudeAccountSwitcherApp/AppStrings.swift`).
- Convenção do store: `save(_:)` só para criar; mutação de perfil existente usa `update(id:_:)`.
- Mensagens de commit: **nunca** incluir `Co-Authored-By: Claude` nem qualquer atribuição a IA (regra do `~/.claude/CLAUDE.md` do usuário, que vence a regra do harness).
- Testes: adicionar `static func testX() throws` ao enum `ProfileStoreTests` e a tupla `("descrição", testX)` ao array `tests` em `main()` (`Tests/ClaudeAccountSwitcherTests/ProfileStoreTests.swift`, o array termina na linha `        ]` ~linha 120). Rodar com `swift run ClaudeAccountSwitcherTests` a partir da raiz do repo. A saída imprime `PASS <nome>`/`FAIL <nome>` por teste e termina com código 1 se algo falhar.
- Build: `swift build` (debug). Verificar que o target App compila mesmo nas tarefas sem teste unitário (UI).
- Trabalhar em uma branch a partir de `main` (ex.: `fix/profile-isolation-audit`), um commit por tarefa.

## Contexto da auditoria (leia antes de começar)

Como uma "sessão" vive em `<perfil>/config` (transcripts em `projects/`, `.claude.json`, `sessions/<pid>.json`), e como a troca só reescreve `active-profile.json` + `launchctl setenv` + symlink do Paseo, está descrito em `docs/superpowers/specs/2026-10-17-profile-switch-session-safety-design.md`. Leia a seção "O que uma sessão é, e onde mora" e o "Bug confirmado em 2026-10-23".

Layout de um perfil gerenciado: `~/Library/Application Support/Claude Account Switcher/Profiles/<UUID>/config` (= `Profile.directory`) com irmão `Profiles/<UUID>/desktop` (= `Profile.desktopDirectory`, sessão do app nativo).

Problemas encontrados (resumo; cada um vira uma tarefa abaixo):

1. **Manutenção apaga credenciais de pastas externas (destrutivo).** `KeychainCredentials.stale` marca como órfã toda credencial `Claude Code-credentials-<hash>` que não seja de um perfil gerenciado — inclusive a de `~/.claude-work` (alias `claude-work` do usuário) ou da pasta própria de outro app.
2. **Processo filho de uma sessão aberta é redirecionado ao perfil ativo.** O launcher `bin/claude` sobrescreve qualquer `CLAUDE_CONFIG_DIR` dentro da raiz gerenciada, inclusive o herdado por uma sessão `claude` viva no perfil A. Depois de trocar para B, `claude mcp add`/`claude -p` rodados pela ferramenta Bash daquela sessão gravam em B.
3. **Remover perfil deixa `Profiles/<UUID>/desktop`** (cookies/sessão do app nativo) no disco; o alerta promete apagar tudo.
4. **Desinstalar deixa estado dividido:** não faz `launchctl unsetenv` e não reverte o provider `claude` do Paseo (que fica apontando para um launcher que não existe mais).
5. `ConversationMatch.resumeCommand` ainda começa com `cas switch '<nome>'` (troca o perfil global da máquina só para retomar; falha com nomes duplicados). O launcher resume-aware já resolve o perfil dono.
6. `addAccount` cria `Profiles/<UUID>/config` antes do login e deixa a pasta órfã se o login falha/cancela.
7. `ActivationService.rollback` grava `store.save(previousRecord)` (padrão de lost update que o resto evita; ramo inalcançável, mas contradiz a convenção).
8. `migrateExisting` chama `execute(plan)` sem `desktopTarget`, então o ramo que copia a sessão do app nativo na migração é código morto.

---

### Task 1: Manutenção só apaga credenciais de diretórios órfãos do próprio app

**Files:**
- Modify: `Sources/ClaudeAccountSwitcherCore/Infrastructure/KeychainCredentials.swift:28-32`
- Modify: `Sources/ClaudeAccountSwitcherCore/Infrastructure/MaintenanceService.swift:53-55`
- Modify: `Sources/ClaudeAccountSwitcherApp/MenuBarController.swift` (texto do alerta de manutenção, ~linha 340)
- Modify: `README.md:107`
- Test: `Tests/ClaudeAccountSwitcherTests/ProfileStoreTests.swift` (`testKeychainServiceParsingAndStale`, ~linha 943)

**Interfaces:**
- Produces: `KeychainCredentials.stale(services: [String], orphanedProfileDirectories: [URL]) -> [String]` — devolve só os serviços cujo hash bate com `<órfão>/config`. A assinatura antiga `stale(services:knownDirectories:)` é removida.

- [x] **Step 1: Reescrever o teste para o novo contrato**

Substituir, em `testKeychainServiceParsingAndStale`, a última linha (`try check(KeychainCredentials.stale(services: services, knownDirectories: [dirA, dirB]) == ...`) por:

```swift
        // Só credenciais de diretórios órfãos do PRÓPRIO app podem ser apagadas. Uma credencial de
        // pasta externa (~/.claude-work, pasta de outro app) não é "de perfil que já não existe":
        // apagá-la destruiria um login que o usuário ainda usa fora do switcher.
        let orphanContainer = URL(fileURLWithPath: "/tmp/cas/Profiles/DEADBEEF-0000-0000-0000-000000000000")
        let orphanService = KeychainCredentials.serviceName(for: orphanContainer.appendingPathComponent("config"))
        let external = KeychainCredentials.serviceName(for: URL(fileURLWithPath: "/Users/x/.claude-work"))
        let candidates = [a, orphanService, external, "Claude Code-credentials-deadbeef"]
        try check(KeychainCredentials.stale(services: candidates, orphanedProfileDirectories: [orphanContainer]) == [orphanService], "stale must list only services of orphaned managed directories")
        try check(KeychainCredentials.stale(services: candidates, orphanedProfileDirectories: []).isEmpty, "no orphans → nothing to delete, even with unknown services present")
```

- [x] **Step 2: Rodar o teste e confirmar que falha na compilação**

Run: `swift run ClaudeAccountSwitcherTests 2>&1 | tail -5`
Expected: erro de compilação `extra argument 'orphanedProfileDirectories'` / `missing argument for parameter 'knownDirectories'`.

- [x] **Step 3: Implementar o novo `stale`**

Em `KeychainCredentials.swift`, substituir a função `stale(services:knownDirectories:)` por:

```swift
    /// Serviços que pertencem a diretórios órfãos de `Profiles/` (perfil removido pela metade).
    /// Deliberadamente NÃO é "tudo que não é de um perfil conhecido": o usuário pode usar
    /// `CLAUDE_CONFIG_DIR` próprio fora do app (`~/.claude-work`, pasta de outro app) e o launcher
    /// respeita essas pastas — apagar a credencial delas destruiria um login em uso.
    public static func stale(services: [String], orphanedProfileDirectories: [URL]) -> [String] {
        let orphans = Set(orphanedProfileDirectories.map { serviceName(for: $0.appendingPathComponent("config", isDirectory: true)) })
        return services.filter { orphans.contains($0) }
    }
```

Em `MaintenanceService.scan`, a chamada passa a usar o relatório de órfãos já calculado (mover a linha `report.orphanedDirectories = ...` para ANTES do bloco do keychain, se ainda não estiver):

```swift
        report.orphanedDirectories = try store.orphanedProfileDirectories()
        if let keychain {
            report.staleKeychainServices = KeychainCredentials.stale(services: keychain.listServices(), orphanedProfileDirectories: report.orphanedDirectories)
        }
```

- [x] **Step 4: Ajustar o texto do alerta e o README**

Em `MenuBarController.runMaintenance`, a linha do Keychain passa a dizer de onde vêm as credenciais:

```swift
            AppStrings.t("• \(report.staleKeychainServices.count) credencial(is) no Keychain de diretórios órfãos de Profiles/ (credenciais de pastas externas ao app nunca são tocadas)", "• \(report.staleKeychainServices.count) Keychain credential(s) of orphaned Profiles/ directories (credentials of folders outside the app are never touched)"),
```

No `README.md`, linha 107, trocar `Keychain credentials of removed profiles` por `Keychain credentials of orphaned managed profile directories (credentials of external config folders such as ~/.claude-work are never touched)`.

- [x] **Step 5: Rodar a suíte completa**

Run: `swift run ClaudeAccountSwitcherTests 2>&1 | grep -E 'FAIL|PASS keychain|PASS maintenance'`
Expected: `PASS keychain services parse...`, `PASS maintenance scan...`, nenhum `FAIL`.

- [x] **Step 6: Commit**

```bash
git add Sources/ClaudeAccountSwitcherCore/Infrastructure/KeychainCredentials.swift Sources/ClaudeAccountSwitcherCore/Infrastructure/MaintenanceService.swift Sources/ClaudeAccountSwitcherApp/MenuBarController.swift README.md Tests/ClaudeAccountSwitcherTests/ProfileStoreTests.swift
git commit -m "fix: maintenance only deletes Keychain credentials of orphaned managed directories"
```

---

### Task 2: Launcher respeita o `CLAUDE_CONFIG_DIR` herdado de uma sessão que ele mesmo lançou

**Files:**
- Modify: `Sources/ClaudeAccountSwitcherCore/Infrastructure/ShellIntegration.swift:100-150` (`renderLauncher`)
- Test: `Tests/ClaudeAccountSwitcherTests/ProfileStoreTests.swift` (novo `testLauncherKeepsInheritedDirOfLaunchedSession`)

**Interfaces:**
- Produces: o launcher exporta `CAS_LAUNCHED_DIR=<dir escolhido>` antes do `exec`. Numa invocação seguinte, se `CLAUDE_CONFIG_DIR` for igual a `CAS_LAUNCHED_DIR` herdado e o diretório existir, o launcher usa esse valor sem consultar o estado ativo (a sessão pai é dona do valor). Um `CLAUDE_CONFIG_DIR` que veio só do `cas-env.sh` (sem a marca, ou com marca divergente) continua seguindo o perfil ativo.

- [x] **Step 1: Escrever o teste**

Adicionar ao enum (logo após `testLauncherKeepsForeignConfigDir`):

```swift
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
```

E registrar no array `tests`, após a tupla de `testLauncherKeepsForeignConfigDir`:

```swift
            ,("launcher keeps the inherited CLAUDE_CONFIG_DIR of a session it launched itself", testLauncherKeepsInheritedDirOfLaunchedSession)
```

- [x] **Step 2: Rodar e ver falhar**

Run: `swift run ClaudeAccountSwitcherTests 2>&1 | grep 'inherited CLAUDE_CONFIG_DIR'`
Expected: `FAIL launcher keeps the inherited ... : launcher must export CAS_LAUNCHED_DIR ...`

- [x] **Step 3: Alterar o launcher**

Em `renderLauncher`, substituir o bloco `case "${CLAUDE_CONFIG_DIR:-}" in ... esac` por:

```sh
# Pasta escolhida por quem chamou, fora da raiz gerenciada: não é um perfil, então não é nossa para trocar.
case "${CLAUDE_CONFIG_DIR:-}" in
  ''|"$MANAGED_ROOT"|"$MANAGED_ROOT"/*) ;;
  *) exec "$OFFICIAL" "$@" ;;
esac
# Filho de uma sessão que este launcher lançou (marca CAS_LAUNCHED_DIR igual ao valor herdado): a sessão
# pai é dona do perfil. Sem isso, `claude mcp add`/`claude -p` rodados de dentro de uma sessão em A
# gravariam no perfil ativo B depois de uma troca. Um valor que veio só do cas-env.sh não traz a marca.
if [ -n "${CAS_LAUNCHED_DIR:-}" ] && [ "${CLAUDE_CONFIG_DIR:-}" = "$CAS_LAUNCHED_DIR" ] && [ -d "$CAS_LAUNCHED_DIR" ]; then
  exec "$OFFICIAL" "$@"
fi
```

E, no fim do script, antes de `exec "$OFFICIAL" "$@"`, trocar a linha `export CLAUDE_CONFIG_DIR="$CONFIG_DIR"` por:

```sh
export CLAUDE_CONFIG_DIR="$CONFIG_DIR"
export CAS_LAUNCHED_DIR="$CONFIG_DIR"
exec "$OFFICIAL" "$@"
```

Atualizar o doc comment de `renderLauncher` adicionando um parágrafo:

```swift
    /// A marca `CAS_LAUNCHED_DIR` (exportada junto com `CLAUDE_CONFIG_DIR` antes do exec) identifica processos
    /// filhos de uma sessão lançada por este launcher: quando o valor herdado é igual à marca, ele é respeitado
    /// mesmo estando dentro da raiz gerenciada, para a sessão pai continuar dona do perfil após uma troca.
```

- [x] **Step 4: Rodar a suíte completa**

Run: `swift run ClaudeAccountSwitcherTests 2>&1 | grep -E 'FAIL|PASS launcher'`
Expected: todos os `launcher ...` em PASS (inclui `keeps a CLAUDE_CONFIG_DIR chosen outside`, `--resume follows`, `stays consistent under rapid`), nenhum `FAIL`.

- [x] **Step 5: Commit**

```bash
git add Sources/ClaudeAccountSwitcherCore/Infrastructure/ShellIntegration.swift Tests/ClaudeAccountSwitcherTests/ProfileStoreTests.swift
git commit -m "fix: launcher keeps the profile of the session that spawned it after a switch"
```

---

### Task 3: Remover perfil apaga o contêiner `Profiles/<UUID>` inteiro (inclusive `desktop`)

**Files:**
- Modify: `Sources/ClaudeAccountSwitcherCore/Infrastructure/ProfileStore.swift:60-73` (`remove`)
- Test: `Tests/ClaudeAccountSwitcherTests/ProfileStoreTests.swift` (`testRemoveProfile`, ~linha 546)

**Interfaces:**
- Produces: `ProfileStore.remove(_:)` remove `Profiles/<UUID>` quando `profile.directory` é `Profiles/<UUID>/config` (layout gerenciado); caso contrário mantém o comportamento atual (só `profile.directory`).

- [x] **Step 1: Estender o teste**

Substituir `testRemoveProfile` por:

```swift
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
```

- [x] **Step 2: Rodar e ver falhar**

Run: `swift run ClaudeAccountSwitcherTests 2>&1 | grep -E 'remove'`
Expected: `FAIL ... : desktop session of the removed profile was left on disk`

- [x] **Step 3: Implementar**

Em `ProfileStore.remove`, trocar a linha `if fileManager.fileExists(atPath: profile.directory.path) { try fileManager.removeItem(at: profile.directory) }` por:

```swift
            // Layout gerenciado é `Profiles/<uuid>/config` com o irmão `desktop` (sessão do app nativo):
            // apaga o contêiner inteiro para não deixar cookies logados nem um órfão para a manutenção.
            let container = profile.directory.deletingLastPathComponent()
            let target = container.lastPathComponent == profile.id.uuidString ? container : profile.directory
            if fileManager.fileExists(atPath: target.path) { try fileManager.removeItem(at: target) }
```

- [x] **Step 4: Rodar a suíte completa**

Run: `swift run ClaudeAccountSwitcherTests 2>&1 | grep -E 'FAIL|PASS.*remov'`
Expected: `PASS` em `testRemoveProfile` e `testRemoveKeepsMetadataWhenDirectoryDeletionFails`; nenhum `FAIL`. (O segundo continua válido sem alteração: ele deixa `Profiles/<uuid>` com permissão 0o500, e apagar o contêiner recursivamente ainda precisa remover `config` de dentro de um pai somente-leitura, logo falha e o metadata fica íntegro.)

- [x] **Step 5: Commit**

```bash
git add Sources/ClaudeAccountSwitcherCore/Infrastructure/ProfileStore.swift Tests/ClaudeAccountSwitcherTests/ProfileStoreTests.swift
git commit -m "fix: removing a profile also deletes its desktop session directory"
```

---

### Task 4: Desinstalar limpa o launchd e reverte o provider do Paseo

**Files:**
- Modify: `Sources/ClaudeAccountSwitcherCore/Infrastructure/PaseoIntegration.swift` (novo `revert()`)
- Modify: `Sources/ClaudeAccountSwitcherApp/MenuBarController.swift:856-877` (`uninstall`)
- Modify: `Sources/ClaudeAccountSwitcherApp/PreferencesView.swift:126`
- Test: `Tests/ClaudeAccountSwitcherTests/ProfileStoreTests.swift` (novo `testPaseoRevertRemovesOnlyOurFields`)

**Interfaces:**
- Produces: `PaseoIntegration.revert() throws -> URL?` — remove `agents.providers.claude.command` se for `[launcherURL.path]` e `agents.providers.claude.env.CLAUDE_CONFIG_DIR` se for `activeConfigDirSymlink.path`; faz backup em `Backups/paseo-config-<epoch>.json` antes de escrever; devolve a URL do backup, ou `nil` se não havia nada nosso para reverter (sem escrever). Lança `PaseoIntegrationError.configNotFound` se o config não existe.

- [x] **Step 1: Escrever o teste**

```swift
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
```

Registrar no array `tests`:

```swift
            ,("paseo revert removes only the launcher command and symlink env, with backup", testPaseoRevertRemovesOnlyOurFields)
```

- [x] **Step 2: Rodar e ver falhar na compilação**

Run: `swift run ClaudeAccountSwitcherTests 2>&1 | grep -m1 'revert'`
Expected: `error: value of type 'PaseoIntegration' has no member 'revert'`

- [x] **Step 3: Implementar `revert()`**

Adicionar a `PaseoIntegration` (após `integrate()`):

```swift
    /// Desfaz exatamente o que `integrate()` gravou: tira `command` quando é o nosso launcher e o env
    /// `CLAUDE_CONFIG_DIR` quando é o nosso symlink. Qualquer outro campo (inclusive um env próprio do
    /// usuário) fica intacto. Devolve o backup gravado, ou `nil` quando não havia nada nosso (não escreve).
    /// Usado na desinstalação: sem isto o provider ficaria apontando para um launcher que não existe mais.
    @discardableResult
    public func revert() throws -> URL? {
        guard let raw = try? Data(contentsOf: configURL) else { throw PaseoIntegrationError.configNotFound }
        guard var root = try JSONSerialization.jsonObject(with: raw) as? [String: Any] else { throw PaseoIntegrationError.invalidConfig }
        guard var agents = root["agents"] as? [String: Any],
              var providers = agents["providers"] as? [String: Any],
              var claude = providers["claude"] as? [String: Any] else { return nil }
        var changed = false
        if claude["command"] as? [String] == [launcherURL.path] { claude["command"] = nil; changed = true }
        if var env = claude["env"] as? [String: Any], env["CLAUDE_CONFIG_DIR"] as? String == activeConfigDirSymlink.path {
            env["CLAUDE_CONFIG_DIR"] = nil
            claude["env"] = env.isEmpty ? nil : env
            changed = true
        }
        guard changed else { return nil }

        let backups = appSupport.appendingPathComponent("Backups", isDirectory: true)
        try FileManager.default.createDirectory(at: backups, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let backupURL = backups.appendingPathComponent("paseo-config-\(Int(Date().timeIntervalSince1970)).json")
        try raw.write(to: backupURL, options: .atomic)

        providers["claude"] = claude
        agents["providers"] = providers
        root["agents"] = agents
        let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted])
        try data.write(to: configURL, options: .atomic)
        return backupURL
    }
```

- [x] **Step 4: Rodar o teste**

Run: `swift run ClaudeAccountSwitcherTests 2>&1 | grep -E 'FAIL|PASS paseo'`
Expected: todos `paseo ...` em PASS, nenhum `FAIL`.

- [x] **Step 5: Usar no `uninstall` e ajustar os textos**

Em `MenuBarController.uninstall`, substituir o corpo do `do { ... }` por:

```swift
        do {
            let home = FileManager.default.homeDirectoryForCurrentUser
            try shell.remove(home: home)
            try? loginItem.setEnabled(false)
            try? FileManager.default.removeItem(at: shell.launcherURL())
            // Sem o launcher e o bloco do shell, novos terminais voltam para ~/.claude. O launchd e o
            // Paseo precisam voltar junto, senão apps GUI e o Paseo ficariam num perfil e o terminal em outro.
            try? SystemLaunchdEnvironment().unset()
            if paseo.isDetected() { try? paseo.revert() }
            let bundle = Bundle.main.bundleURL
            if bundle.path.hasPrefix("/Applications/") || bundle.path.hasPrefix(home.appendingPathComponent("Applications").path + "/") {
                try? FileManager.default.removeItem(at: bundle)
            }
            preferencesWindowController?.close()
            notify(AppStrings.t("Aplicativo desinstalado; seus perfis foram preservados", "App uninstalled; your profiles were preserved"))
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { NSApp.terminate(nil) }
        } catch { showError(error) }
```

E trocar `alert.messageText`/`alert.informativeText` do mesmo método por:

```swift
        alert.messageText = AppStrings.t("Desinstalar Claude Account Switcher?", "Uninstall Claude Account Switcher?")
        alert.informativeText = AppStrings.t(
            "O aplicativo, o launcher, a integração do terminal, a variável CLAUDE_CONFIG_DIR do launchd e a integração com o Paseo serão removidos. Novos processos claude voltam a usar ~/.claude. Seus perfis, credenciais e dados em Library/Application Support serão preservados.",
            "The app, the launcher, the terminal integration, the launchd CLAUDE_CONFIG_DIR variable and the Paseo integration will be removed. New claude processes go back to ~/.claude. Your profiles, credentials and data in Library/Application Support are preserved.")
        alert.addButton(withTitle: AppStrings.t("Desinstalar", "Uninstall"))
        alert.addButton(withTitle: AppStrings.t("Cancelar", "Cancel"))
```

Em `PreferencesView.swift:126`, trocar o `Text("Os perfis e credenciais serão preservados ao desinstalar.")` por:

```swift
                    Text(AppStrings.t("Ao desinstalar, perfis e credenciais são preservados; terminal, launchd e Paseo voltam para ~/.claude.", "Uninstalling keeps profiles and credentials; terminal, launchd and Paseo go back to ~/.claude."))
```

- [x] **Step 6: Build e suíte**

Run: `swift build 2>&1 | tail -3 && swift run ClaudeAccountSwitcherTests 2>&1 | grep -c FAIL`
Expected: `Build complete!` e `0`.

- [x] **Step 7: Commit**

```bash
git add Sources/ClaudeAccountSwitcherCore/Infrastructure/PaseoIntegration.swift Sources/ClaudeAccountSwitcherApp/MenuBarController.swift Sources/ClaudeAccountSwitcherApp/PreferencesView.swift Tests/ClaudeAccountSwitcherTests/ProfileStoreTests.swift
git commit -m "fix: uninstall unsets the launchd variable and reverts the Paseo provider"
```

---

### Task 5: Comando "Onde está minha conversa?" não troca mais o perfil global

**Files:**
- Modify: `Sources/ClaudeAccountSwitcherCore/Infrastructure/ConversationLocator.swift:11-18`
- Modify: `Sources/ClaudeAccountSwitcherApp/MenuBarController.swift` (`locateConversation`, texto do `ask.informativeText`)
- Test: `Tests/ClaudeAccountSwitcherTests/ProfileStoreTests.swift` (`testConversationLocator`, ~linha 1008)

**Interfaces:**
- Produces: `ConversationMatch.resumeCommand` vira `cd '<cwd>' && claude --resume <id>` (ou só `claude --resume <id>` sem cwd). O launcher resume-aware (`renderLauncher`) já escolhe o perfil dono.

- [x] **Step 1: Atualizar as asserções do teste**

Em `testConversationLocator`, trocar as duas verificações de `resumeCommand` por:

```swift
        // Sem `cas switch`: o launcher resume-aware já abre a conversa no perfil dono, e trocar o perfil
        // global da máquina só para retomar uma conversa era efeito colateral indesejado.
        try check(byID[0].resumeCommand == "cd '/Users/me/Develop/api' && claude --resume aaaa1111-0000-0000-0000-000000000000", "unexpected resume command: \(byID[0].resumeCommand)")
```

e

```swift
        try check(bySlug[0].resumeCommand == "claude --resume bbbb2222-0000-0000-0000-000000000000", "resume command without cwd should be just the resume")
```

- [x] **Step 2: Rodar e ver falhar**

Run: `swift run ClaudeAccountSwitcherTests 2>&1 | grep 'conversation locator'`
Expected: `FAIL conversation locator ... unexpected resume command: cas switch 'Work' && ...`

- [x] **Step 3: Implementar**

Em `ConversationLocator.swift`, substituir `resumeCommand` por:

```swift
    /// Comando pronto para retomar: entra na pasta e faz `--resume`. Não troca o perfil ativo: o launcher
    /// gerenciado (`ShellIntegrationManager.renderLauncher`) detecta que o id pertence a outro perfil e
    /// abre a conversa lá, sem mexer na conta do resto da máquina.
    public var resumeCommand: String {
        var parts: [String] = []
        if let cwd { parts.append("cd \(Self.quoted(cwd))") }
        parts.append("claude --resume \(sessionID)")
        return parts.joined(separator: " && ")
    }
```

Se `quoted(_:)` ficar sem uso além do `cd`, mantenha-o (ainda é usado). Em `MenuBarController.locateConversation`, trocar o `ask.informativeText` por:

```swift
        ask.informativeText = AppStrings.t("Trocar de perfil não move conversas: cada uma fica no perfil em que foi iniciada. O comando gerado retoma a conversa no perfil dono sem trocar o perfil ativo. Informe o id da sessão ou um trecho do diretório do projeto.", "Switching profiles does not move conversations: each one stays in the profile it was started in. The generated command resumes it in the owning profile without changing the active profile. Enter the session id or a fragment of the project directory.")
```

- [x] **Step 4: Rodar a suíte**

Run: `swift run ClaudeAccountSwitcherTests 2>&1 | grep -E 'FAIL|PASS conversation'`
Expected: `PASS conversation locator ...`, nenhum `FAIL`.

- [x] **Step 5: Commit**

```bash
git add Sources/ClaudeAccountSwitcherCore/Infrastructure/ConversationLocator.swift Sources/ClaudeAccountSwitcherApp/MenuBarController.swift Tests/ClaudeAccountSwitcherTests/ProfileStoreTests.swift
git commit -m "fix: resume command relies on the launcher instead of switching the active profile"
```

---

### Task 6: Login cancelado ou falho não deixa diretório órfão

**Files:**
- Modify: `Sources/ClaudeAccountSwitcherApp/MenuBarController.swift:366-384` (`addAccount`)

Sem teste unitário (fluxo de UI + OAuth no browser); verificação por build e revisão.

- [x] **Step 1: Implementar a limpeza no `catch`**

Substituir o bloco `DispatchQueue.global(qos: .userInitiated).async { ... }` de `addAccount` por:

```swift
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            do {
                try self.auth.login(profileDirectory: directory, kind: kind)
                let status = try self.auth.status(profileDirectory: directory)
                let profile = Profile(id: id, name: name, email: status.email, organization: status.organization, kind: status.kind, directory: directory, health: status.isAuthenticated ? .ready : .expired)
                try self.store.save(profile)
                DispatchQueue.main.async { self.rebuildMenu(); self.notify(AppStrings.t("Conta adicionada", "Account added")); self.offerDesktopSessionCopy(for: profile) }
            } catch {
                // O diretório foi criado antes do OAuth; sem perfil salvo ele viraria um órfão em Profiles/
                // (com a credencial no Keychain, se o login chegou a gravar antes de falhar no status).
                try? self.keychain.delete(for: directory)
                try? FileManager.default.removeItem(at: directory.deletingLastPathComponent())
                DispatchQueue.main.async { self.showError(error) }
            }
        }
```

- [x] **Step 2: Build**

Run: `swift build 2>&1 | tail -3`
Expected: `Build complete!`

- [x] **Step 3: Commit**

```bash
git add Sources/ClaudeAccountSwitcherApp/MenuBarController.swift
git commit -m "fix: clean up the managed directory when adding an account fails"
```

---

### Task 7: Rollback da ativação usa `update` em vez de `save` do snapshot

**Files:**
- Modify: `Sources/ClaudeAccountSwitcherCore/Infrastructure/ActivationService.swift:58-63`

Coberto pelos testes existentes `testActivationRollback*` e `testActivationPreservesConcurrentEdits`; não há cenário observável novo (o `save` é o último passo), a mudança é de consistência com a convenção do store.

- [x] **Step 1: Implementar**

Em `rollback(...)`, trocar `if didSave, let previousRecord { try? store.save(previousRecord) }` por:

```swift
        // Só os campos que a ativação gravou: `save` do snapshot inteiro reverteria rename/uso feitos por
        // outro escritor nesse meio-tempo (mesma regra do caminho feliz).
        if didSave, let previousRecord {
            try? store.update(id: previousRecord.id) { $0.lastUsedAt = previousRecord.lastUsedAt; $0.health = previousRecord.health }
        }
```

- [x] **Step 2: Rodar a suíte**

Run: `swift run ClaudeAccountSwitcherTests 2>&1 | grep -E 'FAIL|PASS activation'`
Expected: todos `activation ...` em PASS, nenhum `FAIL`.

- [x] **Step 3: Commit**

```bash
git add Sources/ClaudeAccountSwitcherCore/Infrastructure/ActivationService.swift
git commit -m "refactor: activation rollback restores only its own fields"
```

---

### Task 8: Migração copia a sessão do app nativo para o perfil importado de `~/.claude` (só com o app fechado)

**Files:**
- Modify: `Sources/ClaudeAccountSwitcherCore/Infrastructure/MigrationService.swift:106-135` (`execute`)
- Modify: `Sources/ClaudeAccountSwitcherApp/MenuBarController.swift:490-500` (`migrateExisting`)
- Test: `Tests/ClaudeAccountSwitcherTests/ProfileStoreTests.swift` (`testMigrationImportsDesktopSession`, ~linha 1259)

**Interfaces:**
- Produces: `MigrationService.execute(_ plan: MigrationPlan, desktopTarget: URL? = nil, isDesktopRunning: () -> Bool = { false }) throws -> MigrationReport`. Com `desktopTarget` definido e o app aberto, lança `MigrationError.desktopAppRunning` ANTES de copiar qualquer coisa (o chamador decide se importa sem a sessão desktop). A cópia do desktop usa staging + rename, igual a `copyDefaultDesktopSessionIfAvailable`.

- [x] **Step 1: Estender o teste**

Substituir `testMigrationImportsDesktopSession` por:

```swift
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
```

- [x] **Step 2: Rodar e ver falhar na compilação**

Run: `swift run ClaudeAccountSwitcherTests 2>&1 | grep -m1 'isDesktopRunning'`
Expected: `error: extra argument 'isDesktopRunning' in call`

- [x] **Step 3: Implementar em `execute`**

Substituir a assinatura e o bloco de cópia do desktop:

```swift
    public func execute(_ plan: MigrationPlan, desktopTarget: URL? = nil, isDesktopRunning: () -> Bool = { false }) throws -> MigrationReport {
        let fm = FileManager.default; var imported: [URL] = []
        // Decide antes de tocar no disco: copiar LevelDB/SQLite do app aberto gera sessão inconsistente.
        if desktopTarget != nil, plan.desktopSource != nil, isDesktopRunning() { throw MigrationError.desktopAppRunning }
        for source in plan.sources {
            let id = UUID(); let destination = try store.createManagedDirectory(id: id)
            let entries = try fm.contentsOfDirectory(at: source, includingPropertiesForKeys: [.isSymbolicLinkKey], options: [])
            for entry in entries {
                if (try entry.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true { throw NSError(domain: "ClaudeAccountSwitcher", code: 1001, userInfo: [NSLocalizedDescriptionKey: "symbolic links are not imported"]) }
                try fm.copyItem(at: entry, to: destination.appendingPathComponent(entry.lastPathComponent))
            }
            // Só a pasta padrão `~/.claude` depende do `~/.claude.json` global; uma pasta usada via
            // CLAUDE_CONFIG_DIR (ex.: ~/.claude-work) já traz o seu próprio e esse vence.
            let ownConfig = destination.appendingPathComponent(".claude.json")
            if source.lastPathComponent == ".claude", let globalConfig = plan.globalConfig, !fm.fileExists(atPath: ownConfig.path), fm.fileExists(atPath: globalConfig.path) {
                try fm.copyItem(at: globalConfig, to: ownConfig)
            }
            try store.save(Profile(id: id, name: source.lastPathComponent == ".claude" ? "Claude pessoal" : "Claude work", kind: .custom, directory: destination, health: .unknown))
            imported.append(destination)
            if let desktopSource = plan.desktopSource, source.path == desktopTarget?.path {
                // Mesmo staging atômico de `copyDefaultDesktopSessionIfAvailable`: uma cópia interrompida
                // nunca passa por sessão válida em `hasRealDesktopSession`.
                let desktopDestination = destination.deletingLastPathComponent().appendingPathComponent("desktop", isDirectory: true)
                let staging = destination.deletingLastPathComponent().appendingPathComponent(".desktop.tmp-\(UUID().uuidString)", isDirectory: true)
                do { try MigrationService.copyDesktopSessionContents(from: desktopSource, to: staging) }
                catch { try? fm.removeItem(at: staging); throw error }
                try fm.moveItem(at: staging, to: desktopDestination)
            }
        }
        return MigrationReport(imported: imported, aliases: plan.aliases)
    }
```

(O bloco antigo que fazia `createDirectory` + loop de `copyItem` para o desktop é removido, pois `copyDesktopSessionContents` já recusa symlinks e cria o destino.)

- [x] **Step 4: Ligar na UI**

Em `MenuBarController.migrateExisting`, substituir o `do { ... }` por:

```swift
        do {
            let plan = try migration.preview(home: home)
            guard !plan.sources.isEmpty else { notify(AppStrings.t("Nenhum perfil existente encontrado", "No existing profiles found")); return }
            // A sessão do app nativo (pasta padrão) corresponde à conta de ~/.claude; só ela recebe a cópia.
            let desktopTarget = plan.desktopSource == nil ? nil : plan.sources.first(where: { $0.lastPathComponent == ".claude" })
            let alert = NSAlert(); alert.messageText = AppStrings.t("Migrar perfis existentes?", "Migrate existing profiles?")
            var lines = plan.sources.map(\.path)
            if desktopTarget != nil { lines.append(AppStrings.t("+ sessão do app nativo do Claude (copiada para o perfil de ~/.claude; feche o app antes)", "+ native Claude app session (copied into the ~/.claude profile; quit the app first)")) }
            alert.informativeText = lines.joined(separator: "\n") + "\n\n" + AppStrings.t("Os originais serão mantidos.", "The originals are kept.")
            alert.addButton(withTitle: AppStrings.t("Migrar", "Migrate")); alert.addButton(withTitle: AppStrings.t("Cancelar", "Cancel"))
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            let report = try migration.execute(plan, desktopTarget: desktopTarget, isDesktopRunning: { desktopClient.isRunning() })
            rebuildMenu(); notify(AppStrings.t("\(report.imported.count) perfil(is) migrado(s)", "\(report.imported.count) profile(s) migrated"))
        } catch MigrationError.desktopAppRunning {
            showError(NSError(domain: "Claude Account Switcher", code: 8, userInfo: [NSLocalizedDescriptionKey: AppStrings.t("Feche o app nativo do Claude e tente de novo: a sessão dele só pode ser copiada com o app fechado.", "Quit the native Claude app and try again: its session can only be copied while the app is closed.")]))
        } catch { showError(error) }
```

- [x] **Step 5: Build e suíte completa**

Run: `swift build 2>&1 | tail -3 && swift run ClaudeAccountSwitcherTests 2>&1 | grep -E 'FAIL|PASS migration'`
Expected: `Build complete!`, todos `migration ...` em PASS, nenhum `FAIL`.

- [x] **Step 6: Commit**

```bash
git add Sources/ClaudeAccountSwitcherCore/Infrastructure/MigrationService.swift Sources/ClaudeAccountSwitcherApp/MenuBarController.swift Tests/ClaudeAccountSwitcherTests/ProfileStoreTests.swift
git commit -m "fix: migration copies the native app session into the ~/.claude profile"
```

---

### Task 9: Documentação (spec, CLAUDE.md, README)

**Files:**
- Modify: `docs/superpowers/specs/2026-10-17-profile-switch-session-safety-design.md` (nova seção no fim)
- Modify: `CLAUDE.md` (entradas de `ShellIntegration.swift`, `KeychainCredentials.swift`, `ProfileStore.swift`, `ConversationLocator.swift`, `PaseoIntegration.swift`)
- Modify: `README.md` (seção de limitações/uninstall, onde já fala de "Uninstall" ou "Maintenance")

- [x] **Step 1: Adicionar a seção à spec**

Acrescentar ao fim de `2026-10-17-profile-switch-session-safety-design.md`:

```markdown
## Auditoria 2026-11-13: mistura entre perfis e resíduos

| # | Cenário | Resultado | Ação |
|---|---|---|---|
| D1 | "Manutenção…" tratava como órfã toda credencial `Claude Code-credentials-<hash>` que não fosse de perfil gerenciado — inclusive `~/.claude-work` (alias `claude-work`) e pastas de outros apps que o launcher respeita de propósito | **Bug confirmado** (credencial f6312d1d de `~/.claude-work` seria apagada) | `KeychainCredentials.stale(services:orphanedProfileDirectories:)` só devolve credenciais de `Profiles/<uuid>` órfãos |
| D2 | Sessão viva no perfil A; usuário troca para B; a ferramenta Bash dessa sessão roda `claude mcp add`/`claude -p` → launcher sobrescrevia o `CLAUDE_CONFIG_DIR` herdado (está na raiz gerenciada) e gravava em B | **Bug confirmado** por teste com o launcher instalado | Launcher exporta `CAS_LAUNCHED_DIR`; herdado igual à marca é respeitado. Valor que veio só do `cas-env.sh` segue o ativo |
| D3 | `ProfileStore.remove` apagava só `config`; `desktop` (cookies do app nativo) sobrava como órfão | Confirmado | Remove o contêiner `Profiles/<uuid>` inteiro |
| D4 | Desinstalar não fazia `launchctl unsetenv` nem revertia o provider do Paseo (que apontava para o launcher apagado) | Confirmado | `SystemLaunchdEnvironment.unset()` + `PaseoIntegration.revert()` na desinstalação |
| D5 | `resumeCommand` começava com `cas switch` (trocava o perfil global; falha com nomes duplicados) | Confirmado | Só `cd && claude --resume`; o launcher resolve o perfil dono |
| D6 | `addAccount` deixava `Profiles/<uuid>` órfão quando o login falhava/cancelava | Confirmado (órfão de jul/2026 no disco) | Limpa diretório e credencial no `catch` |
| D7 | Rollback da ativação com `save` do snapshot | Inalcançável, inconsistente com a convenção | `update(id:)` só de `lastUsedAt`/`health` |
| D8 | Cópia da sessão desktop na migração nunca rodava (`desktopTarget` nunca passado) | Código morto | `migrateExisting` passa o alvo `~/.claude`; `execute` recusa com o app aberto e copia em staging |

Limitações mantidas (documentadas, sem correção):
- Trocas concorrentes GUI + `cas switch` podem intercalar os três passos (estado, launchd, symlink). Janela de milissegundos; exigiria lock entre processos.
- Com `relaunchDesktopOnSwitch` desligado, o app nativo aberto pelo Dock usa sempre a pasta padrão (`~/Library/Application Support/Claude`), isto é, a conta logada ali, independente do perfil ativo.
- Apps GUI (VS Code, Cursor) leem `launchctl getenv` uma vez no spawn: sessões abertas pela extensão depois de uma troca continuam no perfil de quando o app foi aberto.
```

- [x] **Step 2: Atualizar o CLAUDE.md**

Na entrada de `ShellIntegration.swift`, acrescentar ao fim: `Exporta `CAS_LAUNCHED_DIR`; um `CLAUDE_CONFIG_DIR` herdado igual à marca (filho de sessão lançada pelo launcher) é respeitado mesmo dentro da raiz gerenciada (auditoria 2026-11-13).`

Na entrada de `KeychainCredentials.swift`, trocar `listServices()/stale(...) para credenciais órfãs` por `listServices()/stale(services:orphanedProfileDirectories:) — só credenciais de Profiles/<uuid> órfãos; pastas externas (~/.claude-work) nunca são tocadas`.

Na entrada de `ProfileStore.swift`, acrescentar: `remove(_:) apaga o contêiner Profiles/<uuid> inteiro (config + desktop).`

Na entrada de `ConversationLocator.swift`, trocar `monta o comando --resume` por `monta `cd && claude --resume` (sem `cas switch`: o launcher resolve o perfil dono)`.

Na entrada de `PaseoIntegration.swift`, acrescentar: `revert() desfaz command/env na desinstalação.`

- [x] **Step 3: README**

Na linha de **Maintenance…** (já ajustada na Task 1) nada mais. Localizar a frase sobre desinstalar (`grep -n -i uninstall README.md`) e acrescentar: `Uninstalling also clears the launchd CLAUDE_CONFIG_DIR variable and reverts the Paseo provider, so terminal, GUI apps and Paseo all go back to ~/.claude together.` Se não houver frase sobre uninstall, adicionar esse parágrafo logo após a linha de Maintenance.

- [x] **Step 4: Commit**

```bash
git add docs/superpowers/specs/2026-10-17-profile-switch-session-safety-design.md CLAUDE.md README.md
git commit -m "docs: record the 2026-11-13 profile isolation audit and its fixes"
```

---

### Task 10: Verificação final

- [x] **Step 1: Suíte completa e build de release**

Run: `swift run ClaudeAccountSwitcherTests 2>&1 | tail -3 && swift build -c release --product ClaudeAccountSwitcher 2>&1 | tail -2`
Expected: última linha dos testes sem `FAIL` (contagem total = 103 + 2 novos = 105 testes), `Build complete!`.

- [x] **Step 2: Conferir o histórico**

Run: `git log --oneline main..HEAD`
Expected: 9 commits, um por tarefa (Tasks 1–9), nenhum com `Co-Authored-By`.
