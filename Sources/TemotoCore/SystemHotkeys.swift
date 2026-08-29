import Foundation

/// macOS 自身のショートカット（システム設定 → キーボード → ショートカット）を読む係。
///
/// 2026-08-30 作者「テモトにかかわらず全てのショートカットを確認できる仕組みにできないかな？？
/// ショートカットがかぶっているので、設定できなかったり、動かなかったりする」。
///
/// ⚠️ できること・できないことを最初に書いておく（誇大広告は信頼を失う）:
/// - ✅ macOS のシステムショートカット: `com.apple.symbolichotkeys` に全部書いてあるので読める
/// - ✅ テモト自身の割り当て: `Settings.allShortcuts` にある
/// - ❌ **他のアプリのグローバルキー（Raycast等）の一覧**: macOS に聞く公の窓口が無い。
///   代わりに「そのキーを試しに登録してみる」ことで、取られているかだけは分かる
///   （テモトが起動時にやっている失敗検出と同じ手）。一覧は無理でも、判定はできる。
public enum SystemHotkeys {

    /// システムショートカットの1つ
    public struct Entry: Equatable, Sendable {
        /// symbolichotkeys の番号
        public let id: Int
        /// 人が読める名前（知らない番号は「システムの機能 #id」）
        public let name: String
        /// 押すキー。読めない形（マウス起動など）は nil
        public let shortcut: Shortcut?
        public let enabled: Bool

        /// 名前が分からず、番号のままか。
        /// ⚠️ Apple は番号と機能の対応を公にしていない。分からないものに
        /// それらしい名前を付けると**嘘になる**ので、番号のまま出す。
        /// キーが取られている事実は名前が無くても伝わる（それがこの画面の目的）
        public var isUnnamed: Bool { names[id] == nil }

        public init(id: Int, name: String, shortcut: Shortcut?, enabled: Bool) {
            self.id = id
            self.name = name
            self.shortcut = shortcut
            self.enabled = enabled
        }
    }

    /// `defaults read com.apple.symbolichotkeys AppleSymbolicHotKeys` の辞書を解く。
    ///
    /// 形: { "79": { enabled: 1, value: { parameters: [ascii, keyCode, cocoaFlags], type: "standard" } } }
    /// ⚠️ parameters の3つ目は **Cocoa の修飾キー**（⌃=0x40000…）。Carbon ではない。
    /// ⚠️ enabled が無い項目は「入」扱い（OSの既定がそうなっている）
    public static func parse(_ domain: [String: Any]) -> [Entry] {
        var entries: [Entry] = []
        for (key, raw) in domain {
            guard let id = Int(key), let body = raw as? [String: Any] else { continue }
            let enabled = (body["enabled"] as? Bool) ?? ((body["enabled"] as? Int).map { $0 != 0 } ?? true)
            var shortcut: Shortcut?
            if let value = body["value"] as? [String: Any],
               let parameters = value["parameters"] as? [Any], parameters.count >= 3,
               let keyCode = intValue(parameters[1]), keyCode >= 0,
               let flags = intValue(parameters[2]) {
                let carbon = Shortcut.carbonModifiers(fromCocoaRawFlags: UInt(truncatingIfNeeded: flags))
                let label = keyLabel(keyCode: UInt32(keyCode), ascii: intValue(parameters[0]) ?? 65535)
                // 修飾キーもラベルも無いものは「キーで押すもの」ではない（マウス角など）
                if !label.isEmpty {
                    shortcut = Shortcut(keyCode: UInt32(keyCode), carbonModifiers: carbon, keyLabel: label)
                }
            }
            entries.append(Entry(id: id, name: names[id] ?? "システムの機能 #\(id)",
                                 shortcut: shortcut, enabled: enabled))
        }
        // 番号順（読むたびに並びが変わると、目で追えない）
        return entries.sorted { $0.id < $1.id }
    }

    /// 入になっていて、キーで押せるものだけ（一覧に出す形）。
    ///
    /// ⚠️ 並びは「名前が分かるもの（名前順）→ 番号だけのもの（番号順）」。
    /// 番号だけのものを名前順に混ぜると「システムの機能 #34」がずらりと真ん中に居座り、
    /// 分かるものが埋もれる。読む人が最初に見たいのは、名前で意味が分かるほう
    public static func active(_ domain: [String: Any]) -> [Entry] {
        let all = parse(domain).filter { $0.enabled && $0.shortcut != nil }
        let named = all.filter { !$0.isUnnamed }.sorted { $0.name < $1.name }
        let numbered = all.filter(\.isUnnamed).sorted { $0.id < $1.id }
        return named + numbered
    }

    /// テモトの割り当てとかぶっているものを探す。
    /// ⚠️ 比べるのは keyCode と修飾キー。keyLabel は見ない
    /// （同じキーでも読み方の文字が違うことがある。F3 と "F3" など）
    public static func conflicts(
        between system: [Entry],
        and mine: [(name: String, shortcut: Shortcut)]
    ) -> [(system: Entry, mineName: String)] {
        var hits: [(Entry, String)] = []
        for entry in system where entry.enabled {
            guard let key = entry.shortcut else { continue }
            for assignment in mine
            where assignment.shortcut.keyCode == key.keyCode
                && assignment.shortcut.carbonModifiers & Shortcut.anyModifier
                    == key.carbonModifiers & Shortcut.anyModifier {
                hits.append((entry, assignment.name))
            }
        }
        return hits.map { (system: $0.0, mineName: $0.1) }
    }

    // MARK: - 名前

    /// 番号 → 名前。
    /// ⚠️ Apple が公に文書化していないが、値は長年安定している
    /// （Mission Control の 32 は 10.7 から同じ）。知らない番号は素直に番号で出す
    public static let names: [Int: String] = [
        7: "画面の反転（アクセシビリティ）",
        8: "ウインドウを操作対象にする",
        9: "メニューバーを操作対象にする",
        10: "Dockを操作対象にする",
        11: "ツールバーを操作対象にする",
        12: "フローティングウインドウを操作対象にする",
        13: "次のウインドウを操作対象にする",
        15: "ズーム機能の入切",
        17: "拡大",
        19: "縮小",
        21: "白黒反転",
        23: "コントラストを上げる",
        25: "コントラストを下げる",
        26: "次のアプリのウインドウ",
        27: "前後のウインドウを切り替える",
        28: "画面全体を撮ってファイルへ",
        29: "画面全体を撮ってクリップボードへ",
        30: "選んだ範囲を撮ってファイルへ",
        31: "選んだ範囲を撮ってクリップボードへ",
        32: "Mission Control",
        33: "アプリケーションウインドウ",
        // ⚠️ ⇧ を足した「ゆっくり動く版」。番号が対になっているので確か
        // （実機で 32=⌃↑ に対し 34=⌃⇧↑、33=⌃↓ に対し 35=⌃⇧↓ と並んでいた）
        34: "Mission Control（ゆっくり）",
        35: "アプリケーションウインドウ（ゆっくり）",
        37: "デスクトップを表示（ゆっくり）",
        36: "デスクトップを表示",
        52: "Dockの表示・非表示",
        57: "キーボードの操作対象を切り替える",
        59: "音声入力の呼び出し",
        60: "前の入力ソースを選択",
        61: "入力メニューの次のソースを選択",
        64: "Spotlight検索",
        65: "Finderの検索ウインドウ",
        79: "左の操作スペースへ移動",
        81: "右の操作スペースへ移動",
        98: "ヘルプメニューを表示",
        118: "デスクトップ1へ切り替え",
        119: "デスクトップ2へ切り替え",
        120: "デスクトップ3へ切り替え",
        121: "デスクトップ4へ切り替え",
        160: "Launchpadを表示",
        163: "通知センターを表示",
        164: "おやすみモードの入切",
        175: "アクセシビリティのショートカット",
        184: "スクリーンショットと収録のオプション",
        190: "クイックメモ",
        222: "書類の翻訳",
    ]

    // MARK: - キーの読み

    /// keyCode → 表示。ascii（parameters[0]）が普通の文字ならそれを大文字で使う
    static func keyLabel(keyCode: UInt32, ascii: Int) -> String {
        if let special = specialKeys[keyCode] { return special }
        // 65535 は「文字なし」の印
        if ascii != 65535, let scalar = Unicode.Scalar(UInt32(ascii)), ascii >= 0x21, ascii < 0x7F {
            return String(Character(scalar)).uppercased()
        }
        return specialKeys[keyCode] ?? ""
    }

    /// 文字にならないキーの読み（US/JISで共通の並び）
    static let specialKeys: [UInt32: String] = [
        36: "⏎", 48: "Tab", 49: "Space", 51: "⌫", 53: "esc", 71: "Clear",
        76: "⏎", 96: "F5", 97: "F6", 98: "F7", 99: "F3", 100: "F8", 101: "F9",
        103: "F11", 105: "F13", 106: "F16", 107: "F14", 109: "F10", 111: "F12",
        113: "F15", 114: "Help", 115: "Home", 116: "PgUp", 117: "⌦", 118: "F4",
        119: "End", 120: "F2", 121: "PgDn", 122: "F1", 123: "←", 124: "→",
        125: "↓", 126: "↑",
    ]

    private static func intValue(_ raw: Any) -> Int? {
        (raw as? Int) ?? (raw as? NSNumber)?.intValue
    }
}
