import Foundation

/// 画面を撮る道具。
///
/// 2026-08-06 作者「キャプチャー機能つけれますか？？
/// 選択範囲や画面全部、画面スクロールでページ全体など。」
///
/// ⚠️ macOS には既に ⇧⌘4 も ⇧⌘5 もある。**同じものを作り直しても意味が無い。**
/// テモトで撮る値打ちは3つ:
///   ① 撮ったものが**そのままコピー履歴に載る**（あとから遡って貼れる）
///   ② 絵の中の文字が読まれて**検索で引ける**（既にある仕組みがそのまま効く）
///   ③ **スクロールしてページ全体**＝macOS 標準に無いもの
/// ①②は既にある土台の上に乗るだけなので、撮り方を増やすのは安い。
///
/// ⚠️ 撮るのは macOS 標準の道具（`screencapture`）に任せる。
/// 自前で範囲選択の窓を描くと、複数画面・拡大表示・スペースの扱いを全部自分で持つことになる。
public struct CaptureShot: Equatable, Sendable, Identifiable {

    /// 何を撮るか
    public enum Target: Equatable, Sendable {
        /// 自分で範囲を選ぶ
        case region
        /// 画面まるごと
        case screen
        /// ウィンドウ1枚（影つき）
        case window
        /// スクロールしながら何枚も撮って1枚に繋ぐ（macOS標準に無い）
        case scrollingPage
    }

    /// 撮ったあとどうするか
    public enum Output: Equatable, Sendable {
        /// 絵のままコピーする
        case image
        /// 絵の中の文字を読んでコピーする
        case text
    }

    public let id: String
    public let title: String
    public let subtitle: String
    public let symbol: String
    public let aliases: [String]
    public let target: Target
    public let output: Output

    public init(id: String, title: String, subtitle: String, symbol: String,
                aliases: [String], target: Target, output: Output) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.symbol = symbol
        self.aliases = aliases
        self.target = target
        self.output = output
    }

    /// `screencapture` に渡す引数。
    ///
    /// ⚠️ シェルは通さない。配列でそのまま渡す（打った文字が混ざる余地を作らない）。
    /// ⚠️ `-c` はクリップボードへ。`-o` は窓撮影のときに影を落とす（影があると切り抜きに困る）。
    /// ⚠️ `-x` は音を鳴らさない指定だが、**あえて使わない**。
    /// シャッター音は「いま撮れた」という唯一の合図で、消すと撮れたのか分からなくなる。
    public var arguments: [String] {
        switch target {
        case .region: return ["-i", "-c"]
        case .screen: return ["-c"]
        case .window: return ["-i", "-w", "-o", "-c"]
        // ⚠️ これだけ screencapture を1回呼んで終わりではない。
        // 何枚も撮って繋ぐので、引数は撮る側（ScrollCapture）が組み立てる
        case .scrollingPage: return []
        }
    }

    /// 画面収録の許可が要るか。
    ///
    /// ⚠️ 範囲選択（`-i`）は macOS 自身の選択画面が撮るので、許可が要らない。
    /// 画面まるごと（`-c` 単独）は**アプリが勝手に撮る**形になるので許可が要る。
    /// この違いを知らないと「範囲は撮れるのに全体だけ真っ黒」の原因が分からない。
    public var needsScreenRecording: Bool {
        // ⚠️ ページ全体は範囲を数値で指定して何枚も撮る＝アプリが自分で撮るので許可が要る
        target == .screen || target == .scrollingPage
    }

    /// スクロールを送るための「アクセシビリティ」の許可が要るか
    public var needsAccessibility: Bool {
        target == .scrollingPage
    }

    /// 入口の検索に出す一式。
    /// ⚠️ 行き先メニューには入れない。撮り方を4つ並べると、行き先が道具の一覧になる。
    /// 「画面の文字を読み取る」だけが行き先（いちばん使うため・2026-08-05 作者指示）。
    public static let all: [CaptureShot] = [
        CaptureShot(id: "shot.region", title: "範囲を撮る",
                    subtitle: "選んだところを絵のままコピーします",
                    symbol: "macwindow.badge.plus",
                    // ⚠️ 撮る系の言葉はここが持つ（文字読み取り側からは外した）。
                    // 同じ言葉を2つの行が持つと、打った人はどちらに行くのか読めない
                    aliases: ["kyaputya", "キャプチャ", "きゃぷちゃ", "capture", "スクショ", "sukusho",
                              "スクリーンショット", "screenshot", "撮る", "toru", "範囲", "はんい",
                              "切り取り", "きりとり"],
                    target: .region, output: .image),
        CaptureShot(id: "shot.screen", title: "画面全体を撮る",
                    subtitle: "いま見えている画面をまるごとコピーします",
                    symbol: "rectangle.on.rectangle",
                    aliases: ["gamen", "画面", "画面全体", "全体", "zentai", "fullscreen",
                              "全画面", "screen", "デスクトップ"],
                    target: .screen, output: .image),
        CaptureShot(id: "shot.window", title: "ウィンドウを撮る",
                    subtitle: "選んだウィンドウを1枚だけ（影つき）コピーします",
                    symbol: "macwindow",
                    // ⚠️ 「ウィンドウ」「window」は**行き先のウィンドウ操作が持っている**。
                    // 同じ言葉にすると、動かしたいのか撮りたいのかで行き先が読めなくなる。
                    // こちらは「撮る」が付いた形と、窓そのものを指す別の言い方だけを持つ
                    aliases: ["窓を撮る", "madowotoru", "ウィンドウを撮る", "アプリの画面",
                              "windowshot", "窓の写真"],
                    target: .window, output: .image),
        CaptureShot(id: "shot.page", title: "ページ全体を撮る",
                    subtitle: "前に出ている窓を、スクロールしながら1枚の長い絵にします",
                    symbol: "arrow.down.doc",
                    aliases: ["peiji", "ページ", "ページ全体", "全部", "長い", "縦長",
                              "scroll", "スクロール", "sukurooru", "fullpage", "たてなが"],
                    target: .scrollingPage, output: .image),
    ]
}
