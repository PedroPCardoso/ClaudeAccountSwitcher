import Foundation
import ServiceManagement

public struct LoginItemService: Sendable {
    public init() {}
    public var isEnabled: Bool { SMAppService.mainApp.status == .enabled }
    public func setEnabled(_ enabled: Bool) throws { if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() } }

    /// Só um `.app` empacotado fora da pasta de build pode virar item de login. Rodando o
    /// executável solto (`swift run`, `.build/...`), `SMAppService.mainApp.register()` registra o
    /// binário cru e o macOS o abre no Terminal a cada login — uma cópia extra do app por execução.
    public static func canRegister(bundleURL: URL) -> Bool {
        bundleURL.pathExtension == "app" && !bundleURL.path.contains("/.build/")
    }
}
