import Foundation

/// 定型文を探すときに、題名のほかに当てにいく文字。
///
/// 🔴 2026-08-02 作者「スニペット機能がうまく機能していない。」
/// 定型文の画面で**読みがなを打つと、その定型文が一覧から消えていた**。
/// 検索の当て先が題名だけで、「検索で当てるために作った欄」であるはずの
/// 読みがなも、中身である本文も見ていなかった。
/// （例: 題名「mail_ゼロクラウド」・読みがな mailz で `mailz` と打つと、
///  `z` が題名に無いのであいまい検索が外れ、0件になる）
public enum SnippetSearch {

    /// 本文をどこまで当て先にするか。
    /// ⚠️ 長い本文をまるごと入れない。ありふれた1文字が全部の定型文に当たり、
    /// 一覧が「全部出る」＝絞れない画面になる。頭の200字あれば用は足りる。
    public static let bodyLimit = 200

    public static func aliases(for snippet: Snippet) -> [String] {
        var out: [String] = []

        let keyword = snippet.keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        if !keyword.isEmpty {
            out.append(keyword)
            // 漢字やかなの読みがなは、ローマ字でも引けるようにする（IMEを切らずに打てる）
            out += JapaneseReading.keys(for: keyword)
        }

        let body = snippet.body.trimmingCharacters(in: .whitespacesAndNewlines)
        if !body.isEmpty {
            out.append(String(body.prefix(bodyLimit)))
        }

        // 同じ文字を二度当てても意味が無い（順番は保つ）
        var seen = Set<String>()
        return out.filter { seen.insert($0).inserted }
    }
}

/// 打った言葉の「言い換え」。
///
/// ⚠️ 日本語入力（IME）が入ったままローマ字を打つと、検索欄に来るのは変換中のかな
/// （mailz → まいｌｚ）。そのままでは英字の名前にも読みがなにも当たらない。
/// 打った言葉で1件も見つからないときだけ、ローマ字に起こした形でもう一度探す。
///
/// ⚠️ 「見つからないときだけ」に限る理由。
/// いつも両方で探すと、かなで正しく絞れている一覧に英字の当たりが混ざって、
/// 打つほど結果が増える（＝絞れない）画面になる。
public enum SearchQuery {

    /// ローマ字に起こした言い換え。かなを含まない・変わらないなら nil
    public static func romajiAlternative(for query: String) -> String? {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        // かなが1文字も無ければ言い換える必要が無い
        guard trimmed.unicodeScalars.contains(where: { (0x3041...0x30FF).contains($0.value) }) else {
            return nil
        }
        let folded = String(FuzzyMatcher.fold(trimmed))
        let romaji = JapaneseReading.normalizeRomaji(JapaneseReading.romaji(of: folded))
        guard !romaji.isEmpty, romaji != folded else { return nil }
        return romaji
    }
}
