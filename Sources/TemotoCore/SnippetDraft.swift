import Foundation

/// 定型文を作る・直すときの「入力の受け取り方」。
///
/// ⚠️ ここに置いてある理由。
/// 2026-07-31、作者が定型文を作ろうとして「保存を押しても保存されない」。
/// 当時の作りは、名前か本文が空だと **打った内容ごと捨てて黙って閉じる** だった。
/// 画面（AppKit）の中に判断を書いていたので、検証機で気づけなかった。
/// 「何を空とみなすか」「名前が無いときどうするか」はここで決めて、検証で縛る。
public enum SnippetDraft {

    /// 本文が空か。空白・改行だけのものも空とみなす（貼り付けても何も起きないため）
    public static func isEmptyBody(_ body: String) -> Bool {
        body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// 一覧に出す名前を決める。
    ///
    /// ⚠️ 名前が空でも突き返さない。本文の1行目から作る。
    /// 「名前が空です」と言って閉じるのは、打った本文を捨てることとほぼ同じ。
    /// - Parameter maxLength: 長い1行目はここで切る（一覧の行に収まる長さ）
    public static func resolvedTitle(title: String, body: String, maxLength: Int = 24) -> String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }

        let firstLine = body
            .split(separator: "\n", omittingEmptySubsequences: true)
            .first?
            .trimmingCharacters(in: .whitespaces) ?? ""
        if firstLine.isEmpty { return "名前のない定型文" }
        guard firstLine.count > maxLength else { return firstLine }
        return String(firstLine.prefix(maxLength)) + "…"
    }
}
