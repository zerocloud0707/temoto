import Foundation

/// よく使うアプリ1つに割り当てたショートカット。
///
/// 2026-07-29 作者「よくアクセスするアプリについてアプリ別にショートカットを設けて欲しい。」
///
/// ⚠️ 目印は `path`。`hiddenApps` / `shownApps` と**同じ持ち方**にそろえてある。
/// ここだけバンドルID（jp.example.app）にすると、同じアプリを設定の別の場所で
/// 選んだときに「出すアプリでは外したのにショートカットは効く」のような、
/// 説明のつかない食い違いが起きる。
///
/// ⚠️ `name` も一緒に持つ。パスから作れる文字ではあるが、
/// ディスク上の名前（System Settings.app）と画面に出る名前（システム設定）は
/// 一致しないことがあるうえ、アプリを消したあとの設定画面で
/// 「/Applications/…app（見つかりません）」としか出せなくなる。
/// 何に割り当てたつもりだったかは、消えたあとこそ要る。
public struct AppBinding: Codable, Equatable, Sendable {
    public var path: String
    public var name: String
    public var shortcut: Shortcut

    public init(path: String, name: String, shortcut: Shortcut) {
        self.path = path
        self.name = name
        self.shortcut = shortcut
    }

    /// パスしか無いときの呼び名（末尾の `.app` を落とす）
    public static func displayName(path: String) -> String {
        let last = URL(fileURLWithPath: path).lastPathComponent
        return last.hasSuffix(".app") ? String(last.dropLast(4)) : last
    }

    /// 設定ファイルに `name` が無い古い形でも読めるようにする
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        path = try c.decode(String.self, forKey: .path)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? AppBinding.displayName(path: path)
        shortcut = try c.decode(Shortcut.self, forKey: .shortcut)
    }
}

/// アプリのショートカットを押したときに何が起きるか。
///
/// ⚠️ 「前に出す」だけにしていない理由。
/// 見たいのは大抵ひと目で、見たら元の作業に戻る。前に出すだけだと、
/// 戻るのに⌘Tabや別のキーが要って、結局2つ覚えることになる。
/// 同じキーで出し入れできれば覚えるのは1つで済む。
///
/// ⚠️ 逆に「押したら消えた」と驚かせる余地もあるので、
/// 設定画面にその場で一言書く（`AppHotKey.note`）。
public enum AppHotKeyOutcome: Equatable, Sendable {
    /// 前に出す（動いていなければ起動する）
    case activate
    /// すでにいちばん前にいる → しまって直前のアプリに戻る
    case hide
    /// アプリが見つからない（消した・動かした）
    case missing
}

public enum AppHotKey {
    public static func outcome(exists: Bool, isFrontmost: Bool) -> AppHotKeyOutcome {
        guard exists else { return .missing }
        return isFrontmost ? .hide : .activate
    }

    /// 見つからないときに出す言葉。
    /// ⚠️ 何も起きないのが一番困る。「どこを直せばいいか」まで書く。
    public static func missingMessage(name: String) -> String {
        "\(name) が見つかりません。設定 →「アプリのキー」で選び直してください。"
    }

    public static let note = "同じキーをもう一度押すと、そのアプリをしまって直前の作業に戻ります。"
}
