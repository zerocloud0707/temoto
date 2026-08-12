import Foundation

/// 一覧に何も出ないときに、何と書くかを決める。
///
/// ⚠️ ここを AppKit 側ではなくライブラリに置いた理由。
///
/// 空っぽの画面は「アプリが壊れた」と受け取られやすい一番の場所なのに、
/// 目で見て確かめるのが一番むずかしい（空にするには、まず空になる条件を作らないといけない）。
/// 文言を計算として切り出しておけば、機械で全部の場合を通せる。
///
/// 決めごと:
/// - **理由を必ず言う**（「無い」のか「まだ登録していない」のか「探している最中」なのか）
/// - **次にできることを添える**。ただし**押せることしか書かない**
///   （「許可してください」と書いたのに作者が許可できなかった一件の反省）
public enum EmptyState {

    public struct Message: Equatable, Sendable {
        /// SF Symbols の名前
        public let symbol: String
        /// 太字で出す一文。今どういう状態か
        public let title: String
        /// 下に小さく出す一文。次に何をすればいいか（無いなら空）
        public let detail: String

        public init(symbol: String, title: String, detail: String) {
            self.symbol = symbol
            self.title = title
            self.detail = detail
        }
    }

    /// - Parameters:
    ///   - mode: 今いる行き先
    ///   - query: 検索欄に打たれている文字
    ///   - isSearching: 探している最中か（ファイル検索だけ非同期なので起こる）
    ///   - hasSource: そもそも元になる項目を持っているか。
    ///     `false` は「絞った結果0件」ではなく「まだ1件も登録していない」という意味。
    ///     ここを区別しないと、登録0件の人に「見つかりません」と出てしまい、
    ///     自分の使い方が悪いのかアプリが壊れているのか分からなくなる。
    public static func message(mode: LauncherMode, query: String,
                               isSearching: Bool, hasSource: Bool) -> Message {
        let trimmed = query.trimmingCharacters(in: .whitespaces)

        if isSearching {
            return Message(symbol: "hourglass", title: "探しています…", detail: "")
        }

        // ファイル検索だけは、打つまで何も出せない（全件を出すと数十万件になる）
        if mode == .files, trimmed.isEmpty {
            return Message(
                symbol: "doc.text.magnifyingglass",
                title: "探したい言葉を打ってください",
                detail: "例: 請求書 pdf 今月　／　議事録 中身:見積")
        }

        if !hasSource {
            return emptySource(mode)
        }

        return Message(
            symbol: "magnifyingglass",
            title: trimmed.isEmpty ? "出せるものがありません" : "「\(trimmed)」に当たるものがありません",
            detail: notFoundDetail(mode))
    }

    /// まだ1件も持っていないとき。**どうすれば増えるか**を書く
    private static func emptySource(_ mode: LauncherMode) -> Message {
        switch mode {
        case .all:
            return Message(symbol: "square.grid.2x2", title: "出せるものがありません",
                           detail: "⌘, の「出すアプリ」で、隠したアプリを戻せます")
        case .clipboard:
            return Message(symbol: "doc.on.clipboard", title: "コピーした履歴はまだありません",
                           detail: "どこかで文字や絵をコピーすると、ここに溜まります")
        case .files:
            return Message(symbol: "doc.text.magnifyingglass", title: "見つかりませんでした",
                           detail: "⌘, の「ファイル検索」で、探す場所を増やせます")
        case .snippets:
            return Message(symbol: "text.quote", title: "定型文はまだありません",
                           detail: "⌘, の「使う機能」から、よく打つ文章を登録できます")
        case .links:
            return Message(symbol: "link", title: "リンクはまだありません",
                           detail: "⌘, から、よく開くページを登録できます")
        case .calculator:
            return Message(symbol: "equal.square",
                           title: "式を打つと、ここに答えが出ます",
                           detail: "例: 1234567*1.1　／　3万+5000　／　(1200+800)*3　／　ans/12")
        case .windows:
            return Message(symbol: "rectangle.split.2x1", title: "動かし方がありません", detail: "")
        }
    }

    /// 絞った結果0件のとき。**打ち方の逃げ道**を書く
    private static func notFoundDetail(_ mode: LauncherMode) -> String {
        switch mode {
        case .all:
            return "ローマ字でも探せます（例: teikei で「定型文」）"
        case .clipboard:
            return "esc で全部の履歴に戻ります"
        case .files:
            // ⚠️ 0件のときこそ、絞りすぎている可能性が高い。減らす方向の逃げ道を出す
            return "言葉を減らしてみてください。「中身も」と打つと本文まで探せます"
        case .snippets, .links:
            return "ローマ字でも探せます"
        case .windows:
            return "esc で全部の動かし方に戻ります"
        case .calculator:
            // ⚠️ 計算は「見つからない」ではなく「式として読めない」。言い方を変えないと、
            // 打ち方が悪いのか壊れているのかが分からない
            return "式として読めませんでした。使えるのは + - * / ( ) と 万・億・％"
        }
    }
}
