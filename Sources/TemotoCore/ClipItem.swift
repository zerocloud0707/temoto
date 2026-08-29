import CryptoKit
import Foundation

/// コピー履歴の1件と、その周りの決まり。
///
/// ⚠️ ここは**保存の形**そのもの。項目を増やすときは必ず `decodeIfPresent` にする。
/// 素直に書くと、前の版で保存したファイルが丸ごと読めなくなる（履歴が全部消える）。

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
