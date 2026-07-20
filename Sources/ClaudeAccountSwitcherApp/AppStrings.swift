import Foundation

enum AppStrings {
    static var portuguese: Bool { Locale.current.language.languageCode?.identifier == "pt" }
    static func t(_ pt: String, _ en: String) -> String { portuguese ? pt : en }
}
