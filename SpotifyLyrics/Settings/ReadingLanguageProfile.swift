import Foundation
import NaturalLanguage

public enum ReadingLanguageGroup: String, CaseIterable, Codable {
    case japanese, chinese, korean, other
    public var title: String {
        switch self {
        case .japanese: return "日语"
        case .chinese: return "中文"
        case .korean: return "韩语"
        case .other: return "其他语言"
        }
    }
    static func detect(_ text: String) -> Self {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        switch recognizer.dominantLanguage {
        case .japanese: return .japanese
        case .simplifiedChinese, .traditionalChinese: return .chinese
        case .korean: return .korean
        default: return .other
        }
    }
}

struct ReadingLanguageProfile: Codable {
    let original: Bool
    let translation: Bool
    let romaji: Bool
    let pinyin: Bool
    let kana: String
    init(_ preferences: DisplayPreferences) {
        original = preferences.showOriginal
        translation = preferences.showTranslation
        romaji = preferences.showRomaji
        pinyin = preferences.showPinyin
        kana = preferences.kanaDisplayMode.rawValue
    }
    func applying(to current: DisplayPreferences) -> DisplayPreferences {
        var value = current
        value.showOriginal = original
        value.showTranslation = translation
        value.showRomaji = romaji
        value.showPinyin = pinyin
        value.kanaDisplayMode = KanaDisplayMode(rawValue: kana) ?? .independentLine
        return value
    }
}
