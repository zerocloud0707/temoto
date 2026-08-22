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

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        build()
    }

    required init?(coder: NSCoder) { nil }

    private func build() {
        // 地はすりガラス。`.sidebar` は「横メニュー用」の材質で、
        // 中身の側（`.windowBackground`）とわずかに濃さが違う。
        // ⚠️ この濃さの差が**唯一の区切り**。線を引かない（枠で形を作らない）
        let glass = NSVisualEffectView()
        glass.material = .sidebar
        glass.blendingMode = .behindWindow
        glass.state = .followsWindowActiveState
        glass.translatesAutoresizingMaskIntoConstraints = false
        addSubview(glass)

        search.placeholderString = "設定を探す"
        search.font = .systemFont(ofSize: 12)
        search.target = self
        search.action = #selector(searchChanged)
        // 打つたびに絞り込む（returnを待たない）
        search.sendsSearchStringImmediately = true
        search.sendsWholeSearchString = false
        search.translatesAutoresizingMaskIntoConstraints = false
        glass.addSubview(search)

        table.headerView = nil
        table.style = .sourceList
        table.rowHeight = 30
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
            glass.topAnchor.constraint(equalTo: topAnchor),
            glass.bottomAnchor.constraint(equalTo: bottomAnchor),
            glass.leadingAnchor.constraint(equalTo: leadingAnchor),
            glass.trailingAnchor.constraint(equalTo: trailingAnchor),

            // ⚠️ 上は OS に聞く。窓の中身を見出し棒の下まで広げている（.fullSizeContentView）ので、
            // 素直に上端へ置くと、閉じる・しまう・広げるの3つの丸に検索欄が重なる。
            // macOS 26 では横メニューを自前のすりガラスで包む（NSContainerConcentricGlassEffectView）ため、
            // 空ける量は版によって変わる。数値を決め打ちしない
            search.topAnchor.constraint(equalTo: safeAreaLayoutGuide.topAnchor, constant: 6),
            search.leadingAnchor.constraint(equalTo: glass.leadingAnchor, constant: 10),
            search.trailingAnchor.constraint(equalTo: glass.trailingAnchor, constant: -10),

            scroll.topAnchor.constraint(equalTo: search.bottomAnchor, constant: 8),
            scroll.leadingAnchor.constraint(equalTo: glass.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: glass.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: glass.bottomAnchor, constant: -8),
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
        guard row < rows.count else { return 30 }
        if case .hit = rows[row] { return 42 }
        return 30
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

/// 横メニュー1行の見た目。記号＋名前（探しているときは画面の名前も）
private final class SidebarRowView: NSTableCellView {
    init(row: SettingsSidebar.Row) {
        super.init(frame: .zero)

        let icon = NSImageView()
        // ⚠️ 記号に色を付けない。色が付くのは行き先のタイルだけ（`ModeTint` の規律）。
        // 選ばれた行では文字も記号も白く抜ける。`.labelColor` にしておくと macOS が抜いてくれる
        icon.image = NSImage(systemSymbolName: row.pane.symbolName, accessibilityDescription: nil)
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
        icon.contentTintColor = .labelColor
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.widthAnchor.constraint(equalToConstant: 18).isActive = true
        addSubview(icon)

        let title = NSTextField(labelWithString: "")
        title.font = .systemFont(ofSize: 13)
        title.lineBreakMode = .byTruncatingTail
        title.translatesAutoresizingMaskIntoConstraints = false

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
            let where_ = NSTextField(labelWithString: item.pane.title)
            where_.font = .systemFont(ofSize: 10)
            where_.textColor = .secondaryLabelColor
            where_.lineBreakMode = .byTruncatingTail
            column.addArrangedSubview(where_)
        }
        addSubview(column)

        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            column.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 8),
            column.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -6),
            column.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { nil }
}
