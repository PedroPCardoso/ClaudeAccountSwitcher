# Uso da conta ativa na barra de menu — design

- **Status:** entregue em 1.3.5 (issue #33, PR #36).
- **Data:** 2026-07-23.

## Objetivo

Mostrar o percentual usado da **janela de 5h da conta ativa** ao lado do ícone do
`NSStatusItem`, com cor por faixa, para leitura imediata sem abrir o menu.

## Escopo

- Título curto ao lado do ícone com o `%` usado da 5h da conta ativa (ex.: `72%`).
- Cor por faixa, com os **mesmos limiares do `UsageView`**: verde `<70`, laranja `70–89`,
  vermelho `≥90`.
- Atualiza junto do refresh existente (timer de 60s, refresh manual, troca de conta) e
  reflete a mudança do toggle imediatamente.
- Sem conta ativa, sem dados de uso, ou snapshot sem cota de 5h → só o ícone.
- Preferência para ligar/desligar (`AppPreferences.showUsageInMenuBar`, default **ligado**).

## Arquitetura / componentes

- `Sources/ClaudeAccountSwitcherCore/Domain/UsageTier.swift` — enum puro
  `UsageTier { ok, warning, critical }` com `forPercent(_:)` aplicando os limiares. Vive no
  Core para ser testável pelo runner (o test target depende só do Core).
- `Sources/ClaudeAccountSwitcherCore/Domain/StatusBarUsage.swift` — `label(activeUsage:)`
  retorna `"72%"` (arredondado) casando a cota pela **identidade estável `QuotaKind.fiveHour`**,
  nunca pelo label localizado, ou `nil`.
- `MenuBarController.swift` — `updateStatusItemUsage()` chamado no rebuild/refresh e ao mudar
  o toggle; compõe `statusItem.button` (imagem + `attributedTitle`) e mapeia
  `UsageTier → NSColor` na camada de view.
- `PreferencesView.swift` — toggle `@AppStorage` para `showUsageInMenuBar`.

## Decisões

- A lógica pura (`UsageTier`, `label`) fica no Core; o mapeamento de cor fica na view. Isso
  desacopla a identidade da cota do seu rótulo traduzido — traduzir o label não pode quebrar
  a leitura da 5h.

## Critérios de aceite / testes

- `UsageTier.forPercent`: `69→ok`, `70→warning`, `89→warning`, `90→critical`, `100→critical`,
  `0→ok`.
- `StatusBarUsage.label`: cota `.fiveHour` em `71.6 → "72%"`; `nil` de usage → `nil`; snapshot
  só com `.sevenDay` → `nil`.
- Toggle desligado mantém só o ícone; ligado volta a exibir o `%`.
