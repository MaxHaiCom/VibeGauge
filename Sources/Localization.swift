import Foundation

/// 界面双语：面板右下角切过就用那个（UserDefaults `uiLanguage` = zh / en），没切过跟随系统首选语言。
var isChineseUI: Bool {
    switch UserDefaults.standard.string(forKey: "uiLanguage") {
    case "zh": return true
    case "en": return false
    default: return Locale.preferredLanguages.first?.hasPrefix("zh") ?? false
    }
}
@inline(__always) func L(_ zh: String, _ en: String) -> String { isChineseUI ? zh : en }
