---
name: release
description: Lançar uma nova versão do Claude Account Switcher (bump de versão, build do .app + DMG, dist/, commit, tag, GitHub release) e SEMPRE instalar a versão localmente ao final. Use quando pedirem para "criar/gerar/lançar a versão X.Y.Z", subir uma release, ou empacotar uma nova versão.
---

# Lançar uma nova versão do Claude Account Switcher

Todo trabalho roda a partir da raiz do repositório (onde vive `Package.swift`):

```zsh
git checkout main && git fetch origin -q && git merge --ff-only origin/main
```

`main` rastreia `origin/main`. Convenção de versão confirmada:
tag `v<X.Y.Z>`, release "Claude Account Switcher <X.Y.Z>", DMG `dist/Claude-Account-Switcher-<X.Y.Z>.dmg`.
Defina `VER=<X.Y.Z>` para os comandos abaixo.

## Regra inegociável

**Toda nova versão criada aqui É instalada localmente ao final** (passo 8). Não pule esse passo.

## Passos

### 1. Pré-checagem: build + testes verdes
```zsh
swift build
swift run ClaudeAccountSwitcherTests   # deve terminar em "N tests passed", exit 0
```
Não lance uma versão com testes vermelhos.

### 2. Bump da versão
Editar `Scripts/build-app.sh` — as duas chaves do Info.plist embutido:
```
<key>CFBundleVersion</key><string>$VER</string>
<key>CFBundleShortVersionString</key><string>$VER</string>
```
(Não há versão em `Package.swift`; o número vive só no `build-app.sh`.)

### 3. Changelog no README (o README É o changelog do projeto)
Em `README.md`: título `# Claude Account Switcher $VER`, a linha
`Current release: **$VER**.`, o link de download apontando para o **asset da release**
(`https://github.com/PedroPCardoso/ClaudeAccountSwitcher/releases/download/v$VER/Claude-Account-Switcher-$VER.dmg`
— não o link raw de `dist/`, que o GitHub não contabiliza como download) e uma nova seção
`### What's new in $VER` (bilíngue não é exigido no README, que é em inglês).

> O link do asset só fica "vivo" depois do passo 7 (`gh release create`). Como os passos rodam em
> sequência na mesma execução, a janela em que o link fica quebrado é breve — mas não pule o
> passo 7 nem publique só o commit do passo 6 isoladamente.

### 4. Build do .app e do DMG
```zsh
./Scripts/build-app.sh    # gera build/Claude Account Switcher.app (inclui o binário cas universal)
./Scripts/build-dmg.sh    # gera build/Claude-Account-Switcher.dmg
```
Confirme a versão e o empacotamento do `cas`:
```zsh
/usr/bin/plutil -extract CFBundleShortVersionString raw "build/Claude Account Switcher.app/Contents/Info.plist"  # = $VER
ls "build/Claude Account Switcher.app/Contents/MacOS/"   # deve listar ClaudeAccountSwitcher E cas
```

### 5. Publicar o DMG versionado em dist/
```zsh
cp "build/Claude-Account-Switcher.dmg" "dist/Claude-Account-Switcher-$VER.dmg"
```

### 6. Commit + push (branch do código)
```zsh
git add README.md Scripts/build-app.sh "dist/Claude-Account-Switcher-$VER.dmg"
git commit -m "release: $VER — <resumo curto>

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
git push origin main
```

### 7. Tag + GitHub release com o DMG anexado
```zsh
git tag -a "v$VER" -m "Claude Account Switcher $VER"
git push origin "v$VER"
gh release create "v$VER" \
  --title "Claude Account Switcher $VER" \
  --notes "## What's new in $VER
- ..." \
  "dist/Claude-Account-Switcher-$VER.dmg#Claude-Account-Switcher-$VER.dmg"
```

### 8. Instalar localmente (OBRIGATÓRIO)
Encerre qualquer instância rodando e instale (o script reconstrói, copia para `~/Applications`
e abre; não migra nem altera contas):
```zsh
pkill -f "Claude Account Switcher" 2>/dev/null; pkill -f ClaudeAccountSwitcher 2>/dev/null || true
./Scripts/install-dev.sh
```
Confirme que instalou em `~/Applications/Claude Account Switcher.app` e que o app abriu.

## Documentação relacionada (fazer se as features novas pedirem)

- **Landing page**: sempre atualize o botão de download em `docs/index.html` para o asset da nova
  release (mesmo padrão de URL do passo 3), seguindo a skill **landing-page**. Se a release muda
  o que o site anuncia (features/versão), atualize também esse conteúdo.
- **CLAUDE.md**: se surgiram novas chaves de `UserDefaults`, novos arquivos/targets ou a
  versão mudou, atualize as seções correspondentes.
- **Specs** (`docs/superpowers/specs/`): registre features grandes como
  `YYYY-MM-DD-<topico>-design.md`.

## Checklist

- [ ] `swift run ClaudeAccountSwitcherTests` verde antes de lançar.
- [ ] `build-app.sh` com `$VER` nas duas chaves de versão.
- [ ] README: título, current release, link do asset da release (não o link raw), "What's new in $VER".
- [ ] Botão de download da landing page (`docs/index.html`) atualizado para o asset da nova release.
- [ ] `.app` reporta `$VER` e empacota `cas`; DMG copiado para `dist/Claude-Account-Switcher-$VER.dmg`.
- [ ] Commit + `push origin main`; tag `v$VER` empurrada; release criada com o DMG.
- [ ] **Instalado localmente via `install-dev.sh` e app aberto.** (obrigatório)
