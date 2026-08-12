import CryptoKit
import Foundation

// MARK: - クリップボード履歴

/// 履歴に残すものの種類。
///
/// ⚠️ 増やしたときに古い clips.enc が読めなくならないよう、
/// ClipItem 側は「知らない種類・欠けた項目は文字として読む」ようにしてある。
/// ここを普通の Codable のまま増やすと、項目が1つ増えただけで
/// 履歴がまるごと読めなくなる（＝全部消えたように見える）。
public enum ClipKind: String, Codable, Sendable {
    case text
    case image
    case file
}

/// 画像の見出しに使う情報。
///
/// 絵そのものはここに入れない。実体は1件1ファイルで別に置く（Store を参照）。
/// clips.enc は「全件を1つの封筒に入れて毎回まるごと書き直す」作りなので、
/// 絵を混ぜると1回コピーするたびに全部の絵を暗号化して書き直すことになる。
public struct ClipImageInfo: Codable, Equatable, Sendable {
    public var pixelWidth: Int
    public var pixelHeight: Int
    public var byteCount: Int
    /// 同じ絵を二度積まないための指紋（SHA256。ここから絵は復元できない）
    public var fingerprint: String

    /// 絵の中から読み取れた文字。
    ///
    /// ⚠️ これを持つ意味は2つある。
    /// 1. 一覧の題名が「画像 912×592」から中身の言葉に変わる（どの絵か目で選べる）
    /// 2. **絵が検索に載る**。今までコピーした絵は名前が無いので二度と探せなかった
    ///
    /// ⚠️ 秘密が写っていたときは、ここには入れない（secretHint の方に理由だけ残す）。
    public var recognizedText: String?

    /// 読み取った文字に秘密が混じっていたときの説明（「カード番号らしき数字列」など）。
    ///
    /// ⚠️ ここが「画像には秘密の検知が効かない」という穴を塞ぐ唯一の場所。
    /// 文字が読めるようになって初めて、スクリーンショットの中のカード番号に気付ける。
    /// **説明だけを持ち、読み取った文字そのものは捨てる。**
    public var secretHint: String?

    /// 文字を読もうとしたか。
    ///
    /// ⚠️ recognizedText が nil なだけでは「まだ読んでいない」のか
    /// 「読んだが文字が無かった（写真・図）」のか区別できず、
    /// 起動のたびに同じ絵を読み直しに行くことになる。
    public var textScanned: Bool

    public init(
        pixelWidth: Int,
        pixelHeight: Int,
        byteCount: Int,
        fingerprint: String,
        recognizedText: String? = nil,
        secretHint: String? = nil,
        textScanned: Bool = false
    ) {
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.byteCount = byteCount
        self.fingerprint = fingerprint
        self.recognizedText = recognizedText
        self.secretHint = secretHint
        self.textScanned = textScanned
    }

    /// 古い clips.enc（文字を読む前の時代のもの）も読めるようにする。
    /// ⚠️ ここを自動生成のままにすると、項目が1つ増えただけで
    /// 過去の画像履歴がまるごと読めなくなる（＝画像が全部消えたように見える）。
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        pixelWidth = try c.decodeIfPresent(Int.self, forKey: .pixelWidth) ?? 0
        pixelHeight = try c.decodeIfPresent(Int.self, forKey: .pixelHeight) ?? 0
        byteCount = try c.decodeIfPresent(Int.self, forKey: .byteCount) ?? 0
        fingerprint = try c.decodeIfPresent(String.self, forKey: .fingerprint) ?? ""
        recognizedText = try c.decodeIfPresent(String.self, forKey: .recognizedText)
        secretHint = try c.decodeIfPresent(String.self, forKey: .secretHint)
        textScanned = try c.decodeIfPresent(Bool.self, forKey: .textScanned) ?? false
    }
}

public struct ClipItem: Codable, Identifiable, Equatable, Sendable {
    public let id: UUID
    public var kind: ClipKind
    /// 文字のときの本文。画像・ファイルのときは空。
    public var text: String
    /// ファイルのときの置き場所。**中身は持たない**（パスだけ覚える）。
    public var filePaths: [String]
    /// 画像のときの見出し情報。絵の実体は別ファイル。
    public var image: ClipImageInfo?
    public var sourceAppName: String?
    public var sourceBundleID: String?
    public var copiedAt: Date
    public var pinned: Bool

    public init(
        id: UUID = UUID(),
        kind: ClipKind = .text,
        text: String = "",
        filePaths: [String] = [],
        image: ClipImageInfo? = nil,
        sourceAppName: String? = nil,
        sourceBundleID: String? = nil,
        copiedAt: Date = Date(),
        pinned: Bool = false
    ) {
        self.id = id
        self.kind = kind
        self.text = text
        self.filePaths = filePaths
        self.image = image
        self.sourceAppName = sourceAppName
        self.sourceBundleID = sourceBundleID
        self.copiedAt = copiedAt
        self.pinned = pinned
    }

    public static func image(
        _ info: ClipImageInfo,
        sourceAppName: String? = nil,
        sourceBundleID: String? = nil,
        copiedAt: Date = Date()
    ) -> ClipItem {
        ClipItem(kind: .image, image: info,
                 sourceAppName: sourceAppName, sourceBundleID: sourceBundleID, copiedAt: copiedAt)
    }

    public static func files(
        _ paths: [String],
        sourceAppName: String? = nil,
        sourceBundleID: String? = nil,
        copiedAt: Date = Date()
    ) -> ClipItem {
        ClipItem(kind: .file, filePaths: paths,
                 sourceAppName: sourceAppName, sourceBundleID: sourceBundleID, copiedAt: copiedAt)
    }

    /// 古い clips.enc（kind が無い時代のもの）も読めるようにする。
    /// 1項目ずつ「無ければ既定」で読む理由は Settings と同じ。
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        text = try c.decodeIfPresent(String.self, forKey: .text) ?? ""
        // 知らない種類が入っていたら文字として扱う。
        // 1件の見た目が崩れる方が、履歴が全部読めなくなるよりましなので。
        let rawKind = try c.decodeIfPresent(String.self, forKey: .kind)
        kind = rawKind.flatMap(ClipKind.init(rawValue:)) ?? .text
        filePaths = try c.decodeIfPresent([String].self, forKey: .filePaths) ?? []
        image = try c.decodeIfPresent(ClipImageInfo.self, forKey: .image)
        sourceAppName = try c.decodeIfPresent(String.self, forKey: .sourceAppName)
        sourceBundleID = try c.decodeIfPresent(String.self, forKey: .sourceBundleID)
        copiedAt = try c.decodeIfPresent(Date.self, forKey: .copiedAt) ?? Date()
        pinned = try c.decodeIfPresent(Bool.self, forKey: .pinned) ?? false
    }

    /// 一覧に出す1行表示（改行を潰して長さを制限する）
    public var previewLine: String {
        switch kind {
        case .text:
            let flattened = text
                .replacingOccurrences(of: "\n", with: " ")
                .replacingOccurrences(of: "\t", with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return String(flattened.prefix(200))
        case .image:
            guard let image else { return "画像" }
            return ImageCaption.title(for: image)
        case .file:
            guard let first = filePaths.first else { return "ファイル" }
            let name = ClipItem.lastComponent(first)
            return filePaths.count == 1 ? name : "\(name) ほか\(filePaths.count - 1)件"
        }
    }

    /// 検索で当てにいく「題名以外」の文字。
    ///
    /// ⚠️ 絵の題名は読み取った文字の**先頭だけ**なので、題名だけを見ていると
    /// 絵の下の方に書いてある言葉で探せない。全文をここから渡す。
    /// （FuzzyMatcher は別名で当たったとき色付けを返さないので、順位にだけ効く）
    public var searchAliases: [String] {
        guard kind == .image, let text = image?.recognizedText, !text.isEmpty else { return [] }
        return [text]
    }

    /// 副題の右側に足す説明（大きさ・置き場所）。
    /// ⚠️ ファイルは**フォルダまで**しか出さない。
    /// 一覧に絶対パスを丸ごと並べると、画面を人に見せたときにそのまま漏れる。
    public var detailLine: String {
        switch kind {
        case .text:
            return ""
        case .image:
            guard let image else { return "" }
            return ImageCaption.detail(for: image)
        case .file:
            guard let first = filePaths.first else { return "" }
            return ClipItem.parentComponent(first)
        }
    }

    /// 右端に出す種類の札
    public var kindLabel: String {
        switch kind {
        case .text: return "履歴"
        case .image: return "画像"
        case .file: return "ファイル"
        }
    }

    static func lastComponent(_ path: String) -> String {
        path.split(separator: "/").last.map(String.init) ?? path
    }

    /// 「~/Downloads」のように、ホーム以下は ~ に畳んだ親フォルダ
    static func parentComponent(_ path: String) -> String {
        var parts = path.split(separator: "/").map(String.init)
        guard parts.count > 1 else { return "/" }
        parts.removeLast()
        let parent = "/" + parts.joined(separator: "/")
        let home = NSHomeDirectory()
        if !home.isEmpty, parent == home { return "~" }
        if !home.isEmpty, parent.hasPrefix(home + "/") {
            return "~" + parent.dropFirst(home.count)
        }
        return parent
    }

    /// いま貼り付けられるファイルだけを返す（元が動いていたら貼りようがない）。
    /// 実在の確認を差し替えられるのは、検証で本物のディスクを触らないため。
    public static func availablePaths(_ paths: [String], exists: (String) -> Bool) -> [String] {
        paths.filter(exists)
    }
}

/// バイト数を人が読める形にする（Raycastの表示に合わせて「99 KB」の形）
public enum ByteSize {
    public static func label(_ bytes: Int) -> String {
        if bytes < 0 { return "0 B" }
        if bytes < 1024 { return "\(bytes) B" }
        let kb = Double(bytes) / 1024
        if kb < 1024 { return "\(Int(kb.rounded())) KB" }
        let mb = kb / 1024
        return String(format: "%.1f MB", mb)
    }
}

/// 中身の指紋。同じものを二度積まないための照合にだけ使う。
/// ハッシュなので、ここから元の中身は取り出せない。
public enum ClipFingerprint {
    public static func of(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

/// 履歴の保持ルール。ピン留めしたものは件数・日数の制限から除外する。
public enum ClipRetention {

    /// - Parameter maxImageCount: 画像だけの件数の枠。
    ///   画像は1件で数MBになるので、文字と同じ枠（既定300件）で持つとディスクを食い潰す。
    ///   ピン留めしたものはこの枠にも数えない。
    public static func prune(
        _ items: [ClipItem],
        maxCount: Int,
        maxAgeDays: Int,
        maxImageCount: Int = 30,
        now: Date = Date()
    ) -> [ClipItem] {
        let cutoff = now.addingTimeInterval(-Double(maxAgeDays) * 86_400)
        let pinned = items.filter { $0.pinned }

        var fresh: [ClipItem] = []
        var imageCount = 0
        for item in items.filter({ !$0.pinned && $0.copiedAt >= cutoff })
                         .sorted(by: { $0.copiedAt > $1.copiedAt }) {
            if item.kind == .image {
                imageCount += 1
                if imageCount > maxImageCount { continue }
            }
            fresh.append(item)
            if fresh.count >= maxCount { break }
        }
        return (pinned + fresh).sorted { $0.copiedAt > $1.copiedAt }
    }
}

// MARK: - 定型文

public struct Snippet: Codable, Identifiable, Equatable, Sendable {
    public let id: UUID
    public var title: String
    public var keyword: String
    public var body: String

    public init(id: UUID = UUID(), title: String, keyword: String = "", body: String) {
        self.id = id
        self.title = title
        self.keyword = keyword
        self.body = body
    }
}

/// 定型文の差し込み。
/// 対応: {date} {date:書式} {time} {clipboard} {query}
public struct SnippetContext: Sendable {
    public var now: Date
    public var clipboard: String
    public var query: String

    public init(now: Date = Date(), clipboard: String = "", query: String = "") {
        self.now = now
        self.clipboard = clipboard
        self.query = query
    }
}

public enum SnippetExpander {
    public static func expand(_ body: String, context: SnippetContext, locale: Locale = Locale(identifier: "ja_JP")) -> String {
        var out = ""
        var rest = Substring(body)

        while let open = rest.firstIndex(of: "{") {
            out += rest[rest.startIndex..<open]
            guard let close = rest[open...].firstIndex(of: "}") else {
                out += rest[open...]
                return out
            }
            let token = String(rest[rest.index(after: open)..<close])
            out += replacement(for: token, context: context, locale: locale)
                ?? "{\(token)}"          // 知らない記法はそのまま残す
            rest = rest[rest.index(after: close)...]
        }
        out += rest
        return out
    }

    private static func replacement(for token: String, context: SnippetContext, locale: Locale) -> String? {
        if token == "clipboard" { return context.clipboard }
        if token == "query" { return context.query }
        if token == "date" { return formatted(context.now, "yyyy-MM-dd", locale) }
        if token == "time" { return formatted(context.now, "HH:mm", locale) }
        if token.hasPrefix("date:") {
            return formatted(context.now, String(token.dropFirst("date:".count)), locale)
        }
        return nil
    }

    private static func formatted(_ date: Date, _ format: String, _ locale: Locale) -> String {
        let f = DateFormatter()
        f.locale = locale
        f.timeZone = TimeZone.current
        f.dateFormat = format
        return f.string(from: date)
    }
}

// MARK: - メモ

/// いつでも呼び出せる1枚のメモ。
/// 振込先や下書きが入りうるので、定型文と同じく暗号化して保存する。
public struct FloatingNote: Codable, Equatable, Sendable {
    public var text: String
    public var updatedAt: Date

    public init(text: String = "", updatedAt: Date = Date()) {
        self.text = text
        self.updatedAt = updatedAt
    }
}

// MARK: - よく使うリンク

/// URLに差し込む値のエスケープ。
///
/// `.urlQueryAllowed` は `&` `=` `?` `+` を通してしまうため、
/// 検索語に `&hl=xx` のような文字列を入れられるとパラメータを1個増やされる。
/// 値として安全なのは非予約文字だけなので、それ以外は全部エンコードする。
enum URLQueryEscape {
    static let allowed = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"
    )

    static func encode(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
    }
}

public struct Quicklink: Codable, Identifiable, Equatable, Sendable {
    public let id: UUID
    public var title: String
    /// {query} を含めると、ランチャーで入力した残りの語を差し込んで開ける
    public var url: String
    /// 分け札（タグ）。
    ///
    /// 2026-08-09 作者「リンクにタグつけれる様にしたい。」
    ///
    /// ⚠️ フォルダにしない。リンクは1つが複数の意味を持つ（例: 落とし物台帳＝ABC・台帳・共有）。
    /// フォルダだと1つの場所にしか置けず、置き場所を決める作業が毎回発生する。
    /// タグなら何枚でも貼れて、どれで探しても出てくる。
    ///
    /// ⚠️ 探すためのものであって、並べるためのものではない。
    /// タグで一覧を折り畳む作りにすると、入口がまた「壁」に戻る（2026-07-30 の反省）。
    public var tags: [String]

    public init(id: UUID = UUID(), title: String, url: String, tags: [String] = []) {
        self.id = id
        self.title = title
        self.url = url
        self.tags = Quicklink.normalize(tags)
    }

    /// ⚠️ 古い quicklinks.json には tags が無い。
    /// 必須にすると読み込みごと失敗して**登録したリンクが全部消えたように見える**
    /// （2026-07-30 に ClipImageInfo で実際に踏んだ地雷と同じ形）。
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        title = try c.decode(String.self, forKey: .title)
        url = try c.decode(String.self, forKey: .url)
        tags = Quicklink.normalize(try c.decodeIfPresent([String].self, forKey: .tags) ?? [])
    }

    /// 打ったタグをそろえる。
    ///
    /// ⚠️ 前後の空白・空の札・同じ札を落とす。
    /// 「ABC, snc,  ABC 」と打たれても1枚にする（大文字小文字は**残す**＝表示は打ったまま、
    /// 見分けだけ小文字でそろえる。人が書いた形を勝手に変えると「直された」と感じる）。
    /// ⚠️ 順番は打った順のまま。並べ替えると、書いた本人の意図（大事な順）が消える。
    public static func normalize(_ tags: [String]) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for tag in tags {
            let trimmed = tag.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            guard seen.insert(trimmed.lowercased()).inserted else { continue }
            out.append(trimmed)
        }
        return out
    }

    /// 「ABC 台帳」「ABC, 台帳」のように打たれた1行を、タグの列にほどく
    public static func parseTags(_ text: String) -> [String] {
        normalize(text.split(whereSeparator: { $0 == "," || $0 == "、" || $0 == " " || $0 == "　" })
            .map(String.init))
    }

    /// 画面に出す形・設定に書き戻す形
    public var tagLine: String { tags.joined(separator: " ") }

    /// 行の右端の札に出す形。
    ///
    /// ⚠️ 全部は出さない。札に幅の上限が無いので、タグを3つ4つ付けた行は
    /// 札が伸びて**題名を押しのける**（題名が読めなくなったら本末転倒）。
    /// 1枚目＋残りの数だけ出す。全部見たい人は編集（⌘E）で見られる。
    public var badgeLabel: String {
        guard let first = tags.first else { return "リンク" }
        let rest = tags.count - 1
        // ⚠️ 1枚目が長いときも縮める。長いタグを付ける人はいる
        let head = first.count <= 8 ? first : String(first.prefix(8)) + "…"
        return rest > 0 ? "\(head) +\(rest)" : head
    }

    /// {query} を差し込んだURLを返す。差し込む値は必ずURLエンコードする。
    public func resolvedURL(query: String) -> String {
        guard url.contains("{query}") else { return url }
        return url.replacingOccurrences(of: "{query}", with: URLQueryEscape.encode(query))
    }

    public var needsQuery: Bool { url.contains("{query}") }
}

// MARK: - 自作コマンド

public struct CustomCommand: Codable, Identifiable, Equatable, Sendable {
    public let id: UUID
    public var title: String
    public var subtitle: String?
    public var action: CommandAction

    public init(id: UUID = UUID(), title: String, subtitle: String? = nil, action: CommandAction) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.action = action
    }
}

/// コマンドの実行内容。
///
/// セキュリティ上の約束: スクリプト実行は必ず「実行ファイルのパス + 引数の配列」で行い、
/// シェルに文字列を組み立てて渡すことは絶対にしない。
/// そのため {query} に何を入れられてもコマンド注入は成立しない（引数1個として渡るだけ）。
public enum CommandAction: Codable, Equatable, Sendable {
    case openPath(String)
    case openURL(String)
    case runScript(path: String, arguments: [String])

    public var kindLabel: String {
        switch self {
        case .openPath: return "フォルダ/ファイルを開く"
        case .openURL: return "リンクを開く"
        case .runScript: return "スクリプトを実行"
        }
    }

    /// {query}（ランチャーで入力した残りの語）と {today}（今日の日付）を差し替える。
    /// スクリプトはシェルを通さず引数の配列で渡すため、{query} に何を入れてもコマンド注入にならない。
    /// URLに差し込むときだけはURLエンコードする。
    public func resolved(query: String, now: Date = Date()) -> CommandAction {
        let today = CommandAction.todayString(now)
        switch self {
        case .runScript(let path, let args):
            return .runScript(path: CommandAction.expandTilde(path), arguments: args.map {
                $0.replacingOccurrences(of: "{query}", with: query)
                  .replacingOccurrences(of: "{today}", with: today)
            })
        case .openPath(let p):
            return .openPath(CommandAction.expandTilde(
                p.replacingOccurrences(of: "{query}", with: query)
                 .replacingOccurrences(of: "{today}", with: today)
            ))
        case .openURL(let u):
            return .openURL(
                u.replacingOccurrences(of: "{query}", with: URLQueryEscape.encode(query))
                 .replacingOccurrences(of: "{today}", with: today)
            )
        }
    }

    public var needsQuery: Bool {
        switch self {
        case .runScript(_, let args): return args.contains { $0.contains("{query}") }
        case .openPath(let p): return p.contains("{query}")
        case .openURL(let u): return u.contains("{query}")
        }
    }

    static func todayString(_ now: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ja_JP")
        f.timeZone = TimeZone.current
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: now)
    }

    static func expandTilde(_ path: String) -> String {
        path.hasPrefix("~") ? NSString(string: path).expandingTildeInPath : path
    }
}
