# CLAUDE.md — Claude Account Switcher

Referência rápida para sessões de trabalho. Lido antes de tocar em código ou docs.

## Visão geral do produto

App nativo macOS (SwiftUI/AppKit), menu-bar app, chamado "Claude Account Switcher". Gerencia
múltiplos perfis/contas isolados do Claude Code (cada um com seu próprio `CLAUDE_CONFIG_DIR`,
credenciais, histórico, config) e permite alternar entre eles. A troca só afeta novos processos;
sessões shell/GUI já abertas não são alteradas. README completo e changelog vivem em
`README.md` (versão atual: 1.3.5 na última leitura).

Componentes de produto (ver specs para detalhes de design):
- Gerenciamento de perfis: `ProfileStore` (persistência), `ActivationService` (troca com rollback),
  `MigrationService` (importação de ambientes `~/.claude` existentes, inclusive sessão do app
  desktop).
- Integração de shell: `ShellIntegrationManager` instala um launcher transparente em
  `~/Library/Application Support/.../bin/claude` que resolve o perfil ativo e invoca o binário
  oficial com `CLAUDE_CONFIG_DIR` correto — cobre shells já abertos, sem precisar de alias.
- Autenticação: `ClaudeAuthService` chama `claude auth status`/login do CLI oficial.
- Uso/cotas: `ClaudeUsageService` lê o endpoint OAuth de consumo (`/api/oauth/usage`, mesmo usado
  pelo 9router, não é API pública documentada) — expõe quotas "Janela 5h", "Semanal" e
  "Semanal <Modelo>" (`seven_day_<modelo>`), mais soma de tokens locais das sessões.
- Alerta de 5h: `FiveHourAlertTracker` dispara notificação nativa uma vez por cruzamento de limiar
  (default 80%) da janela de 5h da conta ativa.
- Alerta de créditos semanais: `WeeklyCreditsAlertTracker` dispara quando restam ≥ threshold% de
  crédito e o reset semanal está a ≤24h. Avalia **todos** os perfis (não só o ativo) a cada
  refresh; se múltiplos perfis disparam no mesmo ciclo, agrupa numa única notificação. Reusa o som
  configurado para o alerta de 5h (`fiveHourAlertSoundName`).
- Integração opcional com Paseo: `PaseoIntegration` mantém um symlink estável apontando para o
  diretório de config do perfil ativo, porque o daemon do Paseo resolve `CLAUDE_CONFIG_DIR` uma
  vez no spawn e nunca relê `launchctl setenv`.
- Sincronização com app desktop nativo do Claude: `DesktopAppActivator`/`DesktopAppClient`
  encerram e relançam o app desktop (`com.anthropic.claudefordesktop`) apontando para o diretório
  do perfil escolhido, quando habilitado.

## Estrutura do repositório

Repositório único, uma branch **`main`** que rastreia `origin/main`
(`git@github.com:PedroPCardoso/ClaudeAccountSwitcher.git`). Tudo vive junto na raiz do repo:
código (`Package.swift`, `Sources/`, `Tests/`, `Scripts/`, `Resources/`), releases (`dist/`),
`README.md`, a landing page publicada (`docs/index.html` + `docs/assets/`), as specs e plans de
design (`docs/superpowers/`), o `CLAUDE.md` e as skills do projeto (`.claude/skills/`).

O GitHub Pages serve a landing page de `origin/main`, pasta `/docs`.

> Histórico: até jul/2026 o projeto usava dois históricos git paralelos (uma `main` só de docs na
> raiz e uma `public-main` num worktree `.worktrees/` com o código). Isso foi unificado numa
> única `main`; não há mais worktree nem branch `public-main`.

## Mapa de arquivos por responsabilidade

Caminho base: raiz do repositório.

### `Sources/ClaudeAccountSwitcherCore/Domain/` (lógica de domínio pura, sem I/O)
- `Profile.swift` — `Profile` (struct principal: id, nome, email, org, cor, ícone, kind, diretório,
  timestamps, health, usage), `ProfileKind`, `ProfileHealth`, `ActiveProfile`.
- `FiveHourAlert.swift` — `FiveHourAlertTracker` (dispara 1x por cruzamento de threshold),
  `FiveHourAlertThreshold` (chave de defaults + resolução de valor inválido), `FiveHourAlertSound`
  (enum de sons do sistema), `WeeklyCreditsAlertTracker` (dispara 1x por `resetAt`, indexado por
  UUID de perfil) e `WeeklyCreditsAlertThreshold` para o alerta de créditos semanais.
- `UsageTier.swift` — enum puro `UsageTier { ok, warning, critical }` + `forPercent(_:)` (limiares
  70/90) para colorir o % da barra de menu (feature 1.3.5, issue #33).
- `StatusBarUsage.swift` — `label(activeUsage:)` monta o `"NN%"` da barra de menu casando a cota
  pela identidade estável `QuotaKind.fiveHour` (issue #33).
- `UsageHistory.swift` — `DailyTokenUsage`, `PlanRecommendation` (+ `evaluate`) e `AnalysisSelection`
  (lógica pura de seleção de contas) da análise de uso agregado (feature 1.3.5, issue #34).
- `ProfileResolver.swift` — `resolve(_:query:)` do CLI `cas` (match exato nome/email →
  found/notFound/ambiguous, issue #35).
- `CASCommand.swift` — `CASParser.parse`/`CASCommand`: parsing/dispatch do CLI `cas` com exit code,
  sem chamar `exit()` (issue #35).

### `Sources/ClaudeAccountSwitcherCore/Infrastructure/` (I/O, processos, rede, sistema)
- `ProfileStore.swift` — persistência atômica de perfis em JSON (`profiles.json`,
  `active-profile.json`) sob um diretório raiz gerenciado; migra estado legado de conta ativa.
- `ActivationService.swift` — orquestra a troca de perfil: atualiza `launchctl setenv
  CLAUDE_CONFIG_DIR`, sincroniza app desktop, integra Paseo; rollback se falhar.
- `ClaudeAuthService.swift` — chama `claude auth status`/login via CLI oficial, mapeia para
  `AuthStatus`.
- `ClaudeLocator.swift` — localiza o binário `claude` real em `~/.local/share/claude/versions/...`.
- `ClaudeUsageService.swift` — busca cotas de uso via endpoint OAuth
  `https://api.anthropic.com/api/oauth/usage`; parse de `five_hour`, `seven_day`,
  `seven_day_<modelo>`; parsing de `resets_at` com timestamps ISO8601 fracionários.
- `UsageHistoryService.swift` — parseia os `.jsonl` de sessão em buckets diários de tokens por
  perfil (agrega só os perfis recebidos; cache por mtime+size), base da análise agregada (issue #34).
- `DesktopAppActivator.swift` / `DesktopAppClient.swift` — localiza, encerra e relança o app
  desktop nativo do Claude (`com.anthropic.claudefordesktop`) apontando para o perfil escolhido.
- `LaunchdEnvironment.swift` — wrapper de `launchctl setenv/unsetenv CLAUDE_CONFIG_DIR`.
- `LoginItemService.swift` — habilita/desabilita início automático via `SMAppService`.
- `MigrationService.swift` — importa ambientes `~/.claude`/`~/.claude-work` existentes, cópia de
  sessão desktop default para perfil novo.
- `PaseoIntegration.swift` — mantém symlink estável de config para compatibilidade com o daemon
  Paseo (ver comentário no arquivo para o motivo detalhado).
- `ProcessRunner.swift` — wrapper de `Process` com limite de output e captura de stdout/stderr.
- `ShellIntegration.swift` — instala/atualiza o launcher transparente `bin/claude` no PATH gerenciado
  do app (marcadores `# >>> Claude Account Switcher >>>` / `# <<< ... <<<`); `install(..., casBinary:)`
  também expõe o CLI `cas` no mesmo bin via symlink idempotente, e `remove()` limpa ambos. Suporta
  zsh/bash/fish (paths escapados via `singleQuoted`).

### `Sources/ClaudeAccountSwitcherApp/` (executável, UI)
- `AppMain.swift` — `@main`, `App` SwiftUI, delega para `MenuBarController` via
  `NSApplicationDelegateAdaptor`.
- `AppStrings.swift` — helper de i18n: `AppStrings.t(pt, en)` retorna a string pt-BR ou en-US
  conforme `Locale.current.language.languageCode == "pt"`. **Convenção obrigatória para toda
  string visível ao usuário** — nunca hardcode texto de UI em um só idioma.
- `MenuBarController.swift` (maior arquivo do target, ~440 linhas) — `NSApplicationDelegate`
  principal: monta `NSStatusItem`, monitora atalho global (`NSEvent.addGlobalMonitorForEvents`),
  lê preferências de `UserDefaults`, dispara alertas de 5h/semanal, coordena `ProfileStore`,
  `ActivationService`, `ClaudeAuthService`, `ClaudeUsageService`, `MigrationService`,
  `ShellIntegrationManager`. Define `AppPreferences` (namespace de chaves de defaults do app,
  atualmente só `relaunchDesktopOnSwitch`).
- `PreferencesView.swift` (~200 linhas) — SwiftUI da janela de Preferências: lista de perfis e
  ações (ativar, renomear, remover, relogin, importar, migrar, integrar Paseo), sliders/pickers de
  threshold e som de alerta via `@AppStorage`.
- `PreferencesWindowController.swift` — `NSWindowController` que hospeda `PreferencesView` via
  `NSHostingView`.
- `QuickSwitcher.swift` — SwiftUI compacto (popover) para busca/troca rápida de perfil por
  nome/email.
- `UsageView.swift` — SwiftUI da janela "Uso do Claude": cards por conta com barras de progresso,
  percentuais e horários de reset.
- `UsageWindowController.swift` — `NSWindowController` que hospeda `UsageView`.
- `AnalysisView.swift` / `AnalysisWindowController.swift` — janela "Análise de uso": gráfico
  empilhado por conta (Swift Charts), toggles de seleção de perfis e card de recomendação Max vs
  Pro; lê/grava `AppPreferences.analysisSelectedProfileIDs` (feature 1.3.5, issue #34).

### `Sources/CAS/` (executável `cas`, CLI)
- `main.swift` — companheiro de linha de comando `cas` (`list`/`current`/`switch <nome|email>`),
  dependente só do Core; reusa `ProfileResolver`/`CASCommand` (Domain) e `ActivationService`
  (`syncDesktopApp: false`). Empacotado em `Contents/MacOS/cas` pelo `build-app.sh` e exposto no
  bin gerenciado via `ShellIntegrationManager.install(..., casBinary:)` (feature 1.3.5, issue #35).

### `Tests/ClaudeAccountSwitcherTests/`
- `ProfileStoreTests.swift` — único arquivo de teste do projeto (533+ linhas). Ver seção de
  convenção de teste abaixo.

### Outros diretórios
- `Scripts/build-app.sh`, `Scripts/build-dmg.sh`, `Scripts/install-dev.sh` — build de `.app`
  distribuível, empacotamento de DMG, instalação local para dev.
- `Resources/claude-launcher`, `Resources/claude-account-switcher-logo.png` — copiados para o
  bundle do app (`resources: [.copy("../../Resources")]` no `Package.swift`).
- `dist/` — DMGs de releases publicadas (1.1.0 a 1.3.5 na última verificação).
- `docs/` — landing page publicada (`index.html` + `assets/`) e specs/plans em `superpowers/`.
- `.claude/skills/` — skills do projeto (`release`, `landing-page`).

## Convenção de teste

Não há XCTest. É um único **executável** `ClaudeAccountSwitcherTests`
(`.executableTarget` no `Package.swift`, `path: Tests/ClaudeAccountSwitcherTests`) cujo `@main`
(`ProfileStoreTests.main()`) roda um array de tuplas `(String, () async throws -> Void)`
sequencialmente, imprime `PASS`/`FAIL` por teste, e sai com código 1 se algo falhar. Assertions via
helper local `check(_ condition: Bool, _ message: String) throws`.

Para adicionar um teste: escrever `static func testX() throws` (ou `async throws`) no mesmo enum
`ProfileStoreTests`, e adicionar a tupla `("descrição legível", testX)` ao array `tests` dentro de
`main()`.

## Comandos exatos

Executar a partir da raiz do repositório (onde vive `Package.swift`):

```zsh
swift build                                   # build de debug
swift build -c release --product ClaudeAccountSwitcher   # build de release do app

swift run ClaudeAccountSwitcherTests          # roda toda a suíte de testes

swift run ClaudeAccountSwitcherApp            # executa o app localmente

./Scripts/build-app.sh                        # empacota .app
./Scripts/build-dmg.sh                        # empacota .dmg
./Scripts/install-dev.sh                      # instalação local para dev
```

Toolchain confirmada no ambiente: Swift 6.3.3 (swift-tools-version 6.0 no `Package.swift`),
`macOS(.v13)` como plataforma mínima.

## Convenção de strings

Toda string visível na UI passa por `AppStrings.t(portuguêsBR, inglêsUS)`
(`Sources/ClaudeAccountSwitcherApp/AppStrings.swift`). Não hardcodar texto de interface em um só
idioma — sempre fornecer os dois. `AppStrings.portuguese` decide o idioma via
`Locale.current.language.languageCode?.identifier == "pt"`.

## Specs e plans de design

Vivem em `docs/superpowers/`:
- `docs/superpowers/specs/` — specs aprovadas, formato de nome
  `YYYY-MM-DD-<topico>-design.md`. Confirmados: `2026-07-19-claude-account-switcher-design.md`,
  `2026-07-20-five-hour-usage-alert-design.md`, `2026-07-20-native-app-profile-sync-design.md`,
  `2026-07-21-weekly-credits-alert-design.md`.
- `docs/superpowers/plans/` — planos de implementação task-by-task, formato de nome
  `YYYY-MM-DD-<topico>.md` (sem sufixo `-design`). Confirmados:
  `2026-07-20-native-app-profile-sync.md`, `2026-07-21-weekly-credits-alert.md`.

Formato geral: markdown estilo "superpowers" (skill `superpowers:writing-plans` e
`superpowers:brainstorming` do harness), com seções tipo "Objetivo", "Escopo", "Arquitetura",
"Componentes" etc. Ver `2026-07-19-claude-account-switcher-design.md` como exemplo de spec
completa.

## Chaves de UserDefaults conhecidas

Todas em `UserDefaults.standard`, sem suíte/domínio customizado:

| Chave | Definida em | Tipo | Default | Uso |
|---|---|---|---|---|
| `fiveHourAlertThreshold` | `FiveHourAlertThreshold.defaultsKey` (Domain/FiveHourAlert.swift) | Double | 80 | Limiar (%) de disparo do alerta de janela de 5h. `FiveHourAlertThreshold.resolve()` cai para o default se fora de `(0, 100]`. |
| `fiveHourAlertSoundName` | `FiveHourAlertSound.defaultsKey` (Domain/FiveHourAlert.swift) | String (raw value do enum) | `standard` | Som do alerta de 5h. Valores: `none, standard, basso, glass, hero, ping, sosumi`. |
| `relaunchDesktopOnSwitch` | `AppPreferences.relaunchDesktopOnSwitch` (App/MenuBarController.swift) | Bool | `false` | Se `true`, trocar de conta encerra e relança o app desktop nativo do Claude. |
| `weeklyCreditsAlertThreshold` | `WeeklyCreditsAlertThreshold.defaultsKey` (Domain/FiveHourAlert.swift) | Double | 30 | Limiar (%) de crédito disponível para disparar o alerta semanal, dentro da janela de 24h antes do reset. |
| `showUsageInMenuBar` | `AppPreferences.showUsageInMenuBar` (App/MenuBarController.swift) | Bool | `true` (registrado) | Se `true`, mostra o % da janela de 5h da conta ativa ao lado do ícone da barra de menu, colorido por faixa. |
| `analysisSelectedProfileIDs` | `AppPreferences.analysisSelectedProfileIDs` (App/MenuBarController.swift) | [String] (UUIDs) | ausente = todos | Perfis incluídos na análise de uso agregado. Ausência da chave = todos selecionados. Lógica pura em `AnalysisSelection` (Domain/UsageHistory.swift). |

## Coisas a confirmar de novo em sessões futuras (podem mudar)

- Estado do repo (`git status`, `git diff`) — pode haver trabalho em progresso não commitado.
- Se novas chaves de `UserDefaults` foram adicionadas.
- Se novos arquivos de spec/plan foram criados em `docs/superpowers/` sem ainda terem sido
  implementados.
