import Foundation

/// 行き先の持ち色（システム設定のサイドバー式＝色のタイルに白い記号）。
///
/// 2026-08-02 作者「デザインがワクワクしない。。もう少し工夫できないかな」。
/// 「色がありすぎ」（7/30）の反省で色を全部抜いたら、今度は楽しさまで消えた。
/// 答えは無色ではなく**しつけられた色**。Apple自身がシステム設定でやっている
/// 「彩度のあるタイル＋白い記号」を、**行き先の6つにだけ**使う。
///
/// ⚠️ 色の規律（ここで決めて、検証で縛る）:
/// 1. 色が付くのは**行き先のタイルだけ**。コマンド・ファイル・履歴の行は無彩色のまま
/// 2. 白い記号が読める明るさに収める（輝度 0.25〜0.62）
/// 3. 行き先どうしで色がかぶらない（見分けが色でも付く）
public struct ModeTint: Equatable, Sendable {
    public let red: Double
    public let green: Double
    public let blue: Double

    public init(red: Double, green: Double, blue: Double) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    /// 白い記号とのぶつかりを見るための明るさ（相対輝度の近似）
    public var luminance: Double {
        0.2126 * red + 0.7152 * green + 0.0722 * blue
    }

    /// 2色の離れ具合（かぶり検査に使う）
    public func distance(to other: ModeTint) -> Double {
        let dr = red - other.red, dg = green - other.green, db = blue - other.blue
        return (dr * dr + dg * dg + db * db).squareRoot()
    }

    // MARK: - 持ち色の割り当て

    /// コピー履歴＝青（クリップボードの定番）
    public static let clipboard = ModeTint(red: 0.25, green: 0.52, blue: 0.95)
    /// ファイル検索＝琥珀（書類の紙色）
    public static let files = ModeTint(red: 0.93, green: 0.55, blue: 0.18)
    /// 定型文＝緑（すぐ使える・出来上がりの色）
    public static let snippets = ModeTint(red: 0.22, green: 0.66, blue: 0.40)
    /// リンク＝青緑（水路・つながり）。
    /// ⚠️ 最初の値（0.20,0.60,0.76）はコピー履歴の青と距離0.21でかぶり検査に落ちた。
    /// 緑へ寄せて離してある（検査が「色が近すぎて見分けにくい」を先に見つけた例）
    public static let links = ModeTint(red: 0.13, green: 0.65, blue: 0.66)
    /// ウィンドウ操作＝紫（画面の配置換え）
    public static let windows = ModeTint(red: 0.56, green: 0.42, blue: 0.90)
    /// メモ＝ローズ（付箋の色。黄色は白い記号が読めないので使わない）
    public static let note = ModeTint(red: 0.90, green: 0.40, blue: 0.52)
    /// 計算＝藍（深い青紫）。
    /// ⚠️ 8色目。最初に置いた (0.36,0.34,0.72) は**道具の青灰と距離0.222**で、
    /// かぶり検査の 0.25 に届かず落ちた（検査が先に見つけた2度目の例）。
    /// 彩度優先で自動探索するとマゼンタのような派手な色が出るが、この製品の規律に合わない。
    /// 濃さと青みを深くして、7色すべてから 0.29 以上離した値がこれ。
    public static let calculator = ModeTint(red: 0.42, green: 0.18, blue: 0.80)
    /// 画面の文字を読み取る＝青灰（スレート）。
    ///
    /// ⚠️ ここだけ彩度を落としてあるのは、手抜きではなく**空きが無い**から。
    /// 既にある6色で色相はほぼ埋まっていて、7色目に彩度の高い色を入れると必ずどれかと近づく
    /// （実際に試した: マゼンタ寄り(0.72,0.30,0.80)は紫と距離0.22で、かぶり検査の0.25に届かない）。
    /// ⚠️ そして意味の上でも正しい。他の6つは**行き先＝場所**だが、これは**道具**。
    /// 同じ列に並んでいても種類が違うことが、色で分かる方がよい。
    public static let captureText = ModeTint(red: 0.42, green: 0.47, blue: 0.55)

    /// 行き先ごとの持ち色。「すべて」は行き先の行にならないので持たない
    public static func tint(for mode: LauncherMode) -> ModeTint? {
        switch mode {
        case .all: return nil
        case .clipboard: return clipboard
        case .files: return files
        case .snippets: return snippets
        case .links: return links
        case .windows: return windows
        case .calculator: return calculator
        }
    }

    /// 検査用: 使っている持ち色の全部。
    /// ⚠️ 色を足したらここにも必ず足す。忘れると、かぶり検査を素通りして
    /// 「見分けの付かない2色」が画面に出る（検査があるのに効かない状態が一番たちが悪い）。
    public static var all: [ModeTint] {
        [clipboard, files, snippets, links, windows, note, captureText, calculator]
    }

    /// 行き先ごとの持ち色（メモ・道具も含めた全部）。
    /// ⚠️ `tint(for mode:)` はモードしか見られないので、モードでない行き先はここで引く。
    public static func tint(for entry: LauncherEntry) -> ModeTint? {
        switch entry {
        case .mode(let mode): return tint(for: mode)
        case .note: return note
        case .captureText: return captureText
        }
    }
}
