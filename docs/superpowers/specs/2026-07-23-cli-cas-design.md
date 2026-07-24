# Companheiro de CLI `cas` — design

- **Status:** entregue em 1.3.5 (issue #35, PR #37).
- **Data:** 2026-07-23.

## Objetivo

Permitir trocar de conta pelo terminal, sem abrir o menu, reusando o domínio existente
(`ProfileStore` / `ActivationService`).

## Escopo — comandos

- `cas list` — lista perfis (nome, email; marca a ativa com `*`).
- `cas current` — mostra o perfil ativo.
- `cas switch <nome|email>` — ativa o perfil por match **exato** de nome ou email. Não
  encontrado → erro + exit ≠ 0; ambíguo → erro pedindo desambiguação + exit ≠ 0.
- Comando desconhecido / sem argumento → mensagem de uso + exit ≠ 0.

O `switch` aplica o mesmo efeito do menu: `active-profile.json`, `launchctl setenv
CLAUDE_CONFIG_DIR` e o symlink do Paseo, via `ActivationService.activate(_, syncDesktopApp:
false)` — o app desktop **não** é relançado pelo CLI.

## Arquitetura / componentes

- `Package.swift` — novo `.executableTarget` **`cas`** em `Sources/CAS/`, dependendo só do
  Core. Resolve o mesmo diretório raiz gerenciado que o app.
- Lógica pura no Core (testável sem I/O):
  - `Domain/ProfileResolver.swift` — `resolve(_:query:)` → found / notFound / ambiguous.
  - `Domain/CASCommand.swift` — parsing/dispatch (`CASParser.parse`) com exit code embutido,
    sem chamar `exit()`.
- `Infrastructure/ShellIntegration.swift` — `install` ganhou parâmetro opcional `casBinary:`
  (default `nil`, preservando a assinatura existente) que expõe `cas` no bin gerenciado via
  symlink idempotente; `remove()` também o apaga. Paths reusam `singleQuoted`.
- `Scripts/build-app.sh` — empacota `cas` em `Contents/MacOS/` (universal via `lipo`); o
  `MenuBarController` instala o `cas` a partir do bundle no startup (irmão do executável,
  funcionando também em dev).

## Considerações

- **Reflexo na app:** a barra de menu relê o estado no refresh (60s) e nas ações; v1 → a UI
  reflete a troca no próximo refresh.
- **Corrida entre processos:** `setActive` é write único atômico (`atomicWrite`), baixo risco;
  app + `cas` podem escrever concorrente.
- **Segurança (OWASP A03/A05):** todo path escrito em shell é quotado/escapado via
  `singleQuoted` — path é tratado como input não-confiável.
- **i18n:** `AppStrings` vive no target App; o CLI usa um helper `t(pt, en)` local equivalente.
  Toda saída é bilíngue.

## Critérios de aceite / testes

- Resolução de perfil: exato por nome; por email; não encontrado → erro; nomes iguais →
  ambiguidade.
- `switch` com `FakeLaunchd` + `ProfileStore` temporário: `store.active()?.id == alvo` e o
  `FakeLaunchd` recebeu o `directory.path`.
- Instalação: `install` cria `cas` no bin gerenciado; `remove` o apaga.
- Parsing: `list`/`current`/`switch <x>` reconhecidos; desconhecido/sem argumento → uso +
  exit ≠ 0.
