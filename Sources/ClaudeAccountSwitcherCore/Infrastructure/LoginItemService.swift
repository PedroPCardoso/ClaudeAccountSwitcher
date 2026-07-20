import Foundation
import ServiceManagement

public struct LoginItemService: Sendable {
    public init() {}
    public var isEnabled: Bool { SMAppService.mainApp.status == .enabled }
    public func setEnabled(_ enabled: Bool) throws { if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() } }
}
