import AppKit
import ApplicationServices
import CoreGraphics
import TemotoCore

/// Accessibility API 越しのウィンドウ操作。
///
/// ここで扱う座標はすべて **AX座標系**（主ディスプレイの左上が原点・yは下向き）。
/// NSScreen から取った値は必ず `Geometry.axRect` を通してから使う。
enum AXWindow {

    /// 「アクセシビリティ」の許可があるか。prompt: true で設定を開くよう促すダイアログが出る。
    static func isTrusted(prompt: Bool) -> Bool {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        return AXIsProcessTrustedWithOptions([key: prompt] as CFDictionary)
    }

    /// 最前面アプリの、キーボード入力を受けているウィンドウ
    static func focused() -> (window: AXUIElement, pid: pid_t)? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        let pid = app.processIdentifier
        var value: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(
            AXUIElementCreateApplication(pid),
            kAXFocusedWindowAttribute as CFString,
            &value
        )
        guard status == .success,
              let value,
              CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement, pid)
    }

    /// 指定したアプリで、いま焦点のある窓を返す。
    ///
    /// ⚠️ `focused()` は「いま前面のアプリ」を見るので、テモトが前に出たあとでは使えない。
    /// 戻り先を覚えるのはテモトを開く**前**なので、相手を名指しできるこちらを使う。
    static func focusedWindow(of app: NSRunningApplication?) -> AXUIElement? {
        guard let pid = app?.processIdentifier else { return nil }
        var value: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(
            AXUIElementCreateApplication(pid),
            kAXFocusedWindowAttribute as CFString,
            &value
        )
        guard status == .success,
              let value,
              CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    /// その窓だけを前に出す。
    ///
    /// ⚠️ これが要る理由（2026-08-23 作者「コピー履歴を貼り付けると、
    /// なぜか他のブラウザの表示が最前面になったりします」）。
    /// アプリを前に出すだけでは、**どの窓が前に来るかは macOS が決める**。
    /// ブラウザのように窓を何枚も開くアプリでは、打っていた窓ではなく別の窓が出てくる。
    /// 名指しした窓に「上がれ」と言い、そのうえで「これが主役／焦点」だと伝える。
    ///
    /// ⚠️ 3つとも投げる。`kAXRaiseAction` は重なりの順だけ、
    /// `kAXMainWindow` はアプリの中の主役、`kAXFocusedWindow` はキー入力の行き先で、
    /// アプリによってどれを見ているかが違う（1つだけだと効かない相手がいる）。
    @discardableResult
    static func raise(_ window: AXUIElement, of app: NSRunningApplication?) -> Bool {
        let raised = AXUIElementPerformAction(window, kAXRaiseAction as CFString) == .success
        var ok = raised
        if let pid = app?.processIdentifier {
            let element = AXUIElementCreateApplication(pid)
            let main = AXUIElementSetAttributeValue(
                element, kAXMainWindowAttribute as CFString, window) == .success
            let focused = AXUIElementSetAttributeValue(
                element, kAXFocusedWindowAttribute as CFString, window) == .success
            ok = ok || main || focused
        }
        return ok
    }

    /// 指定したアプリの、いちばん前の窓の位置と大きさ。
    ///
    /// ⚠️ `focused()` は「いま前面のアプリ」を見るので、テモトが前に出ている間は使えない。
    /// ページ全体を撮るときは**テモトを開く前に前面だった相手**を名指しする必要がある。
    static func frontmostWindowFrame(of app: NSRunningApplication?) -> CGRect? {
        guard let pid = app?.processIdentifier else { return nil }
        let element = AXUIElementCreateApplication(pid)
        var value: CFTypeRef?
        // まず「注目している窓」。取れなければ窓の一覧の先頭（前面の窓）
        if AXUIElementCopyAttributeValue(element, kAXFocusedWindowAttribute as CFString, &value) == .success,
           let value, CFGetTypeID(value) == AXUIElementGetTypeID() {
            return frame(of: value as! AXUIElement)
        }
        var windows: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXWindowsAttribute as CFString, &windows) == .success,
              let list = windows as? [AXUIElement], let first = list.first else { return nil }
        return frame(of: first)
    }

    static func frame(of window: AXUIElement) -> CGRect? {
        var positionValue: CFTypeRef?
        var sizeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &positionValue) == .success,
              AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &sizeValue) == .success,
              let positionValue, let sizeValue,
              CFGetTypeID(positionValue) == AXValueGetTypeID(),
              CFGetTypeID(sizeValue) == AXValueGetTypeID() else { return nil }

        var origin = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionValue as! AXValue, .cgPoint, &origin),
              AXValueGetValue(sizeValue as! AXValue, .cgSize, &size) else { return nil }
        return CGRect(origin: origin, size: size)
    }

    /// 位置 → 大きさ → もう一度位置、の順で設定する。
    ///
    /// 最小サイズが決まっているウィンドウ（ターミナルの一部やチャット系）では、
    /// 大きさを変えた拍子に位置が押し戻されることがある。
    /// 最後にもう一度位置を入れておくと、少なくとも左上は狙った所に収まる。
    @discardableResult
    static func setFrame(_ rect: CGRect, on window: AXUIElement) -> Bool {
        var origin = rect.origin
        var size = rect.size
        guard let positionValue = AXValueCreate(.cgPoint, &origin),
              let sizeValue = AXValueCreate(.cgSize, &size) else { return false }

        let positioned = AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, positionValue)
        let resized = AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, sizeValue)
        AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, positionValue)
        return positioned == .success && resized == .success
    }

    /// アプリをまるごとしまう（⌘Hと同じ）。
    ///
    /// ⚠️ `NSRunningApplication.hide()` は使えない。今のmacOSは背面のプロセスが
    /// 他アプリの表・裏を切り替えることを黙って拒否する（戻り値も false。2026-07-31 実測）。
    /// アクセシビリティ越しなら通る（ウィンドウ分割と同じ許可で動く）。
    @discardableResult
    static func hideApp(pid: pid_t) -> Bool {
        AXUIElementSetAttributeValue(
            AXUIElementCreateApplication(pid),
            kAXHiddenAttribute as CFString,
            kCFBooleanTrue
        ) == .success
    }

    /// 全画面の作業領域（メニューバーとDockを除く）をAX座標系で返す
    static func visibleFramesInAX() -> [CGRect] {
        let screens = NSScreen.screens
        guard let primary = screens.first else { return [] }
        let primaryHeight = primary.frame.height
        return screens.map { Geometry.axRect(fromCocoa: $0.visibleFrame, primaryHeight: primaryHeight) }
    }
}

/// ウィンドウ操作の実行役。
final class WindowManager {

    enum Failure: Equatable {
        case notTrusted
        case noWindow
        case noScreen
        case notResizable
        case noPrevious
        case singleDisplay

        var message: String {
            switch self {
            case .notTrusted: return "「アクセシビリティ」の許可が必要です"
            case .noWindow: return "動かせるウィンドウが見つかりません"
            case .noScreen: return "画面の情報が取れません"
            case .notResizable: return "このウィンドウは大きさを変えられません"
            case .noPrevious: return "戻す先を覚えていません"
            case .singleDisplay: return "画面が1枚しかありません"
            }
        }
    }

    /// レイアウトを当てる前の枠。「元のサイズに戻す」で使う。
    ///
    /// ウィンドウ1枚ごとのIDは公開APIでは取れない（非公開シンボルが要る。
    /// 非公開シンボルは将来のmacOSで消えると起動そのものができなくなるので使わない）。
    /// そのためアプリ（pid）ごとに直前の1枚だけ覚える。
    /// 同じアプリの別ウィンドウを続けて動かした場合、戻せるのは後から動かした方だけ。
    private var previousFrames: [pid_t: CGRect] = [:]

    /// 画面の数や解像度が変わったら、覚えている枠は消えた画面の座標かもしれないので捨てる。
    func forgetPrevious() {
        previousFrames.removeAll()
    }

    @discardableResult
    func apply(_ layout: WindowLayout) -> Failure? {
        guard AXWindow.isTrusted(prompt: false) else { return .notTrusted }
        guard let (window, pid) = AXWindow.focused(),
              let current = AXWindow.frame(of: window) else { return .noWindow }

        let screens = AXWindow.visibleFramesInAX()
        guard let index = Geometry.bestScreenIndex(for: current, screens: screens) else { return .noScreen }

        guard let target = Geometry.targetFrame(
            for: layout,
            visible: screens[index],
            current: current,
            previous: previousFrames[pid]
        ) else {
            return layout == .restore ? .noPrevious : .noWindow
        }

        guard AXWindow.setFrame(target, on: window) else { return .notResizable }

        if layout == .restore {
            previousFrames[pid] = nil
        } else {
            previousFrames[pid] = current
        }
        return nil
    }

    @discardableResult
    func moveToNeighborDisplay(step: Int) -> Failure? {
        guard AXWindow.isTrusted(prompt: false) else { return .notTrusted }
        guard let (window, pid) = AXWindow.focused(),
              let current = AXWindow.frame(of: window) else { return .noWindow }

        let screens = AXWindow.visibleFramesInAX()
        guard let from = Geometry.bestScreenIndex(for: current, screens: screens) else { return .noScreen }
        guard let to = Geometry.neighborScreenIndex(from: from, count: screens.count, step: step) else {
            return .singleDisplay
        }

        let target = Geometry.movedProportionally(current, from: screens[from], to: screens[to])
        guard AXWindow.setFrame(target, on: window) else { return .notResizable }
        previousFrames[pid] = current
        return nil
    }
}
