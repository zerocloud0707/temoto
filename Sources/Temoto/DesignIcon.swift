import AppKit

/// アプリアイコンを描いて書き出す（`--render-icon <出力先フォルダ>`）。
///
/// 意匠: 深いガラスの奥からほのかな光。その上に**太い丸筆で描いた「テ」**が1つ。
///
/// ⚠️ v2（札の中に打った文字）は「箱の中の箱」で、作者に「ダサい」と言われた。
/// アイコンは窓の縮小コピーではなく**印**。要素は地と印の2つまで、
/// 文字はフォントに頼らず自分の線で描く（打った字は名刺、描いた印はロゴ）。
///
/// ⚠️ コードで描く理由。
/// 画像ファイルで持つと、丸みや濃さを変えるたびに描き直しの手作業になる。
/// コードなら Theme と同じ調子で直せて、生成し直すだけで済む。
enum DesignIcon {

    static func parse(_ arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: "--render-icon"),
              index + 1 < arguments.count else { return nil }
        return arguments[index + 1]
    }

    /// アイコンの一辺（Appleの原稿サイズ）と、角丸つき本体の枠。
    /// 本体は1024の中の824＝標準テンプレートの余白（影のための空き）に合わせる。
    private static let canvas: CGFloat = 1024
    private static let plate = NSRect(x: 100, y: 100, width: 824, height: 824)
    private static let plateRadius: CGFloat = 186

    static func run(outputDirectory: String) -> Int32 {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)

        let directory = URL(fileURLWithPath: outputDirectory, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            FileHandle.standardError.write(Data("フォルダを作れません: \(error)\n".utf8))
            return 1
        }

        guard let master = render() else {
            FileHandle.standardError.write(Data("描けませんでした\n".utf8))
            return 1
        }

        // iconutil が読む一式（.iconset）と、確認用の1枚を書く
        let sizes: [(name: String, edge: Int)] = [
            ("icon_16x16", 16), ("icon_16x16@2x", 32),
            ("icon_32x32", 32), ("icon_32x32@2x", 64),
            ("icon_128x128", 128), ("icon_128x128@2x", 256),
            ("icon_256x256", 256), ("icon_256x256@2x", 512),
            ("icon_512x512", 512), ("icon_512x512@2x", 1024),
        ]
        for size in sizes {
            guard write(master, edge: size.edge, to: directory.appendingPathComponent("\(size.name).png")) else {
                return 1
            }
        }
        guard write(master, edge: 1024, to: directory.appendingPathComponent("preview-1024.png")),
              write(master, edge: 128, to: directory.appendingPathComponent("preview-128.png")) else {
            return 1
        }
        return 0
    }

    /// 1024の原稿を描く
    private static func render() -> NSImage? {
        let image = NSImage(size: NSSize(width: canvas, height: canvas))
        image.lockFocus()
        defer { image.unlockFocus() }
        guard let context = NSGraphicsContext.current else { return nil }
        context.imageInterpolation = .high

        let path = NSBezierPath(roundedRect: plate, xRadius: plateRadius, yRadius: plateRadius)

        // 落ち影（Appleのテンプレートと同じく、下へ少し落とす）
        context.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.30)
        shadow.shadowBlurRadius = 22
        shadow.shadowOffset = NSSize(width: 0, height: -12)
        shadow.set()
        NSColor.black.setFill()
        path.fill()
        context.restoreGraphicsState()

        // 地＝深いガラス。上からわずかに光が入り、下へ沈む（3段の勾配）
        NSGradient(colorsAndLocations:
            (NSColor(calibratedRed: 0.20, green: 0.22, blue: 0.34, alpha: 1), 0.0),
            (NSColor(calibratedRed: 0.11, green: 0.12, blue: 0.21, alpha: 1), 0.55),
            (NSColor(calibratedRed: 0.05, green: 0.05, blue: 0.11, alpha: 1), 1.0)
        )?.draw(in: path, angle: -90)

        // ここから中身は窓の形で切り抜いて描く
        context.saveGraphicsState()
        path.addClip()

        // 上端の光の筋（窓と同じ意匠。アイコンの縮尺に合わせて太く）
        NSColor.white.withAlphaComponent(0.22).setFill()
        NSRect(x: plate.minX + 120, y: plate.maxY - 8, width: plate.width - 240, height: 5).fill()

        // 印の後ろに、ほのかな光の玉（ガラスの奥に灯りがある感じ。印へ目を寄せる）
        if let glow = NSGradient(colors: [
            NSColor.white.withAlphaComponent(0.16),
            NSColor.white.withAlphaComponent(0.0),
        ]) {
            let center = NSPoint(x: 518, y: 514)
            glow.draw(fromCenter: center, radius: 0, toCenter: center, radius: 400, options: [])
        }

        // 「テ」を自分の線で描く。太い丸筆・白。
        // 3画: 上の短い横 → 長い横 → 中央から左下へ流れる縦
        let stroke: CGFloat = 88
        NSColor.white.withAlphaComponent(0.97).setStroke()

        let topBar = NSBezierPath()
        topBar.lineWidth = stroke
        topBar.lineCapStyle = .round
        topBar.move(to: NSPoint(x: 388, y: 702))
        topBar.line(to: NSPoint(x: 648, y: 702))
        topBar.stroke()

        let middleBar = NSBezierPath()
        middleBar.lineWidth = stroke
        middleBar.lineCapStyle = .round
        middleBar.move(to: NSPoint(x: 294, y: 556))
        middleBar.line(to: NSPoint(x: 742, y: 556))
        middleBar.stroke()

        // 縦画は長い横の中央から。まっすぐ落ちてから、すそが左へ流れる
        let leg = NSBezierPath()
        leg.lineWidth = stroke
        leg.lineCapStyle = .round
        leg.move(to: NSPoint(x: 542, y: 556))
        leg.curve(to: NSPoint(x: 426, y: 222),
                  controlPoint1: NSPoint(x: 536, y: 434),
                  controlPoint2: NSPoint(x: 474, y: 302))
        leg.stroke()

        context.restoreGraphicsState()
        return image
    }

    /// 指定の一辺に縮めてPNGで書く
    private static func write(_ image: NSImage, edge: Int, to url: URL) -> Bool {
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: edge, pixelsHigh: edge,
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                         isPlanar: false, colorSpaceName: .calibratedRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0) else { return false }
        NSGraphicsContext.saveGraphicsState()
        guard let context = NSGraphicsContext(bitmapImageRep: rep) else { return false }
        NSGraphicsContext.current = context
        context.imageInterpolation = .high
        image.draw(in: NSRect(x: 0, y: 0, width: edge, height: edge),
                   from: NSRect(origin: .zero, size: image.size),
                   operation: .copy, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        guard let data = rep.representation(using: .png, properties: [:]) else { return false }
        do {
            try data.write(to: url)
            return true
        } catch {
            FileHandle.standardError.write(Data("書けません: \(error)\n".utf8))
            return false
        }
    }
}
