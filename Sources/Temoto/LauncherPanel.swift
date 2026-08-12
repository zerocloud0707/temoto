import AppKit
import TemotoCore

/// 検索窓のウィンドウ。
///
/// 枠なしウィンドウは既定ではキーウィンドウになれず、文字を打ち込めない。
/// canBecomeKey を上書きして入力を受け取れるようにする。
final class KeyPanel: NSPanel {
    /// ⌘つきのキーを横取りするための入口
    var keyEquivalentHandler: ((NSEvent) -> Bool)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if keyEquivalentHandler?(event) == true { return true }
        return super.performKeyEquivalent(with: event)
    }
}

/// 角の丸い小さな札（検索欄の左に出す「今どこにいるか」）
final class ChipView: NSView {
    private let label = NSTextField(labelWithString: "")

    init(text: String) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = Theme.Radius.chip
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.stringValue = text
        addSubview(label)
        applyColors()
        resize()
    }

    required init?(coder: NSCoder) { fatalError("使わない") }

    var text: String {
        get { label.stringValue }
        set { label.stringValue = newValue; resize() }
    }

    override func updateLayer() {
        super.updateLayer()
        applyColors()
    }

    private func applyColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = Theme.Palette.tintedFill(.controlAccentColor).cgColor
            label.textColor = .controlAccentColor
        }
    }

    private func resize() {
        label.sizeToFit()
        let width = label.frame.width + 20
        let height = label.frame.height + 9
        setFrameSize(NSSize(width: width, height: height))
        label.frame = NSRect(x: 10, y: 4, width: label.frame.width, height: label.frame.height)
    }
}

/// 一覧の1行
final class LauncherRowView: NSTableCellView {
    private let iconTile = NSView()
    /// タイルの勾配。作り直さず色だけ差し替える（行は使い回されるため）
    private let tileGradient = CAGradientLayer()
    private let iconView = NSImageView()
    private let titleField = NSTextField(labelWithString: "")
    private let subtitleField = NSTextField(labelWithString: "")
    private let badge = KindBadgeView()

    /// 左のアイコンの一辺。絵やファイルの行だけ大きくする（中身が見えないと選べないため）
    private var iconEdge: CGFloat = 26
    /// アイコンの下に四角を敷くか。
    /// ⚠️ 敷くのは SF Symbols の行だけ。アプリのアイコンや写真の下に敷くと、
    /// 元の絵が持っている影や透過とぶつかって二重の四角に見える。
    /// ⚠️ 四角は無彩色（キーの札と同じ濃さ）。種類ごとの色は使わない
    /// （2026-07-30 作者「色がありすぎるし、raycastそのままやし」）。
    private var showsTile = false
    /// 副題が空のときは題名を行の中央に置く（上に寄ったまま下が空くと、行が壊れて見える）
    private var hasSubtitle = false
    /// 行き先の持ち色（あるときだけ、タイルが色ガラスになり記号が白になる）
    private var tint: ModeTint?
    /// コピーした絵の行かどうか。絵は縦横比のまま出して、その形に縁を付ける
    private var isPhoto = false
    /// 絵の縦横比（横 ÷ 縦）
    private var photoAspect: CGFloat = 1

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        iconTile.wantsLayer = true
        iconTile.layer?.cornerRadius = Theme.Radius.iconTile

        // 絵は角を丸めて細い縁を付ける。
        // ⚠️ 白っぽいスクリーンショットは、すりガラスの上だと外周が地に溶けて
        // 「どこまでが絵か」が分からなくなる。縁はその境目を出すためだけのもの。
        iconView.wantsLayer = true
        iconView.layer?.cornerRadius = Theme.Radius.badge
        iconView.layer?.masksToBounds = true
        iconView.imageScaling = .scaleProportionallyUpOrDown
        titleField.font = .systemFont(ofSize: 14)
        titleField.lineBreakMode = .byTruncatingTail
        titleField.maximumNumberOfLines = 1
        subtitleField.font = .systemFont(ofSize: 11)
        // ⚠️ `.secondaryLabelColor` はすりガラスの上だと地に負ける（Theme.Palette.captionText を見ること）。
        // 副題にはファイルの置き場所が入るので、読めないと選びようがない
        subtitleField.textColor = Theme.Palette.captionText
        subtitleField.lineBreakMode = .byTruncatingTail

        addSubview(iconTile)
        addSubview(iconView)
        addSubview(titleField)
        addSubview(subtitleField)
        addSubview(badge)
    }

    required init?(coder: NSCoder) { fatalError("使わない") }

    /// compact ＝ 2ペインの狭い一覧。副題と札を短い方に差し替える
    func configure(item: LauncherItem, matchedIndices: [Int], compact: Bool = false) {
        iconView.image = item.image
        iconEdge = item.iconEdge
        // 小さな絵が出せているときだけ「写真として」描く。
        // 出せないとき（鍵を作り直した後など）は記号で代用しているので、縁を付けると変になる
        isPhoto = item.isClipImage && !item.usesSymbolIcon
        photoAspect = item.imageAspect ?? 1
        showsTile = item.usesSymbolIcon
        tint = item.tint
        titleField.attributedStringValue = LauncherRowView.highlighted(item.title, indices: matchedIndices)
        let subtitle = compact ? (item.compactSubtitle ?? item.subtitle) : item.subtitle
        subtitleField.stringValue = subtitle
        hasSubtitle = item.subtitleInRow && !subtitle.isEmpty
        subtitleField.isHidden = !hasSubtitle
        badge.configure(text: compact ? (item.compactKindLabel ?? item.kindLabel) : item.kindLabel)
        applyColors()
        needsLayout = true
    }

    override func updateLayer() {
        super.updateLayer()
        applyColors()
    }

    private func applyColors() {
        iconTile.isHidden = !showsTile
        effectiveAppearance.performAsCurrentDrawingAppearance {
            // 絵の縁。絵のときだけ描く（アプリのアイコンに縁を付けると角丸が二重になる）
            iconView.layer?.borderWidth = isPhoto ? 1 : 0
            iconView.layer?.borderColor = isPhoto ? Theme.Palette.windowEdge.cgColor : nil
            guard showsTile else { return }
            // 無彩色のタイル。ボタン（keyCapFill）より一段濃い地に、
            // ごくわずかな勾配（上 0.14 → 下 0.07）を敷いて「磨いた札」に見せる
            // （2026-07-31「もっと洗練されたかっこいいデザインに」。平らな一色は灰色の四角にしか見えない）
            if tileGradient.superlayer == nil, let hostLayer = iconTile.layer {
                tileGradient.frame = hostLayer.bounds
                tileGradient.cornerRadius = hostLayer.cornerRadius
                tileGradient.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
                hostLayer.insertSublayer(tileGradient, at: 0)
            }
            if let tint {
                // 行き先だけ、持ち色のタイル（システム設定式）。上をわずかに明るく＝磨いた札と同じ向き
                let base = NSColor(calibratedRed: tint.red, green: tint.green, blue: tint.blue, alpha: 1)
                let top = base.blended(withFraction: 0.22, of: .white) ?? base
                tileGradient.colors = [top.cgColor, base.cgColor]
            } else {
                tileGradient.colors = [Theme.Palette.iconTileTop.cgColor,
                                       Theme.Palette.iconTileBottom.cgColor]
            }
            iconTile.layer?.backgroundColor = nil
            // 枠は描かない。形は塗り（勾配）だけで作る
            // （2026-08-02 作者「もっと洗練された感じで！」＝枠だらけが野暮ったさの正体。
            //  枠を守ってきた理由＝薄いガラスで消える事故は、覆い0.45と勾配で解消済み）
            iconTile.layer?.borderWidth = 0
        }
        guard showsTile else { return }
        // 持ち色のタイルの上は白い記号（システム設定と同じ）。それ以外は文字と同じ色
        iconView.contentTintColor = tint != nil ? .white : .labelColor
    }

    override func layout() {
        super.layout()
        let height = bounds.height
        // 選んだ行の塗りを内側に寄せた分だけ、中身も内側から始める（左端が揃って見える）
        let leftEdge = Theme.Space.rowInset + 10

        // ⚠️ アイコンの置き場所は「幅の決まった列」として扱う。
        // 四角を敷く行（記号）と敷かない行（アプリの絵）で幅が変わると、
        // 「すべて」のように両方が混ざる一覧で題名の左端が数ピクセルずつずれ、
        // 理由の分からないガタつきになる。列の幅は中身に関係なく同じにする。
        let column = iconEdge + 8
        iconTile.frame = NSRect(x: leftEdge, y: (height - column) / 2, width: column, height: column)

        // 絵そのものは列の真ん中へ置く。
        // 写真だけは縦横比のまま縮めた寸法にする（正方形の枠のままだと縁が絵より大きくなる）
        var drawWidth = iconEdge
        var drawHeight = iconEdge
        if isPhoto, photoAspect > 0 {
            if photoAspect >= 1 {
                drawHeight = max(1, iconEdge / photoAspect)
            } else {
                drawWidth = max(1, iconEdge * photoAspect)
            }
        }
        iconView.frame = NSRect(x: leftEdge + (column - drawWidth) / 2, y: (height - drawHeight) / 2,
                                width: drawWidth, height: drawHeight)

        let badgeWidth = badge.fittingWidth
        let badgeRight = Theme.Space.rowInset + 10
        badge.frame = NSRect(x: bounds.width - badgeWidth - badgeRight, y: (height - 16) / 2,
                             width: badgeWidth, height: 16)

        let textX = leftEdge + column + 10
        let textWidth = max(bounds.width - textX - badgeWidth - badgeRight - 12, 40)
        let titleHeight: CGFloat = 19

        if hasSubtitle {
            // 題名＋隙間2＋副題15 のかたまりを、行の真ん中に置く
            let block = titleHeight + 2 + 15
            let bottom = ((height - block) / 2).rounded()
            subtitleField.frame = NSRect(x: textX, y: bottom, width: textWidth, height: 15)
            titleField.frame = NSRect(x: textX, y: bottom + 15 + 2, width: textWidth, height: titleHeight)
        } else {
            titleField.frame = NSRect(x: textX, y: (height - titleHeight) / 2, width: textWidth, height: titleHeight)
        }
    }

    /// 一致した文字だけ色を変える。位置の換算は TextRanges に任せる（そちらは検証済み）。
    static func highlighted(_ text: String, indices: [Int]) -> NSAttributedString {
        let attributed = NSMutableAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: 14),
            .foregroundColor: NSColor.labelColor,
        ])
        for range in TextRanges.utf16Ranges(in: text, characterIndices: indices) {
            attributed.addAttributes(
                [.foregroundColor: NSColor.controlAccentColor,
                 .font: NSFont.systemFont(ofSize: 14, weight: .bold)],
                range: NSRange(location: range.location, length: range.length)
            )
        }
        return attributed
    }
}
