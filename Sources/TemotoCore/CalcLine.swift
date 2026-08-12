import Foundation

/// 計算の行き先で使う「1行ずつの計算」。
///
/// 2026-08-10 作者「計算機能無くなった？？計算ようのメニューが欲しい。計算機能強めて。」
///
/// ⚠️ 「無くなった」と見えた理由は、**行き先の一覧に無かったから**。
/// 計算は入口で式を打てば動いていたが、一覧に名前が無いので存在に気づけない。
/// 動いているかどうかより、**在ると分かるかどうか**の方が先だった。
///
/// ⚠️ 入口の「打ったら答えが出る」はそのまま残す。あれは探しものの片手間に使うもの。
/// こちらは**腰を据えて計算する場所**で、続けて打てる・履歴が残る・前の答えを使える。
public enum CalcLine {

    /// 1行分の計算
    public struct Line: Equatable, Sendable {
        /// 打った式
        public let input: String
        /// 答え（読める形・1,234,567）
        public let display: String
        /// 生の数（貼り付けるのはこちら）
        public let value: Double
        /// 添える説明（123万4567・税込 1,358,023 など）
        public let detail: String

        public init(input: String, display: String, value: Double, detail: String) {
            self.input = input
            self.display = display
            self.value = value
            self.detail = detail
        }
    }

    /// 直前の答えを指す言葉。
    /// ⚠️ `ans` だけでなく日本語も受ける。英語の略語を覚えないと使えない道具にしない。
    public static let previousWords = ["ans", "ANS", "前", "答え", "こたえ", "けっか", "結果"]

    /// 打った式の中の「前の答え」を、実際の数に置き換える。
    ///
    /// ⚠️ 置き換えるのは**言葉が単独で現れたとき**だけ…にはしない。
    /// `ans*1.1` のように続けて打つのが普通なので、そのまま数に差し替える。
    /// ただし前の答えが無いときは触らない（`前` という字を含む検索語を壊さないため）。
    public static func substitutePrevious(_ text: String, previous: Double?) -> String {
        guard let previous else { return text }
        var out = text
        // ⚠️ 長い言葉から先に置き換える。「答え」を先に潰すと「前」だけが残る、が起きる
        for word in previousWords.sorted(by: { $0.count > $1.count }) {
            out = out.replacingOccurrences(of: word, with: trimZeros(previous))
        }
        return out
    }

    /// 打った式を1行に変える。答えが出なければ nil
    public static func line(for input: String, previous: Double? = nil) -> Line? {
        let raw = input.trimmingCharacters(in: .whitespaces)
        guard !raw.isEmpty else { return nil }
        let substituted = substitutePrevious(raw, previous: previous)
        guard let value = Arithmetic.evaluate(substituted), value.isFinite else { return nil }
        let rounded = (value * 100).rounded() / 100
        return Line(input: raw,
                    display: QuickAnswer.grouped(rounded),
                    value: rounded,
                    detail: details(for: rounded).joined(separator: "　"))
    }

    /// 答えに添える説明。
    ///
    /// ⚠️ 出すのは**その場で役に立つものだけ**。
    /// 会計の仕事で毎回いるのは「漢数字の読み」と「税込・税抜」。
    /// 平方根や三角関数を並べても、この人の1日には一度も出てこない。
    public static func details(for value: Double) -> [String] {
        var parts: [String] = []
        let plain = trimZeros(value)
        if let japanese = JapaneseNumber.spell(value), japanese != plain {
            parts.append(japanese)
        }
        // 税込・税抜は整数の金額に見えるときだけ（3.14 の税込に意味は無い）。
        // ⚠️ マイナスには出さない。切り捨ての向きが実務で決まっていないので、
        // テモトが勝手に決めない（決められないものは黙る）。
        if value == value.rounded(), value >= 1, value < 1_000_000_000_000 {
            parts.append("税込 \(QuickAnswer.grouped((value * 1.1).rounded(.down)))")
            parts.append("税抜 \(QuickAnswer.grouped((value / 1.1).rounded(.down)))")
        }
        return parts
    }

    public static func trimZeros(_ value: Double) -> String {
        value == value.rounded()
            ? String(Int(value))
            : String(format: "%.2f", value).replacingOccurrences(of: "0$", with: "", options: .regularExpression)
    }

    // MARK: - 使い方の見本

    /// 何も打っていないときに出す見本。
    ///
    /// ⚠️ 空の画面に「式を打ってください」とだけ出さない。
    /// **何が書けるのかが分からない**のが、計算の道具が使われなくなる一番の理由。
    /// 打てる形をそのまま並べて、真似できるようにする。
    public static let examples: [(input: String, note: String)] = [
        ("1234567*1.1", "掛ける・割る・足す・引く"),
        ("(1200+800)*3", "かっこも使えます"),
        ("3万+5000", "万・億でも打てます"),
        ("1980*0.08", "8%を出す"),
        ("ans/12", "前の答えを続けて使う（ans・前・答え）"),
    ]
}
