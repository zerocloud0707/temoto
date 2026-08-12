import AppKit
import TemotoCore

/// 検索窓の右半分。選んでいる1件の中身を大きく出す。
///
/// ⚠️ この画面が存在する理由（2026-07-30 作者「画像の表示がやっぱりわかりにくい」）。
/// 一覧の行に62ptの絵を置いても、画面写真の中身は読めなかった。
/// Raycastのコピー履歴と同じく、**見分ける仕事はこの右半分が引き受ける**。
/// 一覧の行は小さく戻して、1画面に入る件数を優先する。
///
/// 出す中身（文字の全文・絵・ファイル名・情報欄の行）は TemotoCore.ItemPreview が決める。
/// ここは決まったものを置くだけ（決め方はあちらで検証済み）。
final class PreviewPaneView: NSView {

    // 中身（どれか1つだけ出す）
    private let imageView = NSImageView()
    private let textScroll = NSScrollView()
    private let textView = NSTextView()

    // 下の情報欄
    private let infoDivider = HairlineView(frame: .zero)
    /// 情報欄は件ごとに行数が違うので、その都度作り直す
    private var infoLabels: [(info: ItemPreview.Info, label: NSTextField, value: NSTextField)] = []

    /// 絵の元の大きさ（点）。枠にぴったり合わせて縁を描くために要る。
    /// ⚠️ 一覧の行と同じ理屈。正方形の枠のまま縁を描くと「絵より大きい額縁」になる
    private var imageSize: NSSize = .zero

    private let pad: CGFloat = 14

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        // 絵は角を丸めて細い縁。白いスクリーンショットがすりガラスに溶けないように
        imageView.wantsLayer = true
        imageView.layer?.cornerRadius = Theme.Radius.row
        imageView.layer?.masksToBounds = true
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.isHidden = true

        // 文字は読むだけ。
        // ⚠️ isSelectable も切る。選べるようにすると最初のクリックで焦点を奪い、
        // 検索欄に打っていた続きが打てなくなる（この窓の主役はあくまで検索欄）。
        textView.isEditable = false
        textView.isSelectable = false
        textView.drawsBackground = false
        textView.font = .systemFont(ofSize: 12.5)
        textView.textColor = .labelColor
        textView.textContainerInset = NSSize(width: 0, height: 2)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                                  height: CGFloat.greatestFiniteMagnitude)

        textScroll.documentView = textView
        textScroll.hasVerticalScroller = true
        textScroll.autohidesScrollers = true
        textScroll.drawsBackground = false
        textScroll.isHidden = true

        infoDivider.isHidden = true

        addSubview(imageView)
        addSubview(textScroll)
        addSubview(infoDivider)
    }

    required init?(coder: NSCoder) { fatalError("使わない") }

    // MARK: - 出す・消す

    /// 1件ぶんを出す。絵のときだけ image を渡す（読めなかったときは nil でよい）。
    func show(_ spec: ItemPreview.Spec, image: NSImage?) {
        rebuildInfo(spec.info)

        switch spec.content {
        case .text(let body):
            showText(body)
        case .fileNames(let names):
            showText(names.joined(separator: "\n"))
        case .image:
            if let image {
                textScroll.isHidden = true
                imageView.isHidden = false
                imageView.image = image
                imageSize = image.size
            } else {
                // 鍵を作り直した後など。黙って空白にすると「壊れた」に見える
                showText("（この画像は開けませんでした。鍵が変わった可能性があります）")
            }
        }
        needsLayout = true
    }

    /// 何も選んでいないとき
    func clear() {
        imageView.image = nil
        imageView.isHidden = true
        textScroll.isHidden = true
        rebuildInfo([])
    }

    private func showText(_ body: String) {
        imageView.isHidden = true
        imageView.image = nil
        textScroll.isHidden = false
        textView.string = body
        // 前の項目を途中まで読んでいても、次の項目は必ず頭から
        textView.scroll(.zero)
    }

    // MARK: - 情報欄

    private func rebuildInfo(_ rows: [ItemPreview.Info]) {
        for entry in infoLabels {
            entry.label.removeFromSuperview()
            entry.value.removeFromSuperview()
        }
        infoLabels = rows.map { info in
            let label = NSTextField(labelWithString: info.label)
            label.font = .systemFont(ofSize: 11, weight: .medium)
            label.textColor = info.isWarning ? .systemOrange : Theme.Palette.captionText
            label.lineBreakMode = .byTruncatingTail

            let value = NSTextField(labelWithString: info.value)
            value.font = .systemFont(ofSize: 11.5)
            value.textColor = .labelColor
            // 場所（~/Documents/…）は末尾より真ん中を省いた方が、どこの何かが残る
            value.lineBreakMode = info.label == "場所" ? .byTruncatingMiddle : .byTruncatingTail
            if info.isWarning {
                // 警告だけは折り返して全文出す。切れた警告は警告にならない
                value.lineBreakMode = .byWordWrapping
                value.cell?.wraps = true
                value.maximumNumberOfLines = 3
            }
            addSubview(label)
            addSubview(value)
            return (info, label, value)
        }
        infoDivider.isHidden = infoLabels.isEmpty
    }

    /// 情報欄の1行の高さ（警告は折り返すので行ごとに違う）
    private func rowHeight(_ entry: (info: ItemPreview.Info, label: NSTextField, value: NSTextField),
                           valueWidth: CGFloat) -> CGFloat {
        guard entry.info.isWarning else { return 18 }
        let size = entry.value.cell?.cellSize(forBounds:
            NSRect(x: 0, y: 0, width: valueWidth, height: 1000)) ?? .zero
        return max(18, size.height.rounded(.up))
    }

    // MARK: - 置き場所の計算

    override func layout() {
        super.layout()
        let width = bounds.width
        let labelWidth: CGFloat = 68
        let valueX = pad + labelWidth + 8
        let valueWidth = max(width - valueX - pad, 40)

        // 情報欄は下から積む
        var infoHeight: CGFloat = 0
        let gap: CGFloat = 4
        for entry in infoLabels {
            infoHeight += rowHeight(entry, valueWidth: valueWidth) + gap
        }
        if !infoLabels.isEmpty { infoHeight += 8 }  // 仕切り線との間

        var y = pad + infoHeight
        if !infoLabels.isEmpty {
            infoDivider.frame = NSRect(x: pad, y: y, width: width - pad * 2, height: 1)
            var cursor = y - 8
            for entry in infoLabels {
                let height = rowHeight(entry, valueWidth: valueWidth)
                cursor -= height
                entry.label.frame = NSRect(x: pad, y: cursor + height - 15, width: labelWidth, height: 15)
                entry.value.frame = NSRect(x: valueX, y: cursor, width: valueWidth, height: height)
                cursor -= gap
            }
            y += 1
        }

        // 残りが中身の置き場
        let contentRect = NSRect(x: pad, y: y + 10,
                                 width: width - pad * 2,
                                 height: max(bounds.height - pad - (y + 10), 40))
        textScroll.frame = contentRect

        // 絵は縦横比のまま、枠に収まる大きさへ。
        // ⚠️ 拡大はしない。小さな絵を枠いっぱいに伸ばすと、ぼやけて別物に見える
        if imageSize.width > 0, imageSize.height > 0 {
            let scale = min(1, min(contentRect.width / imageSize.width,
                                   contentRect.height / imageSize.height))
            let drawWidth = (imageSize.width * scale).rounded()
            let drawHeight = (imageSize.height * scale).rounded()
            imageView.frame = NSRect(
                x: contentRect.midX - drawWidth / 2,
                y: contentRect.midY - drawHeight / 2,
                width: drawWidth, height: drawHeight)
        } else {
            imageView.frame = contentRect
        }
        applyColors()
    }

    override func updateLayer() {
        super.updateLayer()
        applyColors()
    }

    private func applyColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            imageView.layer?.borderWidth = imageView.isHidden ? 0 : 1
            imageView.layer?.borderColor = Theme.Palette.windowEdge.cgColor
        }
    }
}

/// プレビューに出す絵（原寸の方）の置き場。
///
/// 一覧の小さな絵（ClipThumbnailCache・256px）とは別に持つ。
/// 原寸は1枚で数MBあるので、覚えるのは直近の数枚だけにして食い過ぎを防ぐ。
/// 開けなかったものも覚えておき、選ぶたびにディスクへ読みに行かない。
enum PreviewImageCache {

    /// 起動時に Store の loadClipImage を差し込む
    static var loader: ((UUID) -> Data?)?

    private static var images: [UUID: NSImage] = [:]
    private static var order: [UUID] = []
    private static var missing: Set<UUID> = []
    private static let capacity = 6

    static func image(for id: UUID) -> NSImage? {
        if let cached = images[id] { return cached }
        if missing.contains(id) { return nil }
        guard let data = loader?(id), let image = NSImage(data: data) else {
            missing.insert(id)
            return nil
        }
        images[id] = image
        order.append(id)
        if order.count > capacity {
            let oldest = order.removeFirst()
            images[oldest] = nil
        }
        return image
    }

    static func forget(_ id: UUID) {
        images[id] = nil
        order.removeAll { $0 == id }
        missing.remove(id)
    }

    /// 鍵が変わったとき・履歴を空にしたときに呼ぶ
    static func forgetAll() {
        images.removeAll()
        order.removeAll()
        missing.removeAll()
    }
}
