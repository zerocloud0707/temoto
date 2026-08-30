import Foundation

/// 「どの割り当てか」を1つの言葉で指す印。
///
/// ⚠️ これが要る理由（2026-08-30）。
/// それまで、割り当ての一覧（`allShortcuts`）と、設定画面の1行ずつの読み書き
/// （get/set の閉包を手で書いたもの）が**別々に並んでいた**。
/// 割り当てを増やすときに一覧へ足し忘れると、同じキーを2つに割り当てても
/// 設定画面は何も言わず、**後から登録した方だけが黙って効かない**。
/// `Settings.allShortcuts` のコメントに「混ぜ忘れると黙って効かない」と書いてあり、
/// それでも**2度**（アプリのキー／書式なし貼り付け等）実際に忘れている。
///
/// 印を1つ作って、一覧も読み書きもここから引けば、忘れようがない。
public enum ShortcutSlot: Equatable, Hashable, Sendable {
    case launcher
    case clipboard
    case snippets
    case note
    case window(WindowLayout)
    /// +1 = 次の画面へ / -1 = 前の画面へ
    case display(step: Int)
    case app(path: String)
    case convert(TextTransform)
    case pastePlain
    case captureText

    /// 空（割り当てなし）にできるか。
    /// ⚠️ 検索窓を開くキーを空にすると、**二度と開けなくなる**（メニューバーからしか戻れない）。
    /// 行き先の4つは入口なので空を許さない
    public var allowsEmpty: Bool {
        switch self {
        case .launcher, .clipboard, .snippets, .note: return false
        default: return true
        }
    }

    /// 画面での並び。同じ種類がまとまって出るように
    public var group: String {
        switch self {
        case .launcher, .clipboard, .snippets, .note: return "開くもの"
        case .window: return "ウィンドウを動かす"
        case .display: return "画面をまたぐ"
        case .convert: return "文字を変換"
        case .pastePlain: return "貼り付け"
        case .captureText: return "画面を読み取る"
        case .app: return "アプリのキー"
        }
    }
}

extension Settings {
    /// 割り当てられる場所すべて。**一覧も読み書きもここが正本**。
    ///
    /// ⚠️ 割り当てを増やしたら、ここに1行足すだけでよい。
    /// `allShortcuts`（重複の検査）も、設定画面の一覧も、ここから引いている。
    /// ⚠️ アプリのキーは利用者が足すものなので、今あるぶんを並べる
    public var allSlots: [(slot: ShortcutSlot, name: String)] {
        var list: [(ShortcutSlot, String)] = [
            (.launcher, "検索を開く"),
            (.clipboard, "コピー履歴"),
            (.snippets, "定型文"),
            (.note, "メモ"),
        ]
        list += windowBindings.map { (.window($0.layout), $0.layout.title) }
        list += displayBindings.map {
            (.display(step: $0.step), $0.step > 0 ? "次の画面へ移す" : "前の画面へ移す")
        }
        list += convertBindings.map { (.convert($0.transform), $0.transform.title + "に変換") }
        list.append((.pastePlain, "書式なしで貼り付け"))
        list.append((.captureText, "画面の文字を読み取る"))
        list += appBindings.map { (.app(path: $0.path), $0.name) }
        return list.map { (slot: $0.0, name: $0.1) }
    }

    /// その場所に今入っているキー
    public func shortcut(for slot: ShortcutSlot) -> Shortcut? {
        switch slot {
        case .launcher: return launcherShortcut
        case .clipboard: return clipboardShortcut
        case .snippets: return snippetShortcut
        case .note: return noteShortcut
        case .window(let layout): return windowBindings.first { $0.layout == layout }?.shortcut
        case .display(let step): return displayBindings.first { $0.step == step }?.shortcut
        case .app(let path): return appBindings.first { $0.path == path }?.shortcut
        case .convert(let transform): return convertBindings.first { $0.transform == transform }?.shortcut
        case .pastePlain: return pastePlainShortcut
        case .captureText: return captureTextShortcut
        }
    }

    /// その場所のキーを差し替える。
    /// ⚠️ 空にできない場所（行き先の4つ）に nil を渡しても**何もしない**。
    /// 黙って消すと、開く手段が無くなって戻れなくなる
    public mutating func setShortcut(_ value: Shortcut?, for slot: ShortcutSlot) {
        if value == nil && !slot.allowsEmpty { return }
        switch slot {
        case .launcher: if let value { launcherShortcut = value }
        case .clipboard: if let value { clipboardShortcut = value }
        case .snippets: if let value { snippetShortcut = value }
        case .note: if let value { noteShortcut = value }
        case .window(let layout):
            windowBindings.removeAll { $0.layout == layout }
            if let value { windowBindings.append(WindowBinding(layout: layout, shortcut: value)) }
        case .display(let step):
            displayBindings.removeAll { $0.step == step }
            if let value { displayBindings.append(DisplayBinding(step: step, shortcut: value)) }
        case .app(let path):
            if let value, let index = appBindings.firstIndex(where: { $0.path == path }) {
                appBindings[index].shortcut = value
            } else if value == nil {
                appBindings.removeAll { $0.path == path }
            }
        case .convert(let transform):
            convertBindings.removeAll { $0.transform == transform }
            if let value { convertBindings.append(ConvertBinding(transform: transform, shortcut: value)) }
        case .pastePlain: pastePlainShortcut = value
        case .captureText: captureTextShortcut = value
        }
    }
}

/// キーの一覧を、打った言葉で絞る。
///
/// 2026-08-30 作者「ショートカットの検索や、テモトのショートカットは
/// この画面で変更できたり」。
public enum ShortcutSearch {
    /// 名前でもキーでも当たるようにする。
    ///
    /// ⚠️ **キーそのもの**で探せることが肝。「⌃⌥V は何に使っている？」と
    /// 調べたい場面が本来の使い道で、名前だけで探せても半分しか役に立たない。
    /// ⚠️ 修飾キーの記号（⌃⌥⇧⌘）で打つのは大変なので、
    /// `ctrl` `opt` `cmd` `shift` のような英字でも当たるようにする
    public static func matches(query: String, name: String, shortcut: Shortcut?) -> Bool {
        let words = query
            .folding(options: [.caseInsensitive, .widthInsensitive], locale: nil)
            .split(whereSeparator: { $0 == " " || $0 == "　" })
            .map(String.init)
        guard !words.isEmpty else { return true }

        var hay = name
        if let shortcut {
            hay += "\u{1}" + shortcut.displayString
            hay += "\u{1}" + spelled(shortcut)
        } else {
            hay += "\u{1}割り当てなし"
        }
        let folded = hay.folding(options: [.caseInsensitive, .widthInsensitive], locale: nil)
        return words.allSatisfy { folded.contains($0) }
    }

    /// 修飾キーを英字に開く（⌃ → control ctrl / ⌥ → option opt alt …）
    static func spelled(_ shortcut: Shortcut) -> String {
        var parts: [String] = []
        if shortcut.carbonModifiers & Shortcut.controlBit != 0 { parts += ["control", "ctrl"] }
        if shortcut.carbonModifiers & Shortcut.optionBit != 0 { parts += ["option", "opt", "alt"] }
        if shortcut.carbonModifiers & Shortcut.shiftBit != 0 { parts += ["shift"] }
        if shortcut.carbonModifiers & Shortcut.cmdBit != 0 { parts += ["command", "cmd"] }
        parts.append(shortcut.keyLabel)
        return parts.joined(separator: " ")
    }
}
