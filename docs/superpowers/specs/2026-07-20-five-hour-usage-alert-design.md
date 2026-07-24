# Alerta de uso da janela de 5h — Design

## Objetivo

Avisar o usuário via notificação nativa do macOS (com som configurável) sempre que a conta **ativa** atingir um percentual configurável (padrão 80%) de uso na janela de 5 horas do Claude, sinalizando que uma troca de conta deve ser feita antes de esbarrar no limite.

## Escopo

- Cobre apenas o perfil atualmente ativo (o que o `claude` usa nas próximas execuções). Perfis inativos não disparam esse alerta — a ideia é sinalizar a troca, não monitorar contas paradas.
- Cobre apenas a cota "Janela 5h" (`ClaudeQuota.key == "Janela 5h"`), retornada pelo `ClaudeUsageService`. As cotas semanais (`Semanal`, `Semanal <modelo>`) ficam fora do escopo.
- O limite é configurável em Preferências (padrão 80%), sem toggle de liga/desliga separado.
- O som da notificação é configurável em Preferências entre: Nenhum, Padrão, Basso, Glass, Hero, Ping, Sosumi.
- Não cobre persistência do estado "já alertado" entre reinícios do app — é aceitável perder o estado e potencialmente alertar de novo logo após um restart.
- Não cobre troca automática de conta — o app apenas sinaliza; a troca continua manual (menu ou `⌥⌘C`).

## Onde a lógica entra

O ciclo de atualização de uso já existe: `MenuBarController.applicationDidFinishLaunching` cria um `Timer` de 60s que chama `refreshProfileMetadata()`, que por sua vez busca `ClaudeUsageSnapshot` de cada perfil via `ClaudeUsageService.fetch(profileDirectory:)`. A checagem de alerta entra logo após o snapshot do perfil **ativo** (`store.active()`) ser obtido, dentro do mesmo loop — os demais perfis continuam sendo atualizados normalmente para a `UsageView`, mas não passam pela checagem de alerta.

## Componentes alterados

### `MenuBarController`

- Nova propriedade `private var fiveHourAlerted = false` — memória volátil indicando se já foi disparado alerta para o perfil ativo no ciclo de uso corrente.
- A troca de conta (`activate`) já muda o perfil ativo; o código de ativação passa a resetar `fiveHourAlerted = false` ao concluir uma troca, já que a conta nova começa sem alerta disparado.
- Nova função `checkFiveHourAlert(activeProfile: Profile, snapshot: ClaudeUsageSnapshot)` chamada dentro do loop de `refreshProfileMetadata()` apenas para o perfil cujo `id == store.active()?.id`:
  - Lê o limite configurado via `UserDefaults.standard.double(forKey: "fiveHourAlertThreshold")`, com fallback para `80` se não configurado (valor 0 ou ausente).
  - Procura em `snapshot.quotas` a entrada com `key == "Janela 5h"`.
  - Se `usedPercent >= limite`:
    - Se `fiveHourAlerted == false`: dispara a notificação e marca `fiveHourAlerted = true`.
  - Se `usedPercent < limite`: `fiveHourAlerted = false` (rearma o alerta para o próximo cruzamento, o que acontece naturalmente quando a janela de 5h reseta).
- Nova função `notifyFiveHourAlert(profile: Profile, percent: Double, threshold: Double)` (em vez de reaproveitar `notify(_:)` puro, já que precisa de som configurável):
  - Monta a mensagem via `AppStrings.t`: `"⚠️ Troque de conta: {profile.name} está em {percent}% da janela de 5h (limite {threshold}%)"` / `"⚠️ Switch accounts: {profile.name} is at {percent}% of the 5-hour window (threshold {threshold}%)"`.
  - Lê o som configurado via `UserDefaults.standard.string(forKey: "fiveHourAlertSoundName")`, padrão `"Padrão"/"Default"`.
  - Cria o `NSUserNotification` com `title`, `informativeText` e `soundName`: `nil` para "Nenhum", `NSUserNotificationDefaultSoundName` para "Padrão", ou o nome do som do sistema (`"Basso"`, `"Glass"`, `"Hero"`, `"Ping"`, `"Sosumi"`) diretamente para os demais — esses nomes correspondem aos arquivos em `/System/Library/Sounds` e já funcionam como valor de `soundName`.

### `PreferencesView`

- Novo bloco abaixo da lista de perfis (antes do `Divider()` final): 
  - Um `Stepper` ligado a um `Binding<Double>` para o limite, exibindo `"Alertar quando a janela de 5h atingir {valor}%"`, com range 1...100 e passo 5.
  - Um `Picker` para o som, com as opções Nenhum, Padrão, Basso, Glass, Hero, Ping, Sosumi.
- Os valores iniciais vêm de `UserDefaults.standard` (limite padrão 80, som padrão "Padrão").
- Mudanças gravam imediatamente em `UserDefaults.standard` via closures `onThresholdChange: (Double) -> Void` e `onAlertSoundChange: (String) -> Void`, seguindo o mesmo padrão dos outros closures da view (`onActivate`, `onRename` etc.).

### `PreferencesWindowController`

- Passa adiante os novos closures e valores atuais (limite e som) para `PreferencesView`, do mesmo jeito que já faz com os outros parâmetros.

## Fluxo

1. A cada 60s, `refreshProfileMetadata()` busca o snapshot de uso de cada perfil, incluindo o ativo.
2. Assim que o snapshot do perfil ativo é obtido, `checkFiveHourAlert` compara a cota "Janela 5h" contra o limite salvo em `UserDefaults`.
3. Ao cruzar o limite pela primeira vez (de abaixo para igual/acima), dispara uma notificação nativa com o som configurado e marca `fiveHourAlerted = true`.
4. Quando o uso cai abaixo do limite de novo (após o reset da janela de 5h) ou o usuário troca de conta, o alerta é rearmado.
5. O usuário pode ajustar o limite (1–100%) e o som em Preferências a qualquer momento; a mudança vale a partir da próxima verificação.

## Tratamento de falhas

- Perfil ativo sem OAuth válido ou sem cota "Janela 5h" no snapshot: nenhum alerta é avaliado naquele ciclo (comportamento igual ao já existente para uso indisponível).
- Limite inválido em `UserDefaults` (0, negativo ou ausente): usa o padrão de 80%.
- Som inválido/desconhecido em `UserDefaults`: cai para "Padrão".

## Testes

### Unitários

- Dado um snapshot com `usedPercent` abaixo do limite seguido de um snapshot igual/acima para o perfil ativo, a checagem dispara exatamente uma notificação e marca `fiveHourAlerted = true`.
- Uma segunda checagem consecutiva acima do limite não dispara nova notificação (sem duplicar).
- Uma checagem com `usedPercent` voltando abaixo do limite rearma o alerta, permitindo novo disparo em um cruzamento subsequente.
- Trocar de conta ativa reseta `fiveHourAlerted` para `false`.
- Limite ausente/inválido em `UserDefaults` cai para 80%; som ausente/inválido cai para "Padrão".
- Perfis não-ativos com uso acima do limite não disparam alerta.

### Manual

- Configurar o limite para um valor baixo (ex.: 1%) em Preferências e confirmar que a notificação aparece na próxima checagem para a conta ativa com uso real.
- Trocar o som em Preferências e confirmar que o som correspondente toca ao disparar o alerta, incluindo "Nenhum" (silencioso).
- Confirmar que o texto da notificação aparece corretamente em pt-BR e en.
- Confirmar que alterar o limite ou o som em Preferências não exige reiniciar o app.

## Critérios de aceite

1. Quando a conta ativa atinge o limite configurado (padrão 80%) na janela de 5h, uma notificação nativa é exibida sinalizando a troca de conta, com o percentual atual.
2. O mesmo cruzamento não gera notificações repetidas a cada 60s.
3. Trocar de conta ativa rearma a checagem para a nova conta.
4. O usuário pode alterar o limite e o som do alerta em Preferências, com efeito imediato na próxima checagem/disparo.
5. Cotas semanais e perfis não-ativos não disparam esse alerta.
