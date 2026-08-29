import AppKit
import Carbon.HIToolbox
import TemotoCore

/// どのアプリでも、合言葉を打った瞬間に定型文の本文へ置き換える見張り役。
///
/// 2026-08-10 作者「設定した単語を入力したら登録した文字が表示される機能。
/// この機能が実装されていないので、実装して。」
///
/// ⚠️ **照合はここでやらない**（TemotoCore.AutoExpand が持つ）。
/// ここがやるのは「キーを見る・合言葉ぶんを消す・本文を打ち込む」だけ。
///
/// ⚠️ この仕組みはキーの流れを見る。だから3つを固く守る:
///   1. **どこにも書かない・送らない**。覚えるのは末尾32文字だけで、それも部品の中から出さない
///   2. **秘密の入力中は完全に止まる**（パスワード欄では macOS が秘密入力の印を立てる。それを見る）
///   3. **日本語入力（IME）の変換中には手を出さない**。変換中の文字は見た目と打鍵が別物で、
///      消す文字数が合わずに文章を壊す。英数で打っているときだけ働く
enum AutoExpandMonitor {

    private static var monitor: Any?
    private static var buffer = ""
    /// 自分が打ち込んでいる最中か（自分の打鍵に自分が反応する無限ループを止める）
    private static var isInjecting = false
    /// 自分が作った出来事に付ける印
    private static let marker: Int64 = 0x54_45_4D_4F   // "TEMO"

    static var storeProvider: (() -> Store)?

    /// 見張りを設定に合わせて入れる／切る。
    ///
    /// ⚠️ NSEvent の全体監視は**他のアプリに向かうキーだけ**が来る。
    /// テモト自身の検索欄には来ない＝入口の合言葉（窓の中の辞書）と取り合いにならない。
    /// ⚠️ アクセシビリティの許可が無いと、何も来ない（エラーにもならない）。
    /// 入れるときに許可が無ければ、その場で伝える。
    static func update(enabled: Bool) {
        if enabled {
            guard monitor == nil else { return }
            if !AXWindow.isTrusted(prompt: false) {
                Toast.show("合言葉の自動展開には「アクセシビリティ」の許可が要ります。"
                           + "メニューの「アクセシビリティを許可」から入れてください",
                           isError: true, area: "定型文の自動展開")
            }
            monitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { event in
                handle(event)
            }
        } else {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            buffer = ""
        }
    }

    private static func handle(_ event: NSEvent) {
        guard !isInjecting else { return }
        // 自分が打ち込んだ分は見ない
        if let cg = event.cgEvent, cg.getIntegerValueField(.eventSourceUserData) == marker { return }
        // ⚠️ パスワード欄（秘密入力）では完全に止まる。覚えもしない
        guard !IsSecureEventInputEnabled() else { buffer = ""; return }
        // ⚠️ 日本語入力の最中は手を出さない（変換中の文字は打鍵と別物）
        guard isASCIICapableInput() else { buffer = ""; return }

        // 修飾キーつき（⌘C 等）は文字ではない。並びも一度捨てる（カーソルが飛ぶ操作が多い）
        if !event.modifierFlags.intersection([.command, .control, .option]).isEmpty {
            buffer = ""
            return
        }

        switch Int(event.keyCode) {
        case kVK_Delete:
            buffer = AutoExpand.bufferAfterBackspace(buffer)
        case kVK_Return, kVK_ANSI_KeypadEnter, kVK_Tab, kVK_Escape,
             kVK_LeftArrow, kVK_RightArrow, kVK_UpArrow, kVK_DownArrow,
             kVK_Home, kVK_End, kVK_PageUp, kVK_PageDown:
            // 行やカーソルが動いた＝いま見えている並びと打鍵の並びがずれた。捨てる
            buffer = ""
        default:
            guard let text = event.characters, !text.isEmpty,
                  !text.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
            else { return }
            buffer = AutoExpand.buffer(buffer, appending: text)
            expandIfMatched()
        }
    }

    private static func expandIfMatched() {
        guard let store = storeProvider?() else { return }
        let pairs = store.snippets.map { (keyword: $0.keyword, body: $0.body) }
        guard let hit = AutoExpand.match(typed: buffer, snippets: pairs) else { return }
        buffer = ""

        // 差し込み（{date} 等）は打ち込む瞬間に展開する（毎回その日の日付が入る）
        let context = SnippetContext(clipboard: NSPasteboard.general.string(forType: .string) ?? "")
        let body = SnippetExpander.expand(hit.body, context: context)
        guard !body.isEmpty else { return }

        // ⚠️ 改行入りの本文は**貼り付け**で入れる。
        // 改行をキーとして打ち込むと、チャットでは「送信」の意味になり、
        // 書きかけの文章が相手に飛ぶ（一番取り返しがつかない事故）。
        if body.contains("\n") {
            deleteTyped(hit.deleteCount)
            // ⚠️ 自動展開は「いま打っているアプリ」がそのまま相手なので、
            // 覚えておく必要はない。ただし窓は名指ししておく（他の窓が前に出ないように）
            let front = NSWorkspace.shared.frontmostApplication
            Paster.paste(body, into: front, window: AXWindow.focusedWindow(of: front))
        } else {
            deleteTyped(hit.deleteCount)
            type(body)
        }
    }

    /// 打たれた合言葉を消す（⌫ を必要な数だけ送る）
    private static func deleteTyped(_ count: Int) {
        isInjecting = true
        let source = CGEventSource(stateID: .combinedSessionState)
        for _ in 0..<count {
            post(CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_Delete), keyDown: true))
            post(CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_Delete), keyDown: false))
        }
        isInjecting = false
    }

    /// 本文を打ち込む。
    /// ⚠️ クリップボードを通さない（1行の本文で人のコピーを上書きしない）。
    /// 文字はキーの出来事に載せて送る。長い本文は20文字ずつに割る（1回に載る量に限りがある）
    private static func type(_ text: String) {
        isInjecting = true
        let source = CGEventSource(stateID: .combinedSessionState)
        var rest = Substring(text)
        while !rest.isEmpty {
            let chunk = String(rest.prefix(20))
            rest = rest.dropFirst(20)
            var units = Array(chunk.utf16)
            let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true)
            down?.keyboardSetUnicodeString(stringLength: units.count, unicodeString: &units)
            post(down)
            post(CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false))
        }
        isInjecting = false
    }

    private static func post(_ event: CGEvent?) {
        event?.setIntegerValueField(.eventSourceUserData, value: marker)
        event?.post(tap: .cghidEventTap)
    }

    /// いまの入力が英数か（日本語入力の変換中でないか）。
    /// IME の変換中は「打った鍵」と「見えている文字」が別物なので、触ると文章を壊す
    private static func isASCIICapableInput() -> Bool {
        guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue() else { return false }
        guard let raw = TISGetInputSourceProperty(source, kTISPropertyInputSourceIsASCIICapable) else { return false }
        return CFBooleanGetValue(unsafeBitCast(raw, to: CFBoolean.self))
    }
}
