import AppKit
import TemotoCore

/// 初めての人に「この窓を出すキー」だけを伝える帯。
///
/// 2026-08-06〜09 の設計（3案＋3審査）の結論。
///
/// ⚠️ **新しい窓は作らない。**
/// 「窓は増やさない。増えるのは行き先だけ」がこの製品の芯（LauncherMode の冒頭）。
/// 案内窓を足すと、窓の数を数えている検証も、外をクリックしたら閉じる決まりも、
/// 全部書き換えることになる。
/// 置き場所は**アプリの棚と同じ場所**。棚は既定では空（appBindings が空）なので、
/// 初めての人の画面ではその66ptが丸ごと空いている。
///
/// ⚠️ 伝えるのは**1つだけ**。機能の一覧は窓の中に既に並んでいるので、帯で二度説明しない
/// （2026-08-05「色々と情報が多くなりすぎている気がする」）。
///
/// ⚠️ 色を足さない。帯は無彩色のまま。画面の色は今までどおり行き先のタイルだけが持つ。
final class WelcomeBandView: NSView {

    /// 押されたとき（キーを決め直す案内のときだけ効く）
    var onReassign: (() -> Void)?

    /// 棚と同じ高さ。ここを変えると一覧の頭が動く
    static let height: CGFloat = AppShelfView.height

    private let cap = KeyCapView(action: HintAction("", ""), scale: 1.8)
    private let title = NSTextField(labelWithString: "")
    private let subtitle = NSTextField(labelWithString: "")
    private let privacy = NSTextField(labelWithString: Welcome.privacyLine)
    private var content: Welcome.BandContent = .key("")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        title.font = .systemFont(ofSize: 15, weight: .semibold)
        title.textColor = .labelColor
        subtitle.font = .systemFont(ofSize: 11.5)
        subtitle.textColor = Theme.Palette.captionText
        privacy.font = .systemFont(ofSize: 11.5)
        privacy.textColor = Theme.Palette.captionText
        privacy.alignment = .right
        privacy.lineBreakMode = .byTruncatingTail
        addSubview(cap)
        addSubview(title)
        addSubview(subtitle)
        addSubview(privacy)
    }

    required init?(coder: NSCoder) { fatalError("使わない") }

    func configure(_ content: Welcome.BandContent) {
        self.content = content
        switch content {
        case .key(let label):
            cap.configure(action: HintAction(label, ""))
            title.stringValue = Welcome.keyTitle
            subtitle.stringValue = Welcome.keySubtitle
            cap.onTap = nil
        case .reassign:
            // ⚠️ 押しても出ないキーを教えない。代わりに決め直す道を出す
            cap.configure(action: HintAction("⌘,", ""))
            title.stringValue = Welcome.reassignTitle
            subtitle.stringValue = Welcome.reassignSubtitle
            cap.onTap = { [weak self] in self?.onReassign?() }
        }
        needsLayout = true
    }

    override func layout() {
        super.layout()
        // 左端は下に続く行（色タイルの左端）にそろえる。ずれると帯だけ浮いて見える
        let left = Theme.Space.edge
        let capSize = cap.intrinsicContentSize
        let capY = ((bounds.height - capSize.height) / 2).rounded()
        cap.frame = NSRect(x: left, y: capY, width: capSize.width, height: capSize.height)

        let textLeft = left + capSize.width + 12
        let titleSize = title.intrinsicContentSize
        let subtitleSize = subtitle.intrinsicContentSize
        // 2行を合わせた高さを、帯の真ん中に置く
        let stack = titleSize.height + 2 + subtitleSize.height
        let stackY = ((bounds.height - stack) / 2).rounded()
        subtitle.frame = NSRect(x: textLeft, y: stackY,
                                width: subtitleSize.width, height: subtitleSize.height)
        title.frame = NSRect(x: textLeft, y: stackY + subtitleSize.height + 2,
                             width: titleSize.width, height: titleSize.height)

        // 右端に「どこにも送らない」。左とぶつかるなら詰め、狭すぎるなら隠す
        let textRight = textLeft + max(titleSize.width, subtitleSize.width) + 16
        let available = bounds.width - Theme.Space.edge - textRight
        let privacySize = privacy.intrinsicContentSize
        if available >= 200 {
            let width = min(privacySize.width, available)
            privacy.isHidden = false
            privacy.frame = NSRect(x: bounds.width - Theme.Space.edge - width,
                                   y: ((bounds.height - privacySize.height) / 2).rounded(),
                                   width: width, height: privacySize.height)
        } else {
            privacy.isHidden = true
        }
    }
}
