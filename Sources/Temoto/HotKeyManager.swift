import Carbon.HIToolbox
import Foundation
import TemotoCore

/// ホットキーを押したときにやること
enum HotKeyAction: Equatable {
    case launcher
    case clipboard
    case snippets
    case note
    case layout(WindowLayout)
    case moveToDisplay(step: Int)
    /// よく使うアプリを前に出す（もう一度押すとしまう）
    case openApp(path: String, name: String)
    /// 選んでいる文字を変換して打ち直す
    case convert(TextTransform)
    /// コピー中の文字から色・書式を落として貼る
    case pastePlain
    case captureText
}

/// グローバルショートカット（複数）。
///
/// Carbon の RegisterEventHotKey を使う。CGEventTap と違って
/// 「入力監視」の権限が要らず、登録した組み合わせが押されたときだけ通知が来る。
/// つまり他のキー入力はこのアプリを一切通らない。
final class HotKeyManager {
    static let shared = HotKeyManager()

    /// 押されたときの通知。必ずメインスレッドで呼ばれる。
    var onTrigger: ((HotKeyAction) -> Void)?

    private var handler: EventHandlerRef?
    private var refs: [UInt32: EventHotKeyRef] = [:]
    private var actions: [UInt32: HotKeyAction] = [:]
    /// 使い回すと前の登録の残り火と取り違えるので、番号は増やす一方にする
    private var nextID: UInt32 = 1

    /// このアプリのホットキーだと分かるようにする4文字コード 'TMTC'
    private let signature: OSType = 0x544D5443

    private init() {}

    /// 全部登録し直す。取れなかったものを返す（他アプリが先に押さえている場合など）。
    @discardableResult
    func register(_ bindings: [(shortcut: Shortcut, action: HotKeyAction)]) -> [(shortcut: Shortcut, action: HotKeyAction)] {
        unregisterAll()
        installHandlerIfNeeded()

        var failures: [(shortcut: Shortcut, action: HotKeyAction)] = []
        for binding in bindings {
            // 修飾キー無しだとそのキーを丸ごと奪ってしまうので登録しない
            guard binding.shortcut.hasModifier else {
                failures.append(binding)
                continue
            }
            let id = nextID
            nextID += 1

            var ref: EventHotKeyRef?
            let status = RegisterEventHotKey(
                binding.shortcut.keyCode,
                binding.shortcut.carbonModifiers,
                EventHotKeyID(signature: signature, id: id),
                GetApplicationEventTarget(),
                0,
                &ref
            )
            if status == noErr, let ref {
                refs[id] = ref
                actions[id] = binding.action
            } else {
                failures.append(binding)
            }
        }
        return failures
    }

    func unregisterAll() {
        for ref in refs.values { UnregisterEventHotKey(ref) }
        refs.removeAll()
        actions.removeAll()
    }

    private func installHandlerIfNeeded() {
        guard handler == nil else { return }
        var spec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        // C の関数ポインタは外の変数を持ち込めないので、共有インスタンス経由で受け渡す
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ -> OSStatus in
            guard let event else { return OSStatus(eventNotHandledErr) }
            var pressed = EventHotKeyID()
            let status = GetEventParameter(
                event,
                EventParamName(kEventParamDirectObject),
                EventParamType(typeEventHotKeyID),
                nil,
                MemoryLayout<EventHotKeyID>.size,
                nil,
                &pressed
            )
            guard status == noErr else { return status }
            let id = pressed.id
            DispatchQueue.main.async { HotKeyManager.shared.fire(id) }
            return noErr
        }, 1, &spec, nil, &handler)
    }

    private func fire(_ id: UInt32) {
        guard let action = actions[id] else { return }
        onTrigger?(action)
    }
}
