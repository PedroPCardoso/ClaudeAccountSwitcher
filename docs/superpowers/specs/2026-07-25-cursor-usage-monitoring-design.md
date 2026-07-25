# Monitoramento de uso do Cursor — Design

## Objetivo

Expor no Claude Account Switcher as mesmas informações de uso que o app já mostra para o Claude Code, agora para a conta logada no Cursor IDE: custo do ciclo de faturamento, limite do plano, percentual usado, tokens por modelo (Claude, GPT, Gemini, Grok, Composer), data de reset do ciclo, histórico diário e alerta configurável de orçamento. Sem troca de contas (o Cursor não tem equivalente a `CLAUDE_CONFIG_DIR`).

## Escopo

- **Dentro:** leitura do token de sessão local, fetch periódico via API interna do Cursor, janelas "Uso do Cursor" e "Análise do Cursor", itens no menu, percentual opcional na barra de menu, alerta de orçamento do ciclo, preferências.
- **Fora:** troca de contas do Cursor; Admin API Enterprise (`api.cursor.com`); renovação automática do JWT (sinaliza "reautentique no Cursor"); estimativa local de custo via tabela de preços (a API já devolve `totalCents`).

## Diferenças vs Claude Code

| Claude Code | Cursor |
|---|---|
| Cotas OAuth (`five_hour`, `seven_day`) | Ciclo mensal (`planUsage.limit` / `totalSpend`) |
| Tokens em `.jsonl` locais | Tokens só via API (`GetAggregatedUsageEvents`) |
| Múltiplos perfis (`CLAUDE_CONFIG_DIR`) | Sessão única (`state.vscdb`) |
| Alerta de 5h + créditos semanais | Alerta de orçamento do ciclo (mensal) |
| Custo estimado (`ModelPricing`) | Custo real da API (`totalCents` / `spendCents`) |

## Fonte de dados

### Credenciais locais

`~/Library/Application Support/Cursor/User/globalStorage/state.vscdb` → tabela `ItemTable`:

| Chave | Uso |
|---|---|
| `cursorAuth/accessToken` | JWT Bearer para a API |
| `cursorAuth/cachedEmail` | E-mail exibido na UI |
| `cursorAuth/stripeMembershipType` | Plano (`pro`, etc.) |
| `glass.lastSignedInAuthId` | workosId (opcional) |

Leitura read-only (`SQLITE_OPEN_READONLY` + `immutable=1`); fallback copia `state.vscdb`+`-wal`+`-shm` para temp se o WAL estiver locked. Token cacheado em memória; re-lê só após 401. Se o `exp` do JWT estiver no passado → `tokenExpired` (não tenta renovar).

### API (Connect-RPC)

```
POST https://api2.cursor.sh/aiserver.v1.DashboardService/<Method>
Authorization: Bearer <accessToken>
Content-Type: application/json
connect-protocol-version: 1
```

1. **`GetCurrentPeriodUsage`** — limite, gasto, início/fim do ciclo.
2. **`GetAggregatedUsageEvents`** — tokens + custo por `modelIntent` no intervalo do ciclo.
3. **`GetDailySpendByCategory`** — histórico diário (`groupBy: 1` = MODEL).

Ordem: (1) primeiro; (2) e (3) usam `billingCycleStart`/`billingCycleEnd`. Degradação graciosa: se (2) ou (3) falharem, o snapshot ainda traz `planUsage`.

### Decisão: espelhar a página "Included in Pro" (duas barras)

A UI do Cursor em Settings → Usage, seção **Included in Pro**, mostra **apenas** duas barras. Não mostra o percentual de `totalSpend / limit`.

| O que o site mostra | Campo da API | Amostra ao vivo (jul/2026) |
|---|---|---|
| "Cursor Models · N% used" | **`autoPercentUsed`** | 0,68 → **1%** |
| "Other Models · N% used" | **`apiPercentUsed`** | 19,42 → **19%** |

Armadilhas — existem na resposta da API, mas **não** devem alimentar as barras do app:

| Campo / cálculo | Valor típico | Por que engana |
|---|---|---|
| `totalSpend / limit` (= `displayMessage`) | ~54% | Mensagem da API, **ausente** na seção Included in Pro |
| `totalPercentUsed` (= `autoModelSelectedDisplayMessage`) | ~3% | Casa com a mensagem "included total usage", **não** com a barra Cursor Models do site |

`CursorPlanUsage` guarda as duas barras (`cursorModelsPercent` / `otherModelsPercent`), o gasto em centavos, e `dashboardUsedPercent` (= max das duas) para badge da barra de menu e alerta de orçamento. `usedPercent` (spend/limit) continua disponível, mas a UI não o apresenta como cota incluída.

## Componentes

### Domain

- `CursorUsage.swift` — `CursorPlanUsage`, `CursorModelUsage`, `CursorModelFamily`, `CursorDailySpend`, `CursorUsageSnapshot`.
- `CursorAlert.swift` — `CursorBudgetAlertTracker` (1× por `billingCycleEnd`), `CursorBudgetAlertThreshold` (default 80).
- Extensão de `StatusBarUsage` — `StatusBarUsageSource` (`off|claude|cursor|both`) com migração de `showUsageInMenuBar`.

### Infrastructure

- `CursorCredentialStore` — lê SQLite, cacheia credenciais.
- `CursorUsageService` — 3 RPCs, reusa `UsageTransport`/`UsageRetryPolicy`.
- `CursorUsageStore` — `cursor-usage.json` atômico no root do app.

### App

- `CursorUsageView` / `CursorUsageWindowController`
- `CursorAnalysisView` / `CursorAnalysisWindowController`
- Itens de menu + refresh no ciclo de 60s + alerta em `MenuBarController`
- Seção Cursor em `PreferencesView`

## Chaves de UserDefaults

| Chave | Tipo | Default | Uso |
|---|---|---|---|
| `cursorMonitoringEnabled` | Bool | `true` | Liga/desliga o monitoramento |
| `cursorBudgetAlertThreshold` | Double | 80 | Limiar (%) do alerta de orçamento |
| `statusBarUsageSource` | String | `off` | `off\|claude\|cursor\|both`; migra de `showUsageInMenuBar` |

Som do alerta reusa `fiveHourAlertSoundName`.

## Riscos

- API interna não documentada — isolada num serviço com degradação graciosa; falha do Cursor nunca quebra o fluxo Claude.
- SQLite com WAL — read-only + cópia de fallback; token cacheado reduz I/O.
