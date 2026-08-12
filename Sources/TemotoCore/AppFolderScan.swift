import Foundation

/// 「自分で作った・自分で置いたアプリ」を探すときの歩き方。
///
/// 2026-08-04 作者「シワケ、シオリ、finderのアプリなど、テモトから簡単に
/// アクセスできる様にしたい。」
/// 調べると Finder は元から出ていたが、**シワケ.app は
/// `~/Documents/Claude/10_アプリ開発/PDF編集/release/mac-arm64/` にいた**＝
/// テモトが見ているフォルダ（/Applications 等）の外。自分で作ったアプリは
/// 作った場所に置いたままになるので、置き場所を足せるようにする。
///
/// ⚠️ ここは「歩き方の規則」だけを持つ（実際にディスクを読むのは画面側）。
/// 規則を間違えると、開発フォルダを丸ごと歩いて固まる・裏方アプリが大量に出る。
public enum AppFolderScan {

    /// どこまで潜るか。
    /// `10_アプリ開発 / PDF編集 / release / mac-arm64 / シワケ.app` で4段なので、
    /// 開発フォルダの根を足しても届く深さにしてある。
    public static let maxDepth = 5

    /// 1つのフォルダから拾う上限（暴走よけ）
    public static let maxApps = 300

    /// 中を歩かないフォルダ。
    /// ⚠️ `node_modules` は要（Electronアプリの中に大量の裏方 .app が入っている）。
    /// ここを歩くと、見つかるのは人が開かないものばかりで、一覧が使い物にならなくなる。
    public static let skipped: Set<String> = [
        "node_modules", ".git", ".build", ".next", ".open-next", ".wrangler",
        "DerivedData", "Pods", "Carthage", ".venv", "venv", "__pycache__",
        "Library", "Caches", ".Trash", ".cache", "vendor", "target",
    ]

    /// このフォルダの中へ入ってよいか。
    ///
    /// ⚠️ `.app` の中には**絶対に入らない**。アプリの中には「◯◯ Helper.app」が
    /// いくつも入っていて、入った瞬間に一覧が裏方だらけになる。
    public static func shouldDescend(name: String, depth: Int) -> Bool {
        guard depth < maxDepth else { return false }
        guard !name.hasSuffix(".app") else { return false }
        guard !name.hasPrefix(".") else { return false }
        return !skipped.contains(name)
    }

    /// 見つけた `.app` を数に入れてよいか（中身の入れ子は数えない）
    public static func isApp(name: String) -> Bool {
        name.hasSuffix(".app") && !name.hasPrefix(".")
    }
}
