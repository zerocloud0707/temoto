import Foundation

/// 検索窓の中で「今どこにいるか」。
///
/// ⚠️ これがテモトの作りの核心。
///
/// 前の作りは、ホットキーごとに別々の窓を出していた。
/// 作者の言葉:「一つ一つが別アプリみたいやし」。まさにそのとおりで、
/// 履歴を見ている最中に定型文へ行くには、いったん閉じて別のキーを押し直すしかなかった。
///
/// 直し方は「窓を1つに保ち、その中でここを行き来する」こと。
/// 窓は増やさない。増えるのは行き先だけ。
public enum LauncherMode: String, CaseIterable, Sendable {
    /// 入口。アプリ・コマンドを探しつつ、他の行き先への入口も並べる
    case all
    /// コピーした履歴
    case clipboard
    /// ファイルを横断して探す（Spotlight）
    case files
    /// 定型文
    case snippets
    /// よく使うリンク
    case links
    /// ウィンドウの分割
    case windows
    /// 計算（2026-08-10 作者「計算ようのメニューが欲しい。計算機能強めて。」）。
    /// ⚠️ 入口で式を打てば前から答えは出ていたが、**一覧に名前が無いので気づけなかった**。
    /// 動くかどうかより、在ると分かるかどうかが先だった
    case calculator

    /// 一覧の入口行に出す名前
    public var title: String {
        switch self {
        case .all: return "すべて"
        case .clipboard: return "コピー履歴"
        case .files: return "ファイル検索"
        case .snippets: return "定型文"
        case .links: return "リンク"
        case .windows: return "ウィンドウ操作"
        case .calculator: return "計算"
        }
    }

    /// 入口行の説明
    public var summary: String {
        switch self {
        case .all: return "アプリ・コマンド・すべての行き先"
        case .clipboard: return "コピーした文字をさかのぼって貼り付ける"
        case .files: return "名前でも中身でもパソコン中のファイルを探す"
        case .snippets: return "登録した文章を呼び出して貼り付ける"
        case .links: return "登録したページを開く"
        case .windows: return "今いちばん前のウィンドウを画面の半分などに動かす"
        case .calculator: return "式を打つと答えが出る。前の答えを続けて使える"
        }
    }

    /// 別の呼び方（かな・ローマ字・英語・通称）。
    ///
    /// 2026-08-05 作者「そもそもスニペットって何？？」
    /// → 表示名は日本語のまま。ただし**海外のアプリで慣れた呼び方でも引ける**ようにする。
    /// テモトを人に見せたとき「スニペットは無いの？」と言われて終わらないための道。
    ///
    /// ⚠️ 漢字の読み（teikei → 定型文）は ReadingIndex が別に見るので、ここには書かない。
    /// ここに書くのは**読みでは絶対に当たらない言い換え**だけ。
    public var aliases: [String] {
        switch self {
        case .all: return []
        case .clipboard:
            return ["clipboard", "クリップボード", "kurippubodo", "コピペ", "copipe",
                    "履歴", "ペースト", "paste", "pasteboard"]
        case .files:
            return ["file", "ファイル", "fairu", "spotlight", "スポットライト",
                    "書類", "shorui", "ドキュメント", "document", "finder"]
        case .snippets:
            return ["snippet", "snippets", "スニペット", "すにぺっと", "sunipetto",
                    "テンプレ", "テンプレート", "template", "よく使う文", "貼り付け文"]
        case .links:
            return ["link", "links", "リンク", "ブックマーク", "bookmark", "url",
                    "お気に入り", "quicklink", "ショートカットリンク"]
        case .windows:
            return ["window", "ウィンドウ", "uindou", "分割", "bunkatsu", "整列",
                    "タイル", "tile", "半分", "画面配置", "レイアウト", "layout"]
        case .calculator:
            return ["keisan", "計算", "けいさん", "電卓", "dentaku", "calc", "calculator",
                    "そろばん", "四則", "たしざん", "percent", "パーセント", "税込", "税抜",
                    "消費税", "zeikomi"]
        }
    }

    /// 検索欄の左に出す札。入口には出さない
    public var chip: String? {
        self == .all ? nil : title
    }

    /// 検索欄の薄い文字
    public var placeholder: String {
        switch self {
        // ⚠️ ローマ字でも引けることをここで言う。
        // 「定型文」が teikei で出るのがテモトの取り柄なのに、
        // 黙っていると誰も試さないまま「日本語では出ない」と思われて終わる。
        case .all: return "アプリ・コマンドを検索（ローマ字でも可）"
        case .clipboard: return "コピーした履歴を検索"
        // ⚠️ ここで例を見せないと、日本語で絞れることに誰も気づかない。
        case .files: return "ファイルを検索（例: 請求書 pdf 今月）"
        case .snippets: return "定型文を検索（ローマ字でも可）"
        case .links: return "リンクを検索（ローマ字でも可）"
        case .windows: return "ウィンドウの動かし方を検索"
        case .calculator: return "式を打つ（例: 1234567*1.1 ／ 3万+5000 ／ ans/12）"
        }
    }

    /// 下部に並べる操作。**押せる操作しか書かない**
    ///
    /// ⚠️ ここを1本の文字列ではなく組にしているのは、画面でキーを枠に入れて描くため。
    /// 「Enter で貼り付け」とベタ書きの一行に戻すと、どこまでがキーで
    /// どこからが説明なのか読み取れず、結局その行は読み飛ばされる。
    public var actions: [HintAction] {
        switch self {
        case .all:
            return [
                HintAction("⏎", "実行"),
                HintAction("↑↓", "移動"),
                HintAction("Tab", "行き先"),
                HintAction("⌘,", "設定"),
                HintAction("esc", "閉じる", isEssential: true),
            ]
        case .clipboard:
            return [
                HintAction("⏎", "貼り付け"),
                // ⚠️ 書かなければ誰も気付かない。⇧↑↓ は打っている文字を邪魔せずに
                // 選ぶ範囲を広げられる唯一のキー（2026-08-09「コピーする際に複数選択したい」）
                HintAction("⇧↑↓", "複数選ぶ"),
                HintAction("⌘C", "コピー"),
                HintAction("⌘P", "ピン留め"),
                HintAction("⌘⌫", "削除"),
                HintAction("esc", "戻る", isEssential: true),
            ]
        // ⚠️ Quick Look は Finder では Space だが、ここは検索欄に文字を打ち続ける画面なので
        // Space は「空白を打つ」以外にできない（打つと語の区切りになる）。だから ⌘Y。
        case .files:
            // ⚠️ 「つまんで運べる」は書かないと誰も試さない。
            // キーではないので `HintAction` の左が空になるが、
            // ここに出さないと「アップロードに使える」ことに一生気づかない
            // （2026-08-30「ドラッグ&ドロップし、どこかにアップしたりできる様にしたい」＝
            //  実装したその日に、案内も一緒に出す）
            // ⚠️ 並びは**よく使う順**。案内バーは狭いと後ろから隠すので、
            // ここの順がそのまま「狭い画面で何が残るか」になる。
            // 見つけたファイルにすることは、開く → 他所へ渡す → 場所を見る、の順に多い
            return [
                HintAction("⏎", "開く"),
                HintAction("ドラッグ", "運ぶ"),
                HintAction("⌘⏎", "Finder"),
                HintAction("⌘Y", "中身"),
                HintAction("⌘C", "パス"),
                HintAction("⌥⏎", "コピー"),
                HintAction("esc", "戻る", isEssential: true),
            ]
        case .snippets:
            // ↑↓ は削って、作る・直す・消すを出す（2026-07-31「新規作成できない。この画面からできるようにしたい」。
            // ↑↓ が動くことは触れば分かるが、⌘N はここに書かないと誰にも見つけられない）
            return [
                HintAction("⏎", "貼り付け"),
                HintAction("⌘N", "新規"),
                HintAction("⌘E", "編集"),
                HintAction("⌘⌫", "削除"),
                HintAction("esc", "戻る", isEssential: true),
            ]
        case .links:
            // 定型文と同じ並び（2026-07-31「リンク追加できない」。作る入口が画面に無かった）
            return [
                HintAction("⏎", "開く"),
                HintAction("⌘N", "新規"),
                HintAction("⌘E", "編集"),
                HintAction("⌘⌫", "削除"),
                HintAction("esc", "戻る", isEssential: true),
            ]
        case .calculator:
            return [
                HintAction("⏎", "答えを貼る"),
                HintAction("⌘C", "答えをコピー"),
                HintAction("⌘⌫", "履歴を消す"),
                HintAction("esc", "戻る", isEssential: true),
            ]
        case .windows:
            return [
                HintAction("⏎", "いちばん前の窓に適用"),
                HintAction("↑↓", "移動"),
                HintAction("esc", "戻る", isEssential: true),
            ]
        }
    }

    /// 1行の文字にしたもの（枠を描けない場所で使う）
    public var hint: String {
        actions.map { "\($0.keys) \($0.label)" }.joined(separator: "　")
    }

    /// 入口行のアイコン（SF Symbols）
    public var symbolName: String {
        switch self {
        case .all: return "square.grid.2x2"
        case .clipboard: return "doc.on.clipboard"
        case .files: return "doc.text.magnifyingglass"
        case .snippets: return "text.quote"
        case .links: return "link"
        case .windows: return "rectangle.split.2x1"
        case .calculator: return "equal.square"
        }
    }

    // ⌘1〜⌘9 の番号はここには無い。
    //
    // ⚠️ 2026-07-29 に固定の番号（clipboard=1, files=2, …）をやめた。
    // 作者が行き先を並べ替えられるようにしたので、番号を機能ごとに固定していると
    // 「1番上に置いたのに札は ⌘3」という読めない画面になる。
    // 番号は**見た目の順**から出す＝`Settings.directNumber(for:)` が1か所で持つ。

    /// esc を押したときの戻り先。
    /// `nil` は「これ以上戻れない＝窓を閉じる」という意味。
    ///
    /// 階層は意図的に浅くしている（すべて ←→ 行き先）。
    /// 深くすると、どこにいるのか分からなくなって結局「別アプリ」に戻る。
    public var parent: LauncherMode? {
        self == .all ? nil : .all
    }

    /// Tab を押したときの次の行き先。
    ///
    /// `enabled` は設定で表示している行き先だけを渡す。
    /// 使わない機能を切った人が、Tab でその機能に着地しないようにするため。
    public func next(within enabled: [LauncherMode]) -> LauncherMode {
        LauncherMode.step(from: self, by: 1, within: enabled)
    }

    public func previous(within enabled: [LauncherMode]) -> LauncherMode {
        LauncherMode.step(from: self, by: -1, within: enabled)
    }

    private static func step(from current: LauncherMode, by delta: Int, within enabled: [LauncherMode]) -> LauncherMode {
        // 入口は必ず巡回に含める。全部切られても迷子にならないように。
        var ring = enabled.filter { $0 != .all }
        ring.insert(.all, at: 0)
        guard ring.count > 1 else { return .all }

        let index = ring.firstIndex(of: current) ?? 0
        let moved = (index + delta % ring.count + ring.count) % ring.count
        return ring[moved]
    }
}
