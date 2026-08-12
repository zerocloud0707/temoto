import AppKit
import TemotoCore

/// 選んでいる文字を、その場で変換して打ち直す。
///
/// 流れ: ⌘C を送って選んでいる文字をもらう → 変換（TextTransform） → ⌘V で打ち直す。
///
/// ⚠️ コピー経由にしている理由。
/// 他のアプリの「選んでいる文字」はアクセシビリティ越しでも取れないことが多く
/// （Electron系・ブラウザの中身など）、確実に取れる道はコピーだけ。
/// キー送出はウィンドウ分割と同じ「アクセシビリティ」の許可で動く。
enum TextConverter {

    /// 進行中は次を受け付けない。
    /// 連打で ⌘C と ⌘V が交錯すると、変換前の文字を貼り戻す事故になる。
    private static var isRunning = false

    static func convertSelection(_ transform: TextTransform, watcher: ClipboardWatcher?) {
        guard !isRunning else { return }
        isRunning = true

        let pasteboard = NSPasteboard.general
        let before = pasteboard.changeCount
        sendKey(8, flags: .maskCommand)   // ⌘C（8 = C）

        // 相手のアプリがペーストボードに書くのを待つ（最長0.6秒・30msごとに見る）。
        // 何も選んでいないとき、たいていのアプリは何も書かない＝時間切れで分かる。
        poll(until: { pasteboard.changeCount != before },
             deadline: Date().addingTimeInterval(0.6)) { copied in
            // コピーで増えた変化は履歴に取り込まない（変換の途中経過で履歴を汚さない）
            watcher?.ignoreCurrentChange()

            guard copied, let text = pasteboard.string(forType: .string), !text.isEmpty else {
                isRunning = false
                Toast.show("変換する文字が選ばれていません", isError: true)
                return
            }

            let converted = transform.apply(text)
            pasteboard.clearContents()
            pasteboard.setString(converted, forType: .string)
            watcher?.ignoreCurrentChange()

            // 相手はさっきまでどおり最前面にいるので、前に出し直す手間は要らない。
            // 書いた直後の一拍は、ペーストボードの中身が行き渡るのを待つ分
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                sendKey(9, flags: .maskCommand)   // ⌘V（9 = V）
                isRunning = false
            }
        }
    }

    /// コピー中の文字から色・書式を落として、その場に貼る（⌘⇧V の役）。
    ///
    /// ⚠️ 変換と違って ⌘C は送らない。「もうコピーしてある」ものが対象。
    /// Webやメールからコピーすると色・字の大きさ・リンクがくっ付いてくるが、
    /// 欲しいのはたいてい文字だけ。ペーストボードを文字だけに置き直してから貼る。
    static func pastePlain(watcher: ClipboardWatcher?) {
        guard !isRunning else { return }
        let pasteboard = NSPasteboard.general
        guard let text = pasteboard.string(forType: .string), !text.isEmpty else {
            Toast.show("コピーした文字がありません（先にコピーしてから押してください）", isError: true)
            return
        }
        isRunning = true
        // 同じ文字を「文字だけ」で置き直す＝書式・リンク・絵の同乗を全部降ろす
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        watcher?.ignoreCurrentChange()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            sendKey(9, flags: .maskCommand)   // ⌘V
            isRunning = false
        }
    }

    private static func poll(
        until condition: @escaping () -> Bool,
        deadline: Date,
        then: @escaping (Bool) -> Void
    ) {
        if condition() { then(true); return }
        if Date() >= deadline { then(false); return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) {
            poll(until: condition, deadline: deadline, then: then)
        }
    }

    /// ⌘つきのキーを1回押して離す。
    /// flags を明示して送るので、ショートカットを押したまま（⌃⌥を握ったまま）でも
    /// 相手には ⌘C / ⌘V として届く。
    private static func sendKey(_ key: CGKeyCode, flags: CGEventFlags) {
        let source = CGEventSource(stateID: .combinedSessionState)
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: false) else { return }
        down.flags = flags
        up.flags = flags
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }
}
