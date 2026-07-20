# Claude Account Switcher 1.2.0

App nativo de barra de menus para alternar entre perfis isolados do Claude Code no macOS. O perfil selecionado vale para novas sessões; sessões já abertas continuam intactas.

Release atual: **1.2.0**. O DMG distribuído contém um binário universal para Apple Silicon e Intel quando o build é executado em um ambiente macOS com suporte aos dois targets.

Download direto: [Claude-Account-Switcher-1.2.0.dmg](https://github.com/PedroPCardoso/ClaudeAccountSwitcher/raw/main/dist/Claude-Account-Switcher-1.2.0.dmg)

### Uso real Pro/Max

Nas Preferências e ao passar o mouse sobre cada conta no menu da barra, o app consulta diretamente a cota OAuth do Claude Code (janela de 5 horas e semanal). Cada perfil usa exclusivamente a credencial armazenada no Keychain do próprio diretório `CLAUDE_CONFIG_DIR`; nenhuma instalação de 9router ou outro gateway é necessária. A consulta usa um endpoint de consumidor da Anthropic e pode mudar sem aviso.

O menu **Ver uso do Claude…** abre uma janela interna com cartões por conta, barras visuais de progresso, percentuais usados e horários de renovação.

## Estado atual

O projeto já contém o núcleo de perfis, persistência atômica, descoberta do Claude Code, autenticação via `claude auth`, launcher, ativação com rollback, migração, login item e menu de barra. O ambiente usado para este build tem Swift Command Line Tools, mas não tem Xcode/XCTest; por isso o pacote inclui um runner de testes executável.

Em **Preferências…**, é possível ver o e-mail e o status de cada conta, ativar, renomear, remover ou refazer o login de um perfil. Ao abrir a tela, o app atualiza os dados de autenticação pelo `claude auth status` oficial.

## Build e testes

```zsh
cd /path/to/ClaudeAccountSwitcher
swift run ClaudeAccountSwitcherTests
swift build -c release --product ClaudeAccountSwitcher
./Scripts/build-app.sh
./Scripts/build-dmg.sh
```

O runner deve imprimir `N tests passed`. O build gera `build/Claude Account Switcher.app`, assinado localmente com assinatura ad hoc.
`./Scripts/build-dmg.sh` também gera `build/Claude-Account-Switcher.dmg` para arrastar o app para `Applications`.

## Instalação

```zsh
./Scripts/install-dev.sh
```

O script somente constrói, copia e abre o app. Ele não migra contas, não altera `.zprofile` e não remove aliases.

## Primeiro uso

Abra o app, importe `~/.claude` e `~/.claude-work` pela interface e confirme o backup antes de limpar aliases. Para adicionar conta, escolha Claude Pro/Max ou Anthropic Console; o login oficial abre no navegador e o perfil é salvo isoladamente.

Perfis ficam em `~/Library/Application Support/Claude Account Switcher/Profiles/`. Metadados e estado ativo ficam no mesmo diretório. Tokens não são lidos pelo app; o Claude Code e o Keychain continuam responsáveis por eles.

## Integração

Ao reparar a integração, o app instala um launcher em `~/Library/Application Support/Claude Account Switcher/bin/claude` e adiciona um bloco delimitado a `~/.zprofile`. O launcher preserva todos os argumentos do comando `claude` e injeta `CLAUDE_CONFIG_DIR` do perfil ativo. O app também atualiza o ambiente launchd para aplicativos gráficos novos.

O atalho padrão é `⌥⌘C`. Aplicativos que já estavam abertos podem precisar ser reiniciados para receber o novo ambiente.

## Recuperação

Antes de qualquer migração o app cria backups com manifesto. Se a troca falhar, o estado ativo anterior é restaurado. A remoção de perfil é recuperável pela área `Recently Removed`. Para remover a integração, use a ação de reparo/remoção no app; o bloco delimitado é o único trecho editado.

## Desenvolvimento

O núcleo está em `Sources/ClaudeAccountSwitcherCore`, a UI em `Sources/ClaudeAccountSwitcherApp` e o runner em `Tests/ClaudeAccountSwitcherTests`. Para uso de XCTest e assinatura de desenvolvimento, instale Xcode e mantenha os mesmos módulos e interfaces.
