import Foundation

/// リンクを作る・直すときの「入力の受け取り方」。
///
/// ⚠️ 定型文（`SnippetDraft`）と同じ考え方でここに置いている。
/// 画面（AppKit）の中に判断を書くと検証機で縛れず、
/// 2026-07-31 の「保存を押しても保存されない」のような失敗に気づけない。
public enum QuicklinkDraft {

    /// 打ったものを、開けるURLの形にそろえる。
    ///
    /// ⚠️ `https://` を付け足すのは、人は「github.com」と打つから。
    /// ここで直さないと「開けません」とだけ出て、何が悪いのか分からない。
    /// ただし `mailto:` や `raycast://` のような**別の仕組みは触らない**
    /// （勝手に https を付けると、その行き先が永久に開けなくなる）。
    public static func normalizedURL(_ input: String) -> String {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        // 「なにか:」で始まっていれば、すでに行き先の種類が書かれている
        if let colon = trimmed.firstIndex(of: ":") {
            let scheme = trimmed[trimmed.startIndex..<colon]
            let isScheme = !scheme.isEmpty && scheme.allSatisfy {
                $0.isLetter || $0.isNumber || $0 == "+" || $0 == "-" || $0 == "."
            }
            if isScheme, scheme.first?.isLetter == true { return trimmed }
        }
        return "https://" + trimmed
    }

    /// 開ける形になっているか。
    ///
    /// ⚠️ `{query}` は差し込む前だと URL として壊れて見えることがあるので、
    /// 判定の前に当たり障りのない文字へ置き換えてから見る。
    public static func isOpenable(_ url: String) -> Bool {
        let filled = url.replacingOccurrences(of: "{query}", with: "x")
        guard !filled.trimmingCharacters(in: .whitespaces).isEmpty,
              let parsed = URL(string: filled),
              let scheme = parsed.scheme, !scheme.isEmpty else { return false }
        // http(s) は行き先（ホスト）まで無いと開けない
        if scheme == "http" || scheme == "https" { return parsed.host?.isEmpty == false }
        return true
    }

    /// 一覧に出す名前を決める。空ならURLから作る（突き返さない）
    public static func resolvedTitle(title: String, url: String) -> String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        let filled = url.replacingOccurrences(of: "{query}", with: "")
        if let host = URL(string: filled)?.host, !host.isEmpty {
            return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        }
        let bare = url.trimmingCharacters(in: .whitespacesAndNewlines)
        return bare.isEmpty ? "名前のないリンク" : bare
    }
}
