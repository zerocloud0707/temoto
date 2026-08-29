import AppKit

/// 選んだものを、ランチャーを開く直前に使っていたアプリへ貼り付ける。
enum Paster {

    // MARK: - ペーストボードに置くだけ（貼り付けはしない）

    static func copy(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    /// 絵を置く。
    ///
    /// PNG だけだと受け取れないアプリ（TIFF しか見ない古い作り）があるので、
    /// 同じ絵を TIFF でも置いておく。相手が読める方を選ぶ。
    static func copyImage(_ png: Data) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setData(png, forType: .png)
        if let rep = NSBitmapImageRep(data: png),
           let tiff = rep.representation(using: .tiff, properties: [:]) {
            pasteboard.setData(tiff, forType: .tiff)
        }
    }

    /// ファイルを置く。中身ではなく置き場所を渡すので、Finder でコピーしたのと同じ状態になる。
    static func copyFiles(_ paths: [String]) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        let urls = paths.map { NSURL(fileURLWithPath: $0) }
        guard !urls.isEmpty else { return }
        pasteboard.writeObjects(urls)
    }

    // MARK: - 置いて ⌘V を送る

    /// 送り先を明示的に前面へ戻してから送るので、ランチャー自身には入らない。
    ///
    /// - Parameter afterCopy: ペーストボードに書いた直後に呼ばれる。
    ///   自分で書いた分を履歴に取り込まないよう、見張り役へ知らせるために使う。
    static func paste(_ text: String, into app: NSRunningApplication?,
                            window: AXUIElement? = nil,
                            afterCopy: (() -> Void)? = nil) {
        pasteAfterWriting(into: app, window: window, afterCopy: afterCopy) { copy(text) }
    }

    static func pasteImage(_ png: Data, into app: NSRunningApplication?,
                            window: AXUIElement? = nil,
                            afterCopy: (() -> Void)? = nil) {
        pasteAfterWriting(into: app, window: window, afterCopy: afterCopy) { copyImage(png) }
    }

    static func pasteFiles(_ paths: [String], into app: NSRunningApplication?,
                            window: AXUIElement? = nil,
                            afterCopy: (() -> Void)? = nil) {
        pasteAfterWriting(into: app, window: window, afterCopy: afterCopy) { copyFiles(paths) }
    }

    private static func pasteAfterWriting(
        into app: NSRunningApplication?,
        window: AXUIElement?,
        afterCopy: (() -> Void)?,
        write: () -> Void
    ) {
        write()
        afterCopy?()

        guard let app else {
            // 戻り先を覚えていない＝どこへ貼るか決められない。
            // 黙って ⌘V を投げると、たまたま前にいたアプリに入り込む
            Toast.show("貼り付け先が分かりません（コピーはできています。⌘V で貼れます）", isError: true)
            return
        }

        // ⚠️ ここは2026-08-23 に作り直した。
        // 作者「コピー履歴を貼り付けると、なぜか他のブラウザの表示が最前面になったりします」。
        //
        // それまでは `NSWorkspace.openApplication` で戻していた。これは
        // **Dock のアイコンを押すのと同じ道**で、そのアプリの窓が全部前に出る。
        // ブラウザのように窓を何枚も開くアプリだと、打っていた窓の他に
        // 別の窓まで手前に飛び出してくる。
        //
        // 正しい道は `NSApp.yieldActivation(to:)`。
        // 「背面のプロセスは他アプリを前に出せない」という制限は本当だが、
        // **いま前面にいる自分が譲る**のは macOS が用意している正規の道で、
        // 窓の重なりには手を出さない。
        if !app.isActive {
            NSApp.yieldActivation(to: app)
            app.activate()
        }
        // 覚えている窓があれば、それだけを名指しで前に出す
        if let window { AXWindow.raise(window, of: app) }

        // ⚠️ 決め打ちの待ち時間にしない。相手が前に出るまでの時間はアプリごとに違い、
        // 短すぎると ⌘V がどこにも入らず「押しても何も起きない」になる。
        waitUntilActive(app, deadline: Date().addingTimeInterval(0.6)) { becameActive in
            if becameActive {
                finish(app: app, window: window)
                return
            }
            // ⚠️ 最後の手段。譲っても前に出てこない相手のときだけ、昔の道（開き直す）を使う。
            // これは窓を全部前に出すが、**貼れないよりはまし**。
            // 常用しないこと（この道が原因で上の不具合が起きていた）
            if let url = app.bundleURL {
                let configuration = NSWorkspace.OpenConfiguration()
                configuration.activates = true
                NSWorkspace.shared.openApplication(at: url, configuration: configuration, completionHandler: nil)
            }
            waitUntilActive(app, deadline: Date().addingTimeInterval(0.6)) { recovered in
                guard recovered else {
                    Toast.show("\(app.localizedName ?? "元のアプリ")に戻れませんでした"
                               + "（コピーはできています。⌘V で貼れます）", isError: true)
                    return
                }
                finish(app: app, window: window)
            }
        }
    }

    /// 前に出たあとの仕上げ。
    /// ⚠️ 窓をもう一度名指しする。アプリが前に出る動きの中で、
    /// macOS が「そのアプリのいちばん新しい窓」を選び直すことがある
    private static func finish(app: NSRunningApplication, window: AXUIElement?) {
        if let window { AXWindow.raise(window, of: app) }
        // 前に出た直後はまだキー入力の受け口が定まっていないことがあるので、一拍置く
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            sendCommandV()
        }
    }

    /// 相手が前面に出るまで見張る（30msごと・締切まで）
    private static func waitUntilActive(
        _ app: NSRunningApplication,
        deadline: Date,
        then: @escaping (Bool) -> Void
    ) {
        if app.isActive { then(true); return }
        if Date() >= deadline { then(false); return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) {
            waitUntilActive(app, deadline: deadline, then: then)
        }
    }

    private static func sendCommandV() {
        let source = CGEventSource(stateID: .combinedSessionState)
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false) else { return }
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }
}
