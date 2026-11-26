# Cópia local das sessões (session archive) — design

Data: 2026-11-26 · Status: implementado (sem UI no app além do toggle; interface pelo `cas`).

## Objetivo

Guardar num banco de dados local uma cópia de **todas as sessões do Claude Code de todos os
perfis**, atualizada **a cada 5 minutos**, para três usos, nesta ordem de prioridade:

1. **Backup** — o CLI apaga transcrições com mais de `cleanupPeriodDays` (30 dias por padrão; na
   máquina do autor só restavam 5 sessões com mais de 25 dias). Uma sessão perdida ou corrompida
   precisa poder voltar ao disco, byte a byte, para `claude --resume`.
2. **Busca** — achar uma conversa por texto em qualquer perfil.
3. **Análise** — SQL livre sobre mensagens, modelos, tokens, projetos e datas.

## Escopo

- Entra: todo `*.jsonl` em `<perfil>/projects/` de cada perfil gerenciado, incluindo transcrições
  de subagente (`projects/<slug>/<sessão>/subagents/*.jsonl`, ~75% dos arquivos).
- Fora (por enquanto): janela de busca no app, `file-history/`, `~/.claude` não importado como
  perfil, política de retenção (o banco só cresce).

## Decisões

- **Um SQLite** (`~/Library/Application Support/Claude Account Switcher/sessions.db`, WAL), usando
  a libsqlite3 do sistema (FTS5 incluso). Alternativas descartadas: pasta espelho + índice (duas
  coisas para sincronizar, ~2× o espaço) e linhas cruas sem compressão (>3 GB).
- **Bytes crus em blocos de ~1 MB comprimidos com lzfse.** Medido em 300 MB reais: blocos de 1 MB
  comprimem ~5×; linha a linha só ~2,2× (e a tabela `WITHOUT ROWID` com blobs grandes quase dobrava
  o arquivo: 1,5 GB). Resultado final: 1,7 GB de `.jsonl` → 419 MB de banco.
- **Busca só no texto humano**: blocos `text` de usuário e assistente. `tool_result`, `tool_use`,
  `thinking`, anexos e linhas `isMeta` ficam fora do FTS (são o grosso dos bytes e poluem resultados),
  mas continuam no backup.
- **Nada é apagado nem sobrescrito.** Arquivo reescrito/encolhido → nova `revision` (a anterior
  ganha `superseded_at`); arquivo que sumiu do disco → `deleted_at`.

## Esquema

| Tabela | Conteúdo |
|---|---|
| `profiles` | id, nome, email, diretório (atualizado a cada sync). |
| `files` | uma linha por (perfil, caminho relativo, revisão): slug, `session_id`, `parent_session_id` (subagente), `head` (primeiros 512 bytes), `byte_offset`, `line_count`, `size`, `mtime`, `superseded_at`, `deleted_at`. |
| `chunks` | `file_id`, `start_offset`, `end_offset`, `codec` (0 cru, 1 lzfse), `data`. Concatenar por `start_offset` = arquivo exato. |
| `messages` | uma linha por mensagem `user`/`assistant`: uuid, timestamp, cwd, git_branch, is_sidechain, model, message_id, request_id, tokens (input/output/cache read/cache creation), text. |
| `messages_fts` | FTS5 external-content sobre `messages.text` (`unicode61 remove_diacritics 2`). |
| `v_messages`, `v_sessions` | visões da revisão atual, com nome do perfil e `resume_id`. |

Observação para análise: o CLI grava várias linhas por resposta em streaming com o mesmo
`message_id:request_id` — deduplicar antes de somar tokens.

## Fluxo do sync

Para cada perfil → para cada `.jsonl`:
1. Atalho: `size`, `mtime` e `byte_offset == size` iguais ao banco → pula sem transação.
2. `BEGIN IMMEDIATE`; relê o estado do arquivo (outro processo pode ter acabado de copiar).
3. Se o início do arquivo ainda começa com o `head` salvo e `size >= byte_offset` → continua do
   offset; senão cria nova revisão a partir do byte 0.
4. `JSONLScanner.scan` (marcador vazio = todas as linhas) entrega as linhas completas; última linha
   sem `\n` só entra se for JSON completo (escrita em andamento fica para o próximo ciclo).
   Bytes vão para o bloco corrente (flush a cada ~1 MB); linhas `user`/`assistant` viram `messages`.
5. Grava `head`, offset, tamanho e mtime lidos antes do scan; `COMMIT`.
6. Arquivos conhecidos que não apareceram → `deleted_at` (só se a pasta `projects/` existe).

Medido (1.826 arquivos, 448 mil linhas): carga inicial 132 s, 41 MB de RAM; ciclo seguinte 1,5 s.

## Integração

- App: `MenuBarController.archiveSessions()` roda ao abrir, ao acordar a tela e a cada
  `SessionArchiveSettings.interval` (300 s) num `Task.detached(priority: .background)`; pausa com a
  tela apagada junto com o refresh. Toggle nas Preferências (`sessionArchiveEnabled`, padrão ligado).
- CLI `cas`:
  - `cas sync` — roda o sync agora e imprime o resumo.
  - `cas search <texto> [--limit N]` — FTS (cada palavra obrigatória, entre aspas), mais recentes
    primeiro, com perfil, id para `--resume`, cwd e trecho destacado.
  - `cas restore <id|prefixo> [--profile <nome|email>]` — recria a sessão e os subagentes dela
    (revisão mais recente) no perfil dono (ou no indicado); nunca sobrescreve arquivo existente;
    imprime `cd <cwd> && claude --resume <id>`.
  - `cas db [sql]` — `exec /usr/bin/sqlite3 -readonly sessions.db`.

## Testes

`ProfileStoreTests`: parser de caminho/linha/consulta FTS; sync incremental de ponta a ponta
(primeira carga, nada muda, append com linha incompleta, busca, subagente, restore byte a byte,
não sobrescreve, reescrita → revisão, última linha sem `\n` com espaços, arquivo apagado marcado uma
vez); parsing dos novos comandos do `cas`. Verificado também em dados reais: 43 arquivos
reconstruídos idênticos ao disco (até 21 MB).

## Próximos passos possíveis

- Janela "Histórico de sessões…" no app (busca + "Restaurar e retomar").
- Política de retenção/compactação (`VACUUM`) se o banco crescer demais.
