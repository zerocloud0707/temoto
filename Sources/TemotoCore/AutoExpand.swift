import Foundation

/// どのアプリでも、合言葉を打った瞬間に定型文の本文へ置き換わる仕組みの「照合の決まり」。
///
/// 2026-08-10 作者「設定した単語を入力したら登録した文字が表示される機能。
/// この機能が実装されていないので、実装して。」
///
/// ⚠️ テモトの窓の中の合言葉（入口で mailz と打つと本文が出る）は既にある。
/// 無かったのは**テモトの外**＝メールでもメモ帳でも、打つそばから置き換わる方。
/// これはキーの流れを見張る仕組みなので、決まりごとを1つ間違えると
/// 「打った文字が勝手に消える」最悪の壊れ方をする。だから照合はここに置いて機械で縛る。
///
/// ⚠️ 名前について: `SnippetExpander` は既にいる（{date} 等の**差し込み**の展開）。
/// こちらは**打鍵の**展開なので AutoExpand。役目が違うものに似た名前を付けない。
public enum AutoExpand {

    /// 覚えておく打鍵の上限。
    /// ⚠️ 合言葉の照合に要るのは末尾だけ。長く持つほど、見張っている文字が増える。
    /// 覚える量は最小にする（この仕組みは打った文字をどこにも書かない・送らないが、
    /// そもそも**持たない**のが一番安全）。
    public static let bufferLimit = 32

    /// 合言葉として使える最短の長さ。
    /// ⚠️ 1文字の合言葉は事故のもと（「a」を登録すると a を打つたびに置き換わる）。
    public static let minKeywordLength = 2

    /// 照合の結果
    public struct Hit: Equatable, Sendable {
        /// 消す文字数（打たれた合言葉の長さ）
        public let deleteCount: Int
        /// 置き換える本文（差し込みは呼ぶ側が展開して渡す前提の生の形）
        public let body: String

        public init(deleteCount: Int, body: String) {
            self.deleteCount = deleteCount
            self.body = body
        }
    }

    /// 打鍵の並びの末尾が、どれかの合言葉と一致するか。
    ///
    /// 決まり（全部ここで縛る）:
    /// 1. **末尾一致**。打っている途中では反応しない
    /// 2. **直前が英数字なら反応しない**。「design」の中の「sig」で暴発しないため。
    ///    ⚠️ ただし ASCII の英数字だけを見る。日本語（かな・漢字）の直後は許す
    ///    （「請求書はmailz」のような打ち方が普通にあるため）
    /// 3. **長い合言葉が勝つ**（「sig」と「sign」が両方あれば sign）
    /// 4. 大文字小文字は区別しない。ただし消す文字数は**実際に打たれた長さ**
    /// 5. 2文字未満・空白入りの合言葉は無視（登録画面で入っても、ここで最後に止める）
    public static func match(typed: String,
                             snippets: [(keyword: String, body: String)]) -> Hit? {
        guard !typed.isEmpty else { return nil }
        let lowered = typed.lowercased()
        var best: (keyword: String, body: String)?
        for snippet in snippets {
            let keyword = snippet.keyword.trimmingCharacters(in: .whitespacesAndNewlines)
            guard keyword.count >= minKeywordLength,
                  !keyword.contains(where: { $0.isWhitespace }) else { continue }
            guard lowered.hasSuffix(keyword.lowercased()) else { continue }
            // 直前の文字（ASCII の英数字なら、単語の途中とみなす）
            if typed.count > keyword.count {
                let before = typed[typed.index(typed.endIndex, offsetBy: -(keyword.count + 1))]
                if before.isASCII && (before.isLetter || before.isNumber) { continue }
            }
            if best == nil || keyword.count > best!.keyword.count {
                best = (keyword, snippet.body)
            }
        }
        guard let best else { return nil }
        return Hit(deleteCount: best.keyword.count, body: best.body)
    }

    // MARK: - 打鍵の覚え方

    /// 文字を打った
    public static func buffer(_ current: String, appending text: String) -> String {
        let joined = current + text
        guard joined.count > bufferLimit else { return joined }
        return String(joined.suffix(bufferLimit))
    }

    /// ⌫ を打った
    public static func bufferAfterBackspace(_ current: String) -> String {
        String(current.dropLast())
    }
}
