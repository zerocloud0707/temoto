import AppKit
import TemotoCore

/// 見た目の決めごとを1か所に集めた場所。
///
/// ⚠️ なぜ数字を各画面に書かないのか。
///
/// 作者の言葉:「一つ一つが別アプリみたいやし」。
/// 中身の作りは1つの窓にまとめたが、**見た目が揃っていなければ結局そう見える**。
/// 角の丸みが窓ごとに 14 / 12 / 10 とばらけているだけで、人は理由を言えないまま
/// 「なんか安っぽい」と感じる。だから丸みも余白も色も、ここにしか書かない。
///
/// 色は macOS のシステム色から作る。数値で色を決め打ちすると、
/// ダークモードや壁紙の色が変わったときだけ読めなくなる（そして気づけない）。
enum Theme {

    // MARK: - 丸み

    enum Radius {
        /// 窓の角。3つの窓（検索窓・メモ・設定）で必ず同じ値を使う。
        /// ⚠️ 2026-07-30「ほとんど変わってない」を受けて 20→26（macOS 26 の Spotlight 級の丸み。
        /// 16→20 では誰も気づかない。丸みは大胆に変えないと変わったことにならない）
        static let window: CGFloat = 26
        /// 一覧で選んでいる行。
        /// ⚠️ 窓の丸みと**同心円**にする（外の丸み26 − 内側への寄せ8 = 18）。
        /// バラバラの丸みは「理由を言えないまま安っぽい」の原因になる
        static let row: CGFloat = 18
        /// キーの札（⏎ や ⌘C）
        static let keyCap: CGFloat = 5
        /// 種類の札（「アプリ」「定型文」）
        static let badge: CGFloat = 5
        /// 検索欄の左に出す行き先の札
        static let chip: CGFloat = 7
        /// SF Symbols の下に敷く四角
        static let iconTile: CGFloat = 7
        /// 押して何かが起きるボタン・プルダウン（高さ24の半分＝完全な半円）。
        /// ⚠️ macOS 26 の標準はカプセル型で、高さは Md=24（.sketch の実測: Mn16/Sm20/Md24/Lg28/XL36）。
        /// キーの札（KeyCap）はカプセルにしない＝キーはキーの形（角丸5）が正しい
        static let capsule: CGFloat = 12

        /// まとまりを載せる面（カード）の角丸。
        /// ⚠️ 窓の角丸（26）より小さく、部品の角丸（7）より大きい。
        /// 窓 > 面 > 部品 の順に丸みが小さくなると、入れ子が自然に見える
        static let card: CGFloat = 12
        /// 押せる部品の高さ（Apple の Md ボタンと同じ）
        static let controlHeight: CGFloat = 24
    }

    // MARK: - 余白

    enum Space {
        /// 窓の左右の余白。検索欄・下の帯・行の中身をこれで縦に揃える
        static let edge: CGFloat = 18
        /// 選んだ行の塗りを、窓の縁からどれだけ内側に入れるか。
        /// ⚠️ 0にすると塗りが端まで届いて、窓の角丸を四角く切り落としたように見える
        static let rowInset: CGFloat = 8
    }

    // MARK: - 行の高さ

    /// ⚠️ 行の高さは全種類で同じにする（2026-07-30 作者「画像の表示がやっぱりわかりにくい」）。
    /// 一度、絵の行だけ80ptに高くしてみたが、62ptの枠でも画面写真の中身は読めなかった。
    /// 絵の見分けは右のプレビュー（PreviewPaneView）に任せ、
    /// 一覧は1画面に入る件数＝探す速さを優先する。
    enum Row {
        /// すべての行
        static let standard: CGFloat = 46
        /// 見出し（「行き先」「コマンド」）。行ではなく仕切りなので低くてよい
        static let header: CGFloat = 30
        /// 絵とファイルの行のアイコン（中身のしるしなので少し大きい）
        static let fileIcon: CGFloat = 34
        /// ふつうの行のアイコン
        static let standardIcon: CGFloat = 24
    }

    // MARK: - 色

    enum Palette {
        /// 選んでいる行の塗り。
        /// ⚠️ 濃い青のベタ塗り（既定の選択色）にしない。
        /// ベタ塗りは行の文字を白に反転させるので、一致した文字を色で示せなくなる。
        /// ⚠️ 枠を捨てた分、塗りを一段上げてある（0.26→0.30。2026-08-02 枠の一掃）
        static var rowSelection: NSColor { .controlAccentColor.withAlphaComponent(0.30) }

        /// キーの札の地色と縁。
        /// ⚠️ 0.07 / 0.14 では薄すぎて枠が消えた（2026-07-29 作者「すごく見づらい」）。
        /// 枠が見えないなら枠を描く意味がない。濃さは `Contrast.Tones` が正
        static var keyCapFill: NSColor { tone(Contrast.Tones.keyCapFill) }
        static var keyCapEdge: NSColor { tone(Contrast.Tones.keyCapEdge) }
        /// アイコンの下敷き（ボタンより一段濃い。見分けるものは地の強さが要る）
        static var iconTileFill: NSColor { tone(Contrast.Tones.iconTile) }
        /// アイコンの下敷きの勾配（上）。わずかな明暗で「磨いた札」に見せる
        static var iconTileTop: NSColor { tone(Contrast.Tones.iconTileTop) }
        /// アイコンの下敷きの勾配（下）
        static var iconTileBottom: NSColor { tone(Contrast.Tones.iconTileBottom) }
        /// 窓の上端の光の筋（暗い見た目でだけ見える）
        static var topGlint: NSColor { tone(Contrast.Tones.topGlint) }
        /// キーの札の勾配（磨いた札の材質。中心は keyCapFill の 0.08）
        static var keyCapTop: NSColor { tone(Contrast.Tones.keyCapTop) }
        static var keyCapBottom: NSColor { tone(Contrast.Tones.keyCapBottom) }
        /// 下の帯の沈み。⚠️ これだけ黒を重ねる（暗い見た目で足元を沈ませる。明るい見た目は0）
        static var footerShade: NSColor {
            adaptive(light: NSColor.black.withAlphaComponent(Contrast.Tones.footerShade.light),
                     dark: NSColor.black.withAlphaComponent(Contrast.Tones.footerShade.dark))
        }

        /// 窓の縁。すりガラスは輪郭を失うので細い線で締める。
        /// ⚠️ 白で固定してはいけない。**明るい地の上では白い線は見えない**。
        /// 明るいときは黒寄り、暗いときは白寄りに入れ替える。
        static var windowEdge: NSColor {
            adaptive(light: NSColor.black.withAlphaComponent(0.13),
                     dark: NSColor.white.withAlphaComponent(0.16))
        }

        /// すりガラスの上にかぶせる薄い覆い。
        ///
        /// ⚠️ これが要る理由。`blendingMode = .behindWindow` は背後の色をそのまま通すので、
        /// 表計算のように**色の付いた帯が並んだ画面**の上に出すと、その色が文字の裏に透けて
        /// 一覧が読めなくなる。少しだけ濁らせて、背後の模様を殺す。
        /// いま暗い見た目か（色の濃さを明暗で変えるときに使う）
        static var isDarkNow: Bool {
            NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        }

        static var backdropVeil: NSColor {
            adaptive(light: NSColor.white.withAlphaComponent(Contrast.Backdrop.veilLightAlpha),
                     dark: NSColor.black.withAlphaComponent(Contrast.Backdrop.veilDarkAlpha))
        }

        /// まとまりを載せる面（カード）の地。
        /// ⚠️ 明は白・暗は**黒**を重ねる（Tone の規約とは逆。理由は Contrast.Card 参照）
        static var cardFill: NSColor {
            adaptive(light: NSColor.white.withAlphaComponent(Contrast.Card.lightWhiteAlpha),
                     dark: NSColor.black.withAlphaComponent(Contrast.Card.darkBlackAlpha))
        }

        /// 仕切り線。
        ///
        /// ⚠️ 前は `.separatorColor.withAlphaComponent(0.7)` だった。
        /// すりガラスの中に置いた部品は外見が **vibrant** になり、そこでの `.separatorColor` は
        /// 明 0.902 / 暗 0.137 に化ける。覆い込みの地（明0.61〜1.00／暗0.08〜0.40）に対して
        /// 最悪 **1.11** ＝ このアプリ自身が決めた「線と分かる下限」`Threshold.visibleEdge = 1.5` を
        /// 下回っていた（2026-08-23 実測）。**引いているつもりで見えていない線**だった。
        /// 明暗どちらでも 1.5 を超える濃さに置き換える
        static var separator: NSColor { tone(Contrast.Tones.separatorLine) }

        /// 主役でない文字（副題・キーの説明・状態）の色。
        ///
        /// ⚠️ ここで `.secondaryLabelColor` を使わないこと。あれは**塗りつぶした地**の上で
        /// 読める濃さに作られていて、すりガラスの上では地に負ける
        /// （2026-07-29 作者の画面で「実行」「移動」「閉じる」が読めなかった）。
        /// 濃さの数字は `Contrast.Tones` が正。あちらは検証にかかっている
        static var captionText: NSColor { tone(Contrast.Tones.caption) }

        /// さらに一段引いた記号（空の一覧の絵など、読ませるためではなく間を持たせるもの）
        static var faintText: NSColor { tone(Contrast.Tones.faint) }

        /// 濃さの決めごと（`Contrast.Tone`）を、明暗に追従する色に組み立てる。
        /// 明るいときは黒を、暗いときは白を重ねる
        static func tone(_ tone: Contrast.Tone) -> NSColor {
            adaptive(light: NSColor.black.withAlphaComponent(tone.light),
                     dark: NSColor.white.withAlphaComponent(tone.dark))
        }

        /// 色付きの下敷き（アイコンの四角・種類の札・行き先の札）。
        ///
        /// ⚠️ 3か所で 0.14 / 0.16 / 0.18 とばらばらに書いていたのをここに集めた。
        /// 同じ画面に並ぶ下敷きの濃さが違うと、意味の違いだと誤解される
        /// （実際には「あとから足したときの気分」でしかない）。
        static func tintedFill(_ tint: NSColor) -> NSColor {
            tint.withAlphaComponent(0.16)
        }

        /// 明るいときと暗いときで別の色を使う。
        /// ⚠️ `NSColor.white.withAlphaComponent(...)` のような固定色を直接書かないこと。
        /// 片方の見た目でしか確かめていない色は、もう片方で必ず消える。
        static func adaptive(light: NSColor, dark: NSColor) -> NSColor {
            NSColor(name: nil) { appearance in
                appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
            }
        }
    }

    // MARK: - 色の数について

    // ここには「種類ごとの色」を**置かない**（2026-07-30 作者「色がありすぎるし、
    // raycastそのままやし」で、種類ごとの5色系統を廃止した）。
    //
    // 色が出る場所は3つだけに絞る:
    //   1. 選んでいる行・札・一致した文字 = macOSのアクセント色（利用者が選んだ1色）
    //   2. 警告 = systemOrange ／ 失敗 = 赤（意味のある色だけ残す）
    //   3. アプリやファイルの本物のアイコン（あれは飾りではなく中身）
    //
    // アイコンの記号は文字色（labelColor）でキーの札と同じ無彩色タイルに載せる。
    // ⚠️ 独自に灰色を薄めないこと。キーの札の濃さ（Contrast.Tones）を使うのは、
    // すりガラスの上で読めることが検証済みだから（2026-07-29 に灰色×灰色で
    // アイコンがまるごと消えた事故がある）。
}

// MARK: - 窓の地

/// すりガラス＋薄い覆い＋細い縁。3つの窓で必ずこれを使う。
///
/// ⚠️ `.hudWindow` を使わない理由（2026-07-29 作者「すごく見づらくなった」）。
/// `.hudWindow` は**暗いHUD**用の材質で、白い文字を載せる前提で作られている。
/// ところが macOS が明るい見た目のときは文字色が**黒のまま**なので、
/// 「灰色の地に黒い文字」という一番読みにくい組み合わせになる。
/// `.popover` は見た目に合わせて明るくも暗くもなるので、文字色と必ず噛み合う。
final class BackdropView: NSVisualEffectView {
    private let veil = NSView()
    /// 行き先の持ち色をごく薄く敷く層
    private let wash = NSView()
    /// 上端の光の筋。ガラスの端が光を拾う表現（暗い見た目でだけ見える）
    private let glint = NSView()

    /// 縁だけ別の色にしたいとき（失敗のお知らせを赤い縁で出す等）。
    /// 中身は変えない。指定しなければ地に合わせた目立たない縁になる
    var edgeColor: NSColor? {
        didSet { applyColors() }
    }

    /// いまいる行き先の持ち色。窓の地ぜんぶにごく薄く差す。
    ///
    /// ⚠️ 2026-08-09 の再設計。色の仕事を「32ptのタイルの中」から**窓そのもの**へ移す。
    /// 入口（すべて）は色を持たない＝無彩色。何も選んでいないのだから色も無い。
    /// 行き先に入って初めて窓が色を帯びる。
    ///
    /// ⚠️ これが効くと、検索欄の左の「コピー履歴」という札が要らなくなる。
    /// 窓が青ければ、言葉で言う必要がない。部品が1つ減る。
    var modeTint: ModeTint? {
        didSet { applyColors() }
    }

    /// 角丸と縁を自分で描くか。
    ///
    /// ⚠️ 検索窓・メモは**枠の無い浮く窓**なので、角も縁も自分で描く（true）。
    /// 設定は**枠のある普通の窓**で、角丸も縁も macOS が描く。
    /// そこで自分でも描くと角が二重になるので false にする。
    /// ⚠️ 材質・覆い・上端の光は**どちらでも同じ**。ここを分けると窓ごとに質感がばらつき、
    /// 作者の言う「一つ一つが別アプリみたい」に戻る（2026-08-23 に設定へも入れた理由）
    private let framed: Bool

    init(frame frameRect: NSRect, framed: Bool = true) {
        self.framed = framed
        super.init(frame: frameRect)
        material = .popover
        blendingMode = .behindWindow
        state = .active
        wantsLayer = true
        layer?.cornerRadius = framed ? Theme.Radius.window : 0
        layer?.masksToBounds = true
        layer?.borderWidth = framed ? 1 : 0

        veil.frame = bounds
        veil.autoresizingMask = [.width, .height]
        veil.wantsLayer = true
        // ⚠️ 最初に足す＝いちばん下に来る。あとから足す中身は必ずこの上に乗る
        addSubview(veil)

        // 行き先の色を差す層（覆いの上・光の筋の下）
        wash.wantsLayer = true
        wash.frame = bounds
        wash.autoresizingMask = [.width, .height]
        addSubview(wash)

        // 上端に1本だけ光を敷く（角の丸みの内側に収まるよう、左右を丸みぶん逃がす）
        glint.wantsLayer = true
        let glintInset = framed ? Theme.Radius.window : 0
        glint.frame = NSRect(x: glintInset, y: bounds.height - 1,
                             width: max(bounds.width - glintInset * 2, 0), height: 1)
        glint.autoresizingMask = [.width, .minYMargin]
        addSubview(glint)
        applyColors()
    }

    required init?(coder: NSCoder) { fatalError("使わない") }

    /// ⚠️ NSVisualEffectView では updateLayer() が呼ばれないことがある。
    /// 見た目の切り替えはこちらで受ける
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColors()
    }

    private func applyColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            if framed { layer?.borderColor = (edgeColor ?? Theme.Palette.windowEdge).cgColor }
            veil.layer?.backgroundColor = Theme.Palette.backdropVeil.cgColor
            // ⚠️ 濃さは「言われて初めて気づく」くらいに留める。
            // ここを上げると窓が色紙になり、行き先のタイルと喧嘩する（色は1か所に集める）
            if let modeTint {
                wash.layer?.backgroundColor = NSColor(
                    calibratedRed: modeTint.red, green: modeTint.green, blue: modeTint.blue,
                    alpha: Theme.Palette.isDarkNow ? 0.16 : 0.10).cgColor
            } else {
                wash.layer?.backgroundColor = NSColor.clear.cgColor
            }
            glint.layer?.backgroundColor = Theme.Palette.topGlint.cgColor
        }
    }
}

/// まとまりを載せる面。
///
/// ⚠️ 枠は描かない（`borderWidth = 0`）。形は塗りだけで作る。
/// このアプリの決まりが禁じているのは「線で形を作ること」で、「面で形を作ること」ではない。
/// 地がすりガラスになった今、線を引くと線だけが浮いて「紙に定規を当てた」ように見える。
/// ⚠️ ここに `NSVisualEffectView` を使わない。地が既に `.popover` のガラスなので、
/// ガラスの上にガラスを重ねると濁る（横メニューで実際に起きた二重ガラスと同じ）。
final class CardView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = Theme.Radius.card
        layer?.borderWidth = 0
        applyColors()
    }

    required init?(coder: NSCoder) { fatalError("使わない") }

    override func updateLayer() {
        super.updateLayer()
        applyColors()
    }

    /// ⚠️ NSView では見た目が変わっても updateLayer() が呼ばれないことがある
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColors()
    }

    private func applyColors() {
        // ⚠️ `.cgColor` は書いた瞬間の見た目で固まる。必ず今の見た目の下で解く
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = Theme.Palette.cardFill.cgColor
        }
    }
}

/// 文字を打つ場所を表す、わずかに沈んだ面。
///
/// ⚠️ `NSColor.textBackgroundColor` / `.controlBackgroundColor` を使わない。
/// あれは**どの見た目でも不透明**（明1.000／暗0.118）で、すりガラスの上に置くと
/// 真っ白（真っ黒）な箱が貼り付く。2026-08-23 に実際そうなった。
/// ⚠️ かといって地を敷かないのも駄目。枠も地も無いと「どこが打てる場所か」の
/// 手がかりが消える（2026-07-29「枠が消えた」と同じ状態）。
/// ボタンと同じ 0.08 をごく薄く敷いて、面であることだけを示す。
final class FieldWellView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = Theme.Radius.chip
        layer?.masksToBounds = true
        applyColors()
    }

    required init?(coder: NSCoder) { fatalError("使わない") }

    override func updateLayer() {
        super.updateLayer()
        applyColors()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColors()
    }

    private func applyColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = Theme.Palette.keyCapFill.cgColor
        }
    }
}

// MARK: - 文章の組み方

extension Theme {
    enum Text {
        /// 日本語の説明文の行送り。
        ///
        /// ⚠️ AppKit の既定の行送りは欧文向けで、漢字かなが混ざると**行が詰まって**見える。
        /// 2026-08-23 作者「おしゃれさが足りない」の一因。説明が2〜4行あるので効きが大きい。
        /// ⚠️ 1.5 を超えると今度は行がばらけて「読みにくい」になる。1.35 が上限
        static func paragraph(_ lineHeight: CGFloat = 1.35) -> NSParagraphStyle {
            let style = NSMutableParagraphStyle()
            style.lineHeightMultiple = lineHeight
            style.lineBreakMode = .byWordWrapping
            return style
        }
    }
}

// MARK: - 区切り線

/// 窓の中を上下に切る細い線。
///
/// ⚠️ `NSBox(.separator)` を使わない理由: あれは既定の濃さで描かれるので、
/// すりガラスの上だと線だけが黒く浮いて、窓が段ボール箱に見える。
///
/// ⚠️ `view.layer?.backgroundColor = Theme.Palette.separator.cgColor` と直に書かないこと。
/// `.cgColor` は**書いたその瞬間の見た目**で1回だけ色を決めてしまうので、
/// あとから明るい／暗いを切り替えても線は前の色のまま残り、地に溶けて消える。
/// この入れ物は切り替わるたびに塗り直す。
final class HairlineView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        applyColors()
    }

    required init?(coder: NSCoder) { fatalError("使わない") }

    override func updateLayer() {
        super.updateLayer()
        applyColors()
    }

    private func applyColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = Theme.Palette.separator.cgColor
        }
    }

    /// 幅いっぱいの1本を作る。窓の幅が変わっても追従する
    static func full(y: CGFloat, width: CGFloat) -> HairlineView {
        let line = HairlineView(frame: NSRect(x: 0, y: y, width: width, height: 1))
        line.autoresizingMask = [.width]
        return line
    }
}

// MARK: - キーの札

/// 「⏎」「⌘C」のような、押せるキー1つを枠に入れて描く。
///
/// ⚠️ 枠が要る理由。
/// 薄い文字でベタ書きした一行（`⏎ 貼り付け　⌘C コピー`）は、
/// どこまでがキーでどこからが説明なのか目が切り分けられず、まるごと読み飛ばされる。
/// 枠に入れると「これはキーだ」と一目で分かるので、初めて見た人でも試せる。
///
/// ⚠️ 2026-07-30 作者「キーボード操作もいいのですが、ボタンも欲しい」で**押せる札**になった。
/// 札に乗せると同じことがクリックでも起きる（キーの説明とボタンを別々に置くと場所も二重になる）。
final class KeyCapView: NSView {
    /// 札の地。⚠️ keyLabel（NSTextField）の層に勾配を敷くと文字の上に乗って隠すので、
    /// 地は別のビューで持つ（層の中身→その上に子の層、の順で描かれるため）
    private let capBackground = NSView()
    private let capGradient = CAGradientLayer()
    private let keyLabel = NSTextField(labelWithString: "")
    private let textLabel = NSTextField(labelWithString: "")
    /// クリックされたとき。設定されていれば、乗せたときに札が浮く
    var onTap: (() -> Void)?
    /// 狭くても隠してはいけない札か（esc など、これが無いと出口が分からなくなるもの）
    private(set) var isEssential: Bool = false
    private var isHovering = false

    /// 札そのものの高さ。下の帯の高さもこれに合わせる
    static let capHeight: CGFloat = 18

    /// 大きさの倍率。1＝下の帯の札（既定）。
    /// ⚠️ 初めての人に見せる帯だけ大きくする（1.8）。
    /// そこは「まずこれを押す」1点だけを伝える場所なので、下の帯と同じ小ささでは埋もれる。
    /// ⚠️ 丸みも文字も同じ比で拡げる。高さだけ変えると丸みの比率がばらけて安っぽく見える。
    private let scale: CGFloat

    init(action: HintAction, scale: CGFloat = 1) {
        self.scale = scale
        self.isEssential = action.isEssential
        super.init(frame: .zero)
        wantsLayer = true

        // ⚠️ 等幅にしないと ⌘⏎ と ⌘C で札の幅がガタつき、下の帯が揺れて見える
        keyLabel.font = .monospacedSystemFont(ofSize: 11 * scale, weight: .medium)
        keyLabel.textColor = .labelColor
        keyLabel.alignment = .center
        keyLabel.stringValue = action.keys
        keyLabel.drawsBackground = false

        capBackground.wantsLayer = true
        capBackground.layer?.cornerRadius = Theme.Radius.keyCap * scale
        capGradient.cornerRadius = Theme.Radius.keyCap * scale
        capBackground.layer?.insertSublayer(capGradient, at: 0)

        // ⚠️ `.tertiaryLabelColor` にしない。すりガラスの上では**ほぼ消える**
        // （2026-07-29 作者の画面で「実行」「移動」「閉じる」が読めなかった）。
        // 押せる操作の名前は、読めなければ無いのと同じ。
        textLabel.font = .systemFont(ofSize: 11.5)
        textLabel.textColor = Theme.Palette.captionText
        textLabel.stringValue = action.label

        addSubview(capBackground)
        addSubview(keyLabel)
        addSubview(textLabel)
        applyColors()
        resize()
    }

    required init?(coder: NSCoder) { fatalError("使わない") }

    /// 中身を入れ替える（帯は「キーを教える」と「決め直す」で文字が変わる）
    func configure(action: HintAction) {
        keyLabel.stringValue = action.keys
        textLabel.stringValue = action.label
        resize()
    }

    override var intrinsicContentSize: NSSize { frame.size }

    /// ⚠️ ダークモードへ切り替わったとき、CALayer の色は自動では追従しない。
    /// これを書かないと、明るい地に明るい枠が残って札が消える。
    override func updateLayer() {
        super.updateLayer()
        applyColors()
    }

    private func applyColors() {
        let appearance = effectiveAppearance
        appearance.performAsCurrentDrawingAppearance {
            // 乗せている間は少し浮かせる（押せることが手に伝わる）
            capGradient.colors = (isHovering && onTap != nil)
                ? [Theme.Palette.keyCapEdge.cgColor, Theme.Palette.keyCapEdge.cgColor]
                : [Theme.Palette.keyCapTop.cgColor, Theme.Palette.keyCapBottom.cgColor]
        }
    }

    // MARK: 押せるようにする

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways],
            owner: self, userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) {
        isHovering = true
        applyColors()
    }

    override func mouseExited(with event: NSEvent) {
        isHovering = false
        applyColors()
    }

    /// ⚠️ クリックは自分で受ける。
    /// 中の文字（NSTextField）が既定でクリックを自分のものとして受け取るので、
    /// これが無いと**札の文字の上を押した分が届かない**＝押せる札のつもりが押せない
    /// （2026-08-04 棚の「＋」で同じ穴が見つかったので、こちらも一緒に塞いだ）。
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard onTap != nil else { return super.hitTest(point) }
        let local = convert(point, from: superview)
        return bounds.contains(local) ? self : nil
    }

    override func mouseUp(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if bounds.contains(point), let onTap {
            onTap()
        } else {
            super.mouseUp(with: event)
        }
    }

    override func resetCursorRects() {
        if onTap != nil { addCursorRect(bounds, cursor: .pointingHand) }
    }

    private func resize() {
        keyLabel.sizeToFit()
        textLabel.sizeToFit()

        let capWidth = max(keyLabel.frame.width + 12 * scale, 24 * scale)
        let height = KeyCapView.capHeight * scale
        // ⚠️ 文字の箱は札いっぱいに広げない。NSTextField は箱が文字より高いと
        // **上詰め**で描くので、⏎ や ↑↓ が札の中で上に寄る
        // （2026-08-02 作者「表示位置はちゃんと揃えて！上に寄ってたりする」）。
        // 文字の実寸のまま、札の真ん中に置く。
        let keyHeight = keyLabel.frame.height
        keyLabel.frame = NSRect(x: 0, y: ((height - keyHeight) / 2).rounded(),
                                width: capWidth, height: keyHeight)
        capBackground.frame = NSRect(x: 0, y: 0, width: capWidth, height: height)
        capGradient.frame = capBackground.bounds
        // キーの札と説明の縦位置を、文字の中心どうしで合わせる
        let textY = (height - textLabel.frame.height) / 2
        // ⚠️ 説明が空なら札の右に隙間を作らない（空の説明のぶんだけ札が広く見える）
        let gap: CGFloat = textLabel.stringValue.isEmpty ? 0 : 5
        textLabel.frame = NSRect(x: capWidth + gap, y: textY,
                                 width: textLabel.frame.width, height: textLabel.frame.height)
        setFrameSize(NSSize(width: capWidth + gap + textLabel.frame.width, height: height))
    }
}

// MARK: - 下の帯

/// 窓の下に出す操作の案内。左＝今の状態／右＝押せるキー。
///
/// ⚠️ 左右に分けている理由。
/// 「3件見つかりました」と「⏎ 開く」は性質が違う。
/// 前者は結果の報告で、後者は次にできること。同じ列に混ぜると、
/// 件数が増減するたびにキーの位置が横に動いて、目で追えなくなる。
/// 右端に固定してあれば、キーはいつも同じ場所にある。
final class HintBarView: NSView {
    private let statusLabel = NSTextField(labelWithString: "")
    private var capViews: [KeyCapView] = []
    private var actions: [HintAction] = []
    /// 札がクリックされたとき。キーを押したのと同じことを起こす（配線は各画面が持つ）
    var onAction: ((HintAction) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        // 足元をわずかに沈ませる（暗い見た目だけ。操作の帯に「土台」の座りを作る）
        wantsLayer = true
        statusLabel.font = .systemFont(ofSize: 11.5)
        statusLabel.textColor = Theme.Palette.captionText
        statusLabel.lineBreakMode = .byTruncatingTail
        addSubview(statusLabel)
        applyShade()
    }

    required init?(coder: NSCoder) { fatalError("使わない") }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyShade()
    }

    private func applyShade() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = Theme.Palette.footerShade.cgColor
        }
    }

    /// 左の文字。件数や「探しています…」など、そのときだけの報告
    var status: String {
        get { statusLabel.stringValue }
        set {
            guard statusLabel.stringValue != newValue else { return }
            statusLabel.stringValue = newValue
            needsLayout = true
        }
    }

    /// 右のキー。行き先が変わったときだけ組み直す
    func setActions(_ newActions: [HintAction]) {
        guard newActions != actions else { return }
        actions = newActions
        rebuild()
    }

    private func rebuild() {
        capViews.forEach { $0.removeFromSuperview() }
        capViews = actions.map { action in
            let cap = KeyCapView(action: action)
            cap.onTap = { [weak self] in self?.onAction?(action) }
            return cap
        }
        capViews.forEach { addSubview($0) }
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let gap: CGFloat = 12
        let capY = (bounds.height - KeyCapView.capHeight) / 2

        // 左の報告文には最低これだけ残す（キーで押し潰して件数が消えないように）
        let statusFloor: CGFloat = 180
        let available = max(bounds.width - Theme.Space.edge * 2 - statusFloor, 0)

        // 入りきらないものは隠す。**どれを隠すか**が肝。
        //
        // ⚠️ 2026-08-30 に直した。それまでは右端から詰めて、入らなくなったものを
        // 順に隠していた。右端から詰めると、隠れるのは**配列の先頭側＝いちばんよく使う操作**。
        // 実際、ファイル検索に1つ足しただけで「⌘⏎ Finder」が消えた。
        // すぐ上に「大事なものが残る」と書いてあったのに、逆のことをしていた。
        //
        // 直した決まり:
        // 1. `isEssential`（esc）は何があっても残す。先に場所を取っておく
        // 2. 残りは**配列の順に**取る（前ほどよく使う並びにしてある）
        // 3. 入らなくなったら、そこから後ろを隠す
        let essential = capViews.filter { $0.isEssential }
        let optional = capViews.filter { !$0.isEssential }
        let essentialWidth = essential.reduce(CGFloat(0)) { $0 + $1.frame.width + gap }

        var kept: [KeyCapView] = []
        var usedWidth = essentialWidth
        for cap in optional {
            let width = cap.frame.width + gap
            if usedWidth + width > available { break }
            usedWidth += width
            kept.append(cap)
        }
        let shown = Set(kept.map(ObjectIdentifier.init))
        for cap in optional { cap.isHidden = !shown.contains(ObjectIdentifier(cap)) }
        essential.forEach { $0.isHidden = false }

        // 並びは元の順のまま、右端に寄せて置く
        // （並べ替えると「さっきと違う場所にある」になって目が迷う）
        let order = capViews.filter { !$0.isHidden }
        var x = bounds.width - Theme.Space.edge
        for cap in order.reversed() {
            x -= cap.frame.width
            cap.setFrameOrigin(NSPoint(x: x, y: capY))
            x -= gap
        }

        let statusWidth = max(x - Theme.Space.edge, 0)
        statusLabel.sizeToFit()
        let statusY = (bounds.height - statusLabel.frame.height) / 2
        statusLabel.frame = NSRect(x: Theme.Space.edge, y: statusY,
                                   width: statusWidth, height: statusLabel.frame.height)
    }
}

// MARK: - 選んでいる行

/// 一覧の行の下地。角丸の選択を自前で描く。
///
/// ⚠️ NSTableView の既定（`selectionHighlightStyle = .regular`）は、
/// 窓の端から端まで届く**角ばった濃い青の帯**を描く。
/// せっかく窓の角を丸めても、選んだ行だけ四角い帯が突き抜けるので、
/// 「作りかけのアプリ」に見える一番の原因になっていた。
///
/// `.none` にして自分で描けば、丸みも余白も色も窓と揃えられる。
final class LauncherRowBackground: NSTableRowView {
    override func drawSelection(in dirtyRect: NSRect) {
        guard selectionHighlightStyle != .none else { return }
        let rect = bounds.insetBy(dx: Theme.Space.rowInset, dy: 1)
        let path = NSBezierPath(roundedRect: rect,
                                xRadius: Theme.Radius.row, yRadius: Theme.Radius.row)
        // 塗りだけで示す（枠なし＝macOSの選択の顔。2026-08-02 枠の一掃で線を捨て、塗りを一段上げた）。
        // 左から右へわずかに薄まる＝選択に光の流れを与える（平らな塗り1枚より生きて見える）
        NSGradient(colors: [
            NSColor.controlAccentColor.withAlphaComponent(0.34),
            NSColor.controlAccentColor.withAlphaComponent(0.22),
        ])?.draw(in: path, angle: 0)
    }

    /// ⚠️ 自前で塗るので、文字色の自動反転（白抜き）は止める。
    /// 止めないと、一致した文字だけ色を変える工夫が白一色に潰される。
    override var interiorBackgroundStyle: NSView.BackgroundStyle { .normal }
}

// MARK: - 何も出ないとき

/// 一覧が空のときに真ん中へ出す案内。
///
/// ⚠️ ここを何も描かないと、窓の中がただの空白になる。
/// 空白は「読み込み中なのか」「壊れたのか」「そもそも無いのか」を区別できず、
/// 使う側は**アプリのせいだと思う**（実際には登録がまだ0件なだけでも）。
/// 記号と一文で「今どういう状態か」と「次に何をすればいいか」を必ず言う。
final class EmptyStateView: NSView {
    private let iconView = NSImageView()
    private let messageField = NSTextField(labelWithString: "")
    private let detailField = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.contentTintColor = Theme.Palette.faintText

        // ⚠️ ここは「何も出ていない理由」を伝える唯一の場所なので、薄くしない。
        // 薄い文字で書かれた説明は読まれず、結局「壊れている」と受け取られる。
        messageField.font = .systemFont(ofSize: 13.5, weight: .medium)
        messageField.textColor = .labelColor
        messageField.alignment = .center

        detailField.font = .systemFont(ofSize: 11.5)
        detailField.textColor = Theme.Palette.captionText
        detailField.alignment = .center

        addSubview(iconView)
        addSubview(messageField)
        addSubview(detailField)
    }

    required init?(coder: NSCoder) { fatalError("使わない") }

    /// `detail` は「次にどうすればいいか」。無いなら空でよい（無理に埋めない）
    func configure(symbol: String, message: String, detail: String) {
        iconView.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        messageField.stringValue = message
        detailField.stringValue = detail
        detailField.isHidden = detail.isEmpty
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let iconEdge: CGFloat = 30
        // 真ん中よりわずかに上へ置く。ちょうど真ん中だと、下の帯に近すぎて沈んで見える
        let centerY = bounds.height / 2 + 14

        iconView.frame = NSRect(x: (bounds.width - iconEdge) / 2, y: centerY,
                                width: iconEdge, height: iconEdge)
        messageField.frame = NSRect(x: 20, y: centerY - 26, width: bounds.width - 40, height: 18)
        detailField.frame = NSRect(x: 20, y: centerY - 46, width: bounds.width - 40, height: 16)
    }
}

// MARK: - 種類の札

/// 行の右端に出す種類の名前（「アプリ」「定型文」）と、キー（「⌘1」）。
///
/// ⚠️ キーだけを**下の帯と同じ枠**で描く。同じものは同じ形で描かないと、
/// 下では枠に入っているキーが一覧では分類札に見えて、押せると気づかれない。
///
/// ⚠️ 種類の名前は**色付きの札にしない**（2026-07-30 作者「色がありすぎる」）。
/// 薄い文字でそっと書く。分類は読めれば足りるもので、目立たせるものではない。
final class KindBadgeView: NSView {
    private let label = NSTextField(labelWithString: "")
    /// キーの札と同じ「磨いた札」の勾配（isKey のときだけ見せる）
    private let badgeGradient = CAGradientLayer()
    /// キーとして描くか（中身が ⌘ で始まるとき）
    private var isKey = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        badgeGradient.cornerRadius = Theme.Radius.keyCap
        layer?.insertSublayer(badgeGradient, at: 0)
        label.alignment = .center
        addSubview(label)
    }

    required init?(coder: NSCoder) { fatalError("使わない") }

    func configure(text: String) {
        isKey = text.hasPrefix("⌘") || text.hasPrefix("⌥") || text.hasPrefix("⌃")
        label.stringValue = text
        label.font = isKey
            ? .monospacedSystemFont(ofSize: 10, weight: .medium)
            : .systemFont(ofSize: 10, weight: .regular)
        isHidden = text.isEmpty
        applyColors()
        needsLayout = true
    }

    override func updateLayer() {
        super.updateLayer()
        applyColors()
    }

    private func applyColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            if isKey {
                layer?.cornerRadius = Theme.Radius.keyCap
                badgeGradient.isHidden = false
                badgeGradient.colors = [Theme.Palette.keyCapTop.cgColor,
                                        Theme.Palette.keyCapBottom.cgColor]
                layer?.borderWidth = 0
                label.textColor = .labelColor
            } else {
                layer?.cornerRadius = 0
                badgeGradient.isHidden = true
                layer?.borderWidth = 0
                label.textColor = Theme.Palette.captionText
            }
        }
    }

    /// 中身に合わせた必要な幅。
    ///
    /// 🔴 ここで `label.sizeToFit()` を呼んではいけない。
    /// この読み取りは**親（行）の layout の最中**に来る。sizeToFit は測るついでに
    /// ラベルの枠を「文字ぴったり・左寄せ」に書き換えてしまい、札の寸法が変わらない
    /// 行の使い回しでは中央寄せの layout が走り直さないので、書き換えられた枠のまま
    /// 画面に出る＝**行によって ⌘1 の文字が左に寄ったり寄らなかったりする**
    /// （2026-08-02 作者「ズレてる。」の正体）。intrinsicContentSize は枠を動かさない。
    var fittingWidth: CGFloat {
        guard !label.stringValue.isEmpty else { return 0 }
        return min(label.intrinsicContentSize.width + (isKey ? 14 : 4), 96)
    }

    override func layout() {
        super.layout()
        badgeGradient.frame = bounds
        label.frame = NSRect(x: 2, y: (bounds.height - 13) / 2, width: max(bounds.width - 4, 0), height: 13)
    }
}

// MARK: - 押せる札（チップ）

/// 「キーの札」と同じ顔の押せるボタン。
///
/// ⚠️ 2026-07-30 作者「ボタンも欲しい」「デザイン構成を洗練された感じに」。
/// 標準のベゼル（accessoryBarAction等）は場所ごとに顔が違って見えるので、
/// **押せるものはすべて同じ札の形**にそろえる（下の帯のキー・保存・☆・プルダウンが同族になる）。
final class ChipButton: NSButton {
    private var isHovering = false

    convenience init(title: String, target: AnyObject?, action: Selector) {
        self.init(title: title)
        self.target = target
        self.action = action
    }

    init(title: String) {
        super.init(frame: .zero)
        self.title = title
        isBordered = false
        wantsLayer = true
        font = .systemFont(ofSize: 11.5)
        setButtonType(.momentaryChange)
        // 動作ボタンはカプセル型・枠なし（macOS 26 の標準の顔）
        layer?.cornerRadius = Theme.Radius.capsule
        applyColors()
    }

    required init?(coder: NSCoder) { fatalError("使わない") }

    override func sizeToFit() {
        super.sizeToFit()
        // カプセルは端が丸い分、文字の左右に余白が要る。高さは Apple の Md ボタンと同じ
        setFrameSize(NSSize(width: frame.width + 20, height: Theme.Radius.capsule * 2))
    }

    /// ⚠️ 位置を制約で決める場所（設定画面の縦並び）では `sizeToFit()` が呼ばれない。
    /// ここを書かないと、カプセルが文字ぴったりに潰れて丸が欠ける
    /// （2026-08-23、設定の15個のボタンをカプセルに替えたときに必要になった）
    override var intrinsicContentSize: NSSize {
        var size = super.intrinsicContentSize
        // 記号だけのカプセルは正方形でよい（左右の余白は制約側で決める）
        size.width += title.isEmpty ? 0 : 20
        size.height = Theme.Radius.capsule * 2
        return size
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: bounds, options: [.mouseEnteredAndExited, .activeAlways], owner: self, userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) { isHovering = true; applyColors() }
    override func mouseExited(with event: NSEvent) { isHovering = false; applyColors() }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }

    override func updateLayer() {
        super.updateLayer()
        applyColors()
    }

    private func applyColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = (isHovering ? Theme.Palette.keyCapEdge : Theme.Palette.keyCapFill).cgColor
        }
        // ⚠️ 記号だけのカプセル（title が空）では組み直さない。
        // 空の attributedTitle を入れると imagePosition = .imageOnly と衝突してカプセルが潰れる
        if !title.isEmpty {
            attributedTitle = NSAttributedString(string: title, attributes: [
                .font: font ?? .systemFont(ofSize: 11.5),
                .foregroundColor: NSColor.labelColor,
            ])
        }
        contentTintColor = .labelColor
    }
}

/// 「キーの札」と同じ顔のプルダウン。
/// 標準のベゼルはすりガラスの上で灰色の塊に見える（2026-07-30 作者「洗練された感じに」）。
final class ChipPopUpButton: NSPopUpButton {
    init() {
        super.init(frame: .zero, pullsDown: false)
        isBordered = false
        wantsLayer = true
        controlSize = .small
        font = .systemFont(ofSize: 11.5)
        // プルダウンもカプセル型・枠なし（macOS 26 の標準の顔）
        layer?.cornerRadius = Theme.Radius.capsule
        applyColors()
    }

    required init?(coder: NSCoder) { fatalError("使わない") }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }

    override func updateLayer() {
        super.updateLayer()
        applyColors()
    }

    private func applyColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = Theme.Palette.keyCapFill.cgColor
        }
    }
}

// MARK: - 焦点を奪わない一覧

/// クリックで選べるが、キーボードの焦点は**奪わない**一覧。
///
/// ⚠️ これが要る理由（2026-07-30 作者「メモから下の画面に戻れない」）。
/// ふつうの NSTableView は行をクリックした瞬間に自分が焦点を持つ。
/// この窓で esc を受け取れるのは検索欄と書く場所だけなので、
/// 一覧が焦点を持つと **esc がどこにも届かず、窓を閉じて戻れなくなる**。
/// 選ぶのはマウスの仕事、キーは検索欄と編集エリアの仕事、と分ける。
final class NonFocusingTableView: NSTableView {
    override var acceptsFirstResponder: Bool { false }

    /// 右クリックしたときに出す品書きを作る係（行番号を渡す。-1 は行の外）。
    ///
    /// ⚠️ これが要る理由（2026-08-30 作者「コピー履歴で見られたくないものがあります。
    /// 削除できる様にして欲しい」）。1件消す ⌘⌫ は前からあり、下の帯にも
    /// 「⌘⌫ 削除」と出していた。それでも伝わらなかった。
    /// **キーは覚えた人にしか使えない**。右クリックなら覚えなくてよい。
    /// 2026-07-30 にも同じこと（「削除や編集できる様にして」＝実は在った）が起きている。
    /// 2度あったのだから、帯に書き足すのではなく**別の入口**を作る。
    var contextMenuProvider: ((Int) -> NSMenu?)?

    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        let row = self.row(at: point)
        // ⚠️ 右クリックした行が選ばれていなければ、先に選ぶ。
        // 選ばずに品書きだけ出すと、「どれに効くのか」が分からない
        if row >= 0, !selectedRowIndexes.contains(row) {
            selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        }
        return contextMenuProvider?(row)
    }
}

// MARK: - 見出し

/// 一覧の中の小さな見出し（「行き先」「コマンド」「保存した検索」）。
/// 行ではない＝選べない・押せない。目の区切りのためだけにある。
final class HeaderRowView: NSView {
    private let label = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        addSubview(label)
    }

    required init?(coder: NSCoder) { fatalError("使わない") }

    var title: String = "" {
        didSet {
            // 少しだけ字間を空ける。小さな見出しの「見出しらしさ」は字間で出る
            label.attributedStringValue = NSAttributedString(string: title, attributes: [
                .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
                .foregroundColor: Theme.Palette.captionText,
                .kern: 0.8,
            ])
            needsLayout = true
        }
    }

    override func layout() {
        super.layout()
        label.sizeToFit()
        // 下寄せ＝自分の下に続く仲間の見出しであることを形で示す
        label.frame = NSRect(x: Theme.Space.rowInset + 10, y: 4,
                             width: max(bounds.width - (Theme.Space.rowInset + 10) * 2, 40),
                             height: label.frame.height)
    }
}
