# Sincronização do app nativo com o perfil ativo — Design

Extensão do design em `2026-07-19-claude-account-switcher-design.md`. Não substitui nada do que já existe para o CLI; adiciona uma segunda pasta por perfil e um novo componente que mantém o app nativo do Claude para Mac (`com.anthropic.claudefordesktop`, Electron) sincronizado com o perfil ativo escolhido no switcher.

## Motivo

O app nativo do Claude para Mac não lê `CLAUDE_CONFIG_DIR`: ele fixa seu próprio diretório de dados (`~/Library/Application Support/Claude`) independente do ambiente herdado. Confirmado por teste manual: mesmo forçando `CLAUDE_CONFIG_DIR` no processo que o lança, o app ignora o valor. A única forma de rodar contas diferentes nele é apontar `--user-data-dir` para pastas separadas na hora de abrir o processo — o app não expõe troca de conta dentro da mesma janela. Isso é uma limitação conhecida e pedida publicamente (issues #32783, #18435, #20549, #36821 em `anthropics/claude-code`), sem solução oficial da Anthropic até o momento.

## Escopo desta extensão

- Cada perfil gerenciado pelo switcher ganha automaticamente uma segunda pasta, `Profiles/<uuid>/desktop/`, usada como `--user-data-dir` do app nativo. Toda conta ganha as duas pastas (`config/` para o CLI e `desktop/` para o app nativo) — não é opcional por perfil.
- Toda troca de perfil (clique no menu ou atalho `⌥⌘C`) passa a, além do que já faz hoje para o CLI, encerrar a instância atual do app nativo (se estiver rodando) e reabri-lo apontando para o `desktop/` do perfil escolhido. O acoplamento é sempre automático — não há preferência para desativar.
- A migração inicial ganha um passo a mais: detectar se `~/Library/Application Support/Claude` tem sessão de fato (não um estado recém-instalado e vazio) e oferecer importá-la como `desktop/` de um perfil escolhido pelo usuário, copiando (nunca movendo) o conteúdo — mesmo padrão já usado para `~/.claude`/`~/.claude-work`.
- Login no app nativo, quando um perfil ainda não tem sessão salva em `desktop/`, acontece naturalmente: o app abre na tela de login normal dele, sem nenhum fluxo especial do switcher.

Não fazem parte desta extensão: rodar múltiplas instâncias do app nativo simultaneamente, qualquer preferência para desacoplar a troca do CLI da troca do app nativo, e qualquer alteração no comportamento já existente do CLI (que continua inalterado).

## Arquitetura

A troca do app nativo é sempre disparada depois que a troca do CLI já foi confirmada com sucesso pelo `ActivationService` existente (grava perfil ativo, `launchctl setenv`, com rollback total se algo falhar nessa parte — isso não muda). Só então o `ActivationService` chama o novo `DesktopAppActivator`. Uma falha nessa etapa **não desfaz** a troca do CLI, que já está consolidada; é reportada separadamente à interface como um aviso não bloqueante.

O `DesktopAppActivator` sempre encerra a instância atual do app nativo (se houver) e reabre uma nova apontando para o perfil escolhido — não tenta detectar se o app já está no perfil certo, evitando depender de formas frágeis de inspecionar os argumentos de outro processo em execução. Usa exclusivamente `NSRunningApplication`/`NSWorkspace` (APIs oficiais do AppKit); não usa AppleScript nem `osascript`, o que evita o prompt de permissão de Automação do macOS que apareceria na primeira troca.

## Componentes

### DesktopAppLocator

Encontra o bundle do app nativo via `NSWorkspace.urlForApplication(withBundleIdentifier: "com.anthropic.claudefordesktop")`. Se o app não estiver instalado, a sincronização é pulada silenciosamente (log informativo, sem erro visível) — a troca do CLI nunca fica bloqueada pela ausência do app nativo.

### ProfileDirectories (extensão)

Ganha um `desktopDirectory` computado como pasta irmã de `config/`: `Profiles/<uuid>/desktop/`. Não é um campo novo em `Profile`/`profiles.json` — é derivado do `directory` já existente, então não exige migração de schema nem versão nova do arquivo de metadados.

### DesktopAppActivator

Actor que serializa suas próprias operações (mesma disciplina de concorrência do resto do app: uma ativação por vez). Recebe um `DesktopAppClient` injetável (protocolo, para testes) com três operações:

- `runningInstance() -> RunningAppHandle?` — instância atual do app nativo, se houver.
- `terminate(_ handle: RunningAppHandle)` — pede encerramento normal (`NSRunningApplication.terminate()`); se não encerrar dentro de ~5s, usa `forceTerminate()`.
- `launch(bundleURL: URL, userDataDirectory: URL)` — abre nova instância via `NSWorkspace.shared.openApplication(at:configuration:)` com `configuration.arguments = ["--user-data-dir=\(userDataDirectory.path)"]`.

`sync(to profile: Profile)` executa, nessa ordem: localizar o bundle (pular se ausente) → encerrar instância atual se houver → lançar nova instância com o `desktopDirectory` do perfil. Retorna um resultado (`synced`, `skipped(reason)`, `failed(error)`) que o `ActivationService` repassa para a UI.

### ActivationService (extensão)

Depois de confirmar a troca do CLI com sucesso (comportamento atual, inalterado), chama `desktopActivator.sync(to: perfilAtualizado)` e agrega o resultado ao valor retornado, para que `MenuBarController` mostre uma notificação combinada: confirmação da troca de perfil e, se aplicável, aviso de que o app nativo não pôde ser reaberto.

### MigrationService (extensão)

Novo passo de detecção: verificar se `~/Library/Application Support/Claude` contém sessão real (não um estado vazio de instalação nova). Se sim, incluir na lista do que será importado, perguntar a qual perfil deve virar `desktop/` (padrão: o mesmo perfil escolhido para o `~/.claude` correspondente), copiar o conteúdo para `Profiles/<uuid>/desktop/`, validar, e só então oferecer arquivar a pasta original — seguindo os mesmos oito passos já descritos no design original, com a cópia do diretório do app nativo entrando no passo 3 (cópia) e a validação no passo 4.

## Tratamento de falhas

- App nativo não instalado: sincronização pulada, troca do CLI segue normalmente.
- Encerramento não responde a tempo (ex.: diálogo pendente): `forceTerminate()` após o timeout. Isso pode descartar um diálogo de login/2FA em andamento — risco aceito, já que o acoplamento automático foi escolhido explicitamente sabendo desse custo.
- Falha ao relançar (ex.: bundle movido/removido entre localizar e abrir): reportada como aviso separado; a troca do CLI já confirmada permanece válida, sem rollback.
- Primeira ativação de um perfil sem sessão salva em `desktop/`: app abre normalmente na tela de login dele; não há fluxo especial do switcher para isso.

## Estratégia de testes

### Testes unitários

- `DesktopAppActivator` com um `DesktopAppClient` falso injetado: cobre app ausente (pula sem erro), encerramento bem-sucedido seguido de relançamento, timeout de encerramento caindo para `forceTerminate()`, e falha ao relançar retornando `failed` sem afetar estado do CLI.
- `ActivationService`: confirma que `sync(to:)` só é chamado depois que a troca do CLI é bem-sucedida, e que uma falha no `sync` não desfaz o que já foi persistido no `ProfileStore`/`launchd`.
- `ProfileDirectories`: `desktopDirectory` corretamente derivado de `directory` para diferentes UUIDs.
- `MigrationService`: detecção de sessão real vs. instalação vazia em `~/Library/Application Support/Claude`, cópia para o perfil escolhido, usando diretório home temporário como os testes de migração existentes.

### Validação manual no Mac

Adiciona aos passos já existentes no design original:

- Trocar de perfil pelo menu e confirmar que o app nativo fecha e reabre já no `desktop/` do perfil escolhido.
- Trocar de perfil sem o app nativo estar instalado e confirmar que a troca do CLI não é afetada.
- Trocar de perfil pela primeira vez para um perfil sem sessão salva em `desktop/` e confirmar que o app abre na tela de login normal.
- Rodar a migração inicial com uma cópia da pasta real do app nativo e confirmar que ela é importada corretamente como `desktop/` do perfil certo.

## Critérios de aceite

1. Trocar de perfil no menu/atalho fecha a instância atual do app nativo (se houver) e reabre uma nova já apontando para o `desktop/` do perfil escolhido, sem exigir login manual se a sessão já existir naquela pasta.
2. Ausência do app nativo instalado nunca impede ou atrasa a troca de perfil do CLI.
3. Falha ao encerrar/reabrir o app nativo é reportada separadamente e não desfaz a troca do CLI já confirmada.
4. A migração inicial oferece importar a sessão atual do app nativo como `desktop/` de um perfil escolhido, sem apagar ou mover o diretório original antes de confirmação explícita.
5. Nenhuma permissão de Automação do macOS é solicitada por esta funcionalidade.
