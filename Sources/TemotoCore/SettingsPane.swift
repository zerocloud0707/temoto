import Foundation

/// 設定画面の「横メニュー」に並ぶ項目。
///
/// 2026-08-14 作者「こんな感じの横メニューで高級感や操作性の高い構成にしたい」
/// （Raycast の設定画面を見ながら）。
///
/// それまでは上に7つのタブを並べていた。タブは**数が増えるほど1つずつが細くなり**、
/// 字が読めなくなる。横に置けば増えても縦に伸びるだけで済む。
/// macOS 自身のシステム設定も、Ventura でタブから横メニューへ移っている。
///
/// ⚠️ 記号に色を付けない（ここが分かれ目）。
/// 見本にした画面をよく見ると、設定の項目（General/Launcher/Shortcuts…）の記号は**無彩色**で、
/// 色が付いているのは下に並ぶ拡張機能＝別アプリの絵柄だけ。
/// テモトの規律「色が付くのは行き先のタイルだけ」（`ModeTint`）とも一致する。
/// ここで色を足すと、窓の中に**2つ目の色の言葉**ができて意味が薄まる。
public enum SettingsPane: String, CaseIterable, Sendable {
    case general
    case shortcuts
    case appKeys
    case features
    case apps
    case clipboard
    case fileSearch

    /// 横メニューに出す名前
    public var title: String {
        switch self {
        case .general: return "一般"
        case .shortcuts: return "ショートカット"
        case .appKeys: return "アプリのキー"
        case .features: return "使う機能"
        case .apps: return "出すアプリ"
        case .clipboard: return "コピー履歴"
        case .fileSearch: return "ファイル検索"
        }
    }

    /// 記号（SF Symbols の名前）。
    /// ⚠️ macOS 14 に無い名前を書くと、絵が出ないまま静かに空欄になる。
    /// 迷ったら古くからある名前を選ぶ（`sparkles` のような新顔は避ける）
    public var symbolName: String {
        switch self {
        case .general: return "gearshape"
        case .shortcuts: return "command"
        case .appKeys: return "keyboard"
        case .features: return "square.grid.2x2"
        case .apps: return "square.stack"
        case .clipboard: return "doc.on.clipboard"
        case .fileSearch: return "magnifyingglass"
        }
    }
}

/// 探せる設定の1つ。
///
/// 見本にした Raycast v2 も「設定そのものを検索できる」ことを売りにしている。
/// 設定が7画面もあると、**どの画面にあるか思い出せない**のが一番の詰まりどころ。
/// 名前を打てば画面ごと出せるようにする。
public struct SettingsItem: Equatable, Sendable {
    /// どの画面にあるか
    public let pane: SettingsPane
    /// 画面に出ている見出し（そのまま出すので、実物と同じ言い回しにする）
    public let title: String
    /// 別の呼び方。読み・英語・言い換えを入れておくと当たりやすい
    public let keywords: [String]

    public init(pane: SettingsPane, title: String, keywords: [String] = []) {
        self.pane = pane
        self.title = title
        self.keywords = keywords
    }
}

public enum SettingsSearch {
    /// 探せる設定の全部。
    ///
    /// ⚠️ 設定を足したらここにも足す。忘れても壊れないが、**探しても出てこない**。
    /// 画面の見出しと同じ言い回しで書くこと（別の言葉だと、出てきた行と実物が結びつかない）
    public static let items: [SettingsItem] = [
        // ⚠️ `title` は**画面に出ている文字そのまま**にする。
        // 探して出た名前と、開いた画面の見出しが違うと、目で追えず結局見つからない。
        // ここがずれていないかは `Temoto --check-settings-index` が実物を組み立てて確かめる
        // （2026-08-23、私が書いた14件が実物と違っていた。人の突き合わせでは無理だった）。

        // ── 一般
        SettingsItem(pane: .general, title: "Macの起動時にテモトを開く",
                     keywords: ["ログイン", "自動起動", "スタートアップ", "login"]),
        SettingsItem(pane: .general, title: "アクセシビリティの設定を開く",
                     keywords: ["権限", "許可", "accessibility", "貼り付けできない", "動かない"]),
        SettingsItem(pane: .general, title: "設定フォルダを開く",
                     keywords: ["保存先", "settings.json", "バックアップ", "書き出し", "置き場"]),
        SettingsItem(pane: .general, title: "問題を報告する…",
                     keywords: ["エラー", "不具合", "ログ", "報告", "problem", "調子が悪い", "うまくいかない"]),

        // ── ショートカット
        SettingsItem(pane: .shortcuts, title: "検索を開く",
                     keywords: ["ホットキー", "呼び出し", "hotkey", "起動キー", "オプションスペース"]),
        SettingsItem(pane: .shortcuts, title: "開くもの",
                     keywords: ["行き先", "直接開く", "コピー履歴を開く", "定型文を開く", "hotkey"]),
        SettingsItem(pane: .shortcuts, title: "ウィンドウを動かす",
                     keywords: ["半分", "整列", "配置", "最大化", "window"]),
        SettingsItem(pane: .shortcuts, title: "文字を変換",
                     keywords: ["ひらがな", "カタカナ", "全角", "半角", "convert"]),
        SettingsItem(pane: .shortcuts, title: "書式なしで貼り付け",
                     keywords: ["プレーン", "色を落とす", "書式", "paste", "plain"]),
        SettingsItem(pane: .shortcuts, title: "画面の文字を読み取る",
                     keywords: ["OCR", "キャプチャ", "スクショ", "読み取り"]),
        SettingsItem(pane: .shortcuts, title: "はじめの設定に戻す",
                     keywords: ["リセット", "初期化", "元に戻す"]),

        // ── アプリのキー
        SettingsItem(pane: .appKeys, title: "アプリを選ぶ…",
                     keywords: ["アプリ", "起動", "キー", "hotkey", "追加", "割り当て"]),

        // ── 使う機能
        SettingsItem(pane: .features, title: "検索窓に出すもの",
                     keywords: ["隠す", "並べ替え", "行き先", "オンオフ", "使わない"]),
        SettingsItem(pane: .features, title: "合言葉の自動展開",
                     keywords: ["スニペット", "定型文", "展開", "自動入力", "expand", "snippet", "略語"]),
        SettingsItem(pane: .features, title: "並び順を元に戻す",
                     keywords: ["リセット", "初期化", "並び"]),

        // ── 出すアプリ
        SettingsItem(pane: .apps, title: "探すフォルダを追加…",
                     keywords: ["フォルダ", "追加", "見つからない", "出てこない", "場所"]),
        SettingsItem(pane: .apps, title: "アプリを数え直す",
                     keywords: ["再読み込み", "更新", "rescan", "出てこない", "入れたばかり"]),
        SettingsItem(pane: .apps, title: "おすすめの状態に戻す",
                     keywords: ["リセット", "初期化", "選び直す"]),

        // ── コピー履歴
        SettingsItem(pane: .clipboard, title: "残す件数",
                     keywords: ["上限", "何件", "保存", "履歴"]),
        SettingsItem(pane: .clipboard, title: "残す日数",
                     keywords: ["期限", "何日", "古い", "自動で消える"]),
        SettingsItem(pane: .clipboard, title: "画像も残す（スクリーンショットなど）",
                     keywords: ["画像", "スクショ", "写真", "image"]),
        SettingsItem(pane: .clipboard, title: "画像の中の文字を読む（何の画像か題名で分かるようになります）",
                     keywords: ["OCR", "画像", "読み取り", "題名"]),
        SettingsItem(pane: .clipboard, title: "ファイルも残す（Finderでコピーしたもの）",
                     keywords: ["ファイル", "Finder", "コピー"]),
        SettingsItem(pane: .clipboard, title: "保存しないもの",
                     keywords: ["除外", "パスワード", "1password", "無視", "APIキー", "トークン", "秘密"]),
        SettingsItem(pane: .clipboard, title: "コピー履歴をすべて消す…",
                     keywords: ["削除", "クリア", "全部消す", "片付け"]),

        // ── ファイル検索
        SettingsItem(pane: .fileSearch, title: "探す場所（1行に1つ）",
                     keywords: ["フォルダ", "対象", "範囲", "どこを探す"]),
        SettingsItem(pane: .fileSearch, title: "中身も探す（名前に出てこない言葉でも見つかる）",
                     keywords: ["全文", "中身", "本文", "spotlight"]),
        SettingsItem(pane: .fileSearch, title: "出す件数",
                     keywords: ["上限", "多すぎる", "絞る", "何件"]),
    ]

    /// 打った字に当たる設定を返す。
    ///
    /// 決まり:
    /// - 空なら空を返す（＝探していない。呼ぶ側は全部の画面を出す）
    /// - 大文字小文字は無視する
    /// - 空白で区切ったら**全部を満たすもの**だけ（絞り込みになる）
    /// - 見出し・別の呼び方・画面の名前のどれかに含まれれば当たり
    /// - 並びは `items` の順のまま（打つたびに行が飛び跳ねると読めない）
    public static func find(_ query: String) -> [SettingsItem] {
        let words = query
            .folding(options: [.caseInsensitive, .widthInsensitive], locale: nil)
            .split(whereSeparator: { $0 == " " || $0 == "　" })
            .map(String.init)
        guard !words.isEmpty else { return [] }
        return items.filter { item in
            let hay = ([item.title, item.pane.title] + item.keywords)
                .joined(separator: "\u{1}")
                .folding(options: [.caseInsensitive, .widthInsensitive], locale: nil)
            return words.allSatisfy { hay.contains($0) }
        }
    }

    /// 当たった設定が置かれている画面を、横メニューの並び順で返す。
    /// ⚠️ `items` の順ではなく `allCases` の順に直す（横メニューの並びが打つたびに変わらないように）
    public static func panes(matching query: String) -> [SettingsPane] {
        let hit = Set(find(query).map(\.pane))
        return SettingsPane.allCases.filter { hit.contains($0) }
    }
}
