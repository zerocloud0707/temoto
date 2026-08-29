import Foundation

/// 画面に出す文字を作る係。
/// AppKitに触れない純粋な計算だけを置く（そうしないと検証できないため）。

public enum ClipFormatter {
    /// 「3分前」のような相対表記
    public static func relative(_ date: Date, now: Date = Date()) -> String {
        let seconds = Int(now.timeIntervalSince(date))
        if seconds < 0 { return "たった今" }
        if seconds < 60 { return "たった今" }
        if seconds < 3600 { return "\(seconds / 60)分前" }
        if seconds < 86_400 { return "\(seconds / 3600)時間前" }
        return "\(seconds / 86_400)日前"
    }
}

/// 絵の行に出す文字を決める係。
///
/// ⚠️ ここが存在する理由（2026-07-30 作者の指摘「どんな画像かわかりにくい」）。
/// 以前は題名が「画像 912×592」だった。大きさは、絵を選ぶときに一番どうでもいい情報で、
/// 履歴に絵が3枚あると3行とも同じ顔になって見分けがつかなかった。
/// 絵の中に写っている文字を題名にすれば、そのまま「何の絵か」になる。
public enum ImageCaption {

    /// 保存してよい長さ。
    /// ⚠️ 書類のスクリーンショットを丸ごと抱えると clips.enc が一気に膨らむ。
    /// 全件を1つの封筒に入れて毎回書き直す作りなので、1件の重さがそのまま毎回の書き込み量になる。
    public static let maxStoredCharacters = 400

    /// 題名に出す長さ。行に収まる以上は持っていても意味がない。
    public static let maxTitleCharacters = 80

    /// 読み取った生の文字を、保存してよい形に整える。
    ///
    /// 改行は「・」ではなく空白で繋ぐ。読み取りは行ごとに返ってくるので、
    /// 表を読むと1文字ずつ改行が入ることがあり、記号で繋ぐと題名が記号だらけになる。
    public static func trimForStorage(_ raw: String) -> String {
        let flattened = raw
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\t", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
        // 連続した空白を1つに畳む（読み取りは語の間に余分な空白を入れがち）
        var squeezed = ""
        var lastWasSpace = false
        for character in flattened {
            let isSpace = character == " " || character == "\u{3000}"
            if isSpace && lastWasSpace { continue }
            squeezed.append(isSpace ? " " : character)
            lastWasSpace = isSpace
        }
        let trimmed = squeezed.trimmingCharacters(in: .whitespacesAndNewlines)
        return String(trimmed.prefix(maxStoredCharacters))
    }

    /// 大きさだけの表示（文字が読めなかったとき・読む前）
    public static func sizeLabel(_ info: ClipImageInfo) -> String {
        "\(info.pixelWidth)×\(info.pixelHeight)"
    }

    /// 一覧の題名。
    ///
    /// 出し分けは3通り。
    /// - 秘密が写っていた → 文字は出さず、警告を出す（絵は残っているので目で確かめられる）
    /// - 文字が読めた → その文字
    /// - 文字が無かった／まだ読んでいない → 今までどおり大きさ
    public static func title(for info: ClipImageInfo) -> String {
        if info.secretHint != nil { return "⚠️ 画像 \(sizeLabel(info))" }
        if let text = info.recognizedText?.trimmingCharacters(in: .whitespacesAndNewlines),
           !text.isEmpty {
            return String(text.prefix(maxTitleCharacters))
        }
        return "画像 \(sizeLabel(info))"
    }

    /// 副題の右に足す説明。
    ///
    /// ⚠️ 題名が読み取った文字に化けると、大きさの行き場が無くなる。
    /// 大きさは選ぶ手掛かりとしては弱いが、貼る前に知りたいことではあるので副題に移す。
    public static func detail(for info: ClipImageInfo) -> String {
        var parts: [String] = []
        if let hint = info.secretHint { parts.append("秘密が写っている可能性: \(hint)") }
        parts.append(sizeLabel(info))
        parts.append(ByteSize.label(info.byteCount))
        return parts.joined(separator: "・")
    }

    /// この絵はまだ文字を読みに行っていないか。
    /// 起動時に古い履歴をまとめて読み直すときの目印。
    public static func needsScan(_ info: ClipImageInfo) -> Bool {
        !info.textScanned
    }
}

/// 右側の「中身の下見」に出すものを決める係。
///
/// ⚠️ ここが存在する理由（2026-07-30 作者「画像の表示がやっぱりわかりにくい」）。
/// 一覧の行をいくら工夫しても、小さな枠に画面写真を押し込んだら中身は読めない。
/// 見分ける仕事は右半分のプレビューに任せ、一覧は「探して選ぶ」ことに徹する。
/// 何をどう出すかはここで決める（AppKitに触れない＝検証できる）。
public enum ItemPreview {

    /// 右側に出す中身
    public enum Content: Equatable, Sendable {
        /// 文字（履歴の全文・定型文の本文）。一覧と違って改行もそのまま出す
        case text(String)
        /// 絵。実体の読み込みは画面側の仕事（ここはデータを持たない）
        case image
        /// ファイル名の並び。
        /// ⚠️ 名前だけにする。絶対パスを大きく出すと、画面を人に見せたときに漏れる。
        /// 置き場所は情報欄に「~」で畳んだ形で出す
        case fileNames([String])
    }

    /// 下の情報欄の1行
    public struct Info: Equatable, Sendable {
        public let label: String
        public let value: String
        /// 秘密の警告など、色を変えて目立たせる行
        public let isWarning: Bool

        public init(_ label: String, _ value: String, isWarning: Bool = false) {
            self.label = label
            self.value = value
            self.isWarning = isWarning
        }
    }

    public struct Spec: Equatable, Sendable {
        public let content: Content
        public let info: [Info]

        public init(content: Content, info: [Info]) {
            self.content = content
            self.info = info
        }
    }

    /// コピー履歴の1件をプレビューに変える
    public static func spec(for clip: ClipItem, now: Date = Date()) -> Spec {
        // どこから・いつ は全種類に共通。
        // アプリが分からないとき（テモト自身を除外した直後など）は行ごと出さない
        // （「不明」と書かれた行は、読む人に何も足さない）。
        var info: [Info] = []
        if let app = clip.sourceAppName, !app.isEmpty { info.append(Info("アプリ", app)) }
        info.append(Info("いつ", ClipFormatter.relative(clip.copiedAt, now: now)))

        switch clip.kind {
        case .text:
            info.append(Info("文字数", "\(clip.text.count)文字"))
            return Spec(content: .text(clip.text), info: info)

        case .image:
            guard let image = clip.image else { return Spec(content: .image, info: info) }
            // ⚠️ 警告は先頭に置く。下に沈めると、絵に目が行って読まれない
            if let hint = image.secretHint {
                info.insert(Info("注意", "秘密が写っている可能性: \(hint)", isWarning: true), at: 0)
            }
            info.append(Info("大きさ", ImageCaption.sizeLabel(image)))
            info.append(Info("容量", ByteSize.label(image.byteCount)))
            return Spec(content: .image, info: info)

        case .file:
            let names = clip.filePaths.map(ClipItem.lastComponent)
            if let first = clip.filePaths.first {
                info.append(Info("場所", ClipItem.parentComponent(first)))
            }
            if clip.filePaths.count > 1 {
                info.append(Info("個数", "\(clip.filePaths.count)件"))
            }
            return Spec(content: .fileNames(names), info: info)
        }
    }

    /// 定型文をプレビューに変える。
    /// 本文は差し込み前の生の形で出す（{date} が何になるかではなく、何が書いてあるかを確かめる場所）。
    ///
    /// - Parameter expandsEverywhere: 合言葉の自動展開が入っているか。
    ///
    /// ⚠️ `expandsEverywhere` を受け取る理由（2026-08-23 作者
    /// 「mailzと入力しても、you@example.com が自動入力されない」）。
    /// この画面は「キーワード mailz」とだけ出していた。**キーワードがあると書いてあれば、
    /// 打てば効くと思う**のが当たり前で、実際は設定が切だったから何も起きなかった。
    /// 「登録されている」と「今それが効く」は別の話なので、両方をここで言う。
    /// ⚠️ 切のときは、どこを入れればよいかまで書く。「切です」だけでは探しに行けない
    public static func spec(for snippet: Snippet, expandsEverywhere: Bool = false) -> Spec {
        var info: [Info] = []
        if !snippet.keyword.isEmpty {
            info.append(Info("キーワード", snippet.keyword))
            info.append(expandsEverywhere
                ? Info("自動展開", "入（英数で「\(snippet.keyword)」と打つと、どのアプリでも本文に変わります）")
                : Info("自動展開", "切（設定 → 使う機能 → 合言葉の自動展開 で入れられます）", isWarning: true))
        }
        info.append(Info("文字数", "\(snippet.body.count)文字"))
        return Spec(content: .text(snippet.body), info: info)
    }
}

public enum TextRanges {
    /// Character単位の位置を、NSAttributedString が使う UTF-16 の (開始, 長さ) に直す。
    ///
    /// 絵文字や結合文字は1文字がUTF-16で2つ分以上になる。
    /// あいまい検索が返すのは Character 単位の位置なので、そのまま色付けに使うとずれる。
    public static func utf16Ranges(in text: String, characterIndices: [Int]) -> [(location: Int, length: Int)] {
        guard !characterIndices.isEmpty else { return [] }

        var offsets: [Int] = []
        var lengths: [Int] = []
        var offset = 0
        for character in text {
            let length = String(character).utf16.count
            offsets.append(offset)
            lengths.append(length)
            offset += length
        }

        return characterIndices
            .filter { $0 >= 0 && $0 < offsets.count }
            .map { (location: offsets[$0], length: lengths[$0]) }
    }
}
