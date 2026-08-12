import AppKit

/// ペーストボードの絵を、保存できる形に整える係。
///
/// 置かれている形式は相手まかせ（PNG だったり TIFF だったり）なので、
/// 保存も表示も PNG に揃える。TIFF のまま持つと同じ絵で数倍の容量になる。
enum ClipImageMaker {

    /// 一覧の行に出す小さな絵の長辺（px）。
    ///
    /// ⚠️ 2026-07-30 に 96 から上げた。作者の「どんな画像かわかりにくい」の一因がこれ。
    /// 絵の行は高さ80・絵の枠62ptで出す。Retina は1ptが2pxなので、必要なのは124px。
    /// 96pxだと足りず、ただでさえ小さい絵がさらにぼやけていた。
    /// 256にしておくと外付けディスプレイやこの先の拡大にも耐える（1枚10〜20KB程度）。
    static let thumbnailEdge: CGFloat = 256

    /// 取り出した結果。絵そのもの（png）はここから先、暗号化して1件1ファイルで置く。
    struct Made {
        var png: Data
        var pixelWidth: Int
        var pixelHeight: Int
        var thumbnailPNG: Data
    }

    /// ペーストボードから絵を取り出す。絵が無ければ nil。
    static func make(from pasteboard: NSPasteboard) -> Made? {
        guard let rep = bitmap(from: pasteboard),
              let png = rep.representation(using: .png, properties: [:]) else { return nil }
        let width = rep.pixelsWide
        let height = rep.pixelsHigh
        guard width > 0, height > 0, !png.isEmpty else { return nil }
        // 小さい絵が作れなかったときは元の絵で代用する（表示が重くなるだけで、壊れはしない）
        let thumb = thumbnail(from: rep) ?? png
        return Made(png: png, pixelWidth: width, pixelHeight: height, thumbnailPNG: thumb)
    }

    /// 保存済みの PNG から小さな絵を作り直す（古い履歴に thumb が無いとき用）
    static func thumbnail(fromPNG data: Data) -> Data? {
        guard let rep = NSBitmapImageRep(data: data) else { return nil }
        return thumbnail(from: rep)
    }

    private static func bitmap(from pasteboard: NSPasteboard) -> NSBitmapImageRep? {
        // PNG が置いてあればそれが一番素直（スクリーンショットやブラウザの「画像をコピー」）
        if let data = pasteboard.data(forType: .png), let rep = NSBitmapImageRep(data: data) {
            return rep
        }
        // プレビューや古いアプリは TIFF で置く
        if let data = pasteboard.data(forType: .tiff), let rep = NSBitmapImageRep(data: data) {
            return rep
        }
        return nil
    }

    private static func thumbnail(from rep: NSBitmapImageRep) -> Data? {
        let w = CGFloat(rep.pixelsWide)
        let h = CGFloat(rep.pixelsHigh)
        guard w > 0, h > 0 else { return nil }

        let scale = min(1, thumbnailEdge / max(w, h))
        let tw = max(1, Int((w * scale).rounded()))
        let th = max(1, Int((h * scale).rounded()))

        guard let small = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: tw, pixelsHigh: th,
            bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0
        ) else { return nil }
        small.size = NSSize(width: tw, height: th)

        guard let context = NSGraphicsContext(bitmapImageRep: small) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.imageInterpolation = .high
        rep.draw(in: NSRect(x: 0, y: 0, width: tw, height: th))
        NSGraphicsContext.restoreGraphicsState()

        return small.representation(using: .png, properties: [:])
    }
}
