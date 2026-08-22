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
        app.setActivationPolicy(.prohibited)
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
        if let index = CommandLine.arguments.firstIndex(of: "--query"),
           index + 1 < CommandLine.arguments.count {
            controller.previewSearch(CommandLine.arguments[index + 1])
        }
        guard let window = NSApp.windows.first(where: { $0 is SettingsWindow }),
              let root = window.contentView else {
            FileHandle.standardError.write(Data("設定の窓が作れません\n".utf8))
            return 1
        }

        var result: Int32 = 0
        root.effectiveAppearance.performAsCurrentDrawingAppearance {
            // ⚠️ すりガラスは「窓の後ろ」を透かす設定（.behindWindow）だと、
            // 絵に写したとき**素通し＝真っ黒**になる。
            // 描く前だけ「窓の中」を透かす設定に替えると、macOS が本物の材質で塗ってくれる。
            // 自分でそれらしい灰色を塗るより正確（横メニューと中身の濃さの差もそのまま出る）
            switchToWithinWindow(root)
            unwrapSidebar(root)
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

    private static func switchToWithinWindow(_ view: NSView) {
        if let glass = view as? NSVisualEffectView {
            glass.blendingMode = .withinWindow
            glass.state = .active
        }
        view.subviews.forEach(switchToWithinWindow)
    }
}
