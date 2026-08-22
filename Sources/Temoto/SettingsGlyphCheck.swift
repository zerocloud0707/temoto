import AppKit
import TemotoCore

/// 横メニューの記号の「見かけの大きさ」が揃っているかを測る（`--check-settings-glyphs`）。
///
/// ⚠️ なぜ要るか。
/// SF Symbols は文字と同じで、同じ pointSize でも絵によって墨の量と広がりが違う。
/// 実測では、1つの pointSize 12 で描くと墨の長辺が 10.6〜15.0pt（1.36倍）ばらつき、
/// 横に長い keyboard は大きく、細い command は小さく見えた。
/// 目で見て気づけるほどではないが、7つ並ぶと「揃っていない」という感じだけが残る。
/// `SettingsPane.glyphPointSize` で絵ごとに直したので、それが崩れないよう機械に測らせる。
///
/// ⚠️ 閾値を跨いだときの正しい対応は**閾値を緩めることではなく**、
/// `SettingsPane.glyphPointSize` を測り直すこと。
enum SettingsGlyphCheck {

    /// 墨を測るときの拡大率（8倍で描いて数える）
    private static let scale: CGFloat = 8

    static func run() -> Int32 {
        NSApplication.shared.setActivationPolicy(.prohibited)

        var longest: [(pane: SettingsPane, value: CGFloat)] = []
        var areas: [(pane: SettingsPane, value: CGFloat)] = []
        var failures: [String] = []

        for pane in SettingsPane.allCases {
            // ⚠️ 面積は `.preferringHierarchical()` を**外した単色**で測る。
            // 階層で描くと副層が半透明になり、薄い画素まで墨として数えてしまう
            // （階層込みだと採用値でも 1.767 になり、揃っているのに落ちる）
            guard let ink = measure(pane) else {
                failures.append("「\(pane.title)」の記号 \(pane.symbolName) を描けません")
                continue
            }
            longest.append((pane, max(ink.width, ink.height)))
            areas.append((pane, ink.area))
        }

        guard let longMax = longest.max(by: { $0.value < $1.value }),
              let longMin = longest.min(by: { $0.value < $1.value }),
              let areaMax = areas.max(by: { $0.value < $1.value }),
              let areaMin = areas.min(by: { $0.value < $1.value }),
              longMin.value > 0, areaMin.value > 0 else {
            print("  🔴 記号を1つも測れませんでした")
            return 1
        }

        let longRatio = longMax.value / longMin.value
        let areaRatio = areaMax.value / areaMin.value

        if longRatio > 1.30 {
            failures.append("記号の大きさが揃っていない（\(fmt(longRatio))倍・"
                + "大 \(longMax.pane.title) \(fmt(longMax.value))pt／小 \(longMin.pane.title) \(fmt(longMin.value))pt）")
        }
        if areaRatio > 1.45 {
            failures.append("記号の墨の量が揃っていない（\(fmt(areaRatio))倍・"
                + "多 \(areaMax.pane.title)／少 \(areaMin.pane.title)）")
        }
        // タイルの辺に触れると窮屈に見える
        let limit = SettingsSidebar.tileSize - 6
        if longMax.value > limit {
            failures.append("記号がタイルの辺に近すぎる（\(fmt(longMax.value))pt ＞ \(fmt(limit))pt・\(longMax.pane.title)）")
        }

        if failures.isEmpty {
            print("記号の見かけ: 大きさ \(fmt(longRatio))倍（≦1.30）／墨の量 \(fmt(areaRatio))倍（≦1.45）"
                + "／最大 \(fmt(longMax.value))pt（≦\(fmt(limit))pt）")
            return 0
        }
        for f in failures { print("  🔴 \(f)") }
        print("⚠️ 直すのは閾値ではなく SettingsPane.glyphPointSize のほう")
        return 1
    }

    private static func fmt(_ value: CGFloat) -> String { String(format: "%.3f", value) }

    /// 記号を大きく描いて、墨の広がりと量を測る
    private static func measure(_ pane: SettingsPane) -> (width: CGFloat, height: CGFloat, area: CGFloat)? {
        let config = NSImage.SymbolConfiguration(pointSize: pane.glyphPointSize * scale, weight: .medium)
        guard let image = NSImage(systemSymbolName: pane.symbolName, accessibilityDescription: nil)?
            .withSymbolConfiguration(config) else { return nil }

        let size = image.size
        guard size.width > 0, size.height > 0 else { return nil }
        let w = Int(size.width.rounded(.up)), h = Int(size.height.rounded(.up))
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(x: 0, y: 0, width: size.width, height: size.height))
        NSGraphicsContext.restoreGraphicsState()

        var minX = w, minY = h, maxX = -1, maxY = -1
        var ink = 0
        for y in 0..<h {
            for x in 0..<w {
                guard let color = rep.colorAt(x: x, y: y) else { continue }
                // ⚠️ ごく薄い縁（アンチエイリアス）は数えない。数えると絵の輪郭の長さで結果が動く
                guard color.alphaComponent > 0.02 else { continue }
                ink += 1
                if x < minX { minX = x }
                if x > maxX { maxX = x }
                if y < minY { minY = y }
                if y > maxY { maxY = y }
            }
        }
        guard maxX >= minX, maxY >= minY else { return nil }
        return (CGFloat(maxX - minX + 1) / scale,
                CGFloat(maxY - minY + 1) / scale,
                CGFloat(ink) / (scale * scale))
    }
}
