import Foundation

/// Mac 自身の操作と、システム設定の各画面。
///
/// 2026-08-05 作者「全ての入り口としてテモトを利用したい。」
///
/// ⚠️ 入口から Mac そのものを触れないと、結局アップルメニューやシステム設定を
/// 別に開くことになる。「音」と打てば音の設定、「ろっく」と打てば画面ロック、で終わらせる。
///
/// ⚠️ **消す操作は入れない**（ゴミ箱を空にする等）。
/// 入口は打ち間違いが起きる場所で、⏎ が近い。取り返しのつかない操作を置く場所ではない。
///
/// ⚠️ 設定画面のIDは macOS の版で変わる。ここに書いてあるのは実機
/// （`/System/Library/ExtensionKit/Extensions/*.appex` の CFBundleIdentifier）から取った値。
/// 開けない版では「システム設定」だけが開くので、行き止まりにはならない。
public struct SystemPlace: Equatable, Sendable, Identifiable {

    public enum Action: Equatable, Sendable {
        /// システム設定の中の1画面（空文字なら設定そのもの）
        case settingsPane(String)
        /// 画面をロック。
        /// ⚠️ スクリーンセーバを出すだけでは**ロックにならない**（パスワード要求までの遅延がある。
        /// 実測: このMacは300秒）。macOS 標準の ⌃⌘Q を送って本当にロックする。
        case lockScreen
        /// Mac を眠らせる
        case sleep
    }

    public let id: String
    public let title: String
    public let subtitle: String
    /// 左に出す記号（SF Symbols）
    public let symbol: String
    /// 別の呼び方（ローマ字・かな・英語）。打ち方を人に合わせるための言い換え
    public let aliases: [String]
    public let action: Action

    public init(id: String, title: String, subtitle: String,
                symbol: String, aliases: [String], action: Action) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.symbol = symbol
        self.aliases = aliases
        self.action = action
    }

    /// 入口の検索に出す一式。
    /// ⚠️ 短く保つ。設定の全画面を並べると、入口が設定アプリの目次になる。
    /// ここに置くのは「よく行く」「探すのが面倒」の2つを満たすものだけ。
    public static let all: [SystemPlace] = [
        SystemPlace(id: "sys.lock", title: "画面をロック",
                    subtitle: "席を立つときに（macOS標準の ⌃⌘Q と同じ）",
                    symbol: "lock.display",
                    aliases: ["rokku", "ロック", "ろっく", "lock", "離席", "スクリーンセーバ"],
                    action: .lockScreen),
        SystemPlace(id: "sys.sleep", title: "スリープ",
                    subtitle: "Mac を眠らせる",
                    symbol: "moon.fill",
                    aliases: ["suriipu", "スリープ", "すりーぷ", "sleep", "眠る"],
                    action: .sleep),
        SystemPlace(id: "sys.settings", title: "システム設定",
                    subtitle: "設定アプリを開く",
                    symbol: "gearshape.fill",
                    aliases: ["settei", "設定", "せってい", "settings", "環境設定"],
                    action: .settingsPane("")),
        SystemPlace(id: "sys.sound", title: "サウンド設定",
                    subtitle: "音量・出力先を変える",
                    symbol: "speaker.wave.2.fill",
                    aliases: ["oto", "音", "おと", "音量", "sound", "ボリューム", "スピーカー"],
                    action: .settingsPane("com.apple.Sound-Settings.extension")),
        SystemPlace(id: "sys.network", title: "ネットワーク設定",
                    subtitle: "Wi-Fi・接続を確かめる",
                    symbol: "wifi",
                    aliases: ["wifi", "ワイファイ", "waifai", "network", "ネットワーク", "接続"],
                    action: .settingsPane("com.apple.Network-Settings.extension")),
        SystemPlace(id: "sys.bluetooth", title: "Bluetooth 設定",
                    subtitle: "つないだ機器を確かめる",
                    symbol: "dot.radiowaves.right",
                    aliases: ["bluetooth", "ブルートゥース", "buruutuusu", "イヤホン", "マウス"],
                    action: .settingsPane("com.apple.BluetoothSettings")),
        SystemPlace(id: "sys.display", title: "ディスプレイ設定",
                    subtitle: "解像度・明るさ・並び",
                    symbol: "display",
                    aliases: ["display", "ディスプレイ", "画面", "解像度", "明るさ", "モニタ"],
                    action: .settingsPane("com.apple.Displays-Settings.extension")),
        SystemPlace(id: "sys.keyboard", title: "キーボード設定",
                    subtitle: "入力・ショートカット",
                    symbol: "keyboard",
                    aliases: ["keyboard", "キーボード", "kiiboodo", "入力", "ショートカット"],
                    action: .settingsPane("com.apple.Keyboard-Settings.extension")),
        SystemPlace(id: "sys.notification", title: "通知設定",
                    subtitle: "通知を止める・許す",
                    symbol: "bell.badge",
                    aliases: ["tsuuchi", "通知", "つうち", "notification", "集中"],
                    action: .settingsPane("com.apple.Notifications-Settings.extension")),
        SystemPlace(id: "sys.appearance", title: "外観設定",
                    subtitle: "ライト・ダークを変える",
                    symbol: "circle.lefthalf.filled",
                    aliases: ["gaikan", "外観", "appearance", "ダークモード", "dark", "テーマ"],
                    action: .settingsPane("com.apple.Appearance-Settings.extension")),
        SystemPlace(id: "sys.privacy", title: "プライバシーとセキュリティ",
                    subtitle: "アクセシビリティ等の許可",
                    symbol: "lock.shield",
                    aliases: ["privacy", "プライバシー", "security", "許可", "アクセシビリティ", "kyoka"],
                    action: .settingsPane("com.apple.settings.PrivacySecurity.extension")),
    ]

    /// 設定画面を開くためのURL。`x-apple.systempreferences:` は macOS が受け取る決まった形
    public var settingsURL: String? {
        guard case .settingsPane(let identifier) = action else { return nil }
        return identifier.isEmpty
            ? "x-apple.systempreferences:"
            : "x-apple.systempreferences:" + identifier
    }
}
