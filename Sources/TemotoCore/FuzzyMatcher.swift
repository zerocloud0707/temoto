import Foundation

/// あいまい検索。入力文字が候補の中に「その順番で」現れれば一致とみなし、
/// 一致の質（先頭か・連続しているか・語の切れ目か）でスコアを付ける。
///
/// 日本語の自作コマンドを引けるよう、カタカナ→ひらがな・全角英数→半角の畳み込みを行う。
/// 畳み込みは必ず1文字→1文字にしているので、強調表示用の添字が元の文字列とずれない。
public enum FuzzyMatcher {

    public struct Result: Equatable, Sendable {
        public let score: Int
        /// 候補文字列の何文字目が一致したか（0始まり・元の文字列基準）
        public let matchedIndices: [Int]

        public init(score: Int, matchedIndices: [Int]) {
            self.score = score
            self.matchedIndices = matchedIndices
        }
    }

    /// 1文字を検索用に正規化する。必ず1文字を返す（添字の対応を壊さないため）。
    public static func fold(_ c: Character) -> Character {
        guard let scalar = c.unicodeScalars.first, c.unicodeScalars.count == 1 else {
            return Character(c.lowercased().first.map(String.init) ?? String(c))
        }
        let v = scalar.value

        // 全角英数記号 → 半角
        if (0xFF01...0xFF5E).contains(v), let s = Unicode.Scalar(v - 0xFEE0) {
            return Character(String(s)).lowercasedASCII()
        }
        // カタカナ → ひらがな（ヴ ヵ ヶ を含む範囲）
        if (0x30A1...0x30F6).contains(v), let s = Unicode.Scalar(v - 0x60) {
            return Character(s)
        }
        // 全角スペース → 半角スペース
        if v == 0x3000 { return " " }

        return Character(String(scalar)).lowercasedASCII()
    }

    public static func fold(_ s: String) -> [Character] {
        s.map(fold)
    }

    /// 語の切れ目（この位置で一致するとスコアが上がる）。
    /// camelCase は畳み込み後だと小文字に潰れて判定できないので、元の文字列で見る。
    private static func isBoundary(before index: Int, in chars: [Character], raw: [Character]) -> Bool {
        if index == 0 { return true }
        let prev = chars[index - 1]
        if prev == " " || prev == "-" || prev == "_" || prev == "." || prev == "/" {
            return true
        }
        return raw[index - 1].isLowercase && raw[index].isUppercase
    }

    /// 読み（別名）で当たったときに引く点。
    /// 同じ入力なら、表示名そのものに当たった方を必ず上に置くための差。
    public static let aliasPenalty = 40

    /// 表示名で当たらなければ読みでも探す。
    public static func match(query: String, in candidate: String, aliases: [String]) -> Result? {
        if let direct = match(query: query, in: candidate) { return direct }
        return matchAliases(query: query, aliases: aliases)
    }

    /// 読みだけを見る。
    ///
    /// ⚠️ 当たっても matchedIndices は空で返す。
    /// 添字が指しているのは「ていけいぶん」の位置であって「定型文」の位置ではないので、
    /// そのまま色を塗ると関係ない文字が光る。当たった事実だけを返して、色は塗らない。
    public static func matchAliases(query: String, aliases: [String]) -> Result? {
        var best: Int?
        for alias in aliases {
            guard let hit = match(query: query, in: alias) else { continue }
            let score = hit.score - aliasPenalty
            if score > (best ?? Int.min) { best = score }
        }
        guard let best else { return nil }
        return Result(score: best, matchedIndices: [])
    }

    /// 一致しなければ nil。
    public static func match(query: String, in candidate: String) -> Result? {
        let rawCandidate = Array(candidate)
        let q = fold(query).filter { $0 != " " }
        guard !q.isEmpty else {
            return Result(score: 1, matchedIndices: [])
        }
        let c = fold(candidate)
        guard q.count <= c.count else { return nil }

        // 先頭文字が現れる各位置から貪欲に一致させ、最も点の高いものを採る。
        // 単純な前方一致だけだと "支払" が "本日支払一覧" より
        // "支店払込" を優先してしまうため、開始位置を振り直している。
        var best: Result?
        for start in 0..<c.count where c[start] == q[0] {
            if let r = greedyMatch(q, c, rawCandidate, from: start), r.score > (best?.score ?? Int.min) {
                best = r
            }
        }
        return best
    }

    private static func greedyMatch(
        _ q: [Character],
        _ c: [Character],
        _ raw: [Character],
        from start: Int
    ) -> Result? {
        var indices: [Int] = []
        indices.reserveCapacity(q.count)

        var ci = start
        var qi = 0
        var score = 100
        var gap = 0
        var previousMatch = -2

        while qi < q.count {
            guard ci < c.count else { return nil }
            if c[ci] == q[qi] {
                if ci == 0 {
                    score += 20
                }
                if previousMatch == ci - 1 {
                    score += 15
                } else if isBoundary(before: ci, in: c, raw: raw) {
                    score += 10
                }
                previousMatch = ci
                indices.append(ci)
                qi += 1
            } else if !indices.isEmpty {
                gap += 1
            }
            ci += 1
        }

        score -= min(gap, 30)
        // 候補の先頭に近いところで当たった方を優先する。
        // 日本語には語の切れ目が無いので、この差が実質的な決め手になる
        // （「ログ」で "作業ログ ABC" が "ダイアログ設定" より上に来る）。
        score -= min(start, 10)
        // 同じくらいの一致なら短い候補を優先する
        score -= raw.count / 10
        return Result(score: score, matchedIndices: indices)
    }

    /// 候補の並べ替え。一致しないものは除外し、スコアの高い順に返す。
    /// スコアが同じときは表示名の辞書順にして、起動のたびに並びが変わらないようにする。
    /// - Parameter aliases: 表示名で当たらなかったときに見る読み。
    ///   ⚠️ 表示名で当たった時点で呼ばない（読みを作るのは高いので、要るときだけ払う）。
    public static func rank<T>(
        _ items: [T],
        query: String,
        key: (T) -> String,
        aliases: (T) -> [String] = { _ in [] }
    ) -> [(item: T, result: Result)] {
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty else {
            return items.map { ($0, Result(score: 0, matchedIndices: [])) }
        }
        var scored: [(item: T, result: Result, name: String)] = []
        for item in items {
            let name = key(item)
            if let r = match(query: query, in: name) {
                scored.append((item, r, name))
            } else if let r = matchAliases(query: query, aliases: aliases(item)) {
                scored.append((item, r, name))
            }
        }
        scored.sort {
            $0.result.score == $1.result.score ? $0.name < $1.name : $0.result.score > $1.result.score
        }
        return scored.map { ($0.item, $0.result) }
    }
}

private extension Character {
    /// ASCII範囲だけ小文字化する（1文字→1文字を保証する）
    func lowercasedASCII() -> Character {
        guard let v = unicodeScalars.first?.value, unicodeScalars.count == 1 else { return self }
        if (65...90).contains(v), let s = Unicode.Scalar(v + 32) { return Character(s) }
        return self
    }
}
