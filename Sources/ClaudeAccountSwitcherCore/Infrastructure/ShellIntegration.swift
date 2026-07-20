import Foundation

public struct ShellIntegrationManager: Sendable {
    public static let startMarker = "# >>> Claude Account Switcher >>>"
    public static let endMarker = "# <<< Claude Account Switcher <<<"
    public let appSupport: URL
    public init(appSupport: URL) { self.appSupport = appSupport }

    public func launcherURL() -> URL { appSupport.appendingPathComponent("bin/claude") }
    public func install(home: URL, officialBinary: URL) throws {
        let bin = appSupport.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let launcher = renderLauncher(stateURL: appSupport.appendingPathComponent("active-profile.json"), officialBinary: officialBinary)
        try launcher.data(using: .utf8)!.write(to: launcherURL(), options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: launcherURL().path)
        let block = "\(Self.startMarker)\nexport PATH=\"\(bin.path):$PATH\"\n\(Self.endMarker)\n"
        for filename in [".zprofile", ".zshrc"] {
            let shellFile = home.appendingPathComponent(filename)
            let original = (try? String(contentsOf: shellFile, encoding: .utf8)) ?? ""
            if FileManager.default.fileExists(atPath: shellFile.path) {
                let backups = appSupport.appendingPathComponent("Backups", isDirectory: true)
                try FileManager.default.createDirectory(at: backups, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                try? FileManager.default.copyItem(at: shellFile, to: backups.appendingPathComponent("shell-\(Int(Date().timeIntervalSince1970))-\(filename.dropFirst())"))
            }
            let stripped = removeBlock(from: original)
            let content = stripped + (stripped.hasSuffix("\n") || stripped.isEmpty ? "" : "\n") + block
            try content.data(using: .utf8)!.write(to: shellFile, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: shellFile.path)
        }
    }

    public func remove(home: URL) throws {
        for filename in [".zprofile", ".zshrc"] {
            let file = home.appendingPathComponent(filename)
            guard let content = try? String(contentsOf: file, encoding: .utf8) else { continue }
            try removeBlock(from: content).data(using: .utf8)!.write(to: file, options: .atomic)
        }
    }

    public func renderLauncher(stateURL: URL, officialBinary: URL) -> String {
        """
#!/bin/sh
set -eu
STATE='\(stateURL.path)'
OFFICIAL='\(officialBinary.path)'
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
