import SwiftUI

struct PreferencesView: View {
    @AppStorage("shortcutEnabled") private var shortcutEnabled = true
    @AppStorage("startAtLogin") private var startAtLogin = true
    var body: some View {
        Form { Toggle("Atalho global ⌥⌘C", isOn: $shortcutEnabled); Toggle("Iniciar com o Mac", isOn: $startAtLogin); Text("As trocas afetam novas sessões do Claude Code.").foregroundStyle(.secondary) }.padding(20).frame(width: 360)
    }
}
