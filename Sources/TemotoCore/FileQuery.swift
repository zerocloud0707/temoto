import Foundation

/// ファイル検索の「読み取り」係。
///
/// ⚠️ ここに AppKit も NSMetadataQuery も持ち込まない。
/// 検索欄に打たれた文字を、どういう意味に取ったのかを決めるのがこのファイルの仕事で、
/// そこが一番間違えやすい（＝一番検証したい）ところだから。
/// 実際に Spotlight を回すのは Temoto 側の FileSearcher。
///
/// 設計の芯:
/// - 打った言葉を**日本語のまま**絞り込みに使う（`pdf 今週 1MB以上`）
/// - ただし「pdf という名前のファイル」を探したい人のために `名前:pdf` の逃げ道を必ず残す
/// - 何をどう解釈したかを画面に出す（`summary`）。黙って絞ると「出ない」と誤解される

// MARK: - 種類

public enum FileKind: String, CaseIterable, Sendable {
    case pdf
    case image
    case movie
    case audio
    case document
    case spreadsheet
    case presentation
    case text
    case code
    case archive
    case folder
    case app

    public var title: String {
        switch self {
        case .pdf: return "PDF"
        case .image: return "画像"
        case .movie: return "動画"
        case .audio: return "音声"
        case .document: return "文書"
        case .spreadsheet: return "表計算"
        case .presentation: return "スライド"
        case .text: return "テキスト"
        case .code: return "コード"
        case .archive: return "圧縮"
        case .folder: return "フォルダ"
        case .app: return "アプリ"
        }
    }

    /// これを打つとこの種類に絞られる言葉。
    /// ⚠️ 小文字で比較する。日本語と英語の両方を受ける（作者は日本語、検索は英語混じりになりがち）。
    public var words: [String] {
        switch self {
        case .pdf: return ["pdf"]
        case .image: return ["画像", "写真", "image", "images", "img", "photo"]
        case .movie: return ["動画", "映像", "movie", "video", "mp4"]
        case .audio: return ["音声", "音楽", "audio", "music", "mp3"]
        case .document: return ["文書", "ワード", "word", "doc", "docx", "pages"]
        case .spreadsheet: return ["表計算", "エクセル", "excel", "xls", "xlsx", "csv", "numbers"]
        case .presentation: return ["スライド", "パワポ", "powerpoint", "ppt", "pptx", "keynote"]
        case .text: return ["テキスト", "text", "txt", "md", "markdown"]
        case .code: return ["コード", "code", "ソース", "source"]
        case .archive: return ["圧縮", "zip", "アーカイブ", "archive"]
        case .folder: return ["フォルダ", "folder", "ディレクトリ", "directory"]
        case .app: return ["アプリ", "app", "アプリケーション", "application"]
        }
    }

    /// Spotlight の `kMDItemContentTypeTree` に当てる UTI。
    /// ツリーなので、親（public.image など）を指定すれば PNG も JPEG も HEIC も入る。
    public var contentTypes: [String] {
        switch self {
        case .pdf: return ["com.adobe.pdf"]
        case .image: return ["public.image"]
        case .movie: return ["public.movie"]
        case .audio: return ["public.audio"]
        case .document:
            return ["com.microsoft.word.doc",
                    "org.openxmlformats.wordprocessingml.document",
                    "com.apple.iwork.pages.pages",
                    "public.rtf"]
        case .spreadsheet:
            return ["com.microsoft.excel.xls",
                    "org.openxmlformats.spreadsheetml.sheet",
                    "com.apple.iwork.numbers.numbers",
                    "public.comma-separated-values-text"]
        case .presentation:
            return ["com.microsoft.powerpoint.ppt",
                    "org.openxmlformats.presentationml.presentation",
                    "com.apple.iwork.keynote.key"]
        case .text: return ["public.plain-text", "net.daringfireball.markdown"]
        case .code: return ["public.source-code"]
        case .archive: return ["public.archive", "public.zip-archive"]
        case .folder: return ["public.folder"]
        case .app: return ["com.apple.application-bundle"]
        }
    }

    static func matching(_ word: String) -> FileKind? {
        let lower = word.lowercased()
        return allCases.first { $0.words.contains(lower) }
    }
}

// MARK: - 日付

public enum FileDateFilter: String, CaseIterable, Sendable {
    case today
    case yesterday
    case thisWeek
    case thisMonth
    case thisYear
    case lastMonth
    case lastYear
    case last7Days
    case last30Days

    public var title: String {
        switch self {
        case .today: return "今日"
        case .yesterday: return "昨日"
        case .thisWeek: return "今週"
        case .thisMonth: return "今月"
        case .thisYear: return "今年"
        case .lastMonth: return "先月"
        case .lastYear: return "去年"
        case .last7Days: return "1週間以内"
        case .last30Days: return "1ヶ月以内"
        }
    }

    public var words: [String] {
        switch self {
        case .today: return ["今日", "きょう", "today"]
        case .yesterday: return ["昨日", "きのう", "yesterday"]
        case .thisWeek: return ["今週", "こんしゅう", "thisweek"]
        case .thisMonth: return ["今月", "こんげつ", "thismonth"]
        case .thisYear: return ["今年", "ことし", "thisyear"]
        case .lastMonth: return ["先月", "せんげつ", "lastmonth"]
        case .lastYear: return ["去年", "昨年", "きょねん", "lastyear"]
        case .last7Days: return ["1週間以内", "一週間以内", "7日以内", "week"]
        case .last30Days: return ["1ヶ月以内", "1か月以内", "一ヶ月以内", "30日以内", "month"]
        }
    }

    /// - Parameter now: 「今」を外から渡す。
    ///   ここを `Date()` で内側から取ると、検証のたびに答えが変わって確かめようがなくなる。
    public func range(now: Date, calendar: Calendar = FileDateFilter.japaneseCalendar) -> (start: Date?, end: Date?) {
        let startOfToday = calendar.startOfDay(for: now)
        switch self {
        case .today:
            return (startOfToday, calendar.date(byAdding: .day, value: 1, to: startOfToday))
        case .yesterday:
            let start = calendar.date(byAdding: .day, value: -1, to: startOfToday)
            return (start, startOfToday)
        case .thisWeek:
            let start = calendar.dateInterval(of: .weekOfYear, for: now)?.start
            return (start, nil)
        case .thisMonth:
            let start = calendar.dateInterval(of: .month, for: now)?.start
            return (start, nil)
        case .thisYear:
            let start = calendar.dateInterval(of: .year, for: now)?.start
            return (start, nil)
        case .lastMonth:
            guard let thisMonthStart = calendar.dateInterval(of: .month, for: now)?.start,
                  let start = calendar.date(byAdding: .month, value: -1, to: thisMonthStart) else {
                return (nil, nil)
            }
            return (start, thisMonthStart)
        case .lastYear:
            guard let thisYearStart = calendar.dateInterval(of: .year, for: now)?.start,
                  let start = calendar.date(byAdding: .year, value: -1, to: thisYearStart) else {
                return (nil, nil)
            }
            return (start, thisYearStart)
        case .last7Days:
            return (calendar.date(byAdding: .day, value: -7, to: now), nil)
        case .last30Days:
            return (calendar.date(byAdding: .day, value: -30, to: now), nil)
        }
    }

    /// 週の始まりを月曜にした暦。
    /// 既定（日曜始まり）のままだと、月曜の朝に「今週」と打った人に前の週の分まで出てしまう。
    public static let japaneseCalendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.locale = Locale(identifier: "ja_JP")
        c.timeZone = TimeZone.current
        c.firstWeekday = 2
        return c
    }()

    static func matching(_ word: String) -> FileDateFilter? {
        let lower = word.lowercased()
        return allCases.first { $0.words.contains(lower) }
    }
}

// MARK: - 並べ替え

public enum FileSort: String, CaseIterable, Sendable {
    case recent
    case name
    case size
    case opened

    public var title: String {
        switch self {
        case .recent: return "更新が新しい順"
        case .name: return "名前順"
        case .size: return "大きい順"
        case .opened: return "最近開いた順"
        }
    }

    public var words: [String] {
        switch self {
        case .recent: return ["更新順", "新しい順", "recent"]
        case .name: return ["名前順", "name"]
        case .size: return ["大きさ順", "サイズ順", "大きい順", "size"]
        case .opened: return ["開いた順", "最近開いた順", "opened"]
        }
    }

    /// Spotlight の並べ替えキー
    public var key: String {
        switch self {
        case .recent: return "kMDItemContentModificationDate"
        case .name: return "kMDItemFSName"
        case .size: return "kMDItemFSSize"
        case .opened: return "kMDItemLastUsedDate"
        }
    }

    public var ascending: Bool { self == .name }

    static func matching(_ word: String) -> FileSort? {
        let lower = word.lowercased()
        return allCases.first { $0.words.contains(lower) }
    }
}

// MARK: - 探す対象（名前か中身か）

/// 自由語（`DEF` など）をどこに当てるか。
///
/// ⚠️ これが要る理由（2026-07-30 作者「本文検索とファイル名検索を選択できる様にして欲しい」）。
/// 既定の「名前と中身」で `DEF` と打つと、**中身にDEFと書いてあるだけの extension.js** まで並び、
/// 名前に DEF が付いた本命が埋もれる。1語ずつなら `名前:DEF` で逃げられるが、
/// 検索ぜんぶを名前だけに切り替える言葉が無かった。
///
/// `名前:` `中身:` が**語ごと**の指定なのに対し、こちらは**検索ぜんぶ**の切り替え。
/// 両方書いたときは語ごとの指定が勝つ（`名前だけ 中身:見積` は名前でDEF・中身で見積）。
///
/// ⚠️ **既定は「名前だけ」**（2026-07-30 作者「デフォルトは名前検索で」）。
/// 中身まで見ると、本文にその語が書いてあるだけのファイルが山ほど並び、
/// 名前に付いた本命が埋もれる（DEF検索で実際に起きた）。中身は「中身も」と頼んだときだけ。
public enum FileSearchScope: String, CaseIterable, Sendable {
    /// 既定。名前だけに当てる
    case nameOnly
    /// 名前でも中身でも当てる
    case both
    /// 中身だけに当てる
    case contentOnly

    public var title: String {
        switch self {
        case .nameOnly: return "名前だけ"
        case .both: return "名前と中身"
        case .contentOnly: return "中身だけ"
        }
    }

    /// これを打つとこの対象に切り替わる言葉。既定（nameOnly）は何も打たない状態がそれだが、
    /// 「名前だけ」と打っても効く（保存した条件や口癖のため）
    public var words: [String] {
        switch self {
        case .nameOnly: return ["名前だけ", "なまえだけ", "ファイル名だけ", "nameonly"]
        case .both: return ["中身も", "なかみも", "名前と中身", "全文"]
        case .contentOnly: return ["中身だけ", "本文だけ", "なかみだけ", "contentonly"]
        }
    }

    static func matching(_ word: String) -> FileSearchScope? {
        let lower = word.lowercased()
        return allCases.first { $0.words.contains(lower) }
    }
}

// MARK: - 大きさ

public enum FileSizeToken {
    /// 「10MB以上」「500KB以下」を (バイト数, 以上か) に読む。
    /// 読めなければ nil を返して、ただの検索語として扱わせる。
    public static func parse(_ token: String) -> (bytes: Int64, isMinimum: Bool)? {
        let lower = token.lowercased()
        let minimumSuffixes = ["以上", "超", "over", "+"]
        let maximumSuffixes = ["以下", "未満", "under", "-"]

        var body = lower
        var isMinimum = true
        var matched = false
        for suffix in minimumSuffixes where lower.hasSuffix(suffix) {
            body = String(lower.dropLast(suffix.count)); isMinimum = true; matched = true; break
        }
        if !matched {
            for suffix in maximumSuffixes where lower.hasSuffix(suffix) {
                body = String(lower.dropLast(suffix.count)); isMinimum = false; matched = true; break
            }
        }
        guard matched else { return nil }
        guard let bytes = bytes(from: body) else { return nil }
        return (bytes, isMinimum)
    }

    static func bytes(from body: String) -> Int64? {
        let units: [(String, Int64)] = [
            ("gb", 1_073_741_824), ("g", 1_073_741_824), ("ギガ", 1_073_741_824),
            ("mb", 1_048_576), ("m", 1_048_576), ("メガ", 1_048_576),
            ("kb", 1024), ("k", 1024), ("キロ", 1024),
            ("byte", 1), ("b", 1)
        ]
        for (suffix, multiplier) in units where body.hasSuffix(suffix) {
            let number = String(body.dropLast(suffix.count)).trimmingCharacters(in: .whitespaces)
            guard let value = Double(number), value >= 0 else { return nil }
            return Int64(value * Double(multiplier))
        }
        return nil
    }

    public static func label(_ bytes: Int64) -> String {
        ByteSize.label(Int(clamping: bytes))
    }
}

// MARK: - 打たれた言葉

public struct FileQuery: Equatable, Sendable {
    /// 名前でも中身でも当てにいく自由語
    public var terms: [String] = []
    /// `名前:` で名前だけに当てると決めた語
    public var nameTerms: [String] = []
    /// `中身:` で本文だけに当てると決めた語
    public var contentTerms: [String] = []
    public var kinds: [FileKind] = []
    public var date: FileDateFilter?
    public var minBytes: Int64?
    public var maxBytes: Int64?
    /// `場所:` で指定されたフォルダ（言葉のまま。実際のパスに直すのは FileScope の仕事）
    public var folder: String?
    public var sort: FileSort = .recent
    /// 自由語を名前に当てるか中身に当てるか（既定は名前だけ）
    public var scope: FileSearchScope = .nameOnly

    public init() {}

    /// 検索欄の文字を読む。
    ///
    /// ⚠️ 修飾子と見なすのは**トークン丸ごと一致**のときだけ。
    /// 「pdfの作り方.txt」を探して `pdfの作り方` と打った人が、PDF に絞られては困る。
    public static func parse(_ raw: String) -> FileQuery {
        var query = FileQuery()
        let tokens = raw
            .replacingOccurrences(of: "　", with: " ")   // 全角空白も区切りにする
            .split(separator: " ")
            .map(String.init)
            .filter { !$0.isEmpty }

        for token in tokens {
            if let value = prefixed(token, ["名前:", "なまえ:", "name:", "名前：", "name："]) {
                if !value.isEmpty { query.nameTerms.append(value) }
                continue
            }
            if let value = prefixed(token, ["中身:", "なかみ:", "本文:", "content:", "中身：", "本文："]) {
                if !value.isEmpty { query.contentTerms.append(value) }
                continue
            }
            if let value = prefixed(token, ["場所:", "フォルダ:", "path:", "in:", "場所：", "フォルダ："]) {
                if !value.isEmpty { query.folder = value }
                continue
            }
            if let kind = FileKind.matching(token) {
                if !query.kinds.contains(kind) { query.kinds.append(kind) }
                continue
            }
            if let date = FileDateFilter.matching(token) {
                query.date = date
                continue
            }
            if let sort = FileSort.matching(token) {
                query.sort = sort
                continue
            }
            if let scope = FileSearchScope.matching(token) {
                query.scope = scope
                continue
            }
            if let size = FileSizeToken.parse(token) {
                if size.isMinimum { query.minBytes = size.bytes } else { query.maxBytes = size.bytes }
                continue
            }
            query.terms.append(token)
        }
        return query
    }

    private static func prefixed(_ token: String, _ prefixes: [String]) -> String? {
        for prefix in prefixes where token.hasPrefix(prefix) {
            return String(token.dropFirst(prefix.count))
        }
        return nil
    }

    /// 語がひとつも無い＝全件になってしまう検索かどうか。
    /// 絞りだけ（`pdf 今週`）なら回してよい。何も無いときだけ止める。
    public var isRunnable: Bool {
        !terms.isEmpty || !nameTerms.isEmpty || !contentTerms.isEmpty
            || !kinds.isEmpty || date != nil || minBytes != nil || maxBytes != nil || folder != nil
    }

    /// 中身まで見にいく検索語があるか（設定で本文検索を切っているときの判断に使う）
    public var wantsContentSearch: Bool {
        !contentTerms.isEmpty || (!terms.isEmpty && scope != .nameOnly)
    }

    /// 本文検索を切っているのに中身で探そうとしている状態（`中身:` または「中身だけ」）。
    ///
    /// ⚠️ このとき黙って回すと、中身の条件だけが**静かに落ちて**、
    /// 残りの絞り（今月など）だけで全然違う結果が並ぶ。理由を言って止める。
    /// 自由語（`請求書`）は名前でも当てにいけるので、既定（both）では止めない。
    public func isContentSearchBlocked(searchesContent: Bool) -> Bool {
        guard !searchesContent else { return false }
        if !contentTerms.isEmpty { return true }
        return scope == .contentOnly && !terms.isEmpty
    }

    /// 「こう受け取りました」を画面に出すための一行。
    /// ⚠️ 黙って絞り込むと、出てこない理由が分からないまま「使えない」と判断される。
    public func summary(searchesContent: Bool) -> String {
        var parts: [String] = []
        if !kinds.isEmpty { parts.append(kinds.map(\.title).joined(separator: "・")) }
        if let date { parts.append(date.title) }
        if let minBytes { parts.append("\(FileSizeToken.label(minBytes))以上") }
        if let maxBytes { parts.append("\(FileSizeToken.label(maxBytes))以下") }
        if let folder { parts.append("場所 \(folder)") }
        if !nameTerms.isEmpty { parts.append("名前に「\(nameTerms.joined(separator: " "))」") }
        if !contentTerms.isEmpty { parts.append("中身に「\(contentTerms.joined(separator: " "))」") }
        if !terms.isEmpty {
            let where_: String
            switch scope {
            case .nameOnly: where_ = "名前"
            case .contentOnly: where_ = "中身"
            case .both: where_ = searchesContent ? "名前と中身" : "名前"
            }
            parts.append("\(where_)に「\(terms.joined(separator: " "))」")
        }
        if parts.isEmpty { return "" }
        return parts.joined(separator: "／") + " で絞り込み"
    }

    /// Spotlight に渡す条件式。
    ///
    /// - Parameters:
    ///   - searchesContent: 本文まで見るか（設定。切ると速いが「中身:」は効かなくなる）
    ///   - now: 「今日」等の基準時刻。外から渡すのは検証のため。
    /// - Returns: 条件が1つも組めなければ nil。
    public func predicate(
        searchesContent: Bool,
        now: Date = Date(),
        calendar: Calendar = FileDateFilter.japaneseCalendar
    ) -> NSPredicate? {
        var clauses: [NSPredicate] = []

        for term in terms {
            let escaped = FileQuery.escapeForLike(term)
            var alternatives: [NSPredicate] = []
            // 「中身だけ」のときは名前に当てない（当てると `DEF` の名前一致が混ざって意味が変わる）
            if scope != .contentOnly {
                alternatives.append(NSPredicate(format: "kMDItemFSName LIKE[cd] %@", "*\(escaped)*"))
                alternatives.append(NSPredicate(format: "kMDItemDisplayName LIKE[cd] %@", "*\(escaped)*"))
            }
            // 「名前だけ」のときは中身を見にいかない（速くもなる）
            if searchesContent, scope != .nameOnly {
                alternatives.append(NSPredicate(format: "kMDItemTextContent CONTAINS[cd] %@", term))
            }
            // 中身だけ×本文検索オフ＝当てる先が無い。
            // ここで語を黙って捨てると危ないので、回す前に isContentSearchBlocked が止める
            guard let combined = FileQuery.anyOf(alternatives) else { continue }
            clauses.append(combined)
        }

        for term in nameTerms {
            let escaped = FileQuery.escapeForLike(term)
            if let combined = FileQuery.anyOf([
                NSPredicate(format: "kMDItemFSName LIKE[cd] %@", "*\(escaped)*"),
                NSPredicate(format: "kMDItemDisplayName LIKE[cd] %@", "*\(escaped)*")
            ]) {
                clauses.append(combined)
            }
        }

        // 「中身:」は本文検索を切っていたら成立しない。
        // 黙って名前検索に化けさせない（違う結果を正解のような顔で出すのが一番たちが悪い）。
        if searchesContent {
            for term in contentTerms {
                clauses.append(NSPredicate(format: "kMDItemTextContent CONTAINS[cd] %@", term))
            }
        }

        // ⚠️ PDF・画像・動画・音声・コードは種類ひとつにつき UTI が1つしかない。
        // ここを素直に OR で包むと、部品1つの複合条件ができて落ちる（anyOf が包まない）
        if !kinds.isEmpty {
            let types = kinds.flatMap(\.contentTypes)
            if let combined = FileQuery.anyOf(types.map {
                NSPredicate(format: "kMDItemContentTypeTree == %@", $0)
            }) {
                clauses.append(combined)
            }
        }

        if let date {
            let (start, end) = date.range(now: now, calendar: calendar)
            if let start {
                clauses.append(NSPredicate(format: "kMDItemContentModificationDate >= %@", start as NSDate))
            }
            if let end {
                clauses.append(NSPredicate(format: "kMDItemContentModificationDate < %@", end as NSDate))
            }
        }

        if let minBytes {
            clauses.append(NSPredicate(format: "kMDItemFSSize >= %lld", minBytes))
        }
        if let maxBytes {
            clauses.append(NSPredicate(format: "kMDItemFSSize <= %lld", maxBytes))
        }

        return FileQuery.allOf(clauses)
    }

    /// いくつかの条件を「どれか（OR）」でまとめる。
    ///
    /// 🔴 1つしか無いときは**包まない**。これが要。
    /// 部品を1つだけ入れた NSCompoundPredicate を NSMetadataQuery に渡すと、
    /// Spotlight の問い合わせ文への変換（generateMetadataDescription）で例外が飛び、
    /// **アプリがその場で落ちる**（2026-07-31 実測。作者「中身だけを選択するとクラッシュする」）。
    /// 落ちた条件: 「中身だけ」＝当てる先が本文1つ／「種類: PDF・画像・動画・音声・コード」＝UTIが1つ。
    /// Swift では Objective-C の例外を受け止められないので、**作らないこと**でしか防げない。
    static func anyOf(_ predicates: [NSPredicate]) -> NSPredicate? {
        if predicates.isEmpty { return nil }
        if predicates.count == 1 { return predicates[0] }
        return NSCompoundPredicate(orPredicateWithSubpredicates: predicates)
    }

    /// いくつかの条件を「すべて（AND）」でまとめる。1つなら包まない（理由は anyOf と同じ）
    static func allOf(_ predicates: [NSPredicate]) -> NSPredicate? {
        if predicates.isEmpty { return nil }
        if predicates.count == 1 { return predicates[0] }
        return NSCompoundPredicate(andPredicateWithSubpredicates: predicates)
    }

    /// Spotlight に渡して落ちない形か。
    /// ⚠️ 渡す直前の最後の関所。ここを通らないものは検索しない（落ちるより0件のほうがまし）。
    public static func isMetadataSafe(_ predicate: NSPredicate) -> Bool {
        guard let compound = predicate as? NSCompoundPredicate else { return true }
        guard compound.subpredicates.count >= 2 else { return false }
        return compound.subpredicates
            .compactMap { $0 as? NSPredicate }
            .allSatisfy(isMetadataSafe)
    }

    /// LIKE のワイルドカードを打ち消す。
    /// `*` や `?` をそのまま通すと、`*.pdf` と打った人に全然違うものが出る。
    static func escapeForLike(_ term: String) -> String {
        var out = ""
        for character in term {
            switch character {
            case "\\": out += "\\\\"
            case "*": out += "\\*"
            case "?": out += "\\?"
            default: out.append(character)
            }
        }
        return out
    }
}

// MARK: - 検索欄の文字の書き換え

/// プルダウンで選んだ条件を、検索欄の文字に反映する係。
///
/// ⚠️ 作りの芯: **正は常に検索欄の文字**。
/// プルダウンは「打つ代わりに選べる口」でしかなく、選んだ結果は文字（`pdf` `今月`）として
/// 検索欄に入る。逆に文字で打てばプルダウンがそれを指す。
/// 状態を2つ持つと（文字とプルダウンが別々に条件を持つと）、
/// 「画面は PDF なのに結果は全部出る」という追えないずれ方をする。
public enum FileQueryEdit {

    static func tokens(_ raw: String) -> [String] {
        raw.replacingOccurrences(of: "　", with: " ")
            .split(separator: " ")
            .map(String.init)
            .filter { !$0.isEmpty }
    }

    static func placePrefixes() -> [String] {
        ["場所:", "フォルダ:", "path:", "in:", "場所：", "フォルダ："]
    }

    /// 種類の言葉を入れ替える。nil なら取り除くだけ（=すべての種類）。
    public static func replacingKind(_ raw: String, with kind: FileKind?) -> String {
        var kept = tokens(raw).filter { FileKind.matching($0) == nil }
        if let kind { kept.append(kind.words[0]) }
        return kept.joined(separator: " ")
    }

    /// 期間の言葉を入れ替える。nil なら取り除くだけ（=いつでも）。
    public static func replacingDate(_ raw: String, with date: FileDateFilter?) -> String {
        var kept = tokens(raw).filter { FileDateFilter.matching($0) == nil }
        if let date { kept.append(date.words[0]) }
        return kept.joined(separator: " ")
    }

    /// 並べ替えの言葉を入れ替える。nil なら取り除くだけ（=既定の更新順）。
    public static func replacingSort(_ raw: String, with sort: FileSort?) -> String {
        var kept = tokens(raw).filter { FileSort.matching($0) == nil }
        if let sort, sort != .recent { kept.append(sort.words[0]) }
        return kept.joined(separator: " ")
    }

    /// 場所（`場所:X`）を入れ替える。nil なら取り除くだけ（=どこでも）。
    public static func replacingPlace(_ raw: String, with word: String?) -> String {
        let prefixes = placePrefixes()
        var kept = tokens(raw).filter { token in !prefixes.contains { token.hasPrefix($0) } }
        if let word, !word.isEmpty { kept.append("場所:\(word)") }
        return kept.joined(separator: " ")
    }

    /// 探す対象を入れ替える。nil か nameOnly なら取り除くだけ（=既定の「名前だけ」）。
    public static func replacingScope(_ raw: String, with scope: FileSearchScope?) -> String {
        var kept = tokens(raw).filter { FileSearchScope.matching($0) == nil }
        if let scope, scope != .nameOnly { kept.append(scope.words[0]) }
        return kept.joined(separator: " ")
    }
}

// MARK: - 保存した検索

/// 名前を付けて取っておく検索条件。
///
/// ⚠️ 中身はただの検索欄の文字。実行は「検索欄に入れて打ったのと同じ」にする。
/// 別の形（構造体で条件を持つ等）にすると、文字で打てる条件と保存できる条件がずれていく。
///
/// ⚠️ settings.json（平文）に入る。検索の言葉くらいの機微はここに置いてよいという判断だが、
/// パスワードそのものを検索語にして保存するような使い方は想定しない（RUNBOOKに明記）。
public struct SavedFileSearch: Codable, Equatable, Sendable, Identifiable {
    public var name: String
    public var query: String

    public var id: String { name }

    public init(name: String, query: String) {
        self.name = name
        self.query = query
    }
}

/// 保存した検索の一覧をいじる決まり。
///
/// ⚠️ ここに置く理由: 「編集したら並び順が変わった」「改名したら別の条件が黙って消えた」は
/// 画面では気づきにくい壊れ方なので、決まりを検証できる場所に置く。
public enum SavedSearchList {

    /// 保存（☆）。同じ名前があれば**その場所のまま**中身を入れ替え、無ければ末尾に足す。
    /// ⚠️ 「消して足す」で作らない。上書きのたびに末尾へ動くと、覚えた並びが崩れる。
    public static func upserting(_ list: [SavedFileSearch], name: String, query: String) -> [SavedFileSearch] {
        var out = list
        if let index = out.firstIndex(where: { $0.name == name }) {
            out[index] = SavedFileSearch(name: name, query: query)
        } else {
            out.append(SavedFileSearch(name: name, query: query))
        }
        return out
    }

    /// 編集。元の名前の場所で、名前と条件を入れ替える（並びは動かさない）。
    /// - Returns: 改名先が**別の条件**と同じ名前になるときは nil
    ///   （黙ってもう片方を消すくらいなら、断って聞き直す方がまし）。
    public static func updating(
        _ list: [SavedFileSearch],
        originalName: String,
        newName: String,
        newQuery: String
    ) -> [SavedFileSearch]? {
        guard let index = list.firstIndex(where: { $0.name == originalName }) else { return nil }
        if newName != originalName, list.contains(where: { $0.name == newName }) { return nil }
        var out = list
        out[index] = SavedFileSearch(name: newName, query: newQuery)
        return out
    }

    /// 削除
    public static func removing(_ list: [SavedFileSearch], name: String) -> [SavedFileSearch] {
        list.filter { $0.name != name }
    }
}

// MARK: - 探す場所

/// `場所:デスクトップ` のような言葉を、実際のフォルダに直す。
///
/// ⚠️ Desktop / Downloads は macOS が守っているので、
/// 初めて触ったときに許可のダイアログが出る（テモトが壊れているわけではない）。
public enum FileScope {
    public struct Place: Equatable, Sendable {
        public let title: String
        public let words: [String]
        /// ホームからの相対パス。空文字はホームそのもの。
        public let relativePath: String

        public init(title: String, words: [String], relativePath: String) {
            self.title = title
            self.words = words
            self.relativePath = relativePath
        }
    }

    public static let places: [Place] = [
        Place(title: "デスクトップ", words: ["デスクトップ", "desktop"], relativePath: "Desktop"),
        Place(title: "書類", words: ["書類", "ドキュメント", "documents", "document"], relativePath: "Documents"),
        Place(title: "ダウンロード", words: ["ダウンロード", "downloads", "download"], relativePath: "Downloads"),
        Place(title: "ピクチャ", words: ["ピクチャ", "写真フォルダ", "pictures"], relativePath: "Pictures"),
        Place(title: "ムービー", words: ["ムービー", "movies"], relativePath: "Movies"),
        Place(title: "ミュージック", words: ["ミュージック", "music"], relativePath: "Music"),
        Place(title: "ホーム", words: ["ホーム", "home", "~"], relativePath: "")
    ]

    /// 言葉 or パスを、実際のフォルダのパスに直す。
    /// - Parameter home: ホームのパス（検証で本物のディスクを触らないよう外から渡す）
    public static func resolve(_ raw: String, home: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }

        if trimmed.hasPrefix("/") { return normalized(trimmed) }
        if trimmed.hasPrefix("~") {
            let rest = String(trimmed.dropFirst()).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            return normalized(rest.isEmpty ? home : home + "/" + rest)
        }

        let lower = trimmed.lowercased()
        if let place = places.first(where: { $0.words.contains(lower) }) {
            return place.relativePath.isEmpty ? normalized(home) : normalized(home + "/" + place.relativePath)
        }

        // 知らない言葉は「ホームの下のそういう名前のフォルダ」と受け取る。
        // 外れていれば結果が0件になるだけで、変なところを探しにはいかない。
        return normalized(home + "/" + trimmed)
    }

    static func normalized(_ path: String) -> String {
        guard path.count > 1, path.hasSuffix("/") else { return path }
        return String(path.dropLast())
    }
}

// MARK: - フォルダを読む許可

/// macOS が守っているフォルダ（書類・デスクトップ・ダウンロード）に入れるかを確かめる。
///
/// ⚠️ これが要る理由（2026-07-30 作者「裁判_チケット規約 が見つかりません。なぜ？？」）。
/// 実在して Spotlight の索引にも載っているフォルダが、テモトの検索だけ0件だった。
/// 原因は許可: **許可の無いアプリには、Spotlight が「書類」の中身を結果から黙って間引く**。
/// ダイアログも出ないので、探す側には「無い」ようにしか見えない。
///
/// 対策は「実際に読みに行く」こと。読もうとして初めて macOS が許可ダイアログを出す。
/// （ad-hoc署名は作り直すたびに別人扱いになるので、作り直し後は許可を押し直すことになる）
public enum FolderAccess {

    public enum State: Equatable, Sendable {
        case allowed
        case denied
    }

    /// 守られているフォルダ（表示名と、ホームからの相対パス）
    public static let protectedPlaces: [(title: String, relativePath: String)] = [
        ("書類", "Documents"),
        ("デスクトップ", "Desktop"),
        ("ダウンロード", "Downloads"),
    ]

    /// 実際に読んでみる。初めて（または作り直しの後）はここで macOS の許可ダイアログが出る。
    /// ⚠️ ダイアログが出ている間はこの呼び出しが返らないので、必ず裏のスレッドから呼ぶこと。
    public static func probe(_ path: String) -> State {
        do {
            _ = try FileManager.default.contentsOfDirectory(atPath: path)
            return .allowed
        } catch {
            return .denied
        }
    }

    /// 守られているフォルダを順に確かめて、読めなかったものの表示名を返す
    public static func deniedPlaceNames(home: String) -> [String] {
        protectedPlaces.compactMap { place in
            probe(home + "/" + place.relativePath) == .denied ? place.title : nil
        }
    }
}

// MARK: - 出さない場所

/// 結果から必ず外す場所。
///
/// ⚠️ ここを外さないと、`node_modules` の中の .js が何千件も並んで本命が沈む。
/// 「探しても出てこない」より「出しすぎて見つからない」ほうが実際にはよく起きる。
///
/// AppKit 側（FileSearcher）ではなくここに置いてあるのは、
/// 除外の条件こそ静かに壊れる（1つ書き忘れると気づかないまま結果が汚れる）ので、
/// 機械で毎回確かめたいから。
public enum FileNoise {
    public static let excludedFragments = [
        "/node_modules/", "/.git/", "/.build/", "/DerivedData/",
        "/.Trash/", "/Library/Caches/", "/.next/", "/.wrangler/",
        "/Library/Containers/", "/Library/Group Containers/",
        "/Library/Application Support/", "/Library/Developer/",
        "/.venv/", "/venv/", "/__pycache__/", "/.npm/", "/.cache/"
    ]

    public static func isExcluded(_ path: String) -> Bool {
        if path.hasPrefix("/System/") || path.hasPrefix("/private/var/") { return true }
        // ドットで始まるフォルダ・ファイルは基本的に道具の内部。出しても選べない。
        if path.split(separator: "/").contains(where: { $0.hasPrefix(".") && $0 != ".." }) { return true }
        return excludedFragments.contains { path.contains($0) }
    }
}

// MARK: - 種類の札

/// 右端に出す種類の名前。UTI をそのまま出しても人には読めないので日本語に直す。
public enum FileTypeLabel {
    public static func of(_ contentType: String?) -> String {
        guard let contentType, !contentType.isEmpty else { return "ファイル" }
        switch contentType {
        case "com.adobe.pdf": return "PDF"
        case "public.folder", "public.directory": return "フォルダ"
        case "com.apple.application-bundle": return "アプリ"
        default: break
        }
        // 細かい UTI（public.png など）は、頭の一致でざっくり寄せる。
        for kind in FileKind.allCases {
            for type in kind.contentTypes where contentType == type || contentType.hasPrefix(type + ".") {
                return kind.title
            }
        }
        if contentType.hasPrefix("public.image") { return FileKind.image.title }
        if contentType.hasPrefix("public.movie") { return FileKind.movie.title }
        if contentType.hasPrefix("public.audio") { return FileKind.audio.title }
        // 最後は拡張子っぽい末尾を出す（png / heic など）。無理なら「ファイル」。
        let tail = contentType.split(separator: ".").last.map(String.init) ?? ""
        return tail.isEmpty ? "ファイル" : tail.uppercased()
    }
}

// MARK: - 見つかったもの

/// Spotlight が返した1件。
/// ⚠️ 中身は持たない。持つのは「どこにあるか」と見出しだけ。
public struct FileHit: Equatable, Sendable, Identifiable {
    public var path: String
    public var name: String
    public var contentType: String?
    public var byteCount: Int64?
    public var modifiedAt: Date?
    public var isFolder: Bool

    public var id: String { path }

    public init(
        path: String,
        name: String,
        contentType: String? = nil,
        byteCount: Int64? = nil,
        modifiedAt: Date? = nil,
        isFolder: Bool = false
    ) {
        self.path = path
        self.name = name
        self.contentType = contentType
        self.byteCount = byteCount
        self.modifiedAt = modifiedAt
        self.isFolder = isFolder
    }

    /// 一覧の副題。「置き場所 ・ 大きさ ・ いつ」の順。
    /// ⚠️ 絶対パスは出さない。画面を人に見せたときにそのまま漏れるので、ホーム以下は ~ に畳む。
    public func subtitle(home: String, now: Date = Date()) -> String {
        var parts: [String] = [FileHit.foldedParent(path, home: home)]
        if !isFolder, let byteCount { parts.append(FileSizeToken.label(byteCount)) }
        if let modifiedAt { parts.append(ClipFormatter.relative(modifiedAt, now: now)) }
        return parts.filter { !$0.isEmpty }.joined(separator: " ・ ")
    }

    public static func foldedParent(_ path: String, home: String) -> String {
        var parts = path.split(separator: "/").map(String.init)
        guard parts.count > 1 else { return "/" }
        parts.removeLast()
        let parent = "/" + parts.joined(separator: "/")
        if !home.isEmpty, parent == home { return "~" }
        if !home.isEmpty, parent.hasPrefix(home + "/") { return "~" + parent.dropFirst(home.count) }
        return parent
    }
}
