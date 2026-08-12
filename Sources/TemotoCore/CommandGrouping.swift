import Foundation

/// 自作コマンドの「畳み方」を決める係。
///
/// ⚠️ ここが存在する理由（2026-07-30 作者「フォルダーを開くが複数表示されすぎていて、
/// リスト表示されている項目が汚い」）。
/// 「フォルダを開く: ABC」「フォルダを開く: DEF」…と9行並ぶと、入口の画面が
/// 同じ言葉の壁になる。同じ書き出しのコマンドは1行に畳み、Enterで中に入る形にする。
///
/// 畳む決まり（RUNBOOKにも書いてある）:
/// - 題名が「X: 残り」（コロン）または「X 残り」（最初の語）の形で、
///   同じ X を持つコマンドが **3つ以上** あれば、X という1行に畳む
/// - 2つ以下はたまたま似ただけかもしれないので畳まない
/// - 検索で文字を打ったときは畳まない（子を短い名前で直接出す。
///   畳んだままだと「ABC」で作業ログを探せない）
public enum CommandGrouping {

    /// 入口に並べる1行ぶん
    public enum Entry: Equatable, Sendable {
        case group(title: String, commands: [CustomCommand])
        case single(CustomCommand)
    }

    /// 題名の「書き出し」。畳む鍵になる。
    ///
    /// 「フォルダを開く: ABC」→「フォルダを開く」（コロン優先・全角コロンも受ける）
    /// 「作業ログ ABC」→「作業ログ」（空白区切りの最初の語）
    /// 「今日の日記を開く」→ nil（区切りが無い＝畳みようがない）
    public static func prefix(of title: String) -> String? {
        for separator in [": ", "：", ":"] {
            if let range = title.range(of: separator) {
                let head = String(title[..<range.lowerBound]).trimmingCharacters(in: .whitespaces)
                let rest = String(title[range.upperBound...]).trimmingCharacters(in: .whitespaces)
                if !head.isEmpty && !rest.isEmpty { return head }
            }
        }
        if let range = title.range(of: " ") ?? title.range(of: "　") {
            let head = String(title[..<range.lowerBound]).trimmingCharacters(in: .whitespaces)
            let rest = String(title[range.upperBound...]).trimmingCharacters(in: .whitespaces)
            if !head.isEmpty && !rest.isEmpty { return head }
        }
        return nil
    }

    /// 畳んだ中で出す短い題名（書き出しを取り除いた残り）。
    /// 「フォルダを開く: ABC（サンプル商事）」→「ABC（サンプル商事）」
    public static func shortTitle(_ title: String) -> String {
        guard let head = prefix(of: title) else { return title }
        var rest = String(title.dropFirst(head.count))
        for separator in [": ", "：", ":", " ", "　"] where rest.hasPrefix(separator) {
            rest = String(rest.dropFirst(separator.count))
            break
        }
        let trimmed = rest.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? title : trimmed
    }

    /// 畳んだ行の副題に並べる呼び名（短い題名の、さらに頭だけ）。
    /// 「ABC（サンプル商事）」→「ABC」。
    /// 9件ぶんの正式名称を副題に全部並べると、それ自体が新しい壁になるため。
    public static func abbreviated(_ title: String) -> String {
        let short = shortTitle(title)
        for separator in ["（", "(", " ", "　"] {
            if let range = short.range(of: separator) {
                let head = String(short[..<range.lowerBound])
                if !head.isEmpty { return head }
            }
        }
        return short
    }

    /// 入口に並べる形に整理する。順番は元の並びを保つ
    /// （畳んだ行は、その仲間が最初に現れた場所に置く）。
    public static func organize(_ commands: [CustomCommand], minimumGroupSize: Int = 3) -> [Entry] {
        var counts: [String: Int] = [:]
        for command in commands {
            if let head = prefix(of: command.title) { counts[head, default: 0] += 1 }
        }

        var grouped: Set<String> = []
        var entries: [Entry] = []
        for command in commands {
            if let head = prefix(of: command.title), (counts[head] ?? 0) >= minimumGroupSize {
                guard !grouped.contains(head) else { continue }
                grouped.insert(head)
                let members = commands.filter { prefix(of: $0.title) == head }
                entries.append(.group(title: head, commands: members))
            } else {
                entries.append(.single(command))
            }
        }
        return entries
    }

    /// 畳んだ行の副題（呼び名を「・」で並べる）
    public static func memberSummary(_ commands: [CustomCommand]) -> String {
        commands.map { abbreviated($0.title) }.joined(separator: "・")
    }
}
