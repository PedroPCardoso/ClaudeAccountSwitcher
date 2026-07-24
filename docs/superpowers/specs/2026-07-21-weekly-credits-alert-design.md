# Alerta de créditos semanais disponíveis — Design

## Objetivo

Avisar o usuário via notificação nativa do macOS (reusando o som configurável do alerta de 5h) quando **qualquer conta** estiver a até 24h de renovar a janela semanal do Claude e ainda tiver pelo menos um percentual configurável (padrão 30%) de créditos disponíveis — sinalizando que vale usar essa conta com mais frequência antes da renovação, em vez de deixar créditos sobrando.

Este alerta é o inverso do alerta de 5h (`docs/superpowers/specs/2026-07-20-five-hour-usage-alert-design.md`): aquele avisa sobre escassez na conta ativa; este avisa sobre sobra, em todas as contas.

## Escopo

- Cobre apenas a cota `"Semanal"` (7 dias, geral), retornada pelo `ClaudeUsageService`. Cotas por modelo (`"Semanal <Modelo>"`) e a janela de 5h ficam fora do escopo.
- Avalia **todas as contas cadastradas**, não apenas a ativa — a ideia é destacar créditos parados em qualquer conta.
- Condição de disparo por perfil: `resetAt` da cota `"Semanal"` está entre agora e +24h **E** `(100 - usedPercent) >= limiar` (créditos disponíveis).
- O limiar é configurável em Preferências (padrão 30%), sem toggle de liga/desliga separado — mesmo padrão do alerta de 5h.
- O som da notificação reusa a preferência já existente `fiveHourAlertSoundName` (Nenhum, Padrão, Basso, Glass, Hero, Ping, Sosumi). Não há preferência de som própria para este alerta.
- Se mais de uma conta se qualificar no mesmo ciclo de checagem, as contas são agrupadas em **uma única notificação combinada**, não uma por conta.
- Não cobre persistência do estado "já alertado" entre reinícios do app — aceitável perder o estado e potencialmente alertar de novo logo após um restart.
- Não cobre troca automática de conta — o app apenas sinaliza; a troca continua manual (menu ou `⌥⌘C`).

## Onde a lógica entra

O mesmo ciclo de atualização de uso já existe: `MenuBarController.refreshProfileMetadata()` busca `ClaudeUsageSnapshot` de cada perfil via `ClaudeUsageService.fetch(profileDirectory:)` dentro de um `Task.detached`, a cada 60s. A checagem deste alerta entra no mesmo loop `for profile in profiles`, mas — diferente do alerta de 5h, que só olha o perfil ativo — avalia **todo perfil** cujo snapshot tenha uma cota `"Semanal"`. Os resultados são acumulados numa lista local ao `Task.detached` e, ao final do loop, uma única notificação combinada é disparada em `MainActor.run` se a lista não estiver vazia.

## Componentes alterados

### `FiveHourAlert.swift`

Ganha uma nova struct de rastreamento e um novo enum de limiar, ao lado dos já existentes para o alerta de 5h:

```swift
/// Tracks, per profile, which `resetAt` of the weekly window has already
/// fired a "credits available" alert, so each renewal alerts at most once.
public struct WeeklyCreditsAlertTracker: Sendable {
    private var alertedResetAt: [UUID: Date] = [:]
    public init() {}

    @discardableResult
    public mutating func evaluate(profileID: UUID, usedPercent: Double, resetAt: Date?, availableThreshold: Double, now: Date = .now) -> Bool {
        guard let resetAt else { return false }
        let hoursUntilReset = resetAt.timeIntervalSince(now) / 3600
        guard hoursUntilReset > 0, hoursUntilReset <= 24 else { alertedResetAt[profileID] = nil; return false }
        guard (100 - usedPercent) >= availableThreshold else { return false }
        guard alertedResetAt[profileID] != resetAt else { return false }
        alertedResetAt[profileID] = resetAt
        return true
    }
}

public enum WeeklyCreditsAlertThreshold {
    public static let defaultsKey = "weeklyCreditsAlertThreshold"
    public static let `default`: Double = 30

    public static func resolve(_ raw: Double) -> Double {
        (raw > 0 && raw <= 100) ? raw : `default`
    }
}
```

Notas sobre `evaluate`:
- Fora da janela de 24h (incluindo `resetAt` já passado, o que não deveria ocorrer em uso normal mas é tratado defensivamente) limpa o estado alertado daquele perfil, rearmando para a próxima renovação.
- Créditos disponíveis abaixo do limiar simplesmente não dispara, sem alterar o estado — se depois subir (ex.: limiar mudou em Preferências) pode disparar dentro da mesma janela de 24h.
- Um segundo `resetAt` idêntico ao já alertado não dispara de novo (idempotente por renovação).

### `MenuBarController`

- Nova propriedade `private var weeklyCreditsAlert = WeeklyCreditsAlertTracker()`.
- Dentro de `refreshProfileMetadata()`, após o snapshot de **cada** perfil ser obtido e salvo (não só o ativo), chama uma nova função `checkWeeklyCreditsAlert(profile:snapshot:) -> WeeklyCreditsAlertHit?` que:
  - Procura em `snapshot.quotas` a entrada com `key == "Semanal"`.
  - Lê o limiar via `UserDefaults.standard.double(forKey: WeeklyCreditsAlertThreshold.defaultsKey)`, com fallback via `WeeklyCreditsAlertThreshold.resolve`.
  - Chama `weeklyCreditsAlert.evaluate(profileID: profile.id, usedPercent: quota.usedPercent, resetAt: quota.resetAt, availableThreshold: threshold)` (na `MainActor`, já que o tracker vive no controller).
  - Se disparar, retorna um hit com `(profileName, availablePercent, resetAt)`; senão retorna `nil`.
- Os hits do ciclo são acumulados numa lista local (`[WeeklyCreditsAlertHit]`) dentro do `Task.detached`. Ao final do `for profile in profiles`, se a lista não estiver vazia, `MainActor.run { self.notifyWeeklyCreditsAlert(hits) }`.
- Nova função `notifyWeeklyCreditsAlert(_ hits: [WeeklyCreditsAlertHit])`:
  - 1 hit: mensagem via `AppStrings.t`: `"💳 {nome} ainda tem {pct}% dos créditos semanais — renova {resetDescription}"` / `"💳 {name} still has {pct}% of weekly credits — renews {resetDescription}"`.
  - Vários hits: `"💳 Créditos semanais disponíveis: {nome1} ({pct1}%), {nome2} ({pct2}%) — aproveite antes da renovação"` / `"💳 Weekly credits available: {name1} ({pct1}%), {name2} ({pct2}%) — use them before renewal"`.
  - Reusa `fiveHourAlertSoundName()` e `resetDescription(_:)` já existentes.
  - Cria e entrega um `NSUserNotification`, igual ao padrão de `notifyFiveHourAlert`.
- A troca de conta ativa **não** precisa resetar este tracker — ele já é indexado por `profileID` e por `resetAt`, então trocar a conta ativa não afeta o estado de nenhum perfil.

### `PreferencesView`

- Novo `Stepper` no mesmo bloco onde já está o `Stepper` do alerta de 5h (antes do `Divider()` final), ligado a `@AppStorage(WeeklyCreditsAlertThreshold.defaultsKey) private var weeklyCreditsThreshold: Double = WeeklyCreditsAlertThreshold.default`:
  - Texto: `"Avisar quando restarem {valor}% ou mais dos créditos semanais no dia da renovação"` / `"Alert when {valor}% or more of weekly credits remain on renewal day"`.
  - Range 1...100, step 5 — mesmo padrão do Stepper de 5h.
- Nenhum novo `Picker` de som — reusa o `fiveHourSoundRaw` já existente na view.

## Fluxo

1. A cada 60s, `refreshProfileMetadata()` busca o snapshot de uso de cada perfil.
2. Para cada perfil (ativo ou não) cujo snapshot tenha a cota `"Semanal"`, `checkWeeklyCreditsAlert` compara o tempo até `resetAt` e os créditos disponíveis contra o limiar salvo em `UserDefaults`.
3. Perfis que estão a ≤24h da renovação e com créditos disponíveis ≥ limiar entram na lista de hits do ciclo, uma única vez por `resetAt` (renovações futuras rearmam automaticamente).
4. Se a lista de hits não estiver vazia ao final do ciclo, uma notificação nativa combinada é disparada com o som configurado em Preferências (`fiveHourAlertSoundName`).
5. O usuário pode ajustar o limiar (1–100%) em Preferências a qualquer momento; a mudança vale a partir da próxima verificação.

## Tratamento de falhas

- Perfil sem cota `"Semanal"` no snapshot (ex.: sem OAuth válido) ou sem `resetAt`: ignorado nesse ciclo, sem erro.
- Limiar inválido em `UserDefaults` (0, negativo ou >100): usa o padrão de 30%.
- `resetAt` já no passado (não deveria ocorrer em uso normal): tratado como fora da janela de 24h, sem disparo, e limpa o estado alertado daquele perfil.

## Testes

### Unitários

- Dado um perfil com `resetAt` a menos de 24h e créditos disponíveis acima do limiar, `evaluate` retorna `true` uma vez.
- Uma segunda checagem consecutiva com o mesmo `resetAt` não dispara de novo.
- Um perfil com `resetAt` a mais de 24h não dispara.
- Um perfil com créditos disponíveis abaixo do limiar não dispara.
- Quando `resetAt` muda (a janela semanal renovou), o rastreador permite novo disparo para aquele perfil.
- Limiar ausente/inválido em `UserDefaults` cai para 30%.
- Perfis distintos são rastreados independentemente (o disparo de um não afeta o estado de outro).
- A montagem da mensagem combinada para múltiplos hits no mesmo ciclo lista todas as contas qualificadas.

### Manual

- Configurar o limiar para um valor alto (ex.: 90%) em Preferências e confirmar que a notificação aparece para contas próximas da renovação semanal com uso real baixo.
- Confirmar que trocar de conta ativa não interfere neste alerta (contas inativas continuam sendo avaliadas).
- Confirmar que múltiplas contas qualificadas no mesmo ciclo geram uma única notificação combinada, não várias.
- Confirmar que o texto da notificação aparece corretamente em pt-BR e en.
- Confirmar que alterar o limiar em Preferências não exige reiniciar o app.

## Critérios de aceite

1. Quando qualquer conta está a até 24h da renovação da janela semanal com créditos disponíveis acima do limiar configurado (padrão 30%), uma notificação nativa avisa isso, com o percentual disponível.
2. O mesmo vencimento não gera notificações repetidas a cada 60s para a mesma conta.
3. Contas não-ativas também disparam o alerta — a checagem não se restringe à conta ativa.
4. Múltiplas contas qualificadas no mesmo ciclo geram uma única notificação combinada.
5. O usuário pode alterar o limiar em Preferências, com efeito imediato na próxima checagem.
6. Cotas por modelo e a janela de 5h não influenciam este alerta.
