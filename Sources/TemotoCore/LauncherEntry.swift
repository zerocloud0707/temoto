import Foundation

/// 検索窓の先頭に並ぶ「行き先」1つ分。
///
/// なぜ `LauncherMode` と別に要るのか（2026-07-29 作者）。
///   「ここに表示されるメニューを設定できる様にして欲しい。順番とか、不要なものは非表示。」
///
/// 作者の画面に並んでいた6行は、5つの行き先（`LauncherMode`）と**メモ**の混ざりものだった。
/// メモは行き先ではない（同じ窓の中身が変わるのではなく、別の窓が開く）ので
/// `LauncherMode` には入れられない。かといって並べ替えのときだけ別扱いにすると
/// 「メモだけ動かせない」ことになる。並べ替えのあいだだけ、この型で同じものとして扱う。
public enum LauncherEntry: Equatable, Hashable, Sendable {
    case mode(LauncherMode)
    case note
    /// 画面の一部を撮って、その中の文字をコピーする。
    /// 2026-08-05 作者「これコピー履歴や定型文と同じメニューに追加お願い！これよく使うと思うので。」
    ///
    /// ⚠️ メモと同じで**行き先ではない**（窓の中身が変わるのではなく、撮る道具が出る）。
    /// それでも並べ替え・隠すの対象にはしたいので、ここで同じものとして扱う。
    case captureText

    /// 既定の並び。settings.json に何も書いていないときはこの順で出る。
    ///
    /// ⚠️ 入口（`.all`）は入れない。あれは「戻る先」であって、
    /// 一覧に自分自身への入口を並べても押す意味がない。
    /// ⚠️ **新しい行き先は必ず末尾に足す。**
    /// 途中に入れると、既に指が覚えている ⌘番号が全部ずれる
    /// （2026-08-10 に計算を足したとき、宣言の順のままだとメモが ⌘6→⌘7 に動いた）。
    /// 並べ替えたい人は設定でできるので、既定は「後から来たものは後ろ」で通す。
    public static let allCases: [LauncherEntry] =
        LauncherMode.allCases.filter { $0 != .all && $0 != .calculator }.map(LauncherEntry.mode)
        + [.note, .captureText, .mode(.calculator)]

    /// 設定ファイルに書く名前。
    ///
    /// ⚠️ `hiddenFeatures`（隠すもの）と**同じ名前**を使う。
    /// 並べ替え用に別の名前を付けると、隠したのに並びには残る、が起きる。
    public var key: String {
        switch self {
        case .mode(let mode): return mode.rawValue
        case .note: return Settings.noteFeature
        case .captureText: return Settings.captureTextFeature
        }
    }

    public var title: String {
        switch self {
        case .mode(let mode): return mode.title
        case .note: return "メモ"
        case .captureText: return "画面の文字を読み取る"
        }
    }

    public var summary: String {
        switch self {
        case .mode(let mode): return mode.summary
        case .note: return "書き留めて、探して、呼び出す（保存先はアプリの中かフォルダの.md）"
        case .captureText: return "範囲を選ぶと、その中の文字をコピーします"
        }
    }

    public var symbolName: String {
        switch self {
        case .mode(let mode): return mode.symbolName
        case .note: return "note.text"
        case .captureText: return "text.viewfinder"
        }
    }

    /// 別の呼び方（かな・ローマ字・英語・言い換え）。
    ///
    /// 2026-08-05 作者「定型分ではなく、スニペットの方がいいかな？？そもそもスニペットって何？？」
    /// → **表示は日本語のまま**（作った本人が意味を聞く言葉は、名前として働いていない）。
    /// 代わりに**呼び方だけ人に合わせる**。「すにぺっと」でも「snippet」でも定型文に当たるようにする。
    ///
    /// ⚠️ 漢字の読み（teikei → 定型文）は ReadingIndex が別に面倒を見ているので、ここには書かない。
    /// ここに書くのは**読みでは絶対に当たらない言い換え**だけ（英語名・カタカナ語・通称）。
    public var aliases: [String] {
        switch self {
        case .mode(let mode): return mode.aliases
        case .note:
            return ["note", "memo", "ノート", "notoo", "書き置き", "付箋", "メモ帳"]
        case .captureText:
            // ⚠️ 「撮る」側の言葉（キャプチャ・スクショ）は**渡さない**。
            // 2026-08-06 に撮る道具（CaptureShot）を足したとき、こちらが撮る系の言葉を
            // 全部握っていて、打っても撮る行と見分けが付かなかった（検証が12件の重なりを検出）。
            // ここは「文字が欲しい」人の言葉だけを持つ。撮る系は CaptureShot が持つ。
            return ["ocr", "文字起こし", "mojiokoshi", "moji", "もじ", "文字", "文字認識",
                    "読み取り", "yomitori", "text", "テキスト", "書き起こし"]
        }
    }

    public var mode: LauncherMode? {
        if case .mode(let mode) = self { return mode }
        return nil
    }

    public static func from(key: String) -> LauncherEntry? {
        if key == Settings.noteFeature { return .note }
        if key == Settings.captureTextFeature { return .captureText }
        guard let mode = LauncherMode(rawValue: key), mode != .all else { return nil }
        return .mode(mode)
    }

    /// 決めた順を、いま存在するものに当てはめる。
    ///
    /// ⚠️ 3つとも守らないと、機能を足し引きしたときに黙って壊れる。
    ///   1. 決めた順に載っているものは、その順で前に出す
    ///   2. **載っていないものは、既定の順のまま後ろに足す**
    ///      … これが肝。新しい機能を足したとき、古い settings.json にその名前は無い。
    ///        「載っているものだけ出す」作りにすると、足した機能が誰の画面にも出てこず、
    ///        設定を開くまで気づけない（`hiddenFeatures` を差分で持っているのと同じ理由）
    ///   3. 決めた順にあるが、もう無いものは捨てる（機能を消しても壊れない）
    public static func ordered(_ order: [String],
                               among all: [LauncherEntry] = LauncherEntry.allCases) -> [LauncherEntry] {
        var remaining = all
        var result: [LauncherEntry] = []
        for key in order {
            // 同じ名前が2回書いてあっても、1回目で取り出して消えるので二重に出ない
            guard let index = remaining.firstIndex(where: { $0.key == key }) else { continue }
            result.append(remaining.remove(at: index))
        }
        return result + remaining
    }
}
