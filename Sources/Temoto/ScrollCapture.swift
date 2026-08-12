import AppKit
import TemotoCore

/// スクロールしながら何枚も撮って、1枚の長い絵にする。
///
/// 2026-08-06 作者「画面スクロールでページ全体など。」
///
/// ⚠️ **繋ぐ計算はここに書かない**（TemotoCore.ScrollStitcher が持つ）。
/// ここがやるのは「撮る・スクロールを送る・絵と行の見た目を行き来する」だけ。
/// 一番間違えやすい計算を AppKit の外に置いてあるから、作り物のページで機械が確かめられる。
///
/// ⚠️ 撮る相手は**テモトを開く直前に前面だった窓**。
/// 撮る範囲を人に選ばせる作りにすると、選んでいる間にページが動く・
/// 選び終わってから改めて相手を前に出す、という段取りが増えて事故が増える。
enum ScrollCapture {

    /// 1回で撮る上限。
    /// ⚠️ 上限が無いと、終わりを見つけられなかったページで永遠に撮り続ける。
    /// 30枚あれば、窓の高さの十数倍＝たいていのページは端まで届く。
    static let maxFrames = 30

    /// 撮ってから次にスクロールするまでの待ち。
    /// ⚠️ 短すぎると、動いている途中の絵（文字がぶれた絵）を撮る。
    /// macOS のスクロールは慣性で流れるので、止まるのを待つ必要がある。
    static let settle: TimeInterval = 0.42

    /// 1回に送るスクロール量を、窓の高さの何割にするか。
    /// ⚠️ 1.0（＝画面ぴったり）にしない。重なりが無くなると繋ぎ目が合わせられない。
    /// 7割にして、必ず3割は前の絵と重なるようにする。
    static let scrollRatio: CGFloat = 0.7

    /// 前面の窓を、スクロールしながら撮って1枚にする。
    /// - Parameter target: 撮る相手（テモトを開く前に前面だったアプリ）
    static func run(target: NSRunningApplication?) {
        guard AXWindow.isTrusted(prompt: false) else {
            Toast.show("ページ全体を撮るには「アクセシビリティ」の許可が要ります"
                       + "（スクロールを送るため）。メニューの「アクセシビリティを許可」から入れてください",
                       isError: true)
            return
        }
        guard let frame = AXWindow.frontmostWindowFrame(of: target), frame.height > 100 else {
            Toast.show("撮る窓が見つかりませんでした。撮りたい窓を前に出してから、もう一度実行してください",
                       isError: true)
            return
        }

        // 相手を前に出す（テモトを閉じただけでは、前面が別のアプリのことがある）
        target?.activate()

        Toast.show("ページ全体を撮ります。終わるまで触らないでください…")
        DispatchQueue.global(qos: .userInitiated).async {
            let shots = collect(rect: frame)
            DispatchQueue.main.async { finish(shots: shots, rect: frame) }
        }
    }

    // MARK: - 撮る

    /// 撮った1枚（絵と、その行ごとの見た目）
    private struct Frame {
        let image: CGImage
        let rows: [ScrollStitcher.RowSignature]
    }

    private static func collect(rect: CGRect) -> [Frame] {
        var frames: [Frame] = []
        // ⚠️ マウスの位置を窓の真ん中へ動かしてからスクロールを送る。
        // スクロールは「いまカーソルの下にあるもの」へ届くので、動かさないと別の窓が動く。
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let originalMouse = CGEvent(source: nil)?.location
        defer {
            if let originalMouse { CGWarpMouseCursorPosition(originalMouse) }
        }

        for index in 0..<maxFrames {
            guard let image = shoot(rect: rect) else { break }
            frames.append(Frame(image: image, rows: signatures(of: image)))

            // 最後の1枚を撮ったあとはスクロールしない
            guard index < maxFrames - 1 else { break }

            // 2枚目以降は、進んでいなければそこで終わり（下に着いた）
            if frames.count >= 2 {
                let previous = frames[frames.count - 2].rows
                let current = frames[frames.count - 1].rows
                let height = current.count
                let moved = ScrollStitcher.offset(previous: previous, current: current,
                                                  contentTop: 0, contentBottom: height,
                                                  minOverlap: max(1, height / 4))
                if moved == 0 { break }
            }

            CGWarpMouseCursorPosition(center)
            scroll(by: Int32(-rect.height * scrollRatio))
            Thread.sleep(forTimeInterval: settle)
        }
        return frames
    }

    /// 決めた範囲を1枚撮る。
    /// ⚠️ `screencapture` を毎回起こす。速くはないが、画面の取り込みに関する面倒
    /// （複数画面・拡大表示・色空間）を全部 macOS に任せられる。
    private static func shoot(rect: CGRect) -> CGImage? {
        let path = NSTemporaryDirectory() + "temoto-scroll-\(UUID().uuidString).png"
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        // -x: 音を鳴らさない（何十枚も撮るので、鳴らすと騒がしいだけ）
        // -R: 範囲を数値で指定　-o: 影を付けない
        task.arguments = ["-x", "-o", "-R",
                          "\(Int(rect.origin.x)),\(Int(rect.origin.y)),\(Int(rect.width)),\(Int(rect.height))",
                          path]
        do { try task.run() } catch { return nil }
        task.waitUntilExit()
        defer { try? FileManager.default.removeItem(atPath: path) }
        guard let data = FileManager.default.contents(atPath: path),
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        return image
    }

    /// スクロールを送る（画素の単位で）
    private static func scroll(by pixels: Int32) {
        guard let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel,
                                  wheelCount: 1, wheel1: pixels, wheel2: 0, wheel3: 0) else { return }
        event.post(tap: .cghidEventTap)
    }

    // MARK: - 絵と「行の見た目」の行き来

    /// 横幅を16等分して、1行ずつ明るさをまとめる。
    ///
    /// ⚠️ 灰色に落としてから測る。色のまま比べると、同じ場所でも表示の色味の揺れで差が出る。
    private static func signatures(of image: CGImage, buckets: Int = 16) -> [ScrollStitcher.RowSignature] {
        let width = image.width, height = image.height
        guard width > 0, height > 0 else { return [] }
        var pixels = [UInt8](repeating: 0, count: width * height)
        guard let space = CGColorSpace(name: CGColorSpace.linearGray),
              let context = CGContext(data: &pixels, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: width,
                                      space: space, bitmapInfo: CGImageAlphaInfo.none.rawValue) else {
            return []
        }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        var out: [ScrollStitcher.RowSignature] = []
        out.reserveCapacity(height)
        let bucketWidth = max(1, width / buckets)
        for y in 0..<height {
            var signature = ScrollStitcher.RowSignature(repeating: 0, count: buckets)
            for bucket in 0..<buckets {
                let start = bucket * bucketWidth
                let end = min(width, start + bucketWidth)
                guard start < end else { continue }
                var total = 0
                for x in start..<end { total += Int(pixels[y * width + x]) }
                signature[bucket] = UInt8(total / (end - start))
            }
            out.append(signature)
        }
        return out
    }

    // MARK: - 繋いで渡す

    private static func finish(shots: [Frame], rect: CGRect) {
        guard let first = shots.first else {
            Toast.show("撮れませんでした。システム設定 → プライバシーとセキュリティ → 画面収録 で"
                       + "テモトを許可し、テモトを起動しなおしてください",
                       isError: true, area: "ページ全体を撮る")
            return
        }
        let plan = ScrollStitcher.plan(frames: shots.map(\.rows))
        guard plan.totalHeight > 0 else {
            Toast.show("繋げませんでした（動きが読み取れませんでした）", isError: true, area: "ページ全体を撮る")
            return
        }

        // ⚠️ **1画面分しか取れていないのに「ページ全体」と言わない。**
        // スクロールが届かない窓（スクロールできない・別の窓が前に出た・
        // 送ったスクロールを受け取らない作りのページ）でも、撮ること自体は成功するので、
        // 素朴に作ると「1画面の絵」を「ページ全体」として渡してしまう。
        // 撮れた高さが1画面と変わらないなら、それは失敗として伝える。
        if plan.totalHeight <= first.image.height + 4 {
            Toast.show("この窓はスクロールしませんでした。"
                       + "スクロールできる窓を前に出してから、もう一度お試しください"
                       + "（許可が要るときは システム設定 → プライバシーとセキュリティ → アクセシビリティ）",
                       isError: true, area: "ページ全体を撮る")
            return
        }

        let width = first.image.width
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let canvas = CGContext(data: nil, width: width, height: plan.totalHeight,
                                     bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                     bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
            Toast.show("繋げませんでした（絵を用意できませんでした）", isError: true)
            return
        }

        // ⚠️ CGContext は下が原点。上から順に貼るので、下から積む向きに直す
        var y = plan.totalHeight
        for piece in plan.pieces {
            guard piece.frame < shots.count else { continue }
            let source = shots[piece.frame].image
            guard let cut = source.cropping(to: CGRect(x: 0, y: piece.from,
                                                       width: width, height: piece.height)) else { continue }
            y -= piece.height
            canvas.draw(cut, in: CGRect(x: 0, y: y, width: width, height: piece.height))
        }

        guard let stitched = canvas.makeImage() else {
            Toast.show("繋げませんでした", isError: true)
            return
        }

        let rep = NSBitmapImageRep(cgImage: stitched)
        guard let png = rep.representation(using: .png, properties: [:]) else {
            Toast.show("絵にできませんでした", isError: true)
            return
        }
        let board = NSPasteboard.general
        board.clearContents()
        board.setData(png, forType: .png)

        // 画面上の高さ（点）に直して伝える。画素のままだと Retina で倍の数字になって驚かせる
        let scale = CGFloat(first.image.height) / rect.height
        let points = Int(CGFloat(plan.totalHeight) / max(scale, 1))
        let screens = String(format: "%.1f", CGFloat(points) / rect.height)
        if plan.reachedBottom {
            Toast.show("ページ全体を撮りました（画面 \(screens) 枚ぶん・\(shots.count)回撮影）。⌘V で貼れます")
        } else {
            // ⚠️ 最後まで行けたかどうかを必ず伝える。
            // 途中で切れた絵を「全体」と思って使われるのが一番困る
            Toast.show("途中まで撮りました（画面 \(screens) 枚ぶん）。"
                       + "最後まで届いていない可能性があります", isError: true)
        }
    }
}
