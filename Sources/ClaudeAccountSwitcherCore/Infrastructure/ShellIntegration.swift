import Foundation

public struct ShellIntegrationManager: Sendable {
    public static let startMarker = "# >>> Claude Account Switcher >>>"
    public static let endMarker = "# <<< Claude Account Switcher <<<"
    public let appSupport: URL
    public init(appSupport: URL) { self.appSupport = appSupport }

    public func launcherURL() -> URL { appSupport.appendingPathComponent("bin/claude") }
    public func casURL() -> URL { appSupport.appendingPathComponent("bin/cas") }

    /// Quota uma string para uso seguro dentro de aspas simples no shell POSIX. Fecha a
    /// aspa, insere um apóstrofo escapado e reabre (`it's` → `'it'\''s'`), tratando o path
    /// como input não-confiável — um `'` no path deixaria de quebrar o launcher.
    static func singleQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
    public func install(home: URL, officialBinary: URL, casBinary: URL? = nil) throws {
        let bin = appSupport.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let launcher = renderLauncher(stateURL: appSupport.appendingPathComponent("active-profile.json"), officialBinary: officialBinary)
        try launcher.data(using: .utf8)!.write(to: launcherURL(), options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: launcherURL().path)
        // O `cas` é um binário compilado (vive no bundle do .app), não um script gerado: expomos
        // ele no PATH gerenciado via symlink, sempre re-apontando para o binário atual do bundle.
        if let casBinary { try installCAS(from: casBinary) }
        // zsh e bash usam a mesma sintaxe POSIX; fish tem a sua própria.
        let posixBlock = "\(Self.startMarker)\nexport PATH=\(Self.singleQuoted(bin.path)):\"$PATH\"\n\(Self.endMarker)\n"
        let fishBlock = "\(Self.startMarker)\nset -gx PATH \(Self.singleQuoted(bin.path)) $PATH\n\(Self.endMarker)\n"
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
    }

    public func renderLauncher(stateURL: URL, officialBinary: URL) -> String {
        """
#!/bin/sh
set -eu
STATE=\(Self.singleQuoted(stateURL.path))
OFFICIAL=\(Self.singleQuoted(officialBinary.path))
if [ ! -f "$STATE" ]; then echo 'Claude Account Switcher: perfil ativo não encontrado' >&2; exit 78; fi
CONFIG_DIR=$(/usr/bin/plutil -extract directory raw -o - "$STATE" 2>/dev/null || true)
case "$CONFIG_DIR" in file://*) CONFIG_DIR="${CONFIG_DIR#file://}";; esac
if [ -z "$CONFIG_DIR" ] || [ ! -d "$CONFIG_DIR" ]; then echo 'Claude Account Switcher: diretório do perfil indisponível' >&2; exit 78; fi
export CLAUDE_CONFIG_DIR="$CONFIG_DIR"
exec "$OFFICIAL" "$@"
"""
    }

    private func removeBlock(from content: String) -> String {
        guard let start = content.range(of: Self.startMarker), let end = content.range(of: Self.endMarker, range: start.upperBound..<content.endIndex) else { return content }
        var result = content; result.removeSubrange(start.lowerBound...end.upperBound); return result
    }
}
