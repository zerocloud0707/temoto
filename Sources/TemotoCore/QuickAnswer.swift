import Foundation

/// 検索欄に打った文字が「探しもの」ではなく「聞きたいこと」に見えるとき、
/// 一覧の先頭にその場で答えを出す。
///
/// ⚠️ これが「Raycastそのまま」から抜けるための機能（2026-07-29 作者
/// 「raycastそのままなので、何か工夫できないかな。」）。
///
/// 見た目を変えても中身が同じなら、それは同じ道具の色違いでしかない。
/// 変えるなら**作者の1日に出てくるもの**を入れる。作者はCFOで、
/// 1日の中に必ず「消費税を足す」「万で言われた額を数字に直す」
/// 「和暦で書かれた日付を西暦に直す」が出てくる。Raycastの電卓は
/// 英語圏の道具なので、`3万` も `令和8年` も知らない。
///
/// ⚠️ 答えを出すのは**確実に読み取れたときだけ**。
/// 迷ったら黙って何も出さない。検索の邪魔をしてまで出すものではないし、
/// 数字が絡む場面で「たぶんこうだと思う」を出すのは、間違いより質が悪い
/// （合っているように見えて、確かめずに使われる）。
public enum QuickAnswer {

    /// 一覧の先頭に出す1行
    public struct Answer: Equatable, Sendable {
        /// 貼り付け・コピーの中身（そのまま使える形。桁区切りは入れない）
        public let value: String
        /// 画面に出す文字（桁区切りなど、読むための形）
        public let display: String
        /// 何をしたのかの説明
        public let detail: String

        public init(value: String, display: String, detail: String) {
            self.value = value
            self.display = display
            self.detail = detail
        }
    }

    /// 「電卓」を探しに来た人に使い方を出すか。
    ///
    /// 2026-08-02 作者「電卓機能欲しい。」＝**既にあるのに見つけられなかった**。
    /// 行き先に「電卓」は無い（式を打つだけ）ので、探しに来た言葉を受け止めて案内を出す。
    public static func isCalculatorLookup(_ query: String) -> Bool {
        let folded = FuzzyMatcher.fold(query.trimmingCharacters(in: .whitespaces))
        guard !folded.isEmpty else { return false }
        let triggers = ["電卓", "でんたく", "dentaku", "計算", "けいさん", "keisan", "calc", "calculator"]
        return triggers.contains { FuzzyMatcher.fold($0) == folded }
    }

    /// 「電卓」と打った人に出す使い方（1行）
    public static let calculatorGuide =
        "電卓: 式をそのまま打つと答えが出ます（例: 1980*1.1 ／ 3万の10% ／ 1980+10% ／ 128000 ／ 今日）"

    /// 打った文字から答えを作る。読み取れなければ nil。
    public static func answer(for query: String, today: Date = Date(),
                              calendar: Calendar = Calendar(identifier: .gregorian)) -> Answer? {
        let text = query.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return nil }

        if let date = dateAnswer(for: text, today: today, calendar: calendar) { return date }
        if let number = numberAnswer(for: text) { return number }
        return nil
    }

    // MARK: - 計算と金額

    /// 数字・式・「3万」を読む。
    ///
    /// ⚠️ 数字を1つ打っただけでも答えを出すのは、そこが一番使うところだから。
    /// 「1234567」と打てば `1,234,567` と `123万4567` と税込がその場で出る。
    /// 請求書の額を読み上げるとき、桁を指で数えるのをやめられる。
    static func numberAnswer(for text: String) -> Answer? {
        // ⚠️ 検索の邪魔をしない。式に使う文字以外が1つでも混ざっていたら手を出さない。
        // 「1Password」「2階」のようなものまで拾うと、探しものが1行下に押しやられる。
        guard let value = Arithmetic.evaluate(text) else { return nil }
        guard value.isFinite else { return nil }

        // ⚠️ 記号の有無は**そろえたあとの文字**で見る。
        // 元の文字で見ると、全角で打った「１０００＋２０００」の＋を数え落とす。
        let normalized = Arithmetic.normalize(text)
        let hasOperator = normalized.contains(where: { "+-*/()%".contains($0) })
        // ⚠️ 円・¥ は normalize が落とすので、こちらは元の文字で見る。
        let hasUnit = text.contains(where: { "万億兆円¥￥".contains($0) })
        // ⚠️ 数字を短く打っただけのときは答えを出さない。
        // 「2026」はフォルダの名前かもしれない。ここで一覧の先頭を横取りすると、
        // Enter がフォルダを開かずに数字をコピーして「壊れた」としか見えない。
        // 桁を指で数えたくなるのは万の位から＝5桁以上。
        // 式や単位（+ や 万 や 円）が付いていれば、それは探しものではなく問いなので長さは見ない。
        if !hasOperator && !hasUnit {
            guard normalized.filter(Arithmetic.isDigit).count >= 5 else { return nil }
        }

        let isPlainNumber = !hasOperator
        let rounded = (value * 100).rounded() / 100
        let plain = trimZeros(rounded)

        var parts: [String] = []
        if let japanese = JapaneseNumber.spell(rounded), japanese != plain {
            parts.append(japanese)
        }
        // 税込・税抜は「整数の金額に見えるとき」だけ。
        // 3.14 のような数に「税込 3.45」と出しても意味が無い。
        //
        // ⚠️ マイナスには出さない。切り捨ての向きが決まっていないから。
        // -5 の税込を -6 と出すか -5 と出すかは実務の扱い次第で、
        // テモトが勝手に決めていい話ではない。決められないものは黙る。
        if rounded == rounded.rounded(), rounded >= 1, rounded < 1_000_000_000_000 {
            let withTax = (rounded * 1.1).rounded(.down)          // 円未満は切り捨て（請求実務に合わせる）
            let withoutTax = (rounded / 1.1).rounded(.down)
            parts.append("税込 \(grouped(withTax))")
            parts.append("税抜 \(grouped(withoutTax))")
        }

        let detail = parts.isEmpty
            ? (isPlainNumber ? "数字" : "計算した答え")
            : parts.joined(separator: "　/　")
        return Answer(value: plain, display: grouped(rounded), detail: detail)
    }

    /// 3桁ごとに区切る。読むための形なので、貼り付ける値には使わない。
    public static func grouped(_ value: Double) -> String {
        let text = trimZeros(value)
        let negative = text.hasPrefix("-")
        let body = negative ? String(text.dropFirst()) : text
        let parts = body.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false)
        var integer = Array(parts[0])
        var out: [Character] = []
        while integer.count > 3 {
            out.insert(contentsOf: [","] + integer.suffix(3), at: 0)
            integer.removeLast(3)
        }
        out.insert(contentsOf: integer, at: 0)
        let joined = String(out) + (parts.count > 1 ? "." + parts[1] : "")
        return (negative ? "-" : "") + joined
    }

    /// 小数点以下の余計な0を落とす（1.0 → 1）
    static func trimZeros(_ value: Double) -> String {
        if value == value.rounded(), abs(value) < 1e15 {
            return String(Int64(value))
        }
        var text = String(format: "%.2f", value)
        while text.hasSuffix("0") { text.removeLast() }
        if text.hasSuffix(".") { text.removeLast() }
        return text
    }

    // MARK: - 日付と和暦

    static func dateAnswer(for text: String, today: Date, calendar: Calendar) -> Answer? {
        guard let date = JapaneseDate.parse(text, today: today, calendar: calendar) else { return nil }
        let c = calendar.dateComponents([.year, .month, .day, .weekday], from: date)
        guard let y = c.year, let m = c.month, let d = c.day else { return nil }

        let iso = String(format: "%04d-%02d-%02d", y, m, d)
        let wareki = JapaneseDate.wareki(year: y, month: m, day: d) ?? ""
        let weekday = JapaneseDate.weekdayNames[(c.weekday ?? 1) - 1]
        var detail = "\(y)年\(m)月\(d)日（\(weekday)）"
        if !wareki.isEmpty { detail += "　/　\(wareki)" }
        detail += "　/　\(String(format: "%04d%02d%02d", y, m, d))"
        return Answer(value: iso, display: iso, detail: detail)
    }
}

/// 検索欄に打てる範囲の四則演算。
///
/// ⚠️ 自前で書いている理由。`NSExpression` は文字列をそのまま式として動かすので、
/// 打ち間違いで思わぬものが動く余地がある（関数名も書けてしまう）。
/// テモトが受けるのは数と `+-*/()` と `%` だけでいい。
public enum Arithmetic {

    /// 0〜9 の1文字かどうか。
    ///
    /// ⚠️ ここで `Character.isNumber` を使ってはいけない。
    /// あれは Unicode に数の意味がある文字すべてが true になるので、
    /// **万・億・兆・①・½・漢数字まで「数字」になる**。
    /// 数を読み取る輪の中で使うと「3万」の万まで数として飲み込み、
    /// `Double("3万")` が読めずに答えがまるごと消える
    /// （2026-07-29 実際にこれで「3万」の答えが出なくなった）。
    public static func isDigit(_ character: Character) -> Bool {
        character >= "0" && character <= "9" && character.isASCII
    }

    /// 読めなければ nil。**式に使えない文字が1つでもあれば nil**。
    public static func evaluate(_ text: String) -> Double? {
        let normalized = normalize(text)
        guard !normalized.isEmpty else { return nil }
        // 数字が1つも無いものは式ではない（"++" などを弾く）
        guard normalized.contains(where: isDigit) else { return nil }

        var parser = Parser(Array(normalized))
        guard let value = parser.expression(), parser.atEnd else { return nil }
        return value
    }

    private static let fullWidthZero = Unicode.Scalar("０").value
    private static let halfWidthZero = Unicode.Scalar("0").value

    /// 全角・記号・単位を、計算できる形にそろえる。
    /// ⚠️ 知らない文字が混ざっていたら空を返す＝答えを出さない。
    static func normalize(_ text: String) -> String {
        // 「の」は %入りの式でだけ「掛ける」と読む（3万の10% ＝ 3万×10%）。
        // ⚠️ % 無しで「の」を式にすると、「2026の7」のような探しものまで
        // 掛け算の顔で答えてしまう。「の」が電卓の言葉なのは割合の言い方のときだけ。
        let allowsNo = text.contains("%") || text.contains("％")
        var out = ""
        for character in text {
            switch character {
            case " ", ",", "，", "、", "円", "¥", "￥": continue
            case "％": out.append("%")
            case "の" where allowsNo: out.append("*")
            case "０"..."９":
                // 全角の数字を半角に。
                // ⚠️ ここで ! を使わない。上の範囲を見れば必ず通ると分かっていても、
                // 「必ず通るはず」で書いた1行は、範囲を1文字足した日に落ちる。
                // 落ちる代わりに「読めなかった」ことにすれば、答えが出ないだけで済む。
                guard let scalar = character.unicodeScalars.first,
                      let half = Unicode.Scalar(scalar.value - fullWidthZero + halfWidthZero)
                else { return "" }
                out.append(Character(half))
            case "×", "＊": out.append("*")
            case "÷": out.append("/")
            case "＋": out.append("+")
            case "ー", "－", "−": out.append("-")
            case "（": out.append("(")
            case "）": out.append(")")
            case "．": out.append(".")
            case "千", "万", "億", "兆": out.append(character)
            case "0"..."9", "+", "-", "*", "/", "(", ")", ".", "%": out.append(character)
            default: return ""      // 知らない文字＝式ではない
            }
        }
        return out
    }

    /// 再帰下降。左から順に読むだけの素直な作り。
    private struct Parser {
        let chars: [Character]
        var index = 0
        init(_ chars: [Character]) { self.chars = chars }

        var atEnd: Bool { index >= chars.count }
        private func peek() -> Character? { index < chars.count ? chars[index] : nil }

        /// 足し引き。
        ///
        /// ⚠️ `1980+10%` は 1980.1 ではなく **2178**（1割増し）。
        /// 電卓の常識では「+10%」は「1割を足す」で、iPhoneの電卓もExcel脳もそう読む。
        /// 1980.1 を「計算した答え」の顔で出すのが一番危ない（2026-08-02 電卓強化で修正）。
        /// 割合として効かせるのは、右側が「%で終わる単独の数」のときだけ。
        mutating func expression() -> Double? {
            guard var value = term()?.value else { return nil }
            while let op = peek(), op == "+" || op == "-" {
                index += 1
                guard let rhs = term() else { return nil }
                let delta = rhs.isPercent ? value * rhs.value : rhs.value
                value = op == "+" ? value + delta : value - delta
            }
            return value
        }

        /// 掛け割り。掛け算が混ざったら、それはもう割合ではなく普通の数（10%*2 は 0.2）
        mutating func term() -> (value: Double, isPercent: Bool)? {
            guard let first = factor() else { return nil }
            var value = first.value
            var isPercent = first.isPercent
            while let op = peek(), op == "*" || op == "/" {
                index += 1
                guard let rhs = factor() else { return nil }
                // ⚠️ 0で割った答えは出さない。inf を「答え」として見せない
                if op == "/" && rhs.value == 0 { return nil }
                value = op == "*" ? value * rhs.value : value / rhs.value
                isPercent = false
            }
            return (value, isPercent)
        }

        mutating func factor() -> (value: Double, isPercent: Bool)? {
            guard let c = peek() else { return nil }
            if c == "-" {
                index += 1
                guard let v = factor() else { return nil }
                return (-v.value, v.isPercent)
            }
            if c == "+" { index += 1; return factor() }
            if c == "(" {
                index += 1
                guard let v = expression(), peek() == ")" else { return nil }
                index += 1
                return suffixed(v)
            }
            guard Arithmetic.isDigit(c) || c == "." else { return nil }
            var text = ""
            while let n = peek(), Arithmetic.isDigit(n) || n == "." { text.append(n); index += 1 }
            guard let value = Double(text) else { return nil }
            return suffixed(value)
        }

        /// 千・万・億・兆（「3千」「1万3千」と言うので千も受ける）
        static func unitSize(_ character: Character) -> Double? {
            switch character {
            case "千": return 1_000
            case "万": return 10_000
            case "億": return 100_000_000
            case "兆": return 1_000_000_000_000
            default: return nil
            }
        }

        /// 数のうしろに付く単位。`3万` `1億2345万6789` `5%` を読む。
        ///
        /// ⚠️ 万・億は掛け算より先に効かせる（`3万*2` は 60000。3*20000 ではない）。
        ///
        /// ⚠️ 単位が続けて並ぶときは**足し合わせる**。日本語の「1億2345万」は
        /// 1億 と 2345万 を足した言い方であって、掛けているわけではない。
        /// ここを掛け算のまま素通しすると、桁が4桁ずれた額が
        /// 「計算した答え」の顔で出てくる（請求書の場面でいちばん危ない）。
        ///
        /// ⚠️ 並びは必ず大きい順。`1万2億` のような並びは読めなかったことにする。
        /// 打ち間違いを、それらしい数にして黙って返さない。
        mutating func suffixed(_ value: Double) -> (value: Double, isPercent: Bool)? {
            var total: Double = 0
            var pending = value
            var lastSize = Double.infinity
            var sawUnit = false

            while let c = peek(), let size = Parser.unitSize(c) {
                guard size < lastSize else { return nil }
                index += 1
                total += pending * size
                lastSize = size
                sawUnit = true
                pending = 0
                // 単位のうしろに数字が続けば、それは下の桁（1億2345万 の 2345）
                if let next = peek(), Arithmetic.isDigit(next) {
                    var text = ""
                    while let d = peek(), Arithmetic.isDigit(d) || d == "." { text.append(d); index += 1 }
                    guard let number = Double(text) else { return nil }
                    pending = number
                }
            }

            var result = sawUnit ? total + pending : value
            var isPercent = false
            while peek() == "%" { result /= 100; index += 1; isPercent = true }
            return (result, isPercent)
        }
    }
}

/// 数を日本語の桁（万・億・兆）で言い直す。
///
/// ⚠️ 会話に出てくるのは「1,234万」で、書類に出てくるのは「12,340,000」。
/// この行き来を頭でやるのが地味に手間で、桁を1つ間違える事故もここで起きる。
public enum JapaneseNumber {

    /// 万より小さい数と、小数は nil（言い直す意味が無い）
    public static func spell(_ value: Double) -> String? {
        guard value == value.rounded(), abs(value) < 1e15 else { return nil }
        let negative = value < 0
        var remaining = Int64(abs(value))
        guard remaining >= 10_000 else { return nil }

        var parts: [String] = []
        for unit in units where remaining >= unit.size {
            let count = remaining / unit.size
            remaining %= unit.size
            parts.append("\(count)\(unit.name)")
        }
        if remaining > 0 { parts.append("\(remaining)") }
        return (negative ? "-" : "") + parts.joined()
    }

    private static let units: [(name: String, size: Int64)] = [
        ("兆", 1_000_000_000_000), ("億", 100_000_000), ("万", 10_000),
    ]
}

/// 日付の読み取りと和暦。
///
/// ⚠️ 元号の始まりだけを持ち、終わりは持たない（次の元号の始まりが終わり）。
/// 両方持つと、改元のたびに2か所直すことになり、片方だけ直した年が必ず出る。
public enum JapaneseDate {

    public static let weekdayNames = ["日", "月", "火", "水", "木", "金", "土"]

    /// 元号の始まった日（新しい順）
    static let eras: [(name: String, year: Int, month: Int, day: Int)] = [
        ("令和", 2019, 5, 1),
        ("平成", 1989, 1, 8),
        ("昭和", 1926, 12, 25),
        ("大正", 1912, 7, 30),
        ("明治", 1868, 1, 25),
    ]

    /// 西暦→和暦。明治より前は nil
    public static func wareki(year: Int, month: Int, day: Int) -> String? {
        let stamp = year * 10000 + month * 100 + day
        for era in eras where stamp >= era.year * 10000 + era.month * 100 + era.day {
            let n = year - era.year + 1
            return "\(era.name)\(n == 1 ? "元" : String(n))年\(month)月\(day)日"
        }
        return nil
    }

    /// 打った文字を日付として読む。読めなければ nil。
    ///
    /// 受ける書き方: きょう / 今日 / あした / 明日 / きのう / 昨日 /
    ///              2026-07-29 / 2026/7/29 / 20260729 / 令和8年7月29日
    public static func parse(_ text: String, today: Date, calendar: Calendar) -> Date? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        let startOfToday = calendar.startOfDay(for: today)

        switch trimmed {
        case "きょう", "今日", "本日", "kyou": return startOfToday
        case "あした", "明日", "asita", "ashita": return calendar.date(byAdding: .day, value: 1, to: startOfToday)
        case "きのう", "昨日", "kinou": return calendar.date(byAdding: .day, value: -1, to: startOfToday)
        default: break
        }

        if let ymd = parseWareki(trimmed) ?? parseSeireki(trimmed) {
            var c = DateComponents()
            c.year = ymd.year; c.month = ymd.month; c.day = ymd.day
            guard let date = calendar.date(from: c) else { return nil }
            // ⚠️ 2026-02-31 のような日は「3月3日」に化ける。化けたら読めなかったことにする
            let back = calendar.dateComponents([.year, .month, .day], from: date)
            guard back.year == ymd.year, back.month == ymd.month, back.day == ymd.day else { return nil }
            return date
        }
        return nil
    }

    /// 令和8年7月29日 / R8.7.29
    static func parseWareki(_ text: String) -> (year: Int, month: Int, day: Int)? {
        for era in eras {
            guard text.hasPrefix(era.name) else { continue }
            let rest = String(text.dropFirst(era.name.count))
            let numbers = rest.split(whereSeparator: { !Arithmetic.isDigit($0) }).compactMap { Int($0) }
            // 「元年」は1年
            let eraYear = rest.hasPrefix("元") ? 1 : numbers.first
            guard let eraYear, eraYear >= 1 else { return nil }
            let tail = rest.hasPrefix("元") ? numbers : Array(numbers.dropFirst())
            guard tail.count >= 2 else { return nil }
            return (era.year + eraYear - 1, tail[0], tail[1])
        }
        return nil
    }

    /// 2026-07-29 / 2026/7/29 / 2026年7月29日 / 20260729
    static func parseSeireki(_ text: String) -> (year: Int, month: Int, day: Int)? {
        // ⚠️ 8桁の数字だけは特別扱い。区切りが無いので split では割れない
        if text.count == 8, text.allSatisfy(Arithmetic.isDigit), let n = Int(text) {
            let year = n / 10000
            guard year >= 1868, year <= 2999 else { return nil }
            return (year, (n / 100) % 100, n % 100)
        }
        let numbers = text.split(whereSeparator: { !Arithmetic.isDigit($0) }).compactMap { Int($0) }
        guard numbers.count == 3 else { return nil }
        // ⚠️ 年は4桁のときだけ受ける。`7/29/26` のような並びを勝手に解釈しない
        guard numbers[0] >= 1868, numbers[0] <= 2999 else { return nil }
        return (numbers[0], numbers[1], numbers[2])
    }
}
