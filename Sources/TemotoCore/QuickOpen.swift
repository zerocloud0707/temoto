import Foundation

/// 打った文字が、そのまま行き先に見えるとき（URL・フォルダ・ファイルの場所）。
///
/// 2026-08-05 作者「全ての入り口としてテモトを利用したい。」
///
/// ⚠️ 入口が「登録したものしか開けない」と、結局ブラウザやFinderを先に開くことになる。
/// 打った文字をそのまま行き先として扱える道が要る。
///
/// ⚠️ ただし**打ちかけを毎回行き先にしない**。
/// `note` `test` のような普通の言葉まで「https://note を開く」と出すと、
/// 一覧の先頭が毎回それに占領されて、探し物が1行下へ押し出される。
/// だから「見るからにURL」「実在する場所」に限る。
public enum QuickOpen {

    public enum Target: Equatable, Sendable {
        /// そのまま開くURL（scheme を補ったあとの形）
        case url(String)
        /// 開くフォルダ/ファイル（`~` を家の場所に開いたあとの形）
        case path(String)
    }

    /// 「これはファイルの名前だ」と分かる終わり方。
    /// ⚠️ `.app` と `.sh` は本物のドメインでもあるが、打つ人の意図はほぼファイル名なので入れる。
    static let fileEndings: Set<String> = [
        "md", "txt", "pdf", "png", "jpg", "jpeg", "gif", "webp", "heic", "svg",
        "doc", "docx", "xls", "xlsx", "ppt", "pptx", "csv", "json", "yml", "yaml",
        "swift", "py", "rb", "js", "ts", "html", "css", "zip", "dmg", "app", "sh",
        "key", "numbers", "pages", "mp3", "mp4", "mov", "log", "sql", "env",
    ]

    /// 打った文字がそのまま行き先になるか。
    /// - Parameters:
    ///   - home: 家のフォルダ（`~` を開くのに使う）
    ///   - exists: その場所が実在するか（実在しないパスは出さない）
    public static func detect(_ query: String, home: String, exists: (String) -> Bool) -> Target? {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }

        // 場所（/ か ~/ で始まる）。**実在するときだけ**出す
        if text.hasPrefix("/") || text.hasPrefix("~/") || text == "~" {
            let expanded = expand(text, home: home)
            return exists(expanded) ? .path(expanded) : nil
        }

        // 空白が入っていたら、それは文章か検索語（URLではない）
        guard !text.contains(" "), !text.contains("　") else { return nil }

        let lower = text.lowercased()
        if lower.hasPrefix("http://") || lower.hasPrefix("https://") { return .url(text) }
        if lower.hasPrefix("www.") { return .url("https://" + text) }

        // scheme が無くてもドメインに見えるもの（例: github.com/example）
        let head = String(lower.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)[0])
        // 打ち間違いで先頭や末尾に点が来ることがある（..や.foo は行き先にしない）
        let labels = head.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard labels.count >= 2, labels.allSatisfy({ !$0.isEmpty }) else { return nil }
        guard let last = labels.last, last.count >= 2,
              last.allSatisfy({ $0.isLetter && $0.isASCII }) else { return nil }
        // ファイルの名前に見えるものは行き先にしない（note.md を https://note.md にしない）
        guard !fileEndings.contains(last) else { return nil }
        guard labels.dropLast().allSatisfy({ label in
            label.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
        }) else { return nil }
        return .url("https://" + text)
    }

    /// `~` を家の場所に開く
    public static func expand(_ path: String, home: String) -> String {
        if path == "~" { return home }
        if path.hasPrefix("~/") { return home + String(path.dropFirst(1)) }
        return path
    }

    /// 見つからなかったときに逃げる先（Webで検索）。
    ///
    /// ⚠️ 既定の検索エンジンを外から知る方法が macOS には無いので、ここは Google に決め打つ。
    /// 打った言葉は**URLの中に入れる形で持っていく**ので、記号や日本語は必ず包んでから渡す。
    public static func webSearchURL(for query: String) -> String {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        let encoded = text.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
        return "https://www.google.com/search?q=" + encoded
    }
}
