import Foundation

/// 文字の変換（ひらがな・カタカナ・全角・半角）。
///
/// 2026-07-31 作者「半角カタカナ、全角カタカナなどに変換するショートカットもお願い。」
/// 日本語入力の F6〜F10 と同じ5種類をそろえてある。
///
/// ⚠️ 変換は「関係のある文字の連続する区間」だけに当てる。
/// ICUの変換（applyingTransform）を文字列全体にかけると、
/// 「全角英数→半角」のつもりが かな まで半角カナになる等、頼んでいない変化が混ざる。
/// 対象の文字だけを切り出し、その区間にだけ変換をかければ、他の文字は1文字も変わらない。
public enum TextTransform: String, CaseIterable, Codable, Sendable {
    case hiragana
    case katakana
    case halfKatakana
    case fullAscii
    case halfAscii

    public var title: String {
        switch self {
        case .hiragana: return "ひらがな"
        case .katakana: return "全角カタカナ"
        case .halfKatakana: return "半角カタカナ"
        case .fullAscii: return "全角英数"
        case .halfAscii: return "半角英数"
        }
    }

    public func apply(_ text: String) -> String {
        switch self {
        case .hiragana:
            // 半角カナも一度全角に起こしてから、ひらがなへ倒す（ﾊﾞｲｸ → バイク → ばいく）
            return Self.mapRuns(text, where: Self.isKana) {
                Self.icu(Self.icu($0, .fullwidthToHalfwidth, reverse: true), .hiraganaToKatakana, reverse: true)
            }
        case .katakana:
            return Self.mapRuns(text, where: Self.isKana) {
                Self.icu(Self.icu($0, .fullwidthToHalfwidth, reverse: true), .hiraganaToKatakana, reverse: false)
            }
        case .halfKatakana:
            // 濁点は分かれた2文字（ｶﾞ）になる。ICUが正しい形を作る
            return Self.mapRuns(text, where: Self.isKana) {
                Self.icu(Self.icu($0, .hiraganaToKatakana, reverse: false), .fullwidthToHalfwidth, reverse: false)
            }
        case .fullAscii:
            // 空白（0x20）は対象にしない。文の区切りまで全角空白になると直しにくい
            return Self.mapRuns(text, where: { (0x21...0x7E).contains($0.value) }) {
                Self.icu($0, .fullwidthToHalfwidth, reverse: true)
            }
        case .halfAscii:
            // 全角空白（U+3000）は半角空白へ。半角に戻したい人は空白も戻したいのが普通
            return Self.mapRuns(text, where: { (0xFF01...0xFF5E).contains($0.value) || $0.value == 0x3000 }) {
                Self.icu($0, .fullwidthToHalfwidth, reverse: false)
            }
        }
    }

    /// かな（変換の対象になる文字）か。
    /// 「。、「」」など CJK の句読点（U+3001〜）は含めない＝変換しても句読点は動かさない。
    private static func isKana(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x3041...0x309F,   // ひらがな（゛゜ゝゞ含む）
             0x30A0...0x30FF,   // カタカナ（ー・含む）
             0x31F0...0x31FF,   // 小書きカナ拡張
             0xFF61...0xFF9F:   // 半角カナ（｡｢｣､･ｰﾞﾟ含む）
            return true
        default:
            return false
        }
    }

    /// 対象の文字が連続する区間だけを変換し、それ以外は1文字も触らない
    private static func mapRuns(
        _ text: String,
        where isTarget: (Unicode.Scalar) -> Bool,
        _ change: (String) -> String
    ) -> String {
        var result = ""
        var run = ""
        for scalar in text.unicodeScalars {
            if isTarget(scalar) {
                run.unicodeScalars.append(scalar)
            } else {
                if !run.isEmpty { result += change(run); run = "" }
                result.unicodeScalars.append(scalar)
            }
        }
        if !run.isEmpty { result += change(run) }
        return result
    }

    private static func icu(_ text: String, _ transform: StringTransform, reverse: Bool) -> String {
        text.applyingTransform(transform, reverse: reverse) ?? text
    }
}

/// 文字の変換に割り当てるショートカット1件
public struct ConvertBinding: Codable, Equatable, Sendable {
    public var transform: TextTransform
    public var shortcut: Shortcut

    public init(transform: TextTransform, shortcut: Shortcut) {
        self.transform = transform
        self.shortcut = shortcut
    }
}
