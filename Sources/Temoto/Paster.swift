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
    static func paste(_ text: String, into app: NSRunningApplication?, afterCopy: (() -> Void)? = nil) {
        pasteAfterWriting(into: app, afterCopy: afterCopy) { copy(text) }
    }

    static func pasteImage(_ png: Data, into app: NSRunningApplication?, afterCopy: (() -> Void)? = nil) {
        pasteAfterWriting(into: app, afterCopy: afterCopy) { copyImage(png) }
    }

    static func pasteFiles(_ paths: [String], into app: NSRunningApplication?, afterCopy: (() -> Void)? = nil) {
        pasteAfterWriting(into: app, afterCopy: afterCopy) { copyFiles(paths) }
    }

    private static func pasteAfterWriting(
        into app: NSRunningApplication?,
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

        // ⚠️ `app.activate()` を当てにしない。今のmacOSは背面のプロセスによる
        // 他アプリの前面化を**黙って拒否**する（戻り値は true のまま。2026-07-31 実測）。
        // Dock と同じ道（LaunchServices）なら通る。アプリのキーで実証済みのやり方をここでも使う。
        if !app.isActive {
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            if let url = app.bundleURL {
                NSWorkspace.shared.openApplication(at: url, configuration: configuration, completionHandler: nil)
            } else {
                app.activate()
            }
        }

        // ⚠️ 決め打ちの待ち時間にしない。相手が前に出るまでの時間はアプリごとに違い、
        // 短すぎると ⌘V がどこにも入らず「押しても何も起きない」になる。
        // 前に出たのを見てから送り、出てこなければ**黙らずに言う**。
        waitUntilActive(app, deadline: Date().addingTimeInterval(0.9)) { becameActive in
            guard becameActive else {
                Toast.show("\(app.localizedName ?? "元のアプリ")に戻れませんでした"
                           + "（コピーはできています。⌘V で貼れます）", isError: true)
                return
            }
            // 前に出た直後はまだキー入力の受け口が定まっていないことがあるので、一拍置く
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                sendCommandV()
            }
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
