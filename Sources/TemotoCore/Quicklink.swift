import Foundation

/// よく使うリンクと、URL に言葉を差し込むときの逃がし方。

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
