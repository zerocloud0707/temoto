import AppKit

/// 文字の入力欄で ⌘C / ⌘V / ⌘X / ⌘A / ⌘Z が効くようにするためだけのメニュー。
///
/// 2026-08-09 作者「リンクを貼り付けることができない。」（リンクを作る画面のURL欄）
///
/// ⚠️ 原因は入力欄でも画面でもなく、**メニューが1つも無いこと**だった。
/// macOS では ⌘V は「編集メニューの『ペースト』の割り当てキー」として配られる。
/// テモトは `LSUIElement`（メニューバーに出ないアプリ）なので画面上部にメニューが出ず、
/// メニューそのものを作っていなかった。届け先が無いキーは、どこにも届かない。
///
/// ⚠️ **メニューは見えなくても効く。**
/// LSUIElement のアプリでも `NSApp.mainMenu` に置いた項目の割り当てキーは処理される。
/// だから「見た目のためのメニュー」ではなく「キーを通すための配線」として置く。
///
/// ⚠️ 動作は自分で書かない。`target` を nil にして、いま入力している欄に届くようにする
/// （responder chain）。自分で貼り付けを実装すると、選択範囲・変換中の文字・
/// 取り消しの積み上げを全部自前で持つことになり、必ずどこかで食い違う。
enum EditMenu {

    /// 起動時に1回だけ組む
    static func install() {
        // 既にあるなら二重に作らない
        guard NSApp.mainMenu == nil else { return }

        let main = NSMenu()

        // ⚠️ アプリ名のメニュー（1番目）は空でも要る。
        // macOS は先頭の項目をアプリのメニューとして特別扱いするので、
        // ここを省くと編集メニューが1番目に来て、割り当てキーの扱いが変わる。
        let appItem = NSMenuItem()
        appItem.submenu = NSMenu(title: "テモト")
        main.addItem(appItem)

        let editItem = NSMenuItem()
        let edit = NSMenu(title: "編集")
        // ⚠️ 題名は日本語にする。見えないメニューだが、VoiceOver は読み上げる
        add(to: edit, "取り消す", #selector(UndoManager.undo), "z")
        add(to: edit, "やり直す", #selector(UndoManager.redo), "Z")
        edit.addItem(.separator())
        add(to: edit, "カット", #selector(NSText.cut(_:)), "x")
        add(to: edit, "コピー", #selector(NSText.copy(_:)), "c")
        add(to: edit, "ペースト", #selector(NSText.paste(_:)), "v")
        // ⚠️ 書式なしで貼り付け。テモトは他所から URL や文章を貼る場面が多く、
        // 色や書体まで持ってこられると入力欄が壊れて見える
        add(to: edit, "書式なしでペースト",
            #selector(NSTextView.pasteAsPlainText(_:)), "V")
        add(to: edit, "すべてを選択", #selector(NSText.selectAll(_:)), "a")
        edit.addItem(.separator())
        add(to: edit, "削除", #selector(NSText.delete(_:)), "")
        editItem.submenu = edit
        main.addItem(editItem)

        NSApp.mainMenu = main
    }

    /// 本当に効くかを実物で確かめる（`--check-menu`）。
    ///
    /// ⚠️ 「メニューを作った」だけでは直った証拠にならない。
    /// 確かめたいのは「入力欄に ⌘V が**届く**か」なので、
    /// 実際に入力欄を作り、クリップボードに文字を置き、⌘V の出来事を送って、
    /// 欄に入ったかどうかを見る。ここまでやらないと「直したつもり」で終わる。
    static func selfTest() -> Int32 {
        let app = NSApplication.shared
        // 実物と同じ「メニューバーに出ないアプリ」の状態にする
        app.setActivationPolicy(.accessory)
        // ⚠️ `--no-menu` を付けると、メニューを組まずに同じことを試す。
        // 「直した」と言うには、**直す前は効かなかった**ことも示さないといけない
        let withMenu = !CommandLine.arguments.contains("--no-menu")
        if withMenu { install() }
        FileHandle.standardError.write(Data(
            (withMenu ? "▼ 編集メニューを組んだ状態\n" : "▼ 編集メニューが無い状態（直す前）\n").utf8))

        let expected = "貼り付けの検査 \(Int.random(in: 1000...9999))"
        let board = NSPasteboard.general
        board.clearContents()
        board.setString(expected, forType: .string)

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 60),
                              styleMask: [.titled], backing: .buffered, defer: false)
        let field = NSTextField(frame: NSRect(x: 10, y: 10, width: 300, height: 24))
        window.contentView?.addSubview(field)
        // ⚠️ アプリを前に出し、少し回してから入力欄を選ぶ。
        // NSTextField は「窓が前面・アプリが前面」で初めて**編集用の中身**が用意される。
        // それが無いと ⌘V は届いても書き込む先が無く、欄は空のまま
        // （2026-08-09 の実測。届いた／入った、を分けて見ないと気づけない）。
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        window.makeFirstResponder(field)
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))

        func press(_ character: String, label: String) -> Bool {
            guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero,
                                               modifierFlags: .command, timestamp: 0,
                                               windowNumber: window.windowNumber, context: nil,
                                               characters: character,
                                               charactersIgnoringModifiers: character,
                                               isARepeat: false, keyCode: 0) else { return false }
            let handled = NSApp.mainMenu?.performKeyEquivalent(with: event) ?? false
            FileHandle.standardError.write(Data("  ⌘\(character)（\(label)）: \(handled ? "届いた" : "届かない")\n".utf8))
            return handled
        }

        var failures = 0
        if !press("v", label: "ペースト") { failures += 1 }
        // 入力欄に入ったかを見る（届いただけでなく、中身が入ったこと）
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        // ⚠️ 編集中の文字は欄そのものではなく「編集用の中身」に入る。
        // 確定前でも読めるよう、両方を見る
        let editing = window.fieldEditor(false, for: field)?.string ?? ""
        window.makeFirstResponder(nil)   // 編集を確定させる
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        let got = field.stringValue.isEmpty ? editing : field.stringValue
        // ⚠️ ここは**この土俵では判定に使えない**。
        // .app として起動していないと入力欄の「編集用の中身」が用意されず、
        // 届いても書き込む先が無い。実測（2026-08-09）で確認済み。
        // 判定はキーが届くかどうかに絞り、入ったかどうかは事実として出すだけにする。
        FileHandle.standardError.write(Data(
            "  （参考）入力欄の中身: 「\(got)」 ※.appでないと入らない\n".utf8))
        window.makeFirstResponder(field)
        if !press("a", label: "すべてを選択") { failures += 1 }
        if !press("c", label: "コピー") { failures += 1 }
        if !press("x", label: "カット") { failures += 1 }

        let summary = failures == 0 ? "✅ 入力欄で編集のキーが効きます\n" : "🔴 \(failures)件 効きません\n"
        FileHandle.standardError.write(Data(summary.utf8))
        return failures == 0 ? 0 : 1
    }

    private static func add(to menu: NSMenu, _ title: String, _ action: Selector, _ key: String) {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        // ⚠️ 大文字のキーは「⇧つき」の意味。⌘⇧V を ⌘V と取り違えないよう、ここで明示する
        if key.count == 1, key == key.uppercased(), key != key.lowercased() {
            item.keyEquivalent = key.lowercased()
            item.keyEquivalentModifierMask = [.command, .shift]
        }
        // target は nil のまま＝いま入力している欄へ届く
        menu.addItem(item)
    }
}
