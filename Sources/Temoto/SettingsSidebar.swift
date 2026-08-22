import AppKit
import TemotoCore

/// 設定画面の横メニュー。
///
/// 2026-08-14 作者「こんな感じの横メニューで高級感や操作性の高い構成にしたい」。
///
/// ⚠️ 見た目を自分で描かない。`NSTableView` の `style = .sourceList` を使うと、
/// 選択の丸み・余白・すりガラスの上での色の抜き方まで **macOS が描く**。
/// システム設定・メール・Finder の横棒と**同じ**になるのが、いちばん高級に見える。
/// 自前で角丸を塗ると、OSの版が変わったときにここだけ古びる。
final class SettingsSidebar: NSView {
    /// 横メニューの1行。探しているときは、当たった設定そのものも行になる
    enum Row: Equatable {
        case pane(SettingsPane)
        case hit(SettingsItem)

        var pane: SettingsPane {
            switch self {
            case .pane(let p): return p
            case .hit(let item): return item.pane
            }
        }
    }

    /// 行が選ばれたときに呼ばれる。
    /// 探して当たった行なら、その設定の名前も渡す（中身の側でそこまで送り届けるため）
    var onSelect: ((SettingsPane, String?) -> Void)?

    private let table = NSTableView()
    private let search = NSSearchField()
    private var rows: [Row] = SettingsPane.allCases.map { .pane($0) }
    /// 探しているかどうか。空欄に戻したら全部の画面に戻す
    private var query: String = ""

    static let width: CGFloat = 208
    /// タイルの一辺（記号の大きさの検査から引く）
    static let tileSize: CGFloat = 20

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        build()
    }

    required init?(coder: NSCoder) { nil }

    private func build() {
        // 地。
        //
        // ⚠️ macOS 26 では**自分で敷かない**。
        // `NSSplitViewItem(sidebarWithViewController:)` を使うと、OS が横メニューを
        // `NSContainerConcentricGlassEffectView`（角丸のガラスの板）で包む。
        // そこに自前のすりガラスを重ねると、せっかくの板を**全面で塗り潰す**＝二重ガラスになり、
        // macOS 26 の見た目（Liquid Glass）が消える。
        // 2026-08-23 作者「もっと透け感とか」——原因の半分はこれだった。
        // 古い macOS では OS が板を用意しないので、そのときだけ自分で敷く。
        let glass: NSView
        if #available(macOS 26.0, *) {
            glass = self
        } else {
            let own = NSVisualEffectView()
            own.material = .sidebar
            own.blendingMode = .behindWindow
            own.state = .followsWindowActiveState
            own.translatesAutoresizingMaskIntoConstraints = false
            addSubview(own)
            NSLayoutConstraint.activate([
                own.topAnchor.constraint(equalTo: topAnchor),
                own.bottomAnchor.constraint(equalTo: bottomAnchor),
                own.leadingAnchor.constraint(equalTo: leadingAnchor),
                own.trailingAnchor.constraint(equalTo: trailingAnchor),
            ])
            glass = own
        }

        search.placeholderString = "設定を探す"
        // ⚠️ 字を小さくしない。macOS の設定の検索欄は高さ 28＝`.large`。
        // 既定（regular・24）に 12pt の字だと、横メニューの中で**ここだけ子ども扱い**に見える
        search.controlSize = .large
        search.target = self
        search.action = #selector(searchChanged)
        // 打つたびに絞り込む（returnを待たない）
        search.sendsSearchStringImmediately = true
        search.sendsWholeSearchString = false
        search.translatesAutoresizingMaskIntoConstraints = false
        glass.addSubview(search)

        table.headerView = nil
        table.style = .sourceList
        // ⚠️ 30 ではなく 32。macOS の横メニュー（システム設定・メール・Finder）の実測が 32 で、
        // 2pt 低いだけで「詰まっている」と感じる（行が7本あれば 14pt ぶん差が出る）
        table.rowHeight = 32
        table.selectionHighlightStyle = .regular
        table.backgroundColor = .clear
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.action = #selector(rowClicked)
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("pane"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.translatesAutoresizingMaskIntoConstraints = false
        glass.addSubview(scroll)

        NSLayoutConstraint.activate([
            // ⚠️ 上は OS に聞く。窓の中身を見出し棒の下まで広げている（.fullSizeContentView）ので、
            // 素直に上端へ置くと、閉じる・しまう・広げるの3つの丸に検索欄が重なる。
            // macOS 26 では横メニューを自前のすりガラスで包む（NSContainerConcentricGlassEffectView）ため、
            // 空ける量は版によって変わる。数値を決め打ちしない
            // ⚠️ 9。`.unified` の道具棒で safeAreaInsets.top が 44 になり、
            // 板の上端から検索欄まで 44+9=53pt ＝ システム設定の実測と一致する
            search.topAnchor.constraint(equalTo: safeAreaLayoutGuide.topAnchor, constant: 9),
            search.leadingAnchor.constraint(equalTo: glass.leadingAnchor, constant: 10),
            search.trailingAnchor.constraint(equalTo: glass.trailingAnchor, constant: -10),

            scroll.topAnchor.constraint(equalTo: search.bottomAnchor, constant: 9),
            scroll.leadingAnchor.constraint(equalTo: glass.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: glass.trailingAnchor),
            // ⚠️ 0。Apple は一覧の下端を板の下端とぴったり合わせる。
            // -8 だと一覧が板の中に浮いて見える
            scroll.bottomAnchor.constraint(equalTo: glass.bottomAnchor, constant: 0),
        ])

        table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
    }

    /// 外から画面を選ぶ（メニューや棚の「アプリを足す」から飛んでくる）
    func select(_ pane: SettingsPane) {
        // 探している最中に外から飛んできたら、絞り込みを解いて全部に戻す。
        // でないと「選んだ画面が横メニューに無い」状態になる
        if !query.isEmpty {
            query = ""
            search.stringValue = ""
            rebuild()
        }
        guard let index = rows.firstIndex(where: { $0.pane == pane }) else { return }
        table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        table.scrollRowToVisible(index)
        onSelect?(pane, nil)
    }

    /// 絵にするとき用（`--render-settings --query スニペット`）。
    /// 探している最中の見た目を、実物の部品のまま確かめられるようにする
    func preview(query text: String) {
        search.stringValue = text
        searchChanged()
    }

    @objc private func searchChanged() {
        query = search.stringValue.trimmingCharacters(in: .whitespaces)
        rebuild()
    }

    private func rebuild() {
        let previous = selectedPane
        if query.isEmpty {
            rows = SettingsPane.allCases.map { .pane($0) }
        } else {
            // 当たった設定そのものを並べる。
            // 「その設定がどの画面にあるか」が分からないのが一番の詰まりどころなので、
            // 設定の名前を出して、下に画面の名前を添える
            rows = SettingsSearch.find(query).map { .hit($0) }
        }
        table.reloadData()

        // 絞り込んだ結果、今見ている画面が消えたら先頭へ移る。
        // ⚠️ 何も当たらなかったときは**画面を変えない**（打っている途中で中身が飛ぶと読めない）
        guard !rows.isEmpty else { return }
        if let previous, let keep = rows.firstIndex(where: { $0.pane == previous }) {
            table.selectRowIndexes(IndexSet(integer: keep), byExtendingSelection: false)
        } else {
            table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
            onSelect?(rows[0].pane, selectedTitle)
        }
    }

    private var selectedPane: SettingsPane? { selectedRow?.pane }

    private var selectedRow: Row? {
        let index = table.selectedRow
        guard index >= 0, index < rows.count else { return nil }
        return rows[index]
    }

    /// 当たった設定の名前（画面そのものを選んだだけなら nil）
    private var selectedTitle: String? {
        if case .hit(let item) = selectedRow { return item.title }
        return nil
    }

    @objc private func rowClicked() {
        guard let pane = selectedPane else { return }
        onSelect?(pane, selectedTitle)
    }
}

extension SettingsSidebar: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        // 探した結果の行は、下に画面の名前を添えるぶん高い
        guard row < rows.count else { return 32 }
        if case .hit = rows[row] { return 44 }
        return 32
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row < rows.count else { return nil }
        return SidebarRowView(row: rows[row])
    }

    /// 矢印キーで動かしたときも中身を切り替える（クリックと同じ扱い）
    func tableViewSelectionDidChange(_ notification: Notification) {
        guard let pane = selectedPane else { return }
        onSelect?(pane, selectedTitle)
    }
}

/// 横メニュー1行の見た目。記号のタイル＋名前（探しているときは画面の名前も）。
///
/// ⚠️ タイルは検索窓の行（`LauncherRowView`）と**同じ作り**にしてある:
/// 角丸 `Theme.Radius.iconTile`、ごくわずかな勾配、**枠は描かない**。
/// 2026-08-02 作者「もっと洗練された感じで！」＝枠だらけが野暮ったさの正体、
/// 2026-07-31「平らな一色は灰色の四角にしか見えない」＝勾配が要る、の2つの結論をそのまま使う。
/// ここを別の作りにすると、窓ごとに質感がばらついて「一つ一つが別アプリみたい」に戻る。
private final class SidebarRowView: NSTableCellView {
    /// タイルの一辺。字（13pt）の行に対して、大きすぎず記号が潰れない大きさ
    /// ⚠️ 行の高さ 32 に対して 20。上下に 6pt ずつ残って落ち着く。
    /// 22 だと 5pt しか残らず、行いっぱいに札が詰まって窮屈に見える
    static let tile: CGFloat = SettingsSidebar.tileSize

    private let tileView = NSView()
    private let tileGradient = CAGradientLayer()
    private let glyph = NSImageView()
    private let tint: ModeTint?

    init(row: SettingsSidebar.Row) {
        tint = row.pane.mode.flatMap { ModeTint.tint(for: $0) }
        super.init(frame: .zero)

        tileView.wantsLayer = true
        tileView.layer?.cornerRadius = Theme.Radius.iconTile
        tileView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(tileView)

        glyph.image = NSImage(systemSymbolName: row.pane.symbolName, accessibilityDescription: nil)
        // ⚠️ 大きさはタイルに対して決める。タイル22に対し記号12が、
        // 上下左右に等しく余白が残って落ち着く（システム設定のタイルと同じ比）
        // ⚠️ `.preferringHierarchical()` は色を足さない。同じ色の**濃さを段にして**
        // 絵の主役と脇役を分ける（歯車なら歯が濃く、中心が薄い）。
        // 平らな一色の記号は、大きさを変えても「線画」のままで奥行きが出ない
        glyph.symbolConfiguration = NSImage.SymbolConfiguration(
            pointSize: row.pane.glyphPointSize, weight: .medium)
            .applying(.preferringHierarchical())
        glyph.imageScaling = .scaleProportionallyDown
        glyph.translatesAutoresizingMaskIntoConstraints = false
        addSubview(glyph)

        let title = NSTextField(labelWithString: "")
        title.font = .systemFont(ofSize: 13)
        title.lineBreakMode = .byTruncatingTail
        title.translatesAutoresizingMaskIntoConstraints = false
        // ⚠️ `textField` に入れておくと、行が選ばれたとき macOS が白く抜いてくれる。
        // 自分で色を切り替えると、選択の色が変わったときに合わなくなる
        textField = title

        let column = NSStackView()
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 1
        column.translatesAutoresizingMaskIntoConstraints = false
        column.addArrangedSubview(title)

        switch row {
        case .pane(let pane):
            title.stringValue = pane.title
        case .hit(let item):
            title.stringValue = item.title
            let place = NSTextField(labelWithString: item.pane.title)
            place.font = .systemFont(ofSize: 10)
            place.textColor = Theme.Palette.captionText
            place.lineBreakMode = .byTruncatingTail
            column.addArrangedSubview(place)
        }
        addSubview(column)

        NSLayoutConstraint.activate([
            tileView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 0),
            tileView.centerYAnchor.constraint(equalTo: centerYAnchor),
            tileView.widthAnchor.constraint(equalToConstant: SidebarRowView.tile),
            tileView.heightAnchor.constraint(equalToConstant: SidebarRowView.tile),

            glyph.centerXAnchor.constraint(equalTo: tileView.centerXAnchor),
            glyph.centerYAnchor.constraint(equalTo: tileView.centerYAnchor),
            // ⚠️ 箱を決めておく。SF Symbols は絵によって見かけの大きさが違うので、
            // pointSize だけに任せると記号ごとに大小がばらつき、並べたとき不揃いに見える。
            // `.scaleProportionallyDown` と組で、はみ出す絵だけを縮める保険にもなる
            glyph.widthAnchor.constraint(equalToConstant: 16),
            glyph.heightAnchor.constraint(equalToConstant: 16),

            column.leadingAnchor.constraint(equalTo: tileView.trailingAnchor, constant: 9),
            column.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -6),
            column.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        applyColors()
    }

    required init?(coder: NSCoder) { nil }

    /// 行が選ばれているか。macOS が入れてくれる。
    ///
    /// ⚠️ これを見ないと、選ばれた行の**青い帯の上に黒い半透明のタイル**が乗る。
    /// 無彩色のタイルは「黒を薄く重ねる」作りなので、地が青くなると黒い汚れに見える。
    /// 選ばれている間は白を薄く重ねる側に入れ替えて、青の上で「明るい札」にする。
    /// ⚠️ 色付きのタイル（コピー履歴・ファイル検索）は入れ替えない。
    /// あれは行き先の色そのものなので、選ばれても色が変わってはいけない
    override var backgroundStyle: NSView.BackgroundStyle {
        didSet { applyColors() }
    }

    /// ⚠️ NSVisualEffectView の上では updateLayer() が呼ばれないことがあるので、
    /// 見た目が変わったときにも塗り直す（Theme.BackdropView と同じ理由）
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColors()
    }

    override func updateLayer() {
        super.updateLayer()
        applyColors()
    }

    private func applyColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            if tileGradient.superlayer == nil, let host = tileView.layer {
                tileGradient.frame = host.bounds
                tileGradient.cornerRadius = host.cornerRadius
                tileGradient.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
                host.insertSublayer(tileGradient, at: 0)
            }
            if let tint {
                // 行き先を設定する画面は、その行き先と同じ色のタイル。
                // 上をわずかに明るく＝検索窓のタイルと同じ向きの勾配
                let base = NSColor(calibratedRed: tint.red, green: tint.green, blue: tint.blue, alpha: 1)
                let top = base.blended(withFraction: 0.22, of: .white) ?? base
                tileGradient.colors = [top.cgColor, base.cgColor]
            } else if backgroundStyle == .emphasized {
                // 選ばれている＝濃い帯の上。白を薄く重ねて「明るい札」にする
                tileGradient.colors = [NSColor.white.withAlphaComponent(0.30).cgColor,
                                       NSColor.white.withAlphaComponent(0.18).cgColor]
            } else {
                tileGradient.colors = [Theme.Palette.iconTileTop.cgColor,
                                       Theme.Palette.iconTileBottom.cgColor]
            }
            // 枠は描かない。形は塗りだけで作る
            tileView.layer?.borderWidth = 0
            tileView.layer?.backgroundColor = nil
        }
        // 色付きのタイルの上と、選ばれた濃い帯の上は白い記号。それ以外は文字と同じ色
        glyph.contentTintColor = (tint != nil || backgroundStyle == .emphasized) ? .white : .labelColor
    }
}
