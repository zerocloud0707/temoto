import AppKit
import TemotoCore

/// 見た目を絵にして書き出す（`--render-preview <出力先.png>`）。
///
/// ⚠️ なぜ要るか。
/// デザインの直しは「実際どう見えるか」を見ないと当てずっぽうになる。
/// 2026-07-30 の「ほとんどデザイン変わってないよ。。。」は、まさに
/// **数値だけ直して目で見ていなかった**ことが原因だった。
/// 検索窓は ⌥Space でしか開かず、外から自動で開くにはアクセシビリティの許可が要る。
/// それなら**アプリ自身に描かせて絵にする**のが確実で、許可も要らない。
///
/// ⚠️ すりガラス（NSVisualEffectView）は絵にすると素通しになるので、
/// ここでは「壁紙＋覆い」を自分で敷いて、実物に近い見え方を作る。
enum DesignPreview {

    static func parse(_ arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: "--render-preview"),
              index + 1 < arguments.count else { return nil }
        return arguments[index + 1]
    }

    /// `--mode clipboard` のように渡すと、その行き先に入った姿を描く
    static func parseMode(_ arguments: [String]) -> LauncherMode? {
        guard let index = arguments.firstIndex(of: "--mode"), index + 1 < arguments.count else { return nil }
        return LauncherMode(rawValue: arguments[index + 1])
    }

    static func run(outputPath: String, dark: Bool) -> Int32 {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        NSApp.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)

        let width = LauncherController.panelWidth
        let height: CGFloat = 536
        let canvas = FlippedCanvas(frame: NSRect(x: 0, y: 0, width: width, height: height))
        canvas.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        canvas.wantsLayer = true
        canvas.isDark = dark
        // 行き先に入った姿（窓が持ち色を帯びる）
        canvas.modeTint = parseMode(CommandLine.arguments).flatMap { ModeTint.tint(for: $0) }
        canvas.mode = parseMode(CommandLine.arguments) ?? .all

        var result: Int32 = 0
        canvas.effectiveAppearance.performAsCurrentDrawingAppearance {
            build(into: canvas, width: width, height: height)
            // ⚠️ アプリのアイコンは macOS が**あとから**読み込む。
            // 組み立てた直後に絵にすると、間に合わなかったものが空の四角で写る
            // （2026-08-04 棚のアイコンが3つ欠けた原因）。少しだけ待つ。
            RunLoop.current.run(until: Date().addingTimeInterval(0.6))
            guard let rep = canvas.bitmapImageRepForCachingDisplay(in: canvas.bounds) else {
                result = 1
                return
            }
            canvas.cacheDisplay(in: canvas.bounds, to: rep)
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

    /// 実物と同じ部品で、代表的な画面（入口＝行き先＋コマンド）を組む
    private static func build(into canvas: NSView, width: CGFloat, height: CGFloat) {
        // 行き先に入った姿（コピー履歴・定型文など）を描く
        if let mode = parseMode(CommandLine.arguments), mode != .all {
            buildMode(into: canvas, width: width, height: height, mode: mode)
            return
        }
        let searchRow = LauncherController.searchRowHeight
        let hintRow = LauncherController.hintRowHeight

        // 検索欄（虫眼鏡＋案内文。実物と同じ置き方）
        let glyph = NSImageView(frame: NSRect(x: Theme.Space.edge, y: 19, width: 22, height: 22))
        glyph.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 17, weight: .medium))
        glyph.contentTintColor = .tertiaryLabelColor
        canvas.addSubview(glyph)
        let field = NSTextField(labelWithString: "アプリ・コマンドを検索（ローマ字でも可）")
        field.font = .systemFont(ofSize: 20, weight: .regular)
        field.textColor = .tertiaryLabelColor
        field.frame = NSRect(x: Theme.Space.edge + 32, y: 15, width: width - Theme.Space.edge * 2 - 32, height: 30)
        canvas.addSubview(field)

        let hairline = HairlineView(frame: NSRect(x: 0, y: searchRow - 1, width: width, height: 1))
        canvas.addSubview(hairline)

        // 初めての人への帯（`--render-preview --welcome` のときだけ）。
        // ⚠️ 実物と同じ部品で描く。ここを別に作ると、絵で確かめる意味が無くなる
        if CommandLine.arguments.contains("--welcome") {
            let band = WelcomeBandView(frame: NSRect(x: 0, y: searchRow,
                                                     width: width, height: WelcomeBandView.height))
            band.configure(.key("⌘Space"))
            band.layoutSubtreeIfNeeded()
            canvas.addSubview(band)
            var y = searchRow + WelcomeBandView.height
            addHeader2(canvas, "行き先", &y, width)
            addEntries(canvas, &y, width, height: height, hintRow: hintRow)
            addHintBar(canvas, width: width, height: height, hintRow: hintRow)
            return
        }

        // よく使うアプリの棚（実物と同じ部品。ここではMacに必ずある2つで見た目を見る）
        let shelf = AppShelfView(frame: NSRect(x: 0, y: searchRow, width: width, height: AppShelfView.height))
        shelf.autoresizingMask = [.width]
        shelf.configure([
            AppBinding(path: "/System/Library/CoreServices/Finder.app", name: "Finder",
                       shortcut: Shortcut(keyCode: 3, carbonModifiers: 4096, keyLabel: "F")),
            AppBinding(path: "/System/Applications/Mail.app", name: "メール",
                       shortcut: Shortcut(keyCode: 46, carbonModifiers: 4096, keyLabel: "M")),
            AppBinding(path: "/System/Applications/Calendar.app", name: "カレンダー",
                       shortcut: Shortcut(keyCode: 8, carbonModifiers: 4096, keyLabel: "C")),
            AppBinding(path: "/System/Applications/Notes.app", name: "メモ",
                       shortcut: Shortcut(keyCode: 45, carbonModifiers: 4096, keyLabel: "N")),
        ])
        shelf.layoutSubtreeIfNeeded()
        canvas.addSubview(shelf)

        // 一覧
        // ⚠️ 実物は棚と一覧の間に余白を入れていない（scrollView が top まで詰めて置かれる）。
        // ここに +6 を書いていたせいで、下絵だけ1行分足りず「7行目が入らない」と誤診した
        // （2026-08-05）。下絵は実物と同じ計算をする。違えば下絵は嘘をつく
        var y = searchRow + AppShelfView.height
        func addHeader(_ title: String) {
            let header = HeaderRowView(frame: NSRect(x: 0, y: y, width: width, height: Theme.Row.header))
            header.title = title
            canvas.addSubview(header)
            y += Theme.Row.header
        }
        func addRow(_ item: LauncherItem, selected: Bool) {
            let rowHeight = Theme.Row.standard
            // ⚠️ 下の帯に重ねて描かない。実物は一覧が帯の上で切れて**スクロールする**ので、
            // 下絵で重ねて描くと「はみ出して壊れている」ようにも「全部見えている」ようにも誤読される。
            // ここで止めれば、下絵は「実際に何行見えるか」をそのまま映す
            guard y + rowHeight <= height - hintRow - 4 else { return }
            if selected {
                let background = LauncherRowBackground(frame: NSRect(x: 0, y: y, width: width, height: rowHeight))
                background.selectionHighlightStyle = .regular
                background.isSelected = true
                canvas.addSubview(background)
            }
            let row = LauncherRowView(frame: NSRect(x: 0, y: y, width: width, height: rowHeight))
            row.configure(item: item, matchedIndices: [])
            row.layoutSubtreeIfNeeded()
            canvas.addSubview(row)
            y += rowHeight
        }

        addHeader("行き先")
        let entries: [(LauncherMode, String, Int)] = [
            (.clipboard, "コピー履歴", 1), (.files, "ファイル検索", 2), (.snippets, "定型文", 3),
            (.links, "リンク", 4), (.windows, "ウィンドウ操作", 5),
        ]
        for (index, entry) in entries.enumerated() {
            addRow(LauncherItem(id: "e\(index)", title: entry.1, subtitle: "",
                                kindLabel: "⌘\(entry.2)", kind: .section(entry.0),
                                needsQuery: false, subtitleInRow: false), selected: index == 0)
        }
        addRow(LauncherItem(id: "note", title: "メモ", subtitle: "", kindLabel: "⌘6",
                            kind: .openNote, needsQuery: false, subtitleInRow: false), selected: false)
        addRow(LauncherItem(id: "capture", title: "画面の文字を読み取る", subtitle: "", kindLabel: "⌘7",
                            kind: .captureText, needsQuery: false, subtitleInRow: false), selected: false)

        guard y + Theme.Row.header + Theme.Row.standard <= height - hintRow - 4 else {
            addHintBar(canvas, width: width, height: height, hintRow: hintRow)
            return
        }
        addHeader("コマンド")
        let command = CustomCommand(title: "書類フォルダを開く",
                                    subtitle: "~/Documents",
                                    action: .openPath("~/Documents"))
        addRow(LauncherItem.from(command), selected: false)
        addHintBar(canvas, width: width, height: height, hintRow: hintRow)
    }

    /// 行き先に入った姿。⚠️ 札は出さない（窓の色がどこにいるかを語る）
    private static func buildMode(into canvas: NSView, width: CGFloat, height: CGFloat,
                                  mode: LauncherMode) {
        let searchRow = LauncherController.searchRowHeight
        let hintRow = LauncherController.hintRowHeight

        // 虫眼鏡はどの行き先でも同じ位置（打ち始める場所が動かない）
        let glyph = NSImageView(frame: NSRect(x: Theme.Space.edge, y: 19, width: 22, height: 22))
        glyph.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 17, weight: .medium))
        glyph.contentTintColor = .tertiaryLabelColor
        canvas.addSubview(glyph)
        let field = NSTextField(labelWithString: mode.placeholder)
        field.font = .systemFont(ofSize: 20, weight: .regular)
        field.textColor = .tertiaryLabelColor
        field.frame = NSRect(x: Theme.Space.edge + 32, y: 15,
                             width: width - Theme.Space.edge * 2 - 32, height: 30)
        canvas.addSubview(field)
        canvas.addSubview(HairlineView(frame: NSRect(x: 0, y: searchRow - 1, width: width, height: 1)))

        // それらしい中身を数行（見た目を見るためのもの）
        let samples: [(String, String)]
        switch mode {
        case .clipboard:
            samples = [("株式会社サンプル商事", "Safari・3分前"),
                       ("taro@example.com", "メール・12分前"),
                       ("2026-08-09 の作業ログ", "テモト・1時間前"),
                       ("https://github.com/example", "Safari・2時間前")]
        case .snippets:
            samples = [("メールの署名", "shomei"), ("請求書の締め文", "shimebun"),
                       ("会議の議事録テンプレート", "gijiroku"), ("振込先の口座", "furikomi")]
        default:
            samples = [("見本の1行目", ""), ("見本の2行目", ""), ("見本の3行目", "")]
        }
        var y = searchRow + 6
        for (index, sample) in samples.enumerated() {
            guard y + Theme.Row.standard <= height - hintRow - 4 else { break }
            if index == 0 {
                let background = LauncherRowBackground(
                    frame: NSRect(x: 0, y: y, width: width, height: Theme.Row.standard))
                background.selectionHighlightStyle = .regular
                background.isSelected = true
                canvas.addSubview(background)
            }
            let row = LauncherRowView(frame: NSRect(x: 0, y: y, width: width, height: Theme.Row.standard))
            let clip = ClipItem(text: sample.0, sourceAppName: nil, copiedAt: Date())
            row.configure(item: LauncherItem(id: "s\(index)", title: sample.0, subtitle: sample.1,
                                             kindLabel: "", kind: .clip(clip), needsQuery: false),
                          matchedIndices: [])
            row.layoutSubtreeIfNeeded()
            canvas.addSubview(row)
            y += Theme.Row.standard
        }
        addHintBar(canvas, width: width, height: height, hintRow: hintRow)
    }

    private static func addHeader2(_ canvas: NSView, _ title: String, _ y: inout CGFloat, _ width: CGFloat) {
        let header = HeaderRowView(frame: NSRect(x: 0, y: y, width: width, height: Theme.Row.header))
        header.title = title
        canvas.addSubview(header)
        y += Theme.Row.header
    }

    private static func addEntries(_ canvas: NSView, _ y: inout CGFloat, _ width: CGFloat,
                                   height: CGFloat, hintRow: CGFloat) {
        let entries: [(LauncherMode, String, Int)] = [
            (.clipboard, "コピー履歴", 1), (.files, "ファイル検索", 2), (.snippets, "定型文", 3),
            (.links, "リンク", 4), (.windows, "ウィンドウ操作", 5),
        ]
        for (index, entry) in entries.enumerated() {
            guard y + Theme.Row.standard <= height - hintRow - 4 else { return }
            if index == 0 {
                let background = LauncherRowBackground(
                    frame: NSRect(x: 0, y: y, width: width, height: Theme.Row.standard))
                background.selectionHighlightStyle = .regular
                background.isSelected = true
                canvas.addSubview(background)
            }
            let row = LauncherRowView(frame: NSRect(x: 0, y: y, width: width, height: Theme.Row.standard))
            row.configure(item: LauncherItem(id: "e\(index)", title: entry.1, subtitle: "",
                                             kindLabel: "⌘\(entry.2)", kind: .section(entry.0),
                                             needsQuery: false, subtitleInRow: false),
                          matchedIndices: [])
            row.layoutSubtreeIfNeeded()
            canvas.addSubview(row)
            y += Theme.Row.standard
        }
    }

    private static func addHintBar(_ canvas: NSView, width: CGFloat, height: CGFloat, hintRow: CGFloat) {
        // 下の帯
        let hint = HintBarView(frame: NSRect(x: 0, y: height - hintRow, width: width, height: hintRow))
        // ⚠️ **描いている行き先の案内**を出す。
        // ここを `.all` に決め打ちしていたせいで、`--mode files` で撮っても
        // 入口の案内が写り、案内バーを絵で確かめられなかった
        // （2026-08-30、ファイル検索に「ドラッグ 運ぶ」を足したのに絵に出なくて気づいた。
        //  すぐ下に「下絵と実物がずれると絵で確かめる意味が無くなる」と自分で書いてあった）。
        let mode = parseMode(CommandLine.arguments) ?? .all
        var actions = mode.actions
        // 棚を出している絵なので、入口のときだけ実物と同じく「←→ アプリ」も入れる
        if mode == .all, let spot = actions.firstIndex(where: { $0.keys == "↑↓" }) {
            actions.insert(HintAction("←→", "アプリ"), at: actions.index(after: spot))
        }
        hint.setActions(actions)
        hint.status = mode.summary
        hint.layoutSubtreeIfNeeded()
        canvas.addSubview(hint)
        let hintLine = HairlineView(frame: NSRect(x: 0, y: height - hintRow, width: width, height: 1))
        canvas.addSubview(hintLine)
    }
}

/// 左上を原点にして描く土台。すりガラスの代わりに「壁紙＋覆い」を自分で敷く
private final class FlippedCanvas: NSView {
    var isDark = true
    var modeTint: ModeTint?
    var mode: LauncherMode = .all
    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds,
                                xRadius: Theme.Radius.window, yRadius: Theme.Radius.window)
        path.addClip()
        // 壁紙のつもりの下地（実機は写真の上に出るので、明暗のある地で確かめる）
        let backdrop = NSGradient(colors: isDark
            ? [NSColor(calibratedRed: 0.10, green: 0.13, blue: 0.20, alpha: 1),
               NSColor(calibratedRed: 0.28, green: 0.24, blue: 0.30, alpha: 1)]
            : [NSColor(calibratedRed: 0.86, green: 0.89, blue: 0.94, alpha: 1),
               NSColor(calibratedRed: 0.98, green: 0.96, blue: 0.92, alpha: 1)])
        backdrop?.draw(in: bounds, angle: -60)
        // 覆い（Contrast.Backdrop の値と同じもの）
        Theme.Palette.backdropVeil.setFill()
        path.fill()
        // 行き先の持ち色をごく薄く（実物の BackdropView.modeTint と同じ濃さ）
        if let modeTint {
            NSColor(calibratedRed: modeTint.red, green: modeTint.green, blue: modeTint.blue,
                    alpha: isDark ? 0.16 : 0.10).setFill()
            path.fill()
        }
        Theme.Palette.windowEdge.setStroke()
        path.lineWidth = 1
        path.stroke()
    }
}
