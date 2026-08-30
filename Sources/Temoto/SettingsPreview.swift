import AppKit
import TemotoCore

/// 設定画面を絵にして書き出す（`--render-settings <出力先.png> [--pane general] [--light]`）。
///
/// ⚠️ なぜ要るか。
/// 設定画面は ⌘Space →⌘, でしか開かない。外から自動で開くにはアクセシビリティの許可が要り、
/// 画面を撮るには画面収録の許可が要る。どちらも「直したつもり」で終わらせる原因になる
/// （2026-07-30「ほとんどデザイン変わってないよ。。。」＝目で見ていなかった失敗）。
/// アプリ自身に描かせれば、許可なしで**実物の部品のまま**確かめられる。
enum SettingsPreview {

    static func parse(_ arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: "--render-settings"),
              index + 1 < arguments.count else { return nil }
        return arguments[index + 1]
    }

    private static func parsePane(_ arguments: [String]) -> SettingsPane {
        guard let index = arguments.firstIndex(of: "--pane"), index + 1 < arguments.count,
              let pane = SettingsPane(rawValue: arguments[index + 1]) else {
            return SettingsPane.allCases[0]
        }
        return pane
    }

    static func run(outputPath: String, dark: Bool) -> Int32 {
        let app = NSApplication.shared
        // ⚠️ `.prohibited` にすると窓が**前面になれない**。
        // 前面でない窓の選択の帯は「控えめな選択」で描かれ、macOS 26 では
        // 絵にすると真っ黒な棒になる（中の字も記号も黒く沈んで消える）。
        // `.accessory` なら前面になれるので、実機と同じ「濃い選択の帯＋白い字」が写る
        app.setActivationPolicy(.accessory)
        NSApp.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)

        // ⚠️ 本物の Store を使う（設定を読むだけ・書かない）。
        // 作り物の設定で描くと、字あふれのような**実際に起きている崩れ**が写らない
        let store = Store()
        let coordinator = PanelCoordinator()
        let controller = SettingsController(
            store: store,
            coordinator: coordinator,
            onShortcutsChanged: {},
            onFeaturesChanged: {},
            appRecords: { [] },
            rescanApps: {},
            onClearClips: {},
            onStatusChanged: {}
        )
        controller.show(selecting: parsePane(CommandLine.arguments))
        NSApp.activate()
        NSApp.windows.first(where: { $0 is SettingsWindow })?.makeKeyAndOrderFront(nil)
        // 前面になるのを待つ（すぐ撮ると、まだ控えめな選択のまま）
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        if let index = CommandLine.arguments.firstIndex(of: "--key-query"),
           index + 1 < CommandLine.arguments.count {
            controller.previewHotkeySearch(CommandLine.arguments[index + 1])
        }
        if let index = CommandLine.arguments.firstIndex(of: "--query"),
           index + 1 < CommandLine.arguments.count {
            controller.previewSearch(CommandLine.arguments[index + 1])
        }
        guard let window = NSApp.windows.first(where: { $0 is SettingsWindow }),
              let root = window.contentView else {
            FileHandle.standardError.write(Data("設定の窓が作れません\n".utf8))
            return 1
        }

        // 材質の比べ物用（--material underWindowBackground など）。
        // ⚠️ 絵にするときだけ差し替える。実装を確定するための下見
        if let index = CommandLine.arguments.firstIndex(of: "--material"),
           index + 1 < CommandLine.arguments.count {
            let name = CommandLine.arguments[index + 1]
            let table: [String: NSVisualEffectView.Material] = [
                "windowBackground": .windowBackground,
                "underWindowBackground": .underWindowBackground,
                "contentBackground": .contentBackground,
                "popover": .popover,
                "menu": .menu,
                "sheet": .sheet,
                "hudWindow": .hudWindow,
                "headerView": .headerView,
                "titlebar": .titlebar,
                "sidebar": .sidebar,
            ]
            if let material = table[name] { applyMaterial(material, to: root) }
        }

        var result: Int32 = 0
        root.effectiveAppearance.performAsCurrentDrawingAppearance {
            // ⚠️ すりガラスは「窓の後ろ」を透かす設定（.behindWindow）だと、
            // 絵に写したとき**素通し＝真っ黒**になる。
            // 描く前だけ「窓の中」を透かす設定に替えると、macOS が本物の材質で塗ってくれる。
            // 自分でそれらしい灰色を塗るより正確（横メニューと中身の濃さの差もそのまま出る）
            // ⚠️ すりガラスの後ろに**壁紙を敷く**。
            // これが無いと `.withinWindow` は透かす相手が無く、材質を変えても
            // 絵はまったく同じになる（実測: 6種類とも1画素も違わなかった）。
            // 検索窓の試作（DesignPreview）が先に使っている手。
            // 実機は写真の上に出るので、明暗のある地で確かめる
            let wall = WallpaperView(frame: root.bounds)
            wall.autoresizingMask = [.width, .height]
            root.addSubview(wall, positioned: .below, relativeTo: nil)
            switchToWithinWindow(root)
            unwrapSidebar(root)
            emphasizeSelection(root)
            window.layoutIfNeeded()
            // アプリのアイコンは macOS があとから読む。待たずに写すと空の四角になる
            RunLoop.current.run(until: Date().addingTimeInterval(0.6))

            guard let rep = root.bitmapImageRepForCachingDisplay(in: root.bounds) else {
                result = 1
                return
            }
            root.cacheDisplay(in: root.bounds, to: rep)
            guard let data = rep.representation(using: .png, properties: [:]) else {
                result = 1
                return
            }
            do {
                try data.write(to: URL(fileURLWithPath: outputPath))
            } catch {
                FileHandle.standardError.write(Data("書き出せません: \(error)\n".utf8))
                result = 1
            }
        }
        return result
    }

    /// 横メニューを、macOS 26 の新しいすりガラスの入れ物から**外に出す**。
    ///
    /// ⚠️ macOS 26 は横メニューを NSContainerConcentricGlassEffectView で自動的に包む。
    /// これは画面には正しく出るが、絵に写すと**真っ白な板**になり、中の行が全部隠れる
    /// （塗りを消してもだめだった。中で独自に描いている）。
    /// 絵にするときだけ、中身を入れ物の外へ移して、入れ物を隠す。
    ///
    /// ⚠️ これは絵にするときだけの細工で、実機では通らない道。
    /// つまり**すりガラスの見え方そのものは、この絵では確かめられない**。
    /// ここで確かめられるのは行の並び・字の大きさ・余白まで。色味は実機で見ること
    private static func unwrapSidebar(_ view: NSView) {
        guard let bar = findSidebar(view) else { return }
        var glass: NSView? = bar.superview
        while let current = glass {
            let name = String(describing: type(of: current))
            if name.contains("Glass"), let parent = current.superview {
                let frame = current.frame
                bar.removeFromSuperview()
                // ⚠️ macOS 26 では横メニューの地は**OSが描く**（自前では敷かない）。
                // その板は絵に写らないので、ここで代役を1枚置く。
                // 代役は `.sidebar` の材質＝OSが使うものと同じ。
                // ⚠️ あくまで代役。実機の Liquid Glass の見え方そのものではない
                let stand = NSVisualEffectView(frame: frame)
                stand.material = .sidebar
                stand.blendingMode = .withinWindow
                stand.state = .active
                stand.wantsLayer = true
                stand.layer?.cornerRadius = 12
                stand.layer?.masksToBounds = true
                stand.autoresizingMask = [.width, .height]
                parent.addSubview(stand)
                // ⚠️ 分割ビューの中では位置を制約で決めていたので、そのままだと
                // 大きさが決まらず**畳まれる**（1度これで検索欄だけが隅に写った）。
                // 外に出すときは、位置を frame で決める側に戻す
                bar.translatesAutoresizingMaskIntoConstraints = true
                bar.frame = frame
                parent.addSubview(bar)
                current.isHidden = true
                // 横メニューの地に敷かれた板も隠す（これが絵では白く写る正体）
                for sibling in parent.subviews where sibling !== bar {
                    let siblingName = String(describing: type(of: sibling))
                    if siblingName.contains("Blurry") || siblingName.contains("Backdrop") {
                        sibling.isHidden = true
                    }
                }
                return
            }
            glass = current.superview
        }
    }

    private static func findSidebar(_ view: NSView) -> SettingsSidebar? {
        if let bar = view as? SettingsSidebar { return bar }
        for child in view.subviews {
            if let found = findSidebar(child) { return found }
        }
        return nil
    }

    /// 中身の側（横メニュー以外）のすりガラスを差し替える
    private static func applyMaterial(_ material: NSVisualEffectView.Material, to view: NSView) {
        if let glass = view as? NSVisualEffectView, glass.material == .windowBackground {
            glass.material = material
        }
        view.subviews.forEach { applyMaterial(material, to: $0) }
    }

    /// 選ばれている行を「前面の窓と同じ」見た目にする。
    ///
    /// ⚠️ 絵にするとき、窓は本当の意味で前面になれない。すると選択は「控えめ」で描かれ、
    /// macOS 26 ではそれが**真っ黒な棒**として写り、中の字も記号も沈んで見えなくなる
    /// （2026-08-23、これを「明るい見た目で選択行が読めない不具合」と読み違えて調べ直した）。
    /// 実機の見え方（青い帯＋白い字）に合わせるため、絵にするときだけ強制する
    private static func emphasizeSelection(_ view: NSView) {
        if let row = view as? NSTableRowView { row.isEmphasized = true }
        view.subviews.forEach(emphasizeSelection)
    }

    private static func switchToWithinWindow(_ view: NSView) {
        if let glass = view as? NSVisualEffectView {
            // ⚠️ 選択の帯（material == .selection）は触らない。
            // ここを .withinWindow に替えると、絵では**真っ黒な棒**になり、
            // 「選択中の行が読めない」という**在りもしない不具合**に見える
            // （2026-08-23、明るい見た目でそう見えて調べ直した）
            if glass.material != .selection {
                glass.blendingMode = .withinWindow
                glass.state = .active
            }
        }
        view.subviews.forEach(switchToWithinWindow)
    }
}


/// 絵にするとき、すりガラスの後ろに敷く「壁紙のつもり」の地。
/// ⚠️ 実機の見え方そのものではない。**材質どうしの差**を見るための下地
private final class WallpaperView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        let dark = NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let backdrop = NSGradient(colors: dark
            ? [NSColor(calibratedRed: 0.10, green: 0.13, blue: 0.20, alpha: 1),
               NSColor(calibratedRed: 0.30, green: 0.22, blue: 0.32, alpha: 1)]
            : [NSColor(calibratedRed: 0.86, green: 0.89, blue: 0.94, alpha: 1),
               NSColor(calibratedRed: 0.98, green: 0.96, blue: 0.92, alpha: 1)])
        backdrop?.draw(in: bounds, angle: -60)
        // 透け具合が分かるように、はっきりした模様を置く（線がどれだけ見えるかで濃さが分かる）
        let stripe = NSColor(calibratedRed: 1, green: 1, blue: 1, alpha: dark ? 0.10 : 0.35)
        stripe.setFill()
        var x: CGFloat = -bounds.height
        while x < bounds.width {
            let path = NSBezierPath()
            path.move(to: NSPoint(x: x, y: 0))
            path.line(to: NSPoint(x: x + bounds.height, y: bounds.height))
            path.line(to: NSPoint(x: x + bounds.height + 26, y: bounds.height))
            path.line(to: NSPoint(x: x + 26, y: 0))
            path.close()
            path.fill()
            x += 90
        }
    }
}
