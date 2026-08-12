import Foundation

/// コピー履歴から**複数まとめて貼る**ときの決まり。
///
/// 2026-08-09 作者「コピーする際に複数選択したい。」
///
/// ⚠️ 順番は**画面に見えているとおり（上から下）**にする。
/// 履歴は新しい順に並んでいるので、内部の並びのまま繋ぐと
/// 「選んだのと逆さま」で出てくる。人は見えているものを信じるので、見えている順で繋ぐ。
///
/// ⚠️ 絵とファイルは文字と混ぜられない。
/// 混ざっていたら**黙って落とさず**、何を落としたかを必ず伝える
/// （黙って一部だけ貼るのが、いちばん気づけない壊れ方）。
public enum ClipJoin {

    /// 繋いだ結果
    public struct Result: Equatable, Sendable {
        /// 実際に貼る文字（空なら貼れるものが無い）
        public let text: String
        /// 繋いだ件数
        public let joined: Int
        /// 文字でないので落とした件数（絵・ファイル）
        public let skipped: Int

        public init(text: String, joined: Int, skipped: Int) {
            self.text = text
            self.joined = joined
            self.skipped = skipped
        }

        public var isEmpty: Bool { joined == 0 }
    }

    /// 区切り。
    /// ⚠️ 改行1つにする。空行を入れると、1行ずつの短い断片を集めたときに
    /// 貼り先が間延びする。逆に区切り無しだと、繋ぎ目で言葉がくっついて読めなくなる。
    public static let separator = "\n"

    /// 選んだものを1つの文字にする。
    /// - Parameter texts: 画面の並び順（上から下）に並べた、各行の文字。文字でない行は nil
    public static func join(_ texts: [String?]) -> Result {
        var parts: [String] = []
        var skipped = 0
        for text in texts {
            guard let text, !text.isEmpty else {
                skipped += 1
                continue
            }
            parts.append(text)
        }
        return Result(text: parts.joined(separator: separator),
                      joined: parts.count, skipped: skipped)
    }

    /// 貼る前に人に見せる一言。
    ///
    /// ⚠️ 落としたものがあるときは必ず言う。
    /// 「3件選んだのに2件しか貼られていない」を後から気づくのが一番困る。
    public static func message(for result: Result) -> String {
        if result.isEmpty {
            return "貼れる文字がありませんでした（絵やファイルはまとめて貼れません）"
        }
        if result.skipped > 0 {
            return "\(result.joined)件を貼りました（絵やファイル \(result.skipped)件は貼れないので外しました）"
        }
        return "\(result.joined)件をつなげて貼りました"
    }

    // MARK: - 絵やファイルも混ざるとき

    /// 選んだ1件分（判断に必要なことだけ）
    public struct Picked: Equatable, Sendable {
        /// 文字ならその中身。絵やファイルなら nil
        public let text: String?
        /// 絵か
        public let isImage: Bool
        /// ファイルか
        public let isFile: Bool

        public init(text: String?, isImage: Bool, isFile: Bool) {
            self.text = text
            self.isImage = isImage
            self.isFile = isFile
        }
    }

    /// 選んだものを、どういう形で相手に渡すか
    public struct Plan: Equatable, Sendable {
        public enum Way: Equatable, Sendable {
            /// 文字としてそのまま貼る
            case text
            /// **全部ファイルにして**渡す（絵は書き出し、文字は .txt にする）
            case files
            /// 渡せるものが無い
            case nothing
        }
        public let way: Way
        /// 文字を繋いだもの（way が .files のときは .txt の中身になる）
        public let text: String
        public let textCount: Int
        public let imageCount: Int
        public let fileCount: Int
    }

    /// どう渡すかを決める。
    ///
    /// ⚠️ 決まりは1文で言えるようにする＝**絵かファイルが1つでも入っていたら、全部ファイルとして渡す**。
    /// 混ざったときに「文字は文字、絵はファイル」と両方をクリップボードへ載せる手もあるが、
    /// 受け取る相手によってどちらが貼られるか変わり、**なぜこうなったか説明できない**動きになる。
    /// 説明できない方が、少し不便より悪い。
    ///
    /// ⚠️ 文字だけのときはファイルにしない。ふつうに貼りたいだけの人に .txt を渡すのは的外れ。
    public static func plan(_ picked: [Picked]) -> Plan {
        var parts: [String] = []
        var images = 0
        var files = 0
        for item in picked {
            if let text = item.text, !text.isEmpty {
                parts.append(text)
            } else if item.isImage {
                images += 1
            } else if item.isFile {
                files += 1
            }
        }
        let joined = parts.joined(separator: separator)
        if images == 0 && files == 0 {
            return Plan(way: parts.isEmpty ? .nothing : .text, text: joined,
                        textCount: parts.count, imageCount: 0, fileCount: 0)
        }
        return Plan(way: .files, text: joined,
                    textCount: parts.count, imageCount: images, fileCount: files)
    }

    /// 渡したあとに出す一言。何をどれだけ渡したかを必ず数で言う
    public static func message(for plan: Plan) -> String {
        switch plan.way {
        case .nothing:
            return "渡せるものがありませんでした"
        case .text:
            return plan.textCount <= 1 ? "貼り付けました" : "\(plan.textCount)件をつなげて貼りました"
        case .files:
            var parts: [String] = []
            if plan.imageCount > 0 { parts.append("画像\(plan.imageCount)件") }
            if plan.fileCount > 0 { parts.append("ファイル\(plan.fileCount)件") }
            if plan.textCount > 0 { parts.append("文字\(plan.textCount)件（.txt にしました）") }
            return parts.joined(separator: "・") + " をファイルとして渡しました"
        }
    }

    /// 選んでいる最中に、下の帯へ出す言葉
    public static func status(count: Int) -> String {
        count <= 1 ? "" : "\(count)件を選んでいます（⏎ でつなげて貼る）"
    }
}
