import Foundation

/// うまくいかなかったことを手元に貯めておく仕組み。
///
/// 2026-08-09 作者「今後他の人にも使ってもらい、エラー情報を収集したい。」
/// → 2案を出して **A案（手元に貯めて、本人が送る）** を選択。
///
/// ⚠️ **勝手に送らない。** テモトの一番の看板は「通信ゼロ」で、
/// 履歴を預けてよいか迷う人はそこで判断している。自動送信を入れた瞬間に看板が下りる。
/// ここがやるのは「貯める・伏せる・見せる」まで。送るかどうかは毎回その人が決める。
///
/// ⚠️ **伏せ字がこの仕組みの心臓部**。
/// 記録は最終的に人の手を離れて私たちに届く。1回でも中身が漏れたら、
/// 「安全だから使っている」という前提そのものが崩れる。
/// だから記録の作り方を2段構えにする:
///   ① 呼ぶ側が「出してよい短い説明」だけを渡す（自由な文字列を流し込ませない）
///   ② それでも混ざったものを、ここで機械的に伏せる（最後の網）
public enum ErrorLog {

    /// 1件分
    public struct Entry: Codable, Equatable, Sendable {
        /// いつ
        public let at: Date
        /// どのあたりで（「画面を撮る」「コピー履歴」など・日本語でよい）
        public let area: String
        /// 何が起きたか（短く・決まった言い回しで）
        public let what: String
        /// 補足（省略可）。⚠️ ここに人の中身を入れない
        public let detail: String

        public init(at: Date, area: String, what: String, detail: String = "") {
            self.at = at
            self.area = area
            self.what = what
            self.detail = ErrorLog.redact(detail)
        }
    }

    /// 貯めておく上限。
    /// ⚠️ 上限が無いと、同じ失敗を繰り返す人の手元でファイルが際限なく育つ。
    /// 新しい方を残す（古い失敗より、いま起きている失敗の方が知りたい）。
    public static let maxEntries = 300

    /// 古いものから捨てて、上限に収める
    public static func trim(_ entries: [Entry], limit: Int = maxEntries) -> [Entry] {
        guard entries.count > limit else { return entries }
        return Array(entries.suffix(limit))
    }

    // MARK: - 伏せ字

    /// 出してはいけないものを伏せる。
    ///
    /// ⚠️ ここで消すのは「その人が誰か」「その人が何を持っているか」が分かるもの。
    /// 何が起きたかを追うのに要らないのに、混ざりやすいものを列挙してある。
    public static func redact(_ text: String) -> String {
        guard !text.isEmpty else { return "" }
        var out = text

        // ① 家のフォルダ＝利用者の名前が入っている。`/Users/junichiro/…` → `~/…`
        let home = NSHomeDirectory()
        if !home.isEmpty { out = out.replacingOccurrences(of: home, with: "~") }
        // 別の人の家も同じ形なので、形で潰す
        out = replace(out, pattern: "/Users/[^/\\s]+", with: "~")

        // ①-2 **フォルダ名とファイル名そのものを伏せる**。
        //
        // ⚠️ ここが最初の版で抜けていた（2026-08-09 実測で発覚）。
        // `~/Documents/01_ABC/請求書_サンプル物産.pdf` は、家の場所を伏せても
        // **顧問先の名前がそのまま残る**。誰の仕事をしているかが外に出るということで、
        // 記録を送ってもらう仕組みとしては致命的。
        // 追うのに要るのは「どの階層の・どんな種類のファイルか」だけなので、そこまで残す。
        out = redactPaths(out)

        // ② メールアドレス
        out = replace(out, pattern: "[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\\.[A-Za-z]{2,}", with: "***@***")

        // ③ 鍵・合言葉らしき長い塊（20文字以上の英数字の連なり）。
        // ⚠️ これが最後の網。呼ぶ側がうっかり流し込んでも、ここで止まる
        out = replace(out, pattern: "[A-Za-z0-9_\\-]{20,}", with: "***")

        // ④ URL は行き先（ホスト）だけ残す。あとに続く道と問い合わせは落とす。
        // ⚠️ 問い合わせ（?以降）には合言葉や書類の番号が入る
        out = replace(out, pattern: "(https?://[^/\\s]+)[^\\s]*", with: "$1/…")

        // ⑤ 数字だけの長い並び（電話・口座・番号の類）
        out = replace(out, pattern: "[0-9]{8,}", with: "***")

        return out
    }

    /// 場所らしき文字の並びを `~/…/***.pdf` の形に潰す。
    ///
    /// ⚠️ 残すのは「家の下か・何階層か・種類（拡張子）」まで。
    /// フォルダ名とファイル名は、そこに仕事の相手の名前が入りうるので全部伏せる。
    static func redactPaths(_ text: String) -> String {
        // 空白で切って、場所に見えるものだけ潰す（文章まで壊さない）
        let parts = text.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
        let masked = parts.map { part -> String in
            guard part.contains("/"), part.hasPrefix("~/") || part.hasPrefix("/") else { return part }
            let components = part.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
            guard components.count >= 1 else { return part }
            let head = part.hasPrefix("~") ? "~" : ""
            // 最後の要素の拡張子だけ残す（.pdf なのか .enc なのかは追うのに要る）
            let last = components[components.count - 1]
            var tail = "***"
            if let dot = last.lastIndex(of: "."), dot != last.startIndex {
                let ext = String(last[last.index(after: dot)...])
                // ⚠️ 拡張子らしいものだけ残す。「請求書.サンプル物産様」のような
                // 点入りの名前を拡張子と勘違いして残さない
                if ext.count <= 6, ext.allSatisfy({ $0.isASCII && $0.isLetter || $0.isNumber }) {
                    tail = "***." + ext
                }
            }
            // 途中のフォルダは数だけ示す（深さは追うのに使える）
            let middle = max(0, components.count - (head.isEmpty ? 1 : 2))
            let dots = middle > 0 ? "/…" : ""
            return head + dots + "/" + tail
        }
        return masked.joined(separator: " ")
    }

    private static func replace(_ text: String, pattern: String, with template: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        return regex.stringByReplacingMatches(
            in: text, range: NSRange(text.startIndex..., in: text), withTemplate: template)
    }

    // MARK: - 人に見せる形

    /// 送る前に**本人が中身を読める**形にする。
    ///
    /// ⚠️ 読めない形（JSONの塊）で「送りますか？」と聞くのは、聞いていないのと同じ。
    /// 何が送られるのかが分かる文にして、そのうえで決めてもらう。
    public static func report(entries: [Entry],
                              appVersion: String,
                              osVersion: String,
                              now: Date) -> String {
        var lines: [String] = []
        lines.append("テモトの不具合の記録")
        lines.append("作成: \(stamp(now))")
        lines.append("テモト: \(appVersion) ／ macOS: \(osVersion)")
        lines.append("")
        if entries.isEmpty {
            lines.append("記録はありません（うまくいかなかったことは1件も起きていません）。")
            return lines.joined(separator: "\n")
        }
        lines.append("記録: \(entries.count)件（新しい順）")
        lines.append("")
        for entry in entries.reversed() {
            var line = "\(stamp(entry.at))  [\(entry.area)] \(entry.what)"
            if !entry.detail.isEmpty { line += " — \(entry.detail)" }
            lines.append(line)
        }
        lines.append("")
        lines.append("※ 個人が分かるもの（家のフォルダ名・メール・鍵・URLの中身・長い番号）は伏せてあります。")
        lines.append("※ コピーした中身・定型文・メモの本文は、はじめから記録していません。")
        return lines.joined(separator: "\n")
    }

    /// 「2026-08-09 14:03」の形。
    /// ⚠️ 秒までは出さない（追うのに要らないし、行動の時刻を細かく残す意味も無い）
    public static func stamp(_ date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone.current
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        return String(format: "%04d-%02d-%02d %02d:%02d",
                      c.year ?? 0, c.month ?? 0, c.day ?? 0, c.hour ?? 0, c.minute ?? 0)
    }

    /// 同じ失敗が並んだときに、まとめて数える（何が一番起きているかを見やすくする）
    public static func summary(entries: [Entry]) -> [(what: String, count: Int)] {
        var counts: [String: Int] = [:]
        var order: [String] = []
        for entry in entries {
            let key = "[\(entry.area)] \(entry.what)"
            if counts[key] == nil { order.append(key) }
            counts[key, default: 0] += 1
        }
        return order
            .map { (what: $0, count: counts[$0] ?? 0) }
            .sorted { $0.count > $1.count }
    }
}
