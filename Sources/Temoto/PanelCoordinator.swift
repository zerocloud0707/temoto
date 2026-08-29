import AppKit
import TemotoCore

/// テモトの窓の交通整理。
///
/// ⚠️ なぜ1か所に集めたか
///   これまでは窓ごとに「直前まで前面だったアプリ」を別々に覚え、
///   閉じ方も窓ごとにその場で書いていた。その結果
///     ・メモだけ外をクリックしても閉じない
///     ・検索窓からメモへ渡り歩くと戻り先の記録が途切れる
///   という食い違いが出た。作者の
///     「メモやその他、アプリとは別の部分をクリックしても閉じなかったり、挙動をもっと上手く作って。」
///   はここが原因。
///
///   決まりは TemotoCore.PanelBehavior（表・検証できる）、
///   実際に閉じる手配はここ（AppKit・1か所）に分ける。
final class PanelCoordinator {

    /// テモトの窓を開く前まで前面だったアプリ。
    /// 3つの窓で1つを共有する（渡り歩いても戻り先を見失わないように）。
    private(set) var previousApp: NSRunningApplication?

    /// テモトを開く前に、その相手で焦点があった**窓**。
    ///
    /// ⚠️ アプリだけ覚えても足りない（2026-08-23 作者「コピー履歴を貼り付けると、
    /// なぜか他のブラウザの表示が最前面になったりします」）。
    /// ブラウザのように窓を何枚も開くアプリでは、アプリを前に出したときに
    /// **どの窓が来るかは macOS が決める**ので、打っていた窓とは限らない。
    /// ⚠️ アクセシビリティの許可が無いときは nil。そのときは今までどおりアプリだけ戻す
    private(set) var previousWindow: AXUIElement?

    private var isVisibleChecks: [PanelKind: () -> Bool] = [:]
    private var closers: [PanelKind: (CloseReason) -> Void] = [:]

    /// 外をクリックしたときの見張り。詳しくは updateOutsideClickMonitor を参照。
    private var outsideClickMonitor: Any?

    deinit {
        if let outsideClickMonitor { NSEvent.removeMonitor(outsideClickMonitor) }
    }

    /// 窓ができたら申告してもらう。
    /// ⚠️ closure は弱参照で渡すこと（ここが持ち主になると解放されない）。
    func register(_ kind: PanelKind,
                  isVisible: @escaping () -> Bool,
                  close: @escaping (CloseReason) -> Void) {
        isVisibleChecks[kind] = isVisible
        closers[kind] = close
    }

    /// 窓を開く直前に必ず呼ぶ。
    /// 1. 戻り先を覚える
    /// 2. 決まりに従って、じゃまになる窓をどかす
    func willOpen(_ kind: PanelKind) {
        rememberFrontmostApp()
        for other in PanelBehavior.panelsToClose(whenOpening: kind) where isVisible(other) {
            closers[other]?(.replacedByAnother)
        }
    }

    /// 窓を出したあとに呼ぶ。
    func didOpen(_ kind: PanelKind) {
        updateOutsideClickMonitor()
    }

    /// 窓を閉じたあとに呼ぶ。決まりが「返す」と言っていれば元のアプリへ焦点を返す。
    func didClose(_ kind: PanelKind, reason: CloseReason) {
        updateOutsideClickMonitor()
        guard PanelBehavior.restoresPreviousApp(kind, reason: reason) else { return }
        restorePreviousApp()
    }

    /// 元のアプリと、そのとき使っていた窓に戻す。
    ///
    /// ⚠️ `NSApp.yieldActivation(to:)` を先に呼ぶ。今の macOS は背面のプロセスが
    /// 他アプリを前に出すのを黙って断るが、**いま前面にいる自分が譲る**のは正規の道。
    /// これを使わずに「アプリを開き直す」（NSWorkspace.openApplication）と、
    /// Dock のアイコンを押したのと同じ扱いになり、そのアプリの**窓が全部前に出る**。
    func restorePreviousApp() {
        guard let app = previousApp else { return }
        NSApp.yieldActivation(to: app)
        app.activate()
        // 窓を覚えていれば、その窓だけを名指しで前に出す
        if let window = previousWindow {
            AXWindow.raise(window, of: app)
        }
    }

    func isVisible(_ kind: PanelKind) -> Bool {
        isVisibleChecks[kind]?() ?? false
    }

    /// いま出ている窓（メニューの状態表示や見張りの判断に使う）
    var visiblePanels: [PanelKind] {
        PanelKind.allCases.filter { isVisible($0) }
    }

    /// 戻り先を覚える。
    ///
    /// ⚠️ すでにテモトが前面のときに上書きすると、戻り先が自分自身になる。
    /// 検索窓を開いたままメモへ移るときがまさにこれなので、そのときは前の記録を残す。
    private func rememberFrontmostApp() {
        let front = NSWorkspace.shared.frontmostApplication
        guard front?.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
        previousApp = front
        // ⚠️ ここで撮っておく。テモトが前に出たあとでは、相手の「焦点のある窓」は取れない
        previousWindow = AXWindow.focusedWindow(of: front)
    }

    // MARK: - 外をクリックしたら閉じる（保険）

    /// クリックそのものを見張る。
    ///
    /// ⚠️ 本筋は各窓の windowDidResignKey。ただしそれは
    /// 「その窓が鍵（key window）を持っていた」ことが前提になっている。
    /// テモトはメニューバーだけのアプリで、窓を出すときに NSApp.activate() で
    /// 自分を前に出しているが、macOS はこれを断ることがある
    /// （他のアプリが操作中のときなど）。断られると
    ///   出ているのに鍵を持っていない → 離れても resignKey が来ない → 閉じない
    /// になる。枠の無い窓は閉じるボタンが無いので、これが起きると剥がせない。
    ///
    /// なので、鍵の受け渡しとは別に「テモトの外でクリックが起きた」こと自体を見張る道を作る。
    /// 二重に閉じにいくが、各窓の close は出ていないときは何もしないので害はない。
    ///
    /// ⚠️ この見張りはアクセシビリティ権限を必要としない。
    /// 権限が要るのはキーボードの見張りだけで、マウスは要らない。
    /// テモトは作り直すたびに権限が外れるので、ここが権限に依存しないことは大事。
    private func updateOutsideClickMonitor() {
        let needsMonitor = visiblePanels.contains { PanelBehavior.closesWhenFocusLost($0) }

        if needsMonitor, outsideClickMonitor == nil {
            // 全体の見張りは「他のアプリに届いたイベント」だけを受け取る。
            // 自分の窓の中を押したときはここへ来ないので、押した拍子に閉じることはない。
            outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(
                matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
            ) { [weak self] _ in
                self?.closePanelsOnOutsideClick()
            }
        } else if !needsMonitor, let monitor = outsideClickMonitor {
            NSEvent.removeMonitor(monitor)
            outsideClickMonitor = nil
        }
    }

    private func closePanelsOnOutsideClick() {
        for kind in visiblePanels where PanelBehavior.closesWhenFocusLost(kind) {
            closers[kind]?(.focusLost)
        }
    }
}
