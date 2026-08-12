import Foundation

/// 日本語の項目を「読み」で引けるようにする。
///
/// ⚠️ これがテモトを作る理由そのもの。
///   作者「UIが英語しか対応していない」
/// 「定型文」を探すのに、いちいち IME を日本語に切り替えて「ていけい」と打たせない。
/// `teikei` のまま当たるようにする。
///
/// やっていること:
///   1. 表示名を読み（ローマ字）に変換する    定型文 → teikeibun
///   2. そのローマ字をひらがなに戻す          teikeibun → ていけいぶん
///   3. どちらも「別名」として検索の対象に足す
///
/// 約束するのは1つだけ:
///   **日本語で名付けた項目は、ローマ字のままでも引ける。**
///   だから相手にするのは「英字キーボードで打てない字を含む名前」に限る。
///   英字だけの名前まで変換すると2000件で300msかかり、1打鍵目が引っかかる。
public enum JapaneseReading {

    /// 読みを作る価値があるか（そのままでは英字で打てない字を含むか）。
    ///
    /// 判断の基準は「日本語かどうか」ではなく **「英字キーボードで打てないか」**。
    /// 打てない字が1つでもあるなら、ローマ字の別名が要る。
    ///
    /// ⚠️ 英字だけの名前（Safari, Google Chrome …）はここで弾く。
    /// アプリ一覧の大半はこれなので、弾かないと1打鍵目に300ms持っていかれる。
    public static func needsReading(_ text: String) -> Bool {
        text.unicodeScalars.contains { scalar in
            let v = scalar.value
            return (0x4E00...0x9FFF).contains(v)   // 漢字
                || (0x3400...0x4DBF).contains(v)   // 漢字（拡張A）
                || v == 0x3005                     // 々
                || (0x3041...0x309F).contains(v)   // ひらがな
                || (0x30A1...0x30FF).contains(v)   // カタカナ（ー を含む）
        }
    }

    /// 表示名 → ローマ字。作れなければ空文字。
    ///
    /// ⚠️ ICU の「Any-Latin」は漢字を中国語のピンインにしてしまう（定型文 → ding xing wen）。
    /// 日本語の読みが要るので、日本語の区切り器に読みを聞く。
    public static func romaji(of text: String) -> String {
        let tokenizer = CFStringTokenizerCreate(
            kCFAllocatorDefault,
            text as CFString,
            CFRangeMake(0, (text as NSString).length),
            kCFStringTokenizerUnitWordBoundary,
            Locale(identifier: "ja_JP") as CFLocale
        )
        var out = ""
        while !CFStringTokenizerAdvanceToNextToken(tokenizer).isEmpty {
            let attribute = CFStringTokenizerCopyCurrentTokenAttribute(
                tokenizer, kCFStringTokenizerAttributeLatinTranscription)
            guard let piece = attribute as? String else { continue }
            out += piece
        }
        return normalizeRomaji(out)
    }

    /// ローマ字を素の英字にそろえる。
    ///
    /// 読みには `kopīrireki` の伸ばし記号や `u~indou` の波が混ざる。
    /// そのままだと `kopiirireki` と打っても当たらないので、
    /// 記号を落として a〜z と数字だけにする。
    public static func normalizeRomaji(_ text: String) -> String {
        // ī → i のように、飾りを分解してから落とす
        let decomposed = text.folding(options: [.diacriticInsensitive, .widthInsensitive], locale: nil)
        return String(decomposed.lowercased().unicodeScalars.filter { scalar in
            let v = scalar.value
            return (97...122).contains(v) || (48...57).contains(v)
        }.map(Character.init))
    }

    /// ローマ字 → ひらがな（teikeibun → ていけいぶん）
    public static func hiragana(ofRomaji romaji: String) -> String {
        guard !romaji.isEmpty else { return "" }
        let buffer = NSMutableString(string: romaji)
        CFStringTransform(buffer as CFMutableString, nil, kCFStringTransformLatinHiragana, false)
        return buffer as String
    }

    /// 表示名から別名（探すための読み）を作る。漢字が無ければ空。
    ///
    /// 返す順番は「ローマ字 → ひらがな」で固定する。
    /// 検索は先に当たった方を採るので、順番が揺れると同じ入力で結果が変わって見える。
    public static func keys(for text: String) -> [String] {
        guard needsReading(text) else { return [] }
        let roman = romaji(of: text)
        guard !roman.isEmpty else { return [] }
        let kana = hiragana(ofRomaji: roman)

        var keys = [roman]
        // 変換が効かず英字のまま返ってきたら、同じものを2つ持たない
        if !kana.isEmpty, kana != roman { keys.append(kana) }
        return keys
    }
}

/// 読みの作り置き。
///
/// 読みを作るのは1件あたり0.15msほどかかる。打つたびに全項目ぶん作り直すと
/// 検索窓が目に見えて引っかかるので、一度作ったものを覚えておく。
///
/// ⚠️ 共有の置き場（static）にしていないのは、消し時が誰にも分からなくなるため。
/// 使う側（検索窓）が1つ持って、その一生と一緒に消える形にしている。
public final class ReadingIndex {

    private var cache: [String: [String]] = [:]

    /// 覚えておく上限。アプリ一覧が数千あっても、実際に検索に出るのはごく一部。
    private let limit: Int

    public init(limit: Int = 4000) {
        self.limit = max(limit, 1)
    }

    public func keys(for text: String) -> [String] {
        if let hit = cache[text] { return hit }
        let made = JapaneseReading.keys(for: text)
        // 上限を超えたら諦めて作り直す（際限なく抱えない・件数だけ見て捨てる）
        if cache.count >= limit { cache.removeAll(keepingCapacity: true) }
        cache[text] = made
        return made
    }

    public var count: Int { cache.count }

    public func clear() { cache.removeAll(keepingCapacity: true) }
}
