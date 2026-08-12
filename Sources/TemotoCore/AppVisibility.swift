import Foundation

/// 検索窓に出すアプリを決める。
///
/// ⚠️ なぜ要るか（2026-07-28 作者の指摘）。
/// 「このアプリに表示されるアプリを選択したい。不要なアプリは表示されない様にしたい。」
///
/// それまでは見つけた `.app` を全部出していた。実機で **211件**。
/// そのうち117件は `/System/Library/CoreServices` の中身で、
/// AOSUIPrefPaneLauncher・AirPlayUIAgent のような「人が開くものではない裏方」だった。
/// 作者が最初に見た画面がこれで、これはテモトを作った理由（使わない機能が多い）の再現でしかない。
///
/// 決め方は2段構え:
///   1段目（自動）… 明らかに人が開かないものを最初から出さない。何も設定しなくても効く
///   2段目（手で選ぶ）… 1段目の判断を1つずつ上書きできる。設定画面のチェックがこれ
public enum AppVisibility {

    // MARK: - 探す場所

    /// 人が自分で開くアプリが入っているフォルダ。
    /// ここに入っているものは既定で出す。
    public static let userDirectories: [String] = [
        "/Applications",
        "/Applications/Utilities",
        "/System/Applications",
        "/System/Applications/Utilities",
        // 「キーチェーンアクセス」「アーカイブユーティリティ」等はここにいる。
        // 直下（下の helperDirectory）とは別のフォルダで、中身はちゃんとした道具。
        "/System/Library/CoreServices/Applications",
    ]

    /// 裏方が入っているフォルダ。**既定では出さない**。
    ///
    /// ここを丸ごと出していたのが今回の原因。117件のうち、人が開くものは数えるほどしかない。
    /// ただし完全に無視はしない。Finder のように「開きたい」ものが混じっているので、
    /// 下の許可リストに書いたものだけ出す。
    public static let helperDirectory = "/System/Library/CoreServices"

    /// 裏方フォルダの中でも出すもの（フォルダ名そのまま）。
    /// ⚠️ ここは短く保つ。増やしたくなったら、まず設定画面で出せることを思い出す
    ///    （利用者が自分で出せるので、既定に足す必要はほとんど無い）。
    public static let helperAllowList: Set<String> = ["Finder.app"]

    /// ホームフォルダの Applications（テモト自身もここにいる）
    public static func homeDirectory(_ home: String) -> String { home + "/Applications" }

    public static func searchDirectories(home: String) -> [String] {
        userDirectories + [helperDirectory, homeDirectory(home)]
    }

    // MARK: - 1段目：自動で決める

    /// Info.plist の値が「はい」を意味するか。
    ///
    /// ⚠️ 素直に `as? Bool` で読むと落とす。
    /// 実機で数えたら、同じ意味の値が **true / YES / 1** の3通りで書かれていた。
    /// 真偽値で入っているものと文字列で入っているものが混在している。
    public static func isTrue(_ value: Any?) -> Bool {
        if let number = value as? NSNumber { return number.boolValue }
        if let text = value as? String {
            return ["1", "true", "yes"].contains(text.lowercased())
        }
        return false
    }

    /// 裏方か（＝Dockにも出ない補助プログラムか）。
    ///
    /// `LSUIElement` … メニューバーだけで動くもの
    /// `LSBackgroundOnly` … 画面を一切持たないもの
    /// どちらも macOS 自身が「人が起動するものではない」と印を付けた目印なので、これに従う。
    /// 実機では CoreServices の117件中 **92件** がこの印を持っていた。
    public static func isHelper(infoPlist: [String: Any]) -> Bool {
        isTrue(infoPlist["LSUIElement"]) || isTrue(infoPlist["LSBackgroundOnly"])
    }

    /// 何も設定していないときに出すかどうか。
    public static func isVisibleByDefault(path: String, isHelper: Bool) -> Bool {
        // 裏方はどのフォルダにいても出さない
        if isHelper { return false }

        let url = URL(fileURLWithPath: path)
        let parent = url.deletingLastPathComponent().path
        if parent == helperDirectory {
            return helperAllowList.contains(url.lastPathComponent)
        }
        return true
    }
}

/// 見つけた `.app` 1つ分。
///
/// 設定画面には**隠れているものも含めて全部**渡す。
/// 出ていないものを一覧から消してしまうと、「あれが出てこない」となったときに
/// 戻す場所が画面のどこにも無くなる（settings.json を手で開くしかない＝設定できないのと同じ）。
public struct AppRecord: Equatable, Sendable {
    public let path: String
    public let name: String
    /// macOS が「裏方」と印を付けているか
    public let isHelper: Bool

    public init(path: String, name: String, isHelper: Bool) {
        self.path = path
        self.name = name
        self.isHelper = isHelper
    }

    /// 一覧に出す場所の呼び名（フォルダのフルパスは長すぎて読めない）
    public var placeLabel: String {
        let parent = URL(fileURLWithPath: path).deletingLastPathComponent().path
        switch parent {
        case "/Applications", "/Applications/Utilities": return "アプリケーション"
        case "/System/Applications": return "標準アプリ"
        case "/System/Applications/Utilities": return "ユーティリティ"
        case "/System/Library/CoreServices": return "システム内部"
        case "/System/Library/CoreServices/Applications": return "システムの道具"
        default:
            return parent.hasSuffix("/Applications") ? "自分で入れたもの" : parent
        }
    }
}
