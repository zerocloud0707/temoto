import Foundation

/// 合言葉（辞書引き）。
///
/// 2026-08-02 作者「例えばmailsと入力したらtaro@example.comと表示されたり、
/// これを辞書機能っていうのかな？？特定の文字列を入力したら設定した項目が表示される様にしたい。」
///
/// 新しい入れ物は作らない。定型文が持っている「読みがな」を入口の合言葉として使う。
/// 打った文字が読みがなに**ぴったり一致**したときだけ、本文を入口の先頭に出す。
///
/// ⚠️ ぴったり一致に限る理由。
/// 部分一致やあいまい一致にすると、何か打つたびに定型文が入口へ紛れ込み、
/// 「入口に並べてよいのは行き先とコマンドだけ」の決めごとが崩れる。
/// 合言葉は「引く」もの＝全部打ったときだけ答える、が辞書の振る舞い。
public enum SnippetDictionary {

    /// 打った文字が読みがなに一致した定型文を返す（定型文の並び順のまま）。
    ///
    /// 一致はあいまい検索と同じ畳み込みで見る＝大文字小文字・全角半角・
    /// ひらがなカタカナの違いは無視する（ＭＡＩＬＳ でも めーる/メール でも引ける）。
    ///
    /// ⚠️ さらに**ローマ字の読みでも突き合わせる**。
    /// 日本語入力（IME）が入ったまま mailz と打つと、検索欄に来るのは
    /// 変換中の「まいｌｚ」で、文字のままでは mailz と一致しない
    /// （2026-08-02 作者「mailzと入力してもtaro@example.comが表示されない」）。
    /// かなをローマ字に起こして比べれば、まいｌｚ → mailz で引ける。
    /// IMEを切り替えずに合言葉が引けることは、この機能の使い物になる/ならないの分かれ目。
    public static func hits(for query: String, in snippets: [Snippet]) -> [Snippet] {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let typed = FuzzyMatcher.fold(trimmedQuery)
        guard !typed.isEmpty else { return [] }
        let typedRomaji = romajiKey(trimmedQuery)

        return snippets.filter { snippet in
            let trimmedKeyword = snippet.keyword.trimmingCharacters(in: .whitespacesAndNewlines)
            let keyword = FuzzyMatcher.fold(trimmedKeyword)
            guard !keyword.isEmpty else { return false }
            if keyword == typed { return true }
            // ローマ字の読みで一致（どちらの側がかなでもよい）
            let keywordRomaji = romajiKey(trimmedKeyword)
            return !keywordRomaji.isEmpty && keywordRomaji == typedRomaji
        }
    }

    /// ローマ字に起こした比較用の形（かな→ローマ字・英字はそのまま・整えは共通の正規化）
    private static func romajiKey(_ text: String) -> String {
        let folded = String(FuzzyMatcher.fold(text))
        return JapaneseReading.normalizeRomaji(JapaneseReading.romaji(of: folded))
    }

    /// 入口の行に出す1行（差し込みを展開した本文の1行目）。
    ///
    /// ⚠️ 展開してから出す。mails → {date} を含む本文なら、今日の日付が入った
    /// 「実際に貼られるもの」を見せる（{date} という記号を見せられても確かめようがない）。
    public static func displayLine(for snippet: Snippet, context: SnippetContext) -> String {
        let expanded = SnippetExpander.expand(snippet.body, context: context)
        let lines = expanded.split(separator: "\n", omittingEmptySubsequences: true)
        guard let first = lines.first else { return "" }
        let head = first.trimmingCharacters(in: .whitespaces)
        return lines.count > 1 ? head + " …" : head
    }
}
