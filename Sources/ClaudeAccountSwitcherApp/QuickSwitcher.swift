import SwiftUI
import ClaudeAccountSwitcherCore

struct QuickSwitcher: View {
    let profiles: [Profile]
    let activeID: UUID?
    let select: (Profile) -> Void
    @State private var query = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Buscar conta", text: $query).textFieldStyle(.roundedBorder)
            ForEach(profiles.filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) || ($0.email?.localizedCaseInsensitiveContains(query) ?? false) }, id: \.id) { profile in
                Button { select(profile) } label: { Label(profile.name, systemImage: profile.icon).frame(maxWidth: .infinity, alignment: .leading) }.buttonStyle(.plain).padding(4).background(profile.id == activeID ? Color.accentColor.opacity(0.15) : .clear)
            }
        }.padding(12).frame(width: 320)
    }
}
