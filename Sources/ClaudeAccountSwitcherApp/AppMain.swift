import SwiftUI

@main
struct ClaudeAccountSwitcherApp: App {
    @NSApplicationDelegateAdaptor(MenuBarController.self) private var delegate
    var body: some Scene { Settings { EmptyView() } }
}
