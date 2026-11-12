import Foundation

public struct ShellIntegrationManager: Sendable {
    public static let startMarker = "# >>> Claude Account Switcher >>>"
    public static let endMarker = "# <<< Claude Account Switcher <<<"
    public let appSupport: URL
    public init(appSupport: URL) { self.appSupport = appSupport }

    public func launcherURL() -> URL { appSupport.appendingPathComponent("bin/claude") }
    public func casURL() -> URL { appSupport.appendingPathComponent("bin/cas") }
    /// Script sourceado por zsh/bash que exporta `CLAUDE_CONFIG_DIR` do perfil ativo em todo shell.
    public func envScriptURL() -> URL { appSupport.appendingPathComponent("bin/cas-env.sh") }
    /// Equivalente para fish (sintaxe própria).
    public func fishEnvScriptURL() -> URL { appSupport.appendingPathComponent("bin/cas-env.fish") }

    /// Quota uma string para uso seguro dentro de aspas simples no shell POSIX. Fecha a
    /// aspa, insere um apóstrofo escapado e reabre (`it's` → `'it'\''s'`), tratando o path
    /// como input não-confiável — um `'` no path deixaria de quebrar o launcher.
    static func singleQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
    public func install(home: URL, officialBinary: URL, casBinary: URL? = nil) throws {
        let bin = appSupport.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let launcher = renderLauncher(stateURL: appSupport.appendingPathComponent("active-profile.json"), officialBinary: officialBinary, profilesDirectory: appSupport.appendingPathComponent("Profiles", isDirectory: true))
        try launcher.data(using: .utf8)!.write(to: launcherURL(), options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: launcherURL().path)
        // O `cas` é um binário compilado (vive no bundle do .app), não um script gerado: expomos
        // ele no PATH gerenciado via symlink, sempre re-apontando para o binário atual do bundle.
        if let casBinary { try installCAS(from: casBinary) }
        // Além do PATH, o bloco sourceia um script que exporta CLAUDE_CONFIG_DIR do perfil ativo no
        // próprio shell. O launcher `bin/claude` já resolve o perfil sozinho, mas instaladores de
        // terceiros (`npx <ferramenta> setup`, plugins, skills) rodam fora dele e só enxergam a
        // variável se ela estiver no ambiente do shell — sem isso gravam em ~/.claude.
        let stateURL = appSupport.appendingPathComponent("active-profile.json")
        try renderEnvScript(stateURL: stateURL).data(using: .utf8)!.write(to: envScriptURL(), options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: envScriptURL().path)
        try renderFishEnvScript(stateURL: stateURL).data(using: .utf8)!.write(to: fishEnvScriptURL(), options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fishEnvScriptURL().path)
        // zsh e bash usam a mesma sintaxe POSIX; fish tem a sua própria.
        let posixBlock = "\(Self.startMarker)\nexport PATH=\(Self.singleQuoted(bin.path)):\"$PATH\"\n[ -r \(Self.singleQuoted(envScriptURL().path)) ] && . \(Self.singleQuoted(envScriptURL().path))\n\(Self.endMarker)\n"
        let fishBlock = "\(Self.startMarker)\nset -gx PATH \(Self.singleQuoted(bin.path)) $PATH\ntest -r \(Self.singleQuoted(fishEnvScriptURL().path)); and source \(Self.singleQuoted(fishEnvScriptURL().path))\n\(Self.endMarker)\n"
        // zsh é o shell padrão do macOS: cria os arquivos se não existirem.
        for filename in [".zprofile", ".zshrc"] {
            try installBlock(posixBlock, into: home.appendingPathComponent(filename), createIfMissing: true)
        }
        // bash e fish: só integra se o usuário já usa aquele shell — não cria dotfiles novos
        // para shells não utilizados.
        for filename in [".bash_profile", ".bashrc"] {
            try installBlock(posixBlock, into: home.appendingPathComponent(filename), createIfMissing: false)
        }
        try installBlock(fishBlock, into: home.appendingPathComponent(".config/fish/config.fish"), createIfMissing: false)
    }

    private func installCAS(from source: URL) throws {
        let destination = casURL()
        // Idempotência: remove qualquer symlink/arquivo anterior antes de recriar apontando para o
        // binário atual (um update do app pode ter movido o bundle).
        if FileManager.default.fileExists(atPath: destination.path) || (try? FileManager.default.destinationOfSymbolicLink(atPath: destination.path)) != nil {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.createSymbolicLink(at: destination, withDestinationURL: source)
    }

    private func installBlock(_ block: String, into shellFile: URL, createIfMissing: Bool) throws {
        let exists = FileManager.default.fileExists(atPath: shellFile.path)
        guard exists || createIfMissing else { return }
        let original = (try? String(contentsOf: shellFile, encoding: .utf8)) ?? ""
        if exists {
            let backups = appSupport.appendingPathComponent("Backups", isDirectory: true)
            try FileManager.default.createDirectory(at: backups, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try? FileManager.default.copyItem(at: shellFile, to: backups.appendingPathComponent("shell-\(Int(Date().timeIntervalSince1970))-\(shellFile.lastPathComponent)"))
        }
        let stripped = removeBlock(from: original)
        let content = stripped + (stripped.hasSuffix("\n") || stripped.isEmpty ? "" : "\n") + block
        try FileManager.default.createDirectory(at: shellFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try content.data(using: .utf8)!.write(to: shellFile, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: shellFile.path)
    }

    public func remove(home: URL) throws {
        let files = [".zprofile", ".zshrc", ".bash_profile", ".bashrc", ".config/fish/config.fish"].map { home.appendingPathComponent($0) }
        for file in files {
            guard let content = try? String(contentsOf: file, encoding: .utf8) else { continue }
            try removeBlock(from: content).data(using: .utf8)!.write(to: file, options: .atomic)
        }
        // Também remove o `cas` do PATH gerenciado (o symlink pode existir mesmo com o alvo ausente).
        let cas = casURL()
        if FileManager.default.fileExists(atPath: cas.path) || (try? FileManager.default.destinationOfSymbolicLink(atPath: cas.path)) != nil {
            try FileManager.default.removeItem(at: cas)
        }
        for script in [envScriptURL(), fishEnvScriptURL()] where FileManager.default.fileExists(atPath: script.path) {
            try FileManager.default.removeItem(at: script)
        }
    }

    /// O launcher resolve o perfil ativo e, para `--resume <id>`/`-r <id>`, segue o perfil DONO da
    /// conversa: transcripts nunca mudam de perfil, então retomar uma sessão criada em outro perfil
    /// falharia com "No conversation found" (e clientes como o Paseo descartam a sessão ao ver esse
    /// erro). Só redireciona quando o id não existe no perfil ativo e existe em exatamente um outro
    /// perfil gerenciado; qualquer dúvida mantém o ativo e deixa o CLI decidir.
    ///
    /// Um `CLAUDE_CONFIG_DIR` herdado FORA da raiz gerenciada (pasta própria de outro app, sandbox, fixture de teste) é
    /// respeitado: apps como o Operaí chamam `claude` pelo PATH com a pasta deles, e sobrescrevê-la punha as sessões e as
    /// limpezas desse app dentro do perfil pessoal. Valores dentro da raiz (o perfil exportado pelo cas-env.sh, mesmo
    /// desatualizado após uma troca, e o symlink `active-config-dir`) seguem o perfil ativo.
    public func renderLauncher(stateURL: URL, officialBinary: URL, profilesDirectory: URL) -> String {
        """
#!/bin/sh
set -eu
STATE=\(Self.singleQuoted(stateURL.path))
OFFICIAL=\(Self.singleQuoted(officialBinary.path))
PROFILES=\(Self.singleQuoted(profilesDirectory.path))
MANAGED_ROOT=\(Self.singleQuoted(profilesDirectory.deletingLastPathComponent().path))
# Pasta escolhida por quem chamou, fora da raiz gerenciada: não é um perfil, então não é nossa para trocar.
case "${CLAUDE_CONFIG_DIR:-}" in
  ''|"$MANAGED_ROOT"|"$MANAGED_ROOT"/*) ;;
  *) exec "$OFFICIAL" "$@" ;;
esac
if [ ! -f "$STATE" ]; then echo 'Claude Account Switcher: perfil ativo não encontrado' >&2; exit 78; fi
CONFIG_DIR=$(/usr/bin/plutil -extract directory raw -o - "$STATE" 2>/dev/null || true)
case "$CONFIG_DIR" in file://*) CONFIG_DIR="${CONFIG_DIR#file://}";; esac
if [ -z "$CONFIG_DIR" ] || [ ! -d "$CONFIG_DIR" ]; then echo 'Claude Account Switcher: diretório do perfil indisponível' >&2; exit 78; fi
# --resume <id>: a conversa fica no perfil em que nasceu.
RESUME_ID=; prev=
for arg in "$@"; do
  case "$prev" in --resume|-r) RESUME_ID=$arg;; esac
  case "$arg" in --resume=*) RESUME_ID=${arg#--resume=};; esac
  prev=$arg
done
case "$RESUME_ID" in *[!0-9a-fA-F-]*|????????) RESUME_ID=;; esac   # só ids hex-com-hífens com 9+ chars
if [ ${#RESUME_ID} -lt 9 ]; then RESUME_ID=; fi
if [ -n "$RESUME_ID" ] && ! ls "$CONFIG_DIR"/projects/*/"$RESUME_ID".jsonl >/dev/null 2>&1; then
  OWNER=; COUNT=0
  for f in "$PROFILES"/*/config/projects/*/"$RESUME_ID".jsonl; do
    [ -f "$f" ] || continue
    OWNER=${f%/projects/*}; COUNT=$((COUNT + 1))
  done
  if [ "$COUNT" -eq 1 ] && [ -d "$OWNER" ]; then
    echo "Claude Account Switcher: sessão $RESUME_ID pertence a outro perfil; usando $OWNER" >&2
    CONFIG_DIR=$OWNER
  fi
fi
export CLAUDE_CONFIG_DIR="$CONFIG_DIR"
exec "$OFFICIAL" "$@"
"""
    }

    /// Script POSIX sourceado por zsh e bash. Exporta `CLAUDE_CONFIG_DIR` do perfil ativo ao carregar
    /// e, em shells interativos, reexporta antes de cada prompt quando `active-profile.json` mudou —
    /// assim uma troca pelo menu ou por `cas switch` alcança shells já abertos, igual ao launcher.
    /// Usa a mesma resolução do launcher (plutil + `file://`), tolerante a falhas: nunca quebra o
    /// shell do usuário, só deixa de exportar.
    public func renderEnvScript(stateURL: URL) -> String {
        """
# Gerado pelo Claude Account Switcher — reescrito a cada reparo da integração; não edite.
# Exporta CLAUDE_CONFIG_DIR do perfil ativo no shell para que instaladores de terceiros
# (npx <ferramenta> setup, plugins, skills) gravem no perfil, e não em ~/.claude.
CAS_STATE=\(Self.singleQuoted(stateURL.path))
cas_env() {
  [ -f "$CAS_STATE" ] || return 0
  _cas_dir=$(/usr/bin/plutil -extract directory raw -o - "$CAS_STATE" 2>/dev/null) || { unset _cas_dir; return 0; }
  case "$_cas_dir" in file://*) _cas_dir="${_cas_dir#file://}";; esac
  if [ -n "$_cas_dir" ] && [ -d "$_cas_dir" ]; then
    export CLAUDE_CONFIG_DIR="$_cas_dir"
    _cas_state_seen=$(_cas_state_mtime)
  fi
  unset _cas_dir
}
_cas_state_mtime() { /usr/bin/stat -f %m "$CAS_STATE" 2>/dev/null; }
_cas_env_refresh() {
  [ -f "$CAS_STATE" ] || return 0
  _cas_now=$(_cas_state_mtime)
  if [ "$_cas_now" != "${_cas_state_seen:-}" ]; then cas_env; fi
  unset _cas_now
}
cas_env
# BASH_VERSION primeiro: o bash sempre a define, enquanto ZSH_VERSION pode ter vazado exportada.
if [ -n "${BASH_VERSION:-}" ]; then
  case ";${PROMPT_COMMAND:-};" in *";_cas_env_refresh;"*) ;; *) PROMPT_COMMAND="_cas_env_refresh${PROMPT_COMMAND:+;$PROMPT_COMMAND}";; esac
elif [ -n "${ZSH_VERSION:-}" ]; then
  autoload -Uz add-zsh-hook 2>/dev/null && add-zsh-hook precmd _cas_env_refresh
fi
"""
    }

    /// Versão fish do script de ambiente: exporta ao carregar e reexporta a cada prompt quando o
    /// estado mudou.
    public func renderFishEnvScript(stateURL: URL) -> String {
        """
# Gerado pelo Claude Account Switcher — reescrito a cada reparo da integração; não edite.
set -g CAS_STATE \(Self.singleQuoted(stateURL.path))
function cas_env
  test -f "$CAS_STATE"; or return 0
  set -l dir (/usr/bin/plutil -extract directory raw -o - "$CAS_STATE" 2>/dev/null); or return 0
  set dir (string replace -r '^file://' '' -- "$dir")
  if test -n "$dir" -a -d "$dir"
    set -gx CLAUDE_CONFIG_DIR "$dir"
    set -g _cas_state_seen (/usr/bin/stat -f %m "$CAS_STATE" 2>/dev/null)
  end
end
function _cas_env_refresh --on-event fish_prompt
  test -f "$CAS_STATE"; or return 0
  set -l now (/usr/bin/stat -f %m "$CAS_STATE" 2>/dev/null)
  if test "$now" != "$_cas_state_seen"; cas_env; end
end
cas_env
"""
    }

    private func removeBlock(from content: String) -> String {
        guard let start = content.range(of: Self.startMarker), let end = content.range(of: Self.endMarker, range: start.upperBound..<content.endIndex) else { return content }
        var result = content; result.removeSubrange(start.lowerBound...end.upperBound); return result
    }
}
