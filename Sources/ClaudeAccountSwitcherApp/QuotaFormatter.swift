import Foundation
import ClaudeAccountSwitcherCore

/// Formatação compartilhada de cotas e datas de reset. Centraliza o que estava duplicado em
/// `MenuBarController`, `PreferencesView` e `UsageView`, e cacheia os `DateFormatter` (antes
/// recriados a cada chamada/render — ver issue #10). Usado apenas na UI (MainActor).
enum QuotaFormatter {
    // DateFormatter é caro de criar; um `static let` reaproveita a instância. `nonisolated(unsafe)`
    // porque só é lido (nunca reconfigurado) e sempre a partir da UI na MainActor.
    nonisolated(unsafe) private static let timeOnly: DateFormatter = {
        let f = DateFormatter(); f.dateStyle = .none; f.timeStyle = .short; return f
    }()
    nonisolated(unsafe) private static let dateAndTime: DateFormatter = {
        let f = DateFormatter(); f.dateStyle = .short; f.timeStyle = .short; return f
    }()

    /// "às HH:MM" quando o reset é hoje; senão "em dd/MM/aa HH:MM".
    static func resetDescription(_ date: Date) -> String {
        if Calendar.current.isDateInToday(date) {
            return AppStrings.t("às \(timeOnly.string(from: date))", "at \(timeOnly.string(from: date))")
        }
        return AppStrings.t("em \(dateAndTime.string(from: date))", "on \(dateAndTime.string(from: date))")
    }

    /// Hora curta do reset (sem prefixo), usada onde o texto ao redor já dá o contexto.
    static func resetTime(_ date: Date) -> String { timeOnly.string(from: date) }

    static func percent(_ usedPercent: Double) -> String { "\(Int(usedPercent.rounded()))%" }
}
