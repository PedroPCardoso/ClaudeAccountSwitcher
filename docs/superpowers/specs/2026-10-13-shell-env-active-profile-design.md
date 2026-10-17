# Exportar `CLAUDE_CONFIG_DIR` do perfil ativo no shell — design

Data: 2026-10-13

## Problema

O launcher `bin/claude` resolve o perfil ativo e injeta `CLAUDE_CONFIG_DIR` só no processo do
`claude`. Instaladores de terceiros rodam fora dele (`npx rea-agents setup`, instaladores de
plugins/skills, scripts que chamam `claude mcp add`). Eles respeitam `CLAUDE_CONFIG_DIR` quando a
variável existe, mas o shell não a tem: gravam em `~/.claude` e `~/.claude.json`, e nada aparece no
perfil em uso. O `launchctl setenv` feito na troca só alcança apps gráficos lançados depois.

## Decisão

O `ShellIntegrationManager` passa a gerar, ao lado do launcher, um script de ambiente que o bloco
delimitado já instalado nos dotfiles sourceia:

- `bin/cas-env.sh` (POSIX, zsh e bash) e `bin/cas-env.fish`.
- Ao carregar, lê `active-profile.json` com a mesma resolução do launcher (`plutil`, tolera
  `file://`) e exporta `CLAUDE_CONFIG_DIR` se o diretório existir. Qualquer falha é silenciosa:
  nunca quebra o shell, só deixa de exportar.
- Em shell interativo registra um refresh antes de cada prompt (`precmd` no zsh, `PROMPT_COMMAND`
  no bash, evento `fish_prompt` no fish) que compara o mtime do estado com o último visto e
  reexporta quando mudou. Assim uma troca pelo menu ou por `cas switch` alcança shells já
  abertos, igual ao comportamento do launcher. Custo: um `stat` por prompt.
- `remove()` apaga os dois scripts junto com o bloco.

## Alternativas descartadas

- Exportar a variável inline no bloco dos dotfiles: fica estática na abertura do shell e não
  acompanha a troca de perfil; também infla o bloco gerenciado.
- Tornar `~/.claude` e `~/.claude.json` symlinks para o perfil ativo: cobre instaladores que
  ignoram a variável, mas sequestra a configuração padrão (usada por VS Code sem o launcher) e
  não é reversível com segurança.
- `launchctl setenv` já existente: não alcança terminais já abertos nem o shell em si.

## Testes

`testShellEnvScriptExportsActiveProfile`: instala, confere que o bloco sourceia o script, roda o
script em `sh`, `zsh` e `bash` e compara a variável com o perfil ativo; troca o perfil, força um
mtime diferente e confere que o refresh reexporta; confere que `remove()` apaga os scripts.
