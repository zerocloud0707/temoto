import Foundation

/// グローバルショートカット。
/// AppKit/Carbonに依存させず（自前ランナーからテストできるように）、Carbon互換の生値で保持する。
/// CapsAwake で実績のある実装をそのまま踏襲している。
public struct Shortcut: Codable, Equatable, Hashable, Sendable {
    public let keyCode: UInt32
    public let carbonModifiers: UInt32
    public let keyLabel: String

    public static let cmdBit: UInt32 = 0x100
    public static let shiftBit: UInt32 = 0x200
    public static let optionBit: UInt32 = 0x800
    public static let controlBit: UInt32 = 0x1000
    public static let anyModifier: UInt32 = cmdBit | shiftBit | optionBit | controlBit

    public init(keyCode: UInt32, carbonModifiers: UInt32, keyLabel: String) {
        self.keyCode = keyCode
        self.carbonModifiers = carbonModifiers
        self.keyLabel = keyLabel
    }

    /// 修飾キーを最低1つ含むか。単独キーをグローバルに奪うのは事故のもとなので必須にする。
    public var hasModifier: Bool { carbonModifiers & Shortcut.anyModifier != 0 }

    /// macOS標準の並び順 ⌃⌥⇧⌘ + キー
    public var displayString: String {
        var s = ""
        if carbonModifiers & Shortcut.controlBit != 0 { s += "⌃" }
        if carbonModifiers & Shortcut.optionBit != 0 { s += "⌥" }
        if carbonModifiers & Shortcut.shiftBit != 0 { s += "⇧" }
        if carbonModifiers & Shortcut.cmdBit != 0 { s += "⌘" }
        s += keyLabel
        return s
    }

    /// Cocoa（NSEvent.modifierFlags.rawValue）→ Carbon修飾キーマスク
    public static func carbonModifiers(fromCocoaRawFlags raw: UInt) -> UInt32 {
        var carbon: UInt32 = 0
        if raw & 0x40000 != 0 { carbon |= controlBit }
        if raw & 0x80000 != 0 { carbon |= optionBit }
        if raw & 0x20000 != 0 { carbon |= shiftBit }
        if raw & 0x100000 != 0 { carbon |= cmdBit }
        return carbon
    }

    /// Carbon修飾キーマスク → Cocoa（NSEvent.ModifierFlags.rawValue）。
    /// メニューにショートカットを**右寄せのネイティブ表示**で出すために使う
    /// （2026-07-30 作者「メニュー画面、構成が汚い」＝題名に全角スペースで
    /// 連結していたのが原因の1つ。右端が揃わず、素人くさい見た目になっていた）。
    public var cocoaModifierRawFlags: UInt {
        var raw: UInt = 0
        if carbonModifiers & Shortcut.controlBit != 0 { raw |= 0x40000 }
        if carbonModifiers & Shortcut.optionBit != 0 { raw |= 0x80000 }
        if carbonModifiers & Shortcut.shiftBit != 0 { raw |= 0x20000 }
        if carbonModifiers & Shortcut.cmdBit != 0 { raw |= 0x100000 }
        return raw
    }

    /// NSMenuItem.keyEquivalent に入れる文字。
    /// メニュー表示中しか発火しないので、グローバルの登録とぶつからない。
    /// 出せないキー（多文字の名前など）は nil＝呼ぶ側は表示しないだけでよい。
    public var menuKeyEquivalent: String? {
        if let special = Shortcut.menuKeyCharacters[keyCode] { return special }
        // 1文字のキー（V や 1）だけそのまま使う。小文字にしないと ⇧ が勝手に付いて見える
        guard keyLabel.count == 1 else { return nil }
        return keyLabel.lowercased()
    }

    /// キーコード → NSMenuItem が理解する特殊文字
    static let menuKeyCharacters: [UInt32: String] = [
        KeyCode.space: " ",
        KeyCode.ret: "\r",
        KeyCode.tab: "\t",
        KeyCode.del: "\u{08}",
        KeyCode.esc: "\u{1B}",
        KeyCode.left: "\u{F702}",
        KeyCode.right: "\u{F703}",
        KeyCode.down: "\u{F701}",
        KeyCode.up: "\u{F700}",
    ]
}

extension Shortcut {
    /// 押されたキーを設定画面に出す文字にする。
    ///
    /// `charactersIgnoringModifiers` をそのまま使うと、矢印や Return が
    /// 目に見えない制御文字（\u{F701} や \r）になって「⌃⌥⇧」の後ろが空白に見える。
    /// 名前が要るキーはここで明示し、それ以外は打った文字を大文字にして使う。
    public static func label(keyCode: UInt32, characters: String?) -> String {
        if let named = KeyCode.names[keyCode] { return named }
        let typed = (characters ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        // 制御文字だけだったときに空の札にしない（何を押したのか分からなくなる）
        guard let first = typed.unicodeScalars.first, first.value >= 0x20, first.value != 0x7F else {
            return "キー\(keyCode)"
        }
        return typed.uppercased()
    }
}

/// よく使うキーコード（kVK_* の値）
public enum KeyCode {
    public static let a: UInt32 = 0
    public static let s: UInt32 = 1
    public static let c: UInt32 = 8
    public static let v: UInt32 = 9
    public static let n: UInt32 = 45
    public static let one: UInt32 = 18
    public static let two: UInt32 = 19
    public static let three: UInt32 = 20
    public static let four: UInt32 = 21

    /// 数字キー（1〜9・0）を打つ順に。アプリのキーを自動で振るときに使う。
    ///
    /// ⚠️ 5 と 6 は番号が逆（5=23 / 6=22）。並び順に見えて並んでいない。
    /// 「18から順に足していけばいい」と書くと、5を押したのに6が動く。
    public static let digits: [(code: UInt32, label: String)] = [
        (18, "1"), (19, "2"), (20, "3"), (21, "4"), (23, "5"),
        (22, "6"), (26, "7"), (28, "8"), (25, "9"), (29, "0"),
    ]
    public static let space: UInt32 = 49
    public static let ret: UInt32 = 36
    public static let tab: UInt32 = 48
    public static let del: UInt32 = 51
    public static let esc: UInt32 = 53
    public static let left: UInt32 = 123
    public static let right: UInt32 = 124
    public static let down: UInt32 = 125
    public static let up: UInt32 = 126

    /// 打った文字からは読み取れないキーの名前
    public static let names: [UInt32: String] = [
        49: "Space", 36: "Return", 48: "Tab", 51: "⌫", 53: "esc",
        76: "Enter", 117: "⌦", 115: "Home", 119: "End", 116: "PageUp", 121: "PageDown",
        123: "←", 124: "→", 125: "↓", 126: "↑",
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6",
        98: "F7", 100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12",
    ]
}
