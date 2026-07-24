---
name: landing-page
description: Publicar ou modificar a landing page (GitHub Pages) do Claude Account Switcher em https://pedropcardoso.github.io/ClaudeAccountSwitcher/. Use quando pedirem para editar, atualizar versão, adicionar features, ou "publicar/subir" o site do projeto.
---

# Publicar/modificar a landing page do Claude Account Switcher

## Fonte da verdade (leia primeiro)

A landing page é **`docs/index.html`** na raiz do repositório, servida pelo GitHub Pages a
partir de `origin/main`, pasta `/docs`. URL no ar:
**https://pedropcardoso.github.io/ClaudeAccountSwitcher/**. É o único `index.html` do site —
sempre edite esse arquivo.

## Configuração do Pages (confirmável, pode mudar)

```
gh api repos/PedroPCardoso/ClaudeAccountSwitcher/pages -q '.source, .html_url, .build_type'
# esperado: {"branch":"main","path":"/docs"}  /  legacy build  /  https://pedropcardoso.github.io/ClaudeAccountSwitcher/
```

`build_type: legacy` = o Pages **reconstrói sozinho** a cada push em `main` que toque `/docs`.
Não há workflow de Actions para disparar.

## Passo a passo para publicar uma mudança

```zsh
git checkout main
git fetch origin -q && git merge --ff-only origin/main   # sincroniza antes de editar
```

1. Edite `docs/index.html` (e/ou adicione imagens em `docs/assets/`).
   - Imagens são referenciadas por caminho **relativo**: `assets/<arquivo>.png`.
   - Assets atuais: `claude-account-switcher-logo.png`, `menu-usage-example.png`.
   - Toda cópia visível é **pt-BR** (a landing é só em português).
   - Só adicione visuais/prints **quando a imagem existir** — não fabricar screenshots.

2. Commit + push (o push em `main` dispara o rebuild do Pages):
   ```zsh
   git add docs/index.html docs/assets
   git commit -m "site: <descrição>

   Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
   git push origin main
   ```

3. **Verifique no ar** (o rebuild leva ~1–2 min):
   ```zsh
   curl -s https://pedropcardoso.github.io/ClaudeAccountSwitcher/ | grep -io "1\.3\.[0-9]\|Novidades[^<]*\|Baixar[^<]*" | head
   gh api repos/PedroPCardoso/ClaudeAccountSwitcher/pages/builds/latest -q '.status'  # "built"
   ```

## Ao lançar uma nova versão

O botão de download aponta para o DMG versionado em `dist/`:
`https://github.com/PedroPCardoso/ClaudeAccountSwitcher/raw/main/dist/Claude-Account-Switcher-<versão>.dmg`.
Ao subir versão, atualize esse link e qualquer número de versão no HTML. O `dist/<dmg>` precisa
existir em `origin/main` (mesmo lugar), senão o link quebra.

## Checklist rápido

- [ ] Editei `docs/index.html`.
- [ ] Imagens novas em `docs/assets/`, referência relativa `assets/...`.
- [ ] Commit em `main`, push `origin main`.
- [ ] `curl` da URL pública confirma a mudança; `pages/builds/latest` = `built`.
