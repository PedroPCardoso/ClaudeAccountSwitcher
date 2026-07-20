# Claude Account Switcher — Design

## Objetivo

Criar um aplicativo nativo de barra de menus para macOS que permita cadastrar e alternar entre qualquer quantidade de perfis isolados do Claude Code. Depois da escolha, novas sessões iniciadas pelo comando normal `claude`, pelo VS Code, pelo Zed ou por outros gerenciadores devem usar o perfil ativo, sem exigir aliases como `claude-work`.

## Escopo da primeira versão

- Aplicativo nativo em Swift e SwiftUI, executado como menu-bar app sem ícone permanente no Dock.
- Compatibilidade mínima com macOS 13 Ventura e Macs Apple Silicon.
- Perfis ilimitados, com autenticação, histórico, configurações, plugins, MCPs, permissões e sessões isolados.
- Importação guiada dos ambientes existentes `~/.claude` e `~/.claude-work`.
- Login de novas contas Claude Pro/Max ou Anthropic Console pelo navegador, iniciado dentro do app.
- Importação de perfis personalizados, inclusive configurações com endpoint ou token gerenciado externamente.
- Troca pelo menu ou pelo atalho global configurável `⌥⌘C`.
- Inicialização automática com o macOS, habilitada por padrão e reversível nas preferências.
- Integração transparente com o comando `claude`, sem manter aliases por conta.
- Aplicação da troca somente a novos processos. Sessões em execução não são alteradas.
- Build local de um `.app` assinável e instalável, acompanhado de instruções de build e reinstalação.

Não fazem parte da primeira versão: sincronização de perfis entre Macs, distribuição na App Store, conta online própria, telemetria remota e alteração de sessões já abertas.

## Arquitetura escolhida

A solução usa uma abordagem híbrida. O app mantém o perfil selecionado em um arquivo de estado local, atualiza `CLAUDE_CONFIG_DIR` no ambiente do usuário para novos aplicativos gráficos e instala um launcher transparente no início do `PATH` para que o comando normal `claude` consulte o perfil ativo em toda execução.

O launcher não contém credenciais. Ele lê apenas o identificador do perfil ativo, resolve seu diretório de configuração e executa o binário oficial do Claude Code com os argumentos originais e `CLAUDE_CONFIG_DIR` definido. Isso garante que shells já abertos recebam a nova seleção sem depender de recarregar `.zshrc`. Novos aplicativos iniciados pelo macOS também herdam o ambiente atualizado. Aplicativos gráficos que já estavam abertos podem precisar ser reiniciados, e o app deve avisar isso após a troca.

A troca física de `~/.claude`, a cópia de tokens e a edição de itens do Keychain ficam explicitamente proibidas. O próprio Claude Code continua responsável por autenticação e armazenamento seguro de credenciais.

## Componentes

### MenuBarApp

Apresenta o perfil ativo, a lista de perfis e as ações principais. Coordena o seletor rápido, preferências, notificações e abertura das telas de gerenciamento, mas não lê arquivos internos dos perfis.

### ProfileStore

Mantém metadados não secretos em:

`~/Library/Application Support/Claude Account Switcher/profiles.json`

Cada registro contém UUID, nome escolhido, e-mail e organização detectados quando disponíveis, cor, ícone, tipo de autenticação, caminho do diretório, datas de criação/último uso e estado de saúde. O perfil ativo fica em um arquivo pequeno separado, escrito atomicamente:

`~/Library/Application Support/Claude Account Switcher/active-profile.json`

### ProfileDirectories

Perfis gerenciados vivem em:

`~/Library/Application Support/Claude Account Switcher/Profiles/<uuid>/config/`

O diretório inteiro pertence a uma única conta e é passado como `CLAUDE_CONFIG_DIR`. Perfis importados podem permanecer no caminho original ou ser copiados para a área gerenciada; a migração padrão copia, valida e só depois oferece arquivar a origem.

### ClaudeLocator

Localiza o executável oficial sem resolver para o launcher do app. A primeira fonte é a instalação nativa atual em `~/.local/share/claude/versions/`; caminhos adicionais podem ser escolhidos pelo usuário. O componente rejeita recursão, valida executabilidade e guarda o caminho confirmado como preferência reparável.

### ClaudeAuthService

Executa processos do Claude Code com um ambiente sanitizado e `CLAUDE_CONFIG_DIR` apontando para um único perfil. Para login usa `claude auth login --claudeai` ou `claude auth login --console`, sem Terminal visível. Para verificação usa `claude auth status --json` e extrai apenas campos de identidade e estado; saídas sensíveis não entram nos logs.

### ProfileActivator

Serializa as trocas. Valida o perfil, grava atomicamente o novo perfil ativo e então atualiza o ambiente do usuário via `launchctl setenv CLAUDE_CONFIG_DIR <path>`. Se qualquer passo falhar, restaura o estado e o ambiente anteriores. Uma ativação bem-sucedida publica uma notificação local e atualiza a interface.

### ShellIntegrationManager

Instala um launcher em um diretório próprio do app e adiciona um bloco delimitado ao `.zprofile` e, quando necessário, ao `.zshrc`. O bloco apenas antepõe o diretório do launcher ao `PATH`. Antes de editar, cria backup versionado; instalação, reparo e remoção são idempotentes. O launcher localiza o binário oficial, lê o estado ativo, define `CLAUDE_CONFIG_DIR` e usa `exec` preservando argumentos, entrada/saída e código de saída.

### MigrationService

Detecta `~/.claude`, `~/.claude-work`, aliases `claude-work`, `code-work` e `zed-work`, além do backup antigo `~/.claude-swap-backup`. A migração:

1. Mostra tudo que será importado ou alterado.
2. Cria backup versionado e manifesto com checksums.
3. Copia cada diretório para um perfil gerenciado sem seguir links externos.
4. Valida a cópia e consulta o estado de autenticação sem expor segredo.
5. Instala e testa o launcher.
6. Ativa o perfil padrão escolhido.
7. Remove apenas os aliases reconhecidos, depois de validação e confirmação na interface.
8. Mantém os originais até o usuário concluir explicitamente a limpeza.

### LoginItemService

Usa `SMAppService` para registrar o app como login item. A opção inicia habilitada, mostra o estado real do sistema e pode ser desativada sem remover dados.

## Fluxos de usuário

### Primeiro uso

O app detecta os dois perfis atuais, explica que nada será apagado durante a migração e apresenta nomes sugeridos. Depois do backup e da cópia, valida os perfis, instala a integração e confirma que uma invocação de teste resolve o diretório correto. O perfil padrão existente fica ativo inicialmente, salvo escolha diferente do usuário.

### Adicionar conta

1. O usuário escolhe Claude Pro/Max ou Anthropic Console e pode informar um nome.
2. O app cria um diretório temporário de perfil.
3. O Claude Code inicia o login oficial e abre o navegador.
4. O app acompanha o processo, exibe progresso e permite cancelar.
5. Após o retorno, `auth status --json` confirma a autenticação e fornece identidade não secreta.
6. O diretório é promovido atomicamente para perfil gerenciado e aparece no menu.
7. Falha ou cancelamento remove somente o diretório temporário.

Adicionar uma conta não desconecta nem altera outras contas.

### Importar perfil personalizado

O usuário escolhe um diretório. O app verifica se ele é legível, contém configuração plausível e não corresponde a outro perfil já registrado. Uma falha no OAuth não invalida automaticamente perfis que usam API, proxy ou endpoint personalizado; nesse caso, o app informa que o perfil é personalizado e permite importá-lo após confirmação.

### Trocar conta

Um clique no perfil ou uma escolha no seletor `⌥⌘C` inicia a ativação. Durante a operação, novas trocas ficam bloqueadas. Ao concluir, o menu, o ícone e uma notificação mostram a conta ativa. A mensagem explica que novos comandos `claude` já usam a seleção e que aplicativos gráficos previamente abertos podem precisar ser reabertos.

### Remover conta

O perfil ativo não pode ser removido até outro ser selecionado. A remoção exige confirmação, registra o perfil como removido e move seu diretório para:

`~/Library/Application Support/Claude Account Switcher/Recently Removed/<uuid>/`

O app oferece restauração. Exclusão permanente é uma ação separada e explícita. O app nunca executa logout em outras contas.

## Interface

O ícone da barra de menus usa um símbolo monocromático compatível com claro/escuro e um pequeno indicador da cor do perfil. O menu mostra, nesta ordem:

- nome e identidade do perfil ativo;
- lista pesquisável de perfis, com marca na conta ativa;
- Adicionar conta;
- Importar perfil;
- Gerenciar perfis;
- Preferências;
- Ajuda/Diagnóstico;
- Encerrar.

O atalho `⌥⌘C` abre um seletor rápido flutuante com foco na busca e navegação por teclado. Se o atalho estiver ocupado, o app informa o conflito e abre a configuração para escolha de outro.

Gerenciar perfis permite renomear, alterar cor/ícone, reautenticar, abrir o diretório, remover e restaurar. Preferências controlam atalho, login automático, notificações, caminho do Claude e reparo/remoção da integração de shell.

## Consistência e concorrência

- Apenas uma migração, autenticação, ativação ou reparo pode ocorrer por vez.
- Arquivos de metadados são escritos em arquivo temporário no mesmo volume e promovidos por rename.
- O launcher lê estado completo ou retorna erro acionável; nunca usa JSON parcialmente escrito.
- Processos já iniciados preservam o `CLAUDE_CONFIG_DIR` recebido no início.
- Uma troca não edita diretórios de perfil.
- Perfis ausentes ou ilegíveis ficam marcados como indisponíveis e não podem ser ativados.
- Se `launchctl` falhar após a gravação do estado, o estado anterior é restaurado e a ativação é reportada como falha.

## Segurança e privacidade

- O app não acessa diretamente tokens, senhas nem itens do Keychain.
- O app não registra saída integral de comandos de autenticação.
- Logs contêm somente horário, operação, UUID do perfil e erros sanitizados.
- Diretórios, metadados, backups e logs usam permissões restritas ao usuário.
- Argumentos de processo são construídos por `Process`, sem interpolação em shell.
- Caminhos importados são padronizados e validados para evitar recursão ou sobreposição entre perfis.
- Nenhuma telemetria ou comunicação própria é enviada pela primeira versão.

## Tratamento de falhas

- Claude ausente ou movido: diagnóstico com seleção manual e reparo.
- Login cancelado, expirado ou offline: perfil temporário descartado e demais perfis preservados.
- Perfil expirado: permanece disponível, recebe aviso e ação Reautenticar.
- Perfil personalizado sem OAuth: validação de estrutura e confirmação explícita.
- Integração de shell modificada externamente: detecção de divergência e reparo idempotente.
- Alias antigo ainda presente: aviso não bloqueante e remoção guiada.
- Atalho global ocupado: conflito visível e remapeamento.
- Arquivo de estado corrompido: restauração do último snapshot válido e abertura do diagnóstico.
- Falha de migração: rollback das mudanças do app e conservação dos diretórios originais.

## Estratégia de testes

### Testes unitários

- serialização, validação e escrita atômica de perfis;
- ordenação, pesquisa e seleção de perfis ilimitados;
- descoberta do binário e prevenção de recursão;
- geração e remoção idempotente do bloco de shell;
- construção do ambiente do launcher;
- parsing sanitizado de `auth status --json`;
- ativação, rollback e recuperação de estado;
- plano de migração, checksums e detecção dos aliases conhecidos;
- estados de login item e preferências.

### Testes de integração

Os testes usam um diretório home temporário, um `launchctl` adaptado e um executável Claude falso que registra apenas argumentos e caminhos. Eles cobrem login bem-sucedido/cancelado, importação padrão/personalizada, troca concorrente, atualização do launcher, migração dos dois ambientes atuais e restauração de backup. Nenhum teste automatizado toca em `~/.claude`, `~/.claude-work`, Keychain ou arquivos reais do shell.

### Validação manual no Mac

- executar migração sobre cópias dos dois perfis reais;
- confirmar troca pelo menu e por `⌥⌘C`;
- executar `claude auth status` pelo comando normal após cada troca;
- iniciar novas instâncias de Terminal, VS Code e Zed e confirmar o perfil;
- confirmar que sessões abertas antes da troca permanecem intactas;
- adicionar e reautenticar uma conta pelo navegador;
- confirmar login item após encerrar sessão de teste;
- testar reparo e desinstalação da integração;
- restaurar um perfil removido;
- inspecionar logs para garantir ausência de segredos.

Qualquer validação sobre os perfis reais exige uma tela de confirmação final com o caminho do backup. O app não remove os diretórios originais automaticamente.

## Entrega

O repositório fica na pasta escolhida pelo usuário. A entrega inclui código-fonte, projeto Xcode, testes, scripts seguros de build/empacotamento, documentação de arquitetura, guia de instalação e um `.app` localmente assinado. A instalação em `/Applications` será oferecida somente após o usuário validar o build; não é requisito para executar testes automatizados.

## Critérios de aceite

1. O usuário importa os dois ambientes atuais sem perda ou modificação dos originais.
2. O menu mostra e alterna entre mais de três perfis.
3. `claude` em um shell já aberto usa o perfil escolhido na próxima execução.
4. Novos aplicativos gráficos recebem o perfil ativo; aplicativos antigos recebem instrução clara para reiniciar.
5. Uma nova conta pode ser autenticada pelo navegador sem o usuário digitar comandos no Terminal.
6. Histórico, plugins, MCPs, permissões e sessões permanecem isolados por perfil.
7. Trocas com falha restauram integralmente o estado anterior.
8. O app inicia com o macOS por padrão e permite desativar essa opção.
9. O atalho global padrão é `⌥⌘C` e pode ser alterado.
10. Nenhum token aparece em metadados, logs ou backups criados pelo app além dos arquivos de perfil copiados integralmente e protegidos.
11. Remoção inicial de perfil é recuperável.
12. O usuário pode reparar ou remover a integração de shell e restaurar seu backup.
