# Troca de perfis: perda e corrupção de sessões — análise e endurecimento

Data: 2026-10-17

## Objetivo

Auditar o caminho completo de uma troca de perfil (menu, `cas switch`, remoção com reativação)
atrás de cenários em que o usuário perde acesso a uma sessão do Claude Code, fica com estado
inconsistente ou tem arquivos corrompidos; cobrir cada cenário com teste e corrigir o que é bug.

## O que uma "sessão" é, e onde mora

Com `CLAUDE_CONFIG_DIR=<perfil>/config`, o Claude Code grava **tudo** dentro do perfil:

| Artefato | Caminho | Observação |
|---|---|---|
| Transcripts/conversas | `projects/<cwd-slug>/<uuid>.jsonl` | base do `--resume`/`--continue` |
| Estado global do CLI | `.claude.json` | MCP servers de usuário, projetos confiáveis, onboarding, conta OAuth |
| Marcador por processo | `sessions/<pid>.json` (+ `.key`) | pid, sessionId, cwd, status; nem sempre removido ao sair |
| Histórico, settings, plugins | `history.jsonl`, `settings.json`, `plugins/` | |
| Credenciais OAuth | Keychain `Claude Code-credentials-<sha256(dir)[0:8]>` | isoladas por perfil (confirmado no Keychain local) |

A troca de perfil **não toca** nesses arquivos: ela só reescreve `active-profile.json`, o
`launchctl setenv` e o symlink do Paseo. Processos já abertos mantêm o `CLAUDE_CONFIG_DIR`
herdado e continuam gravando no perfil antigo. Logo, "perdi minha sessão após trocar" é quase
sempre: a conversa está no outro perfil (volte para ele e use `--resume`), não corrupção.

## Cenários analisados

### A. Corrupção/perda de estado do próprio switcher

| # | Cenário | Resultado | Ação |
|---|---|---|---|
| A1 | Lost update: menu montado em T0 com snapshot do perfil; refresh (60 s, CLI+rede por perfil) grava uso/e-mail em T0+30; rename em T0+35; clique em T0+40 chama `activate(snapshotVelho)` que fazia `store.save(struct inteiro)` | **Bug confirmado**: rename e uso revertidos. O mesmo acontecia no refresh (`save(updated)` derivado da lista capturada no início do ciclo) e no relogin | Corrigido: `ProfileStore.update(id:_:)` faz read-modify-write dentro da fila; `ActivationService`, refresh, relogin e rename usam só os campos que lhes pertencem. Testes `testActivationPreservesConcurrentEdits`, `testStoreUpdateMergesConcurrentWriters` (100 escritores concorrentes, zero perdas) |
| A2 | Trocas rápidas/concorrentes enquanto o launcher `bin/claude` é invocado | OK: `atomicWrite` (tmp + rename) garante que o launcher nunca vê JSON parcial | Teste de estresse `testLauncherSurvivesConcurrentSwitches` (60 trocas × 40 invocações) |
| A3 | `active-profile.json` truncado/corrompido, apontando para diretório apagado, ou ausente | OK (fail-closed): launcher sai com 78 e **não** cai para `~/.claude` (cairia na conta errada em silêncio); `cas-env.sh` não exporta nada; `store.active()` lança `corruptState` | Teste `testLauncherFailsClosedOnCorruptState`. Pendente: a UI usa `try? store.active()` e mostra "nenhum ativo" sem explicar — ver melhorias |
| A4 | Restos de `*.tmp-<uuid>` de um `atomicWrite` interrompido; lixo não-UUID em `Profiles/` | OK: ignorados | Teste `testStoreIgnoresStaleTemporaryFiles` |
| A5 | `active-profile.json` com permissão 644 no disco real (gravado por versão antiga) e nunca corrigido | **Bug confirmado**: `replaceItemAt` preserva metadados do arquivo antigo | Corrigido com `.usingNewMetadataOnly`; mesmo teste |
| A6 | Rollback da ativação (launchd/symlink falham) | OK, já coberto | — |

### B. Perda de dados do Claude Code causada pelo switcher

| # | Cenário | Resultado | Ação |
|---|---|---|---|
| B1 | Importar `~/.claude` (migração inicial) sem o `~/.claude.json` global, que vive **fora** da pasta | **Bug confirmado**: perfil importado perdia MCP servers de usuário, projetos confiáveis e onboarding | Corrigido: `MigrationPlan.globalConfig`; copiado para `<perfil>/.claude.json` quando a pasta é `~/.claude` e não traz o próprio. Teste `testMigrationImportsGlobalConfig` |
| B2 | Remover um perfil com sessões `claude` abertas nele (`store.remove` apaga o diretório) | Risco real: processos perdem o diretório, falham ao gravar ou recriam arquivos soltos | Mitigado: `SessionActivity.runningSessions(in:)` lê `sessions/<pid>.json` e confirma com `kill(pid, 0)`; o alerta de remoção lista os pids e pede para fechar antes. Teste `testSessionActivityDetectsLiveProcesses` |
| B3 | Sync do app desktop: `terminate()` e, após 5 s, `forceTerminate()` | Risco: matar o Electron no meio de escrita em `Cookies` (SQLite) / `Local Storage/leveldb` pode corromper a sessão do app nativo | Não alterado (comportamento opt-in). Ver melhorias |
| B4 | Copiar a sessão default do app desktop (`copyDefaultDesktopSessionIfAvailable`) com o app aberto | Risco: cópia de LevelDB em escrita gera cópia inconsistente; `hasRealDesktopSession` passa a ver a cópia parcial como válida e nunca mais oferece recopiar | Não alterado. Ver melhorias |
| B5 | Lixo `.claude.json.tmp.<pid>.<hash>` nos perfis (52 arquivos no disco real, vários com 0 bytes) | É o próprio CLI interrompido no write+rename; inofensivo, o `.claude.json` final estava íntegro | Nenhuma ação; cabe uma limpeza opcional |
| B6 | Keychain: `remove()` não apaga `Claude Code-credentials-<hash>` | Vazamento de token de perfil removido (5 serviços no Keychain local para 2 perfis vivos) | Não alterado (apagar item do Keychain é destrutivo e pede confirmação). Ver melhorias |

### C. Shell e ambiente

| # | Cenário | Resultado |
|---|---|---|
| C1 | `cas-env.sh` exporta `CLAUDE_CONFIG_DIR` e reexporta a cada prompt via mtime | OK; confirmado em zsh interativo real. Um comando longo já iniciado mantém o valor antigo (esperado) |
| C2 | Launcher sombreia `claude` no PATH e **ignora** o `CLAUDE_CONFIG_DIR` do shell em favor do estado | Coerente: launcher e env script leem a mesma fonte; se divergirem, o launcher vence |
| C3 | Apps GUI (VS Code, Cursor, Paseo) resolvem o env uma vez no spawn | Documentado; Paseo tem o symlink estável |

## Decisões

- **`save(_:)` fica para criação; mutações usam `update(id:)`.** Convenção para novas features:
  nunca gravar um `Profile` inteiro a partir de um snapshot que atravessou await, I/O ou UI.
- **Fail-closed no launcher é desejado.** Trocar silenciosamente para `~/.claude` seria pior do
  que falhar: colocaria o usuário na conta errada.
- **Detectar sessões vivas é heurística, não bloqueio.** O marcador `sessions/<pid>.json` é
  interno do CLI e pode mudar; por isso só avisa, não impede.

## Melhorias implementadas na sequência (mesmo dia)

1. **Reparo guiado do estado ativo.** `ActiveStateRepair.suggestion` (Domain, puro) escolhe o
   perfil cujo diretório coincide com `launchctl getenv CLAUDE_CONFIG_DIR`
   (`LaunchdEnvironmentClient.get()`), senão o de `lastUsedAt` mais recente. O menu mostra
   "⚠️ Arquivo de estado ativo ilegível — reparar…" (ou "aponta para um perfil que não existe
   mais") e a ativação tolera o arquivo corrompido para poder sobrescrevê-lo.
2. **Desktop sync sem `forceTerminate` por padrão.** `SystemDesktopAppClient` só mata à força
   quando a política permite (preferência `forceQuitDesktopOnSwitch`, default `false`);
   `DesktopAppActivator` espera 20 s (era 5) e devolve `.failed` com instrução para fechar
   manualmente.
3. **Cópia da sessão desktop só com o app fechado.** `copyDefaultDesktopSessionIfAvailable`
   recebe `isDesktopRunning` e lança `MigrationError.desktopAppRunning`; a cópia é feita em
   `.desktop.tmp-<uuid>` e renomeada no fim, então uma cópia interrompida nunca passa por
   sessão válida.
4. **Keychain.** `KeychainCredentials` centraliza o nome do serviço
   (`Claude Code-credentials-<sha256(dir)[0:8]>`, reutilizado pelo `ClaudeUsageService`), apaga o
   item ao remover um perfil (o alerta de remoção já diz isso) e lista serviços órfãos a partir de
   `security dump-keychain` (só atributos).
5. **Importação manual via `MigrationService.importDirectory`**, com as mesmas regras da
   migração (sem symlinks, traz `~/.claude.json` quando a pasta é `~/.claude`) e sem deixar
   diretório gerenciado órfão se a cópia falhar.
6. **"Onde está minha conversa?"** `ConversationLocator.find` procura por prefixo do sessionId,
   slug da pasta (`/` e `.` → `-`) ou `cwd` das primeiras linhas do `.jsonl` em todos os perfis,
   ordena por mtime e monta `cas switch '<perfil>' && cd '<cwd>' && claude --resume <id>`. Item
   de menu com busca e botão para copiar o comando.
7. **Manutenção.** `MaintenanceService.scan/apply`: poda `Backups/shell-*` mantendo os 5 mais
   novos por arquivo, apaga `.claude.json.tmp.*` com mais de 7 dias, remove diretórios órfãos de
   `Profiles/` e credenciais órfãs do Keychain. `scan` só lista; `apply` apaga exatamente o
   listado, após confirmação no menu "Manutenção…".

## Bug confirmado em 2026-10-23: `--resume` via Paseo falha após trocar de perfil

Sintoma: "[System Error] No conversation found with session ID: 882affa8…" no Paseo e, em seguida,
a conversa "perde o histórico". Evidência (`~/.paseo/daemon.log`): 4 falhas (21, 22 e 23/10),
todas no provider `claude` (o que segue o symlink do perfil ativo); a sessão existia no perfil
"Agi", mas "Claude work" estava ativo das 15:44 às 17:26; 9 s depois de voltar para "Agi" o
Paseo relançou e funcionou. Após a falha o Paseo loga "Claude resumed session no longer exists;
invalidating persisted session" e a próxima mensagem abre conversa nova — daí o histórico sumir.

Causa raiz: transcripts nunca mudam de perfil, mas o Paseo (e o terminal) retomavam sempre com
o perfil **ativo**. Correção:
- O launcher `bin/claude` lê `--resume <id>`/`--resume=<id>`/`-r <id>`; se o id não existe no
  perfil ativo e existe em exatamente um outro perfil gerenciado (`Profiles/*/config/projects/*/`),
  usa esse perfil e avisa no stderr. Ids inválidos, ausentes, duplicados ou `--continue` mantêm o
  ativo. Teste `testLauncherResumeFollowsConversationProfile`.
- `PaseoIntegration.integrate()` passa a gravar `providers.claude.command = [launcher]` além do
  env; `isConfigured()` exige os dois, então instalações antigas mostram "Integrar com Paseo…"
  de novo. Teste `testPaseoIntegrateSetsCommandToLauncher`. O daemon do Paseo precisa reiniciar
  uma vez para passar a usar o `command`.

## Testes

Quatorze testes novos em `ProfileStoreTests` (100 no total). Primeira leva (sete): lost update na ativação, merge de 100
escritores, estresse do launcher sob trocas concorrentes, fail-closed em estado corrompido/
pendente/ausente para launcher e env script, resíduos temporários + permissões 600, importação do
`~/.claude.json` global e detector de sessões vivas. Verificado em vermelho (3 falhas sem as
correções) e em verde. Segunda leva (sete): sugestão de reparo, parsing/órfãos do Keychain,
cópia desktop recusada com app aberto + staging atômico, `importDirectory` (global config,
symlink, sem órfão), localizador de conversas (id, slug, cwd, comando `--resume`), scan/apply
da manutenção e timeout de encerramento do desktop sem force quit.

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
