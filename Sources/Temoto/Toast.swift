import AppKit

/// 画面の上に少しだけ出る通知。
///
/// 通知センターを使わない理由: 署名の無いアプリだと許可が下りず、
/// 「動いているのに何も言わない」状態になる。自前で出せば権限に左右されない。
enum Toast {
    private static var panel: NSPanel?
    private static var hideWork: DispatchWorkItem?

    /// - Parameter area: どのあたりで起きたか（記録用・省略可）
    static func show(_ message: String, isError: Bool = false, area: String = "") {
        // ⚠️ 失敗のお知らせは**すべてここを通る**ので、記録の入口をここ1つに絞る。
        // 記録用の呼び出しを各所に散らすと必ずどこかで書き忘れる
        // （2026-08-09「エラー情報を収集したい」＝A案・手元に貯めて本人が送る）。
        if isError {
            ErrorReporter.record(area: area.isEmpty ? "テモト" : area, what: message)
        }
        let label = NSTextField(labelWithString: message)
        label.font = .systemFont(ofSize: 14, weight: .medium)
        label.textColor = .labelColor
        label.alignment = .left
        label.sizeToFit()

        // 左に小さな印を置く。
        // ⚠️ 色だけで良し悪しを伝えない。赤と緑の区別が付きにくい人には何も伝わらないので、
        // 形（チェックか三角）でも分かるようにする。
        let icon = NSImageView()
        icon.image = NSImage(
            systemSymbolName: isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill",
            accessibilityDescription: nil)
        icon.contentTintColor = isError ? .systemRed : .systemGreen
        icon.imageScaling = .scaleProportionallyUpOrDown

        let iconEdge: CGFloat = 16
        let width = min(max(label.frame.width + iconEdge + 46, 200), 560)
        let height: CGFloat = 46

        let panel = existingPanel()
        panel.setContentSize(NSSize(width: width, height: height))

        // 地は他の窓と同じ BackdropView。
        // ⚠️ ここだけ材質や丸みを書き直さない。お知らせは検索窓のすぐ上に出るので、
        // 質感が違うと「別のアプリが割り込んできた」ように見える。
        let background = BackdropView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        // 失敗のときだけ縁を赤くする（色だけに頼らず、絵も三角に変えてある）
        if isError { background.edgeColor = NSColor.systemRed.withAlphaComponent(0.7) }

        icon.frame = NSRect(x: 18, y: (height - iconEdge) / 2, width: iconEdge, height: iconEdge)
        label.frame = NSRect(x: 18 + iconEdge + 8, y: (height - label.frame.height) / 2,
                             width: width - (18 + iconEdge + 8) - 18, height: label.frame.height)
        background.addSubview(icon)
        background.addSubview(label)
        panel.contentView = background

        if let screen = NSScreen.main ?? NSScreen.screens.first {
            let visible = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(
                x: visible.midX - width / 2,
                y: visible.maxY - height - 24
            ))
        }

        panel.alphaValue = 1
        panel.orderFrontRegardless()

        hideWork?.cancel()
        let work = DispatchWorkItem {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.25
                panel.animator().alphaValue = 0
            } completionHandler: {
                panel.orderOut(nil)
            }
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + (isError ? 2.4 : 1.4), execute: work)
    }

    private static func existingPanel() -> NSPanel {
        if let panel { return panel }
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 260, height: 46),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        self.panel = panel
        return panel
    }
}
