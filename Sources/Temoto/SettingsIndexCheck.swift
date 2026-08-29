import AppKit
import TemotoCore

/// 「設定を探す」の行き先が合っているかを、**実物の画面を組み立てて**確かめる
/// （`--check-settings-index`）。
///
/// ⚠️ なぜ要るか。
/// 2026-08-23、私は `SettingsSearch.items` に「合言葉の自動展開 → 使う機能」と書いた。
/// 実物は**ショートカット**画面にあった。
/// 検索は当たるのに、開いた画面にその設定が無い——探せないより、たちが悪い。
/// 設定の置き場所を動かすたびに人が突き合わせるのは無理なので、機械にやらせる。
///
/// ⚠️ TemotoChecks（2,500件）ではなくアプリ側に置いてあるのは、
/// 画面の組み立てに AppKit が要るから。build-app.sh がここも呼ぶ。
enum SettingsIndexCheck {

    static func run() -> Int32 {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)

        let store = Store()
        let controller = SettingsController(
            store: store, coordinator: PanelCoordinator(),
            onShortcutsChanged: {}, onFeaturesChanged: {},
            appRecords: { [] }, rescanApps: {}, onClearClips: {}, onStatusChanged: {}
        )

        // 画面ごとに、目に見える文字を全部集める
        var visible: [SettingsPane: String] = [:]
        for pane in SettingsPane.allCases {
            var found: [String] = []
            collect(controller.paneView(for: pane), into: &found)
            visible[pane] = found.joined(separator: "\u{1}")
        }

        if CommandLine.arguments.contains("--dump") {
            for pane in SettingsPane.allCases {
                print("── \(pane.title) [\(pane.rawValue)]")
                for line in (visible[pane] ?? "").split(separator: "\u{1}")
                where line.count >= 3 && line.count <= 30 {
                    print("   \(line)")
                }
            }
            return 0
        }

        var failures: [String] = []

        // ── 記号が実在するか
        // ⚠️ SF Symbols の名前を間違えても落ちない。**黙って空欄**になるだけなので、
        // 横メニューが記号なしの字だけになる。目で見るまで気づけない
        for pane in SettingsPane.allCases
        where NSImage(systemSymbolName: pane.symbolName, accessibilityDescription: nil) == nil {
            failures.append("「\(pane.title)」の記号 \(pane.symbolName) は、このmacOSに在りません")
        }

        // ── 窓の大きさが画面ごとに変わらないか
        // ⚠️ 中身が窓より大きいと、Auto Layout は**窓のほうを広げて**辻褄を合わせる。
        // 2026-08-14、コピー履歴を開くと窓が 578→850 に伸び、アプリのキーでは横が
        // 831→981 に広がっていた。設定の窓は大きさを変えられないので、一度伸びると戻らない。
        // 画面を切り替えるたびに窓が跳ねるのは、いちばん安っぽく見える壊れ方
        controller.show(selecting: SettingsPane.allCases[0])
        guard let window = NSApp.windows.first(where: { $0 is SettingsWindow }) else {
            print("  🔴 設定の窓が作れません")
            return 1
        }
        let expected = window.frame.size
        for pane in SettingsPane.allCases {
            controller.show(selecting: pane)
            window.layoutIfNeeded()
            let size = window.frame.size
            if abs(size.width - expected.width) > 0.5 || abs(size.height - expected.height) > 0.5 {
                if CommandLine.arguments.contains("--why") { widest(controller.paneView(for: pane)) }
                failures.append("「\(pane.title)」を開くと窓の大きさが変わる"
                    + "（\(Int(expected.width))x\(Int(expected.height)) → \(Int(size.width))x\(Int(size.height))）")
            }
        }

        for item in SettingsSearch.items {
            let text = visible[item.pane] ?? ""
            if !text.contains(item.title) {
                failures.append("「\(item.title)」は \(item.pane.title) に出ていません")
            }
        }

        // 逆も見る: どの画面にも見出しがあるのに、探せる設定が1つも無い画面が無いか
        for pane in SettingsPane.allCases where !SettingsSearch.items.contains(where: { $0.pane == pane }) {
            failures.append("\(pane.title) に探せる設定がありません")
        }

        if failures.isEmpty {
            print("設定の探し先: \(SettingsSearch.items.count)件すべて、書いてある画面に実在します")
            print("窓の大きさ: \(SettingsPane.allCases.count)画面とも \(Int(expected.width))x\(Int(expected.height)) のまま変わりません")
            return 0
        }
        for f in failures { print("  🔴 \(f)") }
        print("設定の探し先が \(failures.count)件ずれています")
        return 1
    }

    /// はみ出しの犯人を探す（--why）。望みの幅がいちばん大きい部品を挙げる
    private static func widest(_ view: NSView) {
        var worst: [(CGFloat, String)] = []
        func walk(_ v: NSView) {
            let w = v.fittingSize.width
            if w > 560 {
                var label = String(describing: type(of: v))
                if let f = v as? NSTextField { label += " 「\(f.stringValue.prefix(28))」" }
                if let b = v as? NSButton { label += " 「\(b.title.prefix(28))」" }
                worst.append((w, label))
            }
            v.subviews.forEach(walk)
        }
        walk(view)
        for (w, label) in worst.sorted(by: { $0.0 > $1.0 }).prefix(3) {
            print("      幅 \(Int(w)): \(label)")
        }
    }

    /// 画面に出ている文字を集める。
    /// ⚠️ ボタンの題と札の両方を見る。片方だけだと、ボタンで書かれた設定を見落とす
    private static func collect(_ view: NSView, into found: inout [String]) {
        if let field = view as? NSTextField { found.append(field.stringValue) }
        if let button = view as? NSButton { found.append(button.title) }
        view.subviews.forEach { collect($0, into: &found) }
    }
}
