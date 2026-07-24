# Análise de uso agregado + recomendação Max vs Pro — design

- **Status:** Parte 1 entregue em 1.3.5 (issue #34, PR #38). Parte 2 (saturação persistida)
  em aberto na issue #39.
- **Data:** 2026-07-23.

## Objetivo

Ajudar a decidir o melhor arranjo de planos — um **Max** vs manter **2–3 Pro** — mostrando o
consumo de tokens somado das contas escolhidas ao longo do tempo e uma recomendação.

## Escopo (Parte 1)

1. **Seleção de contas** na métrica: o usuário escolhe quais perfis entram na agregação e na
   recomendação. Seleção persistida e refletida em tempo real no gráfico e no veredito.
2. **Série temporal diária agregada** de tokens, somando apenas as contas selecionadas,
   derivada dos `.jsonl` das sessões (bucket por dia a partir do timestamp de cada linha
   `assistant`).
3. **Gráfico** numa janela "Análise": tokens por dia com breakdown por conta (empilhado) +
   total, restrito à seleção (Swift Charts).
4. **Heurística de recomendação** sobre o conjunto selecionado: `singleMaxLikelyEnough` vs
   `multipleProJustified` vs `inconclusive`, a partir do volume agregado. **Sem preço/limite
   hardcoded.**

## Seleção de contas

- Default: **todas** as contas entram.
- UI: toggle por perfil na seção "Análise" (nome + email + cor). Alternar recomputa série +
  recomendação.
- Persistência: `AppPreferences.analysisSelectedProfileIDs` (`[String]` de UUIDs em
  `UserDefaults`). Ausência da chave = todas selecionadas. Lógica pura em `AnalysisSelection`.
- Robustez: IDs de perfis removidos são ignorados; perfil novo entra selecionado por default
  no primeiro uso (após customizar a seleção, um perfil criado depois começa desmarcado — bate
  com a semântica de "subconjunto salvo = só esses").
- Estado vazio: nenhuma conta selecionada → gráfico vazio + recomendação `inconclusive`.

## Arquitetura / componentes

- `Core/Domain/UsageHistory.swift` — `DailyTokenUsage`, `PlanRecommendation` +
  `PlanRecommendation.evaluate`, e `AnalysisSelection` (lógica pura de seleção, separada de
  `UserDefaults`).
- `Core/Infrastructure/UsageHistoryService.swift` — parseia os `.jsonl` de sessão em buckets
  diários por perfil. Timestamp: campo `timestamp` (ISO8601 fracionário + Z) no nível do
  objeto; tokens em `message.usage` (`input_tokens`/`output_tokens`/`cache_read_input_tokens`/
  `cache_creation_input_tokens`). Agrega apenas os perfis recebidos (a seleção é aplicada pelo
  caller). Cache por `(mtime, size)` espelhando `TokenUsageCache`.
- App: `AnalysisView.swift` (Swift Charts, barras empilhadas, legenda/toggles por conta, card
  de veredito, estados vazios) + `AnalysisWindowController.swift`, ligados ao
  `MenuBarController` com novo item de menu e hook de refresh.

## Fora de escopo (Parte 2 — issue #39)

- Histórico persistido de **saturação** das janelas 5h/semanal (`SnapshotHistoryStore`). A
  heurística da Parte 1 usa apenas a série de tokens, porque a API expõe só `utilization`
  instantâneo.

## Critérios de aceite / testes

- Bucketing: `.jsonl` com timestamps em D1/D2/D3 e dois perfis → 3 buckets, `perProfile` e
  `total` corretos.
- Seleção: só 1 dos 2 perfis → série ignora o outro; lista vazia → série vazia. Persistência
  pura: sem chave → todas; subconjunto salvo → só esses; ID inexistente → ignorado.
- Robustez: linha sem `timestamp`/não-`assistant` puladas; arquivo vazio → sem bucket.
- Cache: arquivo inalterado (mtime+size) não reprocessa (mtime fixo p/ determinismo).
- Heurística: séries fabricadas → `singleMaxLikelyEnough`, `multipleProJustified`,
  `inconclusive` (inclui seleção vazia).
