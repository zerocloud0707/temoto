import AppKit
import TemotoCore

/// 検索欄のすぐ下に並べる、よく使うアプリの棚。
///
/// 2026-08-04 作者「コピー履歴と検索の間にアプリへのリンクを作って欲しい。
/// アイコンが表示される。」
///
/// ⚠️ 中身は「アプリのキー」（設定で選んだアプリ）をそのまま使う。
/// 別の入れ物（お気に入り）を新しく作らない理由は3つ:
///   1. 選ぶ画面がもうある（設定 →「アプリのキー」）＝覚えることが増えない
///   2. キーを割り当てたアプリ＝その人がいちばん使うアプリ、という意味が既にある
///   3. 2つの一覧を別々に持つと、片方に足してもう片方に出ない、が必ず起きる
///
/// ⚠️ 棚は**入口で文字を打っていないときだけ**出す。
/// 打ち始めたら結果に場所を譲る（棚が残ると一覧が1行分せり上がって落ち着かない）。
final class AppShelfView: NSView {

    /// 押されたアプリの置き場所
    var onOpen: ((String) -> Void)?
    /// 「＋」が押された（アプリを足しに行く）
    var onAdd: (() -> Void)?

    /// 棚そのものの高さ。
    /// ⚠️ 2026-08-04 作者「余白の使い方好きじゃない」＝62ptの帯に40ptのアイコンで
    /// 上下が空きすぎ、右は丸ごと空いて「空の棚」に見えていた。中身に合わせて詰める。
    /// ⚠️ 2026-08-04 札（⌃1〜⌃9）を足したぶんだけ高くする（52→66）。
    /// 中身が増えたから高くするのはよい。中身が無いのに高いのが「空の棚」だった
    static let height: CGFloat = 66
    /// アイコンそのものの大きさ（行の色タイル32ptより少し大きい＝棚は押す場所だと分かる）
    private static let iconEdge: CGFloat = 34
    /// 乗せたときの下敷きが絵からはみ出す分
    private static let padding: CGFloat = 4
    /// 絵と絵の間（詰めすぎず、離しすぎず）
    private static let gap: CGFloat = 10

    private var buttons: [AppShelfButton] = []
    private let addButton = AppShelfAddButton(edge: AppShelfView.iconEdge + AppShelfView.padding * 2)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        addButton.onTap = { [weak self] in self?.onAdd?() }
        addSubview(addButton)
    }

    required init?(coder: NSCoder) { fatalError("使わない") }

    /// いま棚に出ているアプリの置き場所（⌃1〜⌃9 と矢印が指す先）
    private(set) var paths: [String] = []

    /// 矢印で選んでいる位置。nil なら棚に入っていない
    var focusedIndex: Int? {
        didSet {
            guard focusedIndex != oldValue else { return }
            for (index, button) in buttons.enumerated() {
                button.isFocused = (index == focusedIndex)
            }
        }
    }

    func configure(_ bindings: [AppBinding]) {
        buttons.forEach { $0.removeFromSuperview() }
        paths = bindings.map(\.path)
        buttons = bindings.enumerated().map { index, binding in
            let button = AppShelfButton(binding: binding,
                                        iconEdge: AppShelfView.iconEdge,
                                        padding: AppShelfView.padding,
                                        keyLabel: ShelfKeys.label(forIndex: index))
            button.onTap = { [weak self] in self?.onOpen?(binding.path) }
            button.isFocused = (index == focusedIndex)
            addSubview(button)
            return button
        }
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let side = AppShelfView.iconEdge + AppShelfView.padding * 2
        let step = AppShelfView.iconEdge + AppShelfView.gap
        // ⚠️ **絵の左端**を一覧の行（色タイルの左端＝Theme.Space.edge）にそろえる。
        // 下敷きの分だけ左へずらして置く（そろっていないと、棚だけ浮いて見える）
        var x = Theme.Space.edge - AppShelfView.padding
        // 絵と札を合わせた高さを、棚の真ん中に置く
        let tall = side + 14
        let y = ((bounds.height - tall) / 2).rounded()
        for button in buttons {
            button.frame = NSRect(x: x, y: y, width: side, height: tall)
            x += step
            // 入りきらない分は隠す（折り返すと棚の高さが変わり、一覧の頭が動く）
            button.isHidden = x + side > bounds.width - Theme.Space.edge
        }
        // 「＋」は最後の絵のすぐ隣（札は無いので、絵の高さに合わせる）。
        // 右の空きは余白として残す（端まで引き伸ばすと、置き場所の意味が消える）
        addButton.frame = NSRect(x: x, y: y + 14, width: side, height: side)
        addButton.isHidden = x + side > bounds.width - Theme.Space.edge
    }
}

/// 棚の右端に置く「＋」。押すと設定の「アプリのキー」へ連れていく。
///
/// ⚠️ 空いた場所に置く意味。棚は「自分で足すもの」だと分かる入口が要る。
/// 設定のどこかにしか無いと、棚は最初の1つのまま一生変わらない。
final class AppShelfAddButton: NSView {
    var onTap: (() -> Void)?
    private var isHovering = false
    private let glyph = NSImageView()

    init(edge: CGFloat) {
        super.init(frame: NSRect(x: 0, y: 0, width: edge, height: edge))
        wantsLayer = true
        layer?.cornerRadius = Theme.Radius.iconTile
        glyph.image = NSImage(systemSymbolName: "plus", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 14, weight: .medium))
        glyph.contentTintColor = Theme.Palette.captionText
        glyph.frame = NSRect(x: 0, y: 0, width: edge, height: edge)
        addSubview(glyph)
        toolTip = "よく使うアプリを足す"
        applyColors()
    }

    required init?(coder: NSCoder) { fatalError("使わない") }

    override func updateLayer() {
        super.updateLayer()
        applyColors()
    }

    private func applyColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = isHovering
                ? Theme.Palette.keyCapEdge.cgColor
                : Theme.Palette.keyCapFill.cgColor
            glyph.contentTintColor = isHovering ? .labelColor : Theme.Palette.captionText
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds,
                                       options: [.mouseEnteredAndExited, .activeAlways],
                                       owner: self, userInfo: nil))
    }


    /// ⚠️ クリックは必ず自分で受ける。
    /// 中に敷いた絵（NSImageView）は既定でクリックを**自分のもの**として受け取るので、
    /// これが無いと絵の上を押した分がボタンに届かない
    /// （2026-08-04 作者「このプラスボタンが何も反応しない。」＝実測で確認）。
    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        return bounds.contains(local) ? self : nil
    }

    override func mouseEntered(with event: NSEvent) { isHovering = true; applyColors() }
    override func mouseExited(with event: NSEvent) { isHovering = false; applyColors() }
    override func mouseUp(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if bounds.contains(point) { onTap?() } else { super.mouseUp(with: event) }
    }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
}

/// 棚の1つ。本物のアプリのアイコン＋乗せたときだけ浮く下敷き
final class AppShelfButton: NSView {
    var onTap: (() -> Void)?

    private let iconView = NSImageView()
    private let binding: AppBinding
    private var isHovering = false
    /// 矢印で選ばれている。乗せているときより強く出す（キーで操作している人の目印）
    var isFocused = false { didSet { if isFocused != oldValue { applyColors() } } }

    private let capLabel = NSTextField(labelWithString: "")

    init(binding: AppBinding, iconEdge: CGFloat, padding: CGFloat, keyLabel: String?) {
        self.binding = binding
        let side = iconEdge + padding * 2
        // 札のぶんだけ縦に伸ばす（札が無ければ絵だけの高さ）
        let capHeight: CGFloat = keyLabel == nil ? 0 : 14
        super.init(frame: NSRect(x: 0, y: 0, width: side, height: side + capHeight))
        wantsLayer = true
        layer?.cornerRadius = Theme.Radius.iconTile

        iconView.image = IconCache.appIcon(binding.path)
        iconView.imageScaling = .scaleProportionallyUpOrDown
        // 本物のアイコンなので、下敷きも縁も付けない（色を足さない決めごとの③）
        // ⚠️ 絵は「上」に置く（下に札が入るので、上下中央にすると札とぶつかる）
        iconView.frame = NSRect(x: padding, y: capHeight + padding, width: iconEdge, height: iconEdge)
        addSubview(iconView)

        // 札＝この窓が開いている間だけ効く番号（⌘1〜⌘6 の行き先と対になる）
        if let keyLabel {
            capLabel.font = .monospacedSystemFont(ofSize: 10, weight: .medium)
            capLabel.textColor = Theme.Palette.captionText
            capLabel.alignment = .center
            capLabel.stringValue = keyLabel
            capLabel.sizeToFit()
            capLabel.frame = NSRect(x: 0, y: 1, width: side, height: capLabel.frame.height)
            addSubview(capLabel)
        }

        // 名前とキーは乗せたときに出す（棚に文字を並べると、アイコンの列が読めなくなる）
        toolTip = binding.shortcut.displayString.isEmpty
            ? binding.name
            : "\(binding.name)（\(binding.shortcut.displayString)）"
        applyColors()
    }

    required init?(coder: NSCoder) { fatalError("使わない") }

    override func updateLayer() {
        super.updateLayer()
        applyColors()
    }

    private func applyColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            if isFocused {
                // 選ばれている札は、行の選択と同じ色で塗って縁を出す（一覧と同じ言葉づかい）
                layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.30).cgColor
                layer?.borderWidth = 1
                layer?.borderColor = NSColor.controlAccentColor.withAlphaComponent(0.55).cgColor
            } else {
                layer?.backgroundColor = isHovering ? Theme.Palette.keyCapFill.cgColor : nil
                layer?.borderWidth = 0
            }
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds,
                                       options: [.mouseEnteredAndExited, .activeAlways],
                                       owner: self, userInfo: nil))
    }


    /// ⚠️ クリックは必ず自分で受ける。
    /// 中に敷いた絵（NSImageView）は既定でクリックを**自分のもの**として受け取るので、
    /// これが無いと絵の上を押した分がボタンに届かない
    /// （＋ボタンで実際に起きた。アプリの絵も同じ作りなので一緒に塞ぐ）。
    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        return bounds.contains(local) ? self : nil
    }

    override func mouseEntered(with event: NSEvent) {
        isHovering = true
        applyColors()
    }

    override func mouseExited(with event: NSEvent) {
        isHovering = false
        applyColors()
    }

    override func mouseUp(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if bounds.contains(point) { onTap?() } else { super.mouseUp(with: event) }
    }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
}
