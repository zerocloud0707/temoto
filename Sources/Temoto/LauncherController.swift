import AppKit
import Quartz
import TemotoCore

/// 検索窓の制御。
///
/// 開くときに「直前まで前面だったアプリ」を覚えておき、
/// 貼り付けやウィンドウ操作のときはそのアプリへ戻してから実行する。
/// 覚えておかないと、貼り付け先が自分自身になってしまう。
final class LauncherController: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate, NSWindowDelegate {

    /// 行き先の定義は TemotoCore.LauncherMode（検証できるようにライブラリ側に置いた）
    typealias Mode = LauncherMode

    /// メモを開いてほしいときに呼ぶ。AppDelegate が繋ぐ。
    var onOpenNote: (() -> Void)?
    /// 初めての案内を、もう一度出す
    func replayWelcome() {
        store.settings.welcomeDone = false
        store.settings.welcomeShows = 0
        store.saveSettings()
        show(.all)
    }

    /// 不具合の記録を見せる（設定と入口の両方から呼ぶ）
    var onShowProblems: (() -> Void)?
    /// 入口の検索から、書き置きの1枚を名指しで開く
    var onOpenNoteItem: ((Note) -> Void)?
    /// 設定を開いてほしいときに呼ぶ。AppDelegate が繋ぐ。
    var onOpenSettings: (() -> Void)?
    /// 棚の「＋」＝設定の「アプリのキー」へ連れていく
    var onAddShelfApp: (() -> Void)?

    private let store: Store
    private let windowManager: WindowManager
    private let watcher: ClipboardWatcher
    /// 窓の交通整理（戻り先の記録と、他の窓をどかす手配）
    private let coordinator: PanelCoordinator

    private let panel: KeyPanel
    private let searchField = NSTextField()
    private let chip = ChipView(text: "")
    /// 検索欄の下に並べる、よく使うアプリの棚（2026-08-04「アプリへのリンクを作って欲しい」）
    private let appShelf = AppShelfView()
    /// 初めての人に「この窓を出すキー」だけを伝える帯（棚と同じ場所に出す）
    private let welcomeBand = WelcomeBandView(frame: .zero)
    /// 窓を出すキーが他のアプリに取られていて登録できなかったか
    var launcherKeyFailed = false
    /// 棚と一覧の境目
    private let shelfDivider = HairlineView(frame: .zero)
    /// 検索欄の左の虫眼鏡（入口にいるときだけ。札が出るときは札に譲る）
    private let searchGlyph = NSImageView()
    private let tableView = NonFocusingTableView()
    private let scrollView = NSScrollView()
    /// 下の帯。左＝今の状態／右＝押せるキー
    private let hintBar = HintBarView()
    /// 一覧が空のときに真ん中へ出す案内（空白のまま放置しないため）
    private let emptyState = EmptyStateView()
    /// 右半分。選んでいる1件の中身を大きく出す（コピー履歴と定型文だけ）
    private let previewPane = PreviewPaneView(frame: .zero)
    /// 一覧とプレビューの間の縦の仕切り
    private let paneDivider = HairlineView(frame: .zero)

    /// ファイル検索の絞り込みの帯（プルダウン＋条件の保存）。files のときだけ出す
    private let filterBar = NSView()
    private let scopePopup = ChipPopUpButton()
    private let kindPopup = ChipPopUpButton()
    private let datePopup = ChipPopUpButton()
    private let placePopup = ChipPopUpButton()
    private let sortPopup = ChipPopUpButton()
    private let saveSearchButton = ChipButton(title: "☆ 条件を保存")
    /// プルダウンを組み立て直すときに action が飛ぶのを抑える印
    private var isRebuildingFilters = false

    /// 畳んだコマンド（「フォルダを開く」等）を開いている最中。
    /// 検索語と同じく、行き先を変えたら捨てる。
    private var openGroup: (title: String, items: [LauncherItem])?

    /// 書類・デスクトップ・ダウンロードを読む許可の確認を、この起動でもう済ませたか
    private var probedProtectedFolders = false
    /// 読めなかったフォルダの名前（空なら全部読めている）
    private var deniedFolderNames: [String] = []

    /// 入口の下に足す「外の世界」の最大件数。
    /// ⚠️ 少なくしておく。ここが増えるほど、上の並び（行き先・コマンド・アプリ）が下へ押される
    static let extraLimit = 4

    private var mode: Mode = .all
    private var appItems: [LauncherItem] = []
    /// 見つけた全部（出さないものも持っておく。設定画面で戻せるようにするため）
    private var appRecords: [AppRecord] = []
    private var results: [(item: LauncherItem, result: FuzzyMatcher.Result)] = []
    /// 貼り付け先＝テモトを開く前まで前面だったアプリ。
    /// 3つの窓で1つを共有する（検索窓→メモと渡り歩いても見失わないように）。
    private var previousApp: NSRunningApplication? { coordinator.previousApp }
    /// テモトを開く前に、その相手で使っていた窓。
    /// ⚠️ 貼り付けのときに**その窓だけ**を前に出すために要る。
    /// アプリだけ前に出すと、ブラウザのように窓を何枚も開くアプリでは別の窓が出てくる
    private var previousWindow: AXUIElement? { coordinator.previousWindow }
    /// {query} の入力を待っている項目
    private var pendingItem: LauncherItem?
    /// 閉じている最中か（閉じる合図が複数の道から同時に来ても1回で済ませる）
    private var isClosing = false
    /// 漢字の読みの作り置き（`teikei` で「定型文」を引くため）
    private let readings = ReadingIndex()

    /// ファイル検索（Spotlight）。
    /// ⚠️ 検索語も結果もどこにも保存しない。窓を閉じたら消える。
    private let fileSearcher = FileSearcher()
    private var fileResults: [LauncherItem] = []
    /// 計算の履歴（新しい順）。⚠️ ディスクには残さない。
    /// 打った式には金額や口座の数字が入りうるので、窓を閉じたら消える方が安全
    private var calcLines: [CalcLine.Line] = []
    /// 探している最中か（空の一覧を「0件」と誤解させないため）
    private var isSearchingFiles = false
    /// Quick Look を出している最中か。
    /// ⚠️ Quick Look は自分がキーウィンドウになるので、そのままだと
    /// windowDidResignKey が走って検索窓が消える（＝プレビューだけが宙に浮く）。
    private var isPreviewing = false
    /// Quick Look に見せているファイル
    private var previewURLs: [URL] = []
    /// 確認ダイアログ（☆保存・⌘E編集）を出している最中か。
    /// ⚠️ Quick Look と同じ罠: ダイアログに焦点が移ると外クリック扱いで窓が裏で閉じる
    private var isShowingDialog = false
    /// 窓の地（行き先の色をここへ差す）
    private weak var backdrop: BackdropView?

    static let panelWidth: CGFloat = 720
    /// 窓の高さ。
    /// ⚠️ 2026-08-05 に 460 → 520 へ。行き先が7つになり、棚を出していると
    /// **5つしか見えていなかった**（メモと文字読み取りが下の帯に隠れ、スクロールしないと分からない）。
    /// 作者「これコピー履歴や定型文と同じメニューに追加お願い」の狙いは
    /// 「打たなくても目に入る」ことなので、見えない位置に置いたら足した意味が無い。
    /// 計算: 536 − 検索欄60 − 下の帯38 − 棚66 = 372pt。見出し30 + 46×7 = 352 なので 20pt の余裕。
    /// ⚠️ ちょうど収まる高さ（520＝残り4pt）にはしない。表の内側の余白が数pt入るだけで
    /// 最後の1行が黙って消える。余裕は「見えなくなる事故」を防ぐための費用。
    private static let panelHeight: CGFloat = 536
    static let searchRowHeight: CGFloat = 60
    static let hintRowHeight: CGFloat = 38
    /// ファイル検索の絞り込みの帯の高さ
    private static let filterRowHeight: CGFloat = 36
    /// 2ペインのときの一覧の幅。残り（約420pt）がプレビュー。
    /// Raycastのコピー履歴とほぼ同じ配分（一覧は題名が読めれば足り、広さは中身に使う）
    private static let listPaneWidth: CGFloat = 300

    /// コピー履歴と定型文は「一覧＋プレビュー」の2ペインで出す。
    ///
    /// ⚠️ 2ペインにする理由（2026-07-30 作者「画像の表示がやっぱりわかりにくい」）。
    /// 一覧の行に絵を押し込む方向は、行を80ptへ高くしても解決しなかった。
    /// 絵は右半分で大きく見せ、一覧は「探して選ぶ」ことに徹する。
    /// 文字の履歴も、切り詰めない全文が右に出るので貼る前に中身を確かめられる。
    private var isTwoPane: Bool {
        pendingItem == nil && (mode == .clipboard || mode == .snippets)
    }

    init(store: Store, windowManager: WindowManager, watcher: ClipboardWatcher, coordinator: PanelCoordinator) {
        self.store = store
        self.windowManager = windowManager
        self.watcher = watcher
        self.coordinator = coordinator

        panel = KeyPanel(
            contentRect: NSRect(x: 0, y: 0, width: LauncherController.panelWidth, height: LauncherController.panelHeight),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        super.init()

        buildPanel()
        // 結果が届いたら一覧に流し込む。
        // 打ち直した後に古い答えが届くことがあるので、必ず今の検索語と照合してから使う。
        fileSearcher.onResults = { [weak self] raw, hits in
            guard let self, self.mode == .files, raw == self.searchField.stringValue else { return }
            let home = NSHomeDirectory()
            self.isSearchingFiles = false
            self.fileResults = hits.map { LauncherItem.from($0, home: home) }
            self.reload()
        }
        fileSearcher.onSearching = { [weak self] raw in
            guard let self, self.mode == .files, raw == self.searchField.stringValue else { return }
            self.isSearchingFiles = true
            self.refreshFileHint()
        }
        coordinator.register(
            .launcher,
            isVisible: { [weak self] in self?.panel.isVisible ?? false },
            close: { [weak self] reason in self?.close(reason: reason) }
        )
        // アプリ一覧の走査はディスクを読むので、開くたびではなく起動時に一度だけ
        rescanApps()
    }

    /// インストール済みアプリを数え直す（メニューから手動で呼ぶ）
    func rescanApps() {
        appRecords = AppCatalog.scanAll(extraFolders: store.settings.appFolders)
        rebuildAppItems()
    }

    /// 設定で出す/出さないを変えたときに呼ぶ。
    /// ディスクは読み直さない（もう手元にあるので、押した瞬間に反映される）。
    func rebuildAppItems() {
        appItems = AppCatalog.items(from: appRecords, settings: store.settings)
    }

    /// 設定画面に渡す「見つかった全部」（隠しているものも含む）
    var allAppRecords: [AppRecord] { appRecords }

    /// 履歴の中身が後から変わったときに呼ぶ（絵の文字を読み終えたときなど）。
    ///
    /// ⚠️ 開いていないときは何もしない。次に開いたときに作り直すので、
    /// 閉じている窓のために描き直す意味がない。
    /// 開いているときは、選んでいた行が動かないように番号を覚えてから戻す。
    func clipsChanged() {
        guard panel.isVisible else { return }
        let selected = tableView.selectedRow
        reload()
        if selected >= 0, selected < results.count {
            tableView.selectRowIndexes(IndexSet(integer: selected), byExtendingSelection: false)
        }
    }

    /// 設定が変わったときに呼ぶ。
    /// 今いる行き先を切られていたら入口へ戻す（開いたまま空の画面に取り残されないように）。
    func settingsChanged() {
        rebuildAppItems()
        // コマンドを直したかもしれないので、開いていた畳みは作り直させる
        openGroup = nil
        if !store.settings.isVisible(mode) {
            mode = .all
            pendingItem = nil
            searchField.stringValue = ""
            refreshChrome()
        }
        if panel.isVisible { reload() }
    }

    // MARK: - 画面の組み立て

    private func buildPanel() {
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.delegate = self
        panel.keyEquivalentHandler = { [weak self] event in self?.handleKeyEquivalent(event) ?? false }

        let width = LauncherController.panelWidth
        let height = LauncherController.panelHeight
        let searchRow = LauncherController.searchRowHeight
        let hintRow = LauncherController.hintRowHeight

        // 窓の地は BackdropView（すりガラス＋薄い覆い＋細い縁）にそろえる。
        // ⚠️ ここで材質を書かない。3つの窓で必ず同じものを使うため
        let container = BackdropView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        backdrop = container
        panel.contentView = container

        searchField.isBordered = false
        searchField.drawsBackground = false
        searchField.focusRingType = .none
        searchField.font = .systemFont(ofSize: 20, weight: .regular)

        // 検索欄の左に虫眼鏡（Spotlightと同じ目印。「ここに打つ」が一目で伝わる）
        searchGlyph.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 17, weight: .medium))
        searchGlyph.contentTintColor = .tertiaryLabelColor
        container.addSubview(searchGlyph)
        searchField.delegate = self
        searchField.cell?.usesSingleLineMode = true
        searchField.frame = NSRect(x: Theme.Space.edge, y: height - searchRow + 15, width: width - Theme.Space.edge * 2, height: 30)
        container.addSubview(searchField)

        chip.isHidden = true
        container.addSubview(chip)

        container.addSubview(HairlineView.full(y: height - searchRow, width: width))

        appShelf.onOpen = { [weak self] path in
            guard let self else { return }
            self.close(reason: .finished)
            ActionRunner.open(appPath: path)
        }
        appShelf.onAdd = { [weak self] in
        // ⚠️ 先に閉じない。閉じると窓が1つも無くなってテモトが前面から外れ、
        // そのあとの「前に出る」がmacOSに拒否されて、開いた窓が**後ろに回る**
        // （2026-08-04「＋ボタン押しても何も反応しない」＝実は後ろで開いていた）。
        // 開く側（PanelCoordinator.willOpen）が先に閉じてくれるので、任せる。
            self?.onAddShelfApp?()
        }
        container.addSubview(appShelf)
        container.addSubview(welcomeBand)
        container.addSubview(shelfDivider)

        scrollView.frame = NSRect(x: 0, y: hintRow, width: width, height: height - searchRow - hintRow)
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        // 一覧の上下に少しだけ余白を取る。行が仕切り線にぴったり接すると窮屈に見える
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.contentInsets = NSEdgeInsets(top: 6, left: 0, bottom: 6, right: 0)

        tableView.headerView = nil
        // ⚠️ 行ごとに高さを変える（tableView(_:heightOfRow:) を実装している）。
        // ここの値は「まだ聞きに来ていない行」の当たりを付けるためだけに使われる
        tableView.rowHeight = Theme.Row.standard
        tableView.backgroundColor = .clear
        // ⚠️ `.inset` は macOS が勝手に左右へ余白を入れる。
        // 選んだ行の丸みは自分で描く（LauncherRowBackground）ので、二重に効くと左端がずれる。
        tableView.style = .plain
        // ⚠️ `.none` にはしない。`.none` だと行に「選ばれている」という状態自体が伝わらず、
        // 自前で描く道（LauncherRowBackground.drawSelection）も呼ばれなくなる。
        // 見た目は行の側で全部描き替えるので、ここは既定のままでよい。
        tableView.selectionHighlightStyle = .regular
        tableView.allowsEmptySelection = true
        // ⚠️ コピー履歴でだけ複数選べる（2026-08-09 作者「コピーする際に複数選択したい。」）。
        // 表そのものは常に許し、**行き先を変えるたびに選択を1つへ戻す**ことで
        // 他の行き先に複数選択が漏れないようにする（表の設定を出し入れすると
        // 選択が飛ぶ・キーの効きが変わる等の副作用が出る）
        tableView.allowsMultipleSelection = true
        tableView.intercellSpacing = NSSize(width: 0, height: 2)
        tableView.dataSource = self
        tableView.delegate = self
        // 右クリックの品書き。キーを覚えていなくても、消す・コピーする道がある状態にする
        tableView.contextMenuProvider = { [weak self] row in self?.contextMenu(forRow: row) }
        tableView.target = self
        tableView.doubleAction = #selector(rowDoubleClicked)
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("main"))
        // ⚠️ 幅を明示しないと NSTableColumn の初期値（16pt）のままになる。
        // 表そのものは窓幅いっぱいでも、行は16ptの帯の中に描かれるので、
        // 題名が4文字くらいで「Find...」と切れ、右寄せのはずの種類ラベル（履歴）が
        // 題名の上に重なる。窓は広いのに文字だけ潰れて見える原因はこれ。
        column.width = width
        column.minWidth = 200
        column.maxWidth = .greatestFiniteMagnitude
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        // 窓の幅が変わったときに列も追従させる
        tableView.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        tableView.autoresizingMask = [.width]
        tableView.sizeLastColumnToFit()
        scrollView.documentView = tableView
        container.addSubview(scrollView)

        // 一覧と同じ場所に重ねる。出す・出さないだけで切り替える
        emptyState.frame = scrollView.frame
        emptyState.isHidden = true
        container.addSubview(emptyState)

        // 右半分のプレビューと縦の仕切り。出すかどうかは layoutContentArea が決める
        paneDivider.isHidden = true
        container.addSubview(paneDivider)
        previewPane.isHidden = true
        container.addSubview(previewPane)

        buildFilterBar()
        container.addSubview(filterBar)

        container.addSubview(HairlineView.full(y: hintRow, width: width))

        hintBar.frame = NSRect(x: 0, y: 0, width: width, height: hintRow)
        hintBar.autoresizingMask = [.width]
        // 札はクリックでも効く（2026-07-30 作者「ボタンも欲しい」）。
        // キーの説明とボタンを別々に置かず、同じ札が両方を兼ねる
        hintBar.onAction = { [weak self] action in self?.runHintAction(action.keys) }
        container.addSubview(hintBar)
    }

    /// 下の帯の札がクリックされたとき。キーを押したのと同じことを起こす。
    /// ⚠️ ここに独自の動きを書かない。キーの道とボタンの道で結果が違うと必ず迷う。
    private func runHintAction(_ keys: String) {
        switch keys {
        case "⏎":
            activateSelection()
        case "↑↓":
            moveSelection(by: 1)
        case "Tab":
            guard pendingItem == nil else { return }
            goTo(mode.next(within: enabledModes))
        case "esc":
            goBack()
        case "⌘,":
        // ⚠️ 先に閉じない。閉じると窓が1つも無くなってテモトが前面から外れ、
        // そのあとの「前に出る」がmacOSに拒否されて、開いた窓が**後ろに回る**
        // （2026-08-04「＋ボタン押しても何も反応しない」＝実は後ろで開いていた）。
        // 開く側（PanelCoordinator.willOpen）が先に閉じてくれるので、任せる。
            onOpenSettings?()
        case "⌘C":
            copySelectionOnly()
        case "⌘P":
            togglePinOnSelection()
        case "⌘⌫":
            if let item = selectedItem, case .savedSearch(let saved) = item.kind {
                deleteSelectedSavedSearch(saved)
            } else if let item = selectedItem, case .snippet(let snippet) = item.kind {
                deleteSnippet(snippet)
            } else if let item = selectedItem, case .quicklink(let link) = item.kind {
                deleteQuicklink(link)
            } else {
                deleteSelectedClips()
            }
        case "⌘⏎":
            guard let item = selectedItem, case .file(let hit) = item.kind else { return }
            close(reason: .finished)
            ActionRunner.reveal(hit.path)
        case "⌘Y":
            previewSelection()
        case "⌥⏎":
            guard let item = selectedItem, case .file(let hit) = item.kind else { return }
            copyFileItself(hit)
        case "⌘E":
            if let item = selectedItem, case .savedSearch(let saved) = item.kind {
                editSelectedSavedSearch(saved)
            } else if let item = selectedItem, case .snippet(let snippet) = item.kind {
                editSnippet(snippet)
            } else if let item = selectedItem, case .quicklink(let link) = item.kind {
                editQuicklink(link)
            }
        case "⌘N":
            if mode == .snippets { editSnippet(nil) }
            if mode == .links { editQuicklink(nil) }
        default:
            break
        }
    }

    // MARK: - ファイル検索の絞り込みの帯

    /// プルダウン（種類・期間・場所・並べ替え）と「条件を保存」。
    ///
    /// ⚠️ 作りの芯: プルダウンは**打つ代わりに選べる口**でしかない。
    /// 選んだ結果は文字（`pdf` `今月`）として検索欄に入り、
    /// 逆に文字で打てばプルダウンがそれを指す（正は常に検索欄の文字）。
    /// 変換は TemotoCore.FileQueryEdit（検証済み）。
    private func buildFilterBar() {
        filterBar.isHidden = true

        for (popup, action) in [
            (scopePopup, #selector(scopePicked)),
            (kindPopup, #selector(kindPicked)),
            (datePopup, #selector(datePicked)),
            (placePopup, #selector(placePicked)),
            (sortPopup, #selector(sortPicked)),
        ] {
            popup.target = self
            popup.action = action
            filterBar.addSubview(popup)
        }

        // 探す対象（2026-07-30 作者「本文検索とファイル名検索を選択できる様に」）
        for scope in FileSearchScope.allCases { scopePopup.addItem(withTitle: scope.title) }
        kindPopup.addItem(withTitle: "種類: すべて")
        for kind in FileKind.allCases { kindPopup.addItem(withTitle: kind.title) }
        datePopup.addItem(withTitle: "期間: いつでも")
        for date in FileDateFilter.allCases { datePopup.addItem(withTitle: date.title) }
        sortPopup.addItem(withTitle: "並び: 更新順")
        for sort in FileSort.allCases where sort != .recent { sortPopup.addItem(withTitle: sort.title) }
        rebuildPlacePopup()

        saveSearchButton.target = self
        saveSearchButton.action = #selector(saveCurrentSearch)
        filterBar.addSubview(saveSearchButton)

        layoutFilterBar()
    }

    /// 場所の候補は「定番の場所」＋設定の「探す場所」。設定が変わるので入るたびに組み直す。
    /// ⚠️ 空白入りのパスは載せない（検索欄の言葉は空白で区切るので、token が割れて壊れる）
    private func rebuildPlacePopup() {
        let selected = placePopup.titleOfSelectedItem
        placePopup.removeAllItems()
        placePopup.addItem(withTitle: "場所: どこでも")
        for place in FileScope.places { placePopup.addItem(withTitle: place.title) }
        for folder in store.settings.fileSearch.folders where !folder.contains(" ") && !folder.contains("　") {
            placePopup.addItem(withTitle: folder)
        }
        if let selected, placePopup.itemTitles.contains(selected) {
            placePopup.selectItem(withTitle: selected)
        }
    }

    private func layoutFilterBar() {
        let height = LauncherController.filterRowHeight
        let controlH = Theme.Radius.capsule * 2   // Apple の Md ボタンと同じ高さ24
        let y = (height - controlH) / 2
        var x = Theme.Space.edge
        for (popup, width) in [(scopePopup, CGFloat(104)), (kindPopup, 100), (datePopup, 110),
                               (placePopup, 122), (sortPopup, 108)] {
            popup.frame = NSRect(x: x, y: y, width: width, height: controlH)
            x += width + 8
        }
        saveSearchButton.sizeToFit()
        let buttonWidth = saveSearchButton.frame.width
        saveSearchButton.frame = NSRect(
            x: LauncherController.panelWidth - Theme.Space.edge - buttonWidth,
            y: y, width: buttonWidth, height: controlH)
    }

    /// 検索欄の文字に合わせて、プルダウンの指す先を合わせ直す（文字が正・プルダウンは鏡）
    private func refreshFilterBar() {
        guard mode == .files else { return }
        isRebuildingFilters = true
        defer { isRebuildingFilters = false }
        let query = FileQuery.parse(searchField.stringValue)

        if let index = FileSearchScope.allCases.firstIndex(of: query.scope) {
            scopePopup.selectItem(at: index)
        }
        if let kind = query.kinds.first, let index = FileKind.allCases.firstIndex(of: kind) {
            kindPopup.selectItem(at: index + 1)
        } else {
            kindPopup.selectItem(at: 0)
        }
        if let date = query.date, let index = FileDateFilter.allCases.firstIndex(of: date) {
            datePopup.selectItem(at: index + 1)
        } else {
            datePopup.selectItem(at: 0)
        }
        let sortsWithoutRecent = FileSort.allCases.filter { $0 != .recent }
        if query.sort != .recent, let index = sortsWithoutRecent.firstIndex(of: query.sort) {
            sortPopup.selectItem(at: index + 1)
        } else {
            sortPopup.selectItem(at: 0)
        }
        if let folder = query.folder {
            let lower = folder.lowercased()
            if let place = FileScope.places.first(where: { $0.words.contains(lower) }) {
                placePopup.selectItem(withTitle: place.title)
            } else if placePopup.itemTitles.contains(folder) {
                placePopup.selectItem(withTitle: folder)
            } else {
                placePopup.selectItem(at: 0)
            }
        } else {
            placePopup.selectItem(at: 0)
        }
    }

    /// プルダウンで選んだ結果を検索欄の文字へ流し込み、検索し直す
    private func applyEditedQuery(_ newRaw: String) {
        searchField.stringValue = newRaw
        runFilesSearch()
    }

    /// 書類・デスクトップ・ダウンロードを読めるか、実際に読んで確かめる。
    ///
    /// ⚠️ 副作用が本命。許可が無い（または作り直しで外れた）とき、
    /// ここで初めて macOS の許可ダイアログが出る。出さないままだと、
    /// Spotlight が「書類」の中身を黙って間引き、**実在するファイルが0件に見える**
    /// （2026-07-30 作者「裁判_チケット規約 が見つかりません。なぜ？？」の正体）。
    ///
    /// ダイアログが出ている間は読み込みが返らないので、裏のスレッドで確かめる。
    private func probeProtectedFoldersIfNeeded() {
        guard mode == .files, !probedProtectedFolders else { return }
        probedProtectedFolders = true
        let home = NSHomeDirectory()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let denied = FolderAccess.deniedPlaceNames(home: home)
            DispatchQueue.main.async {
                guard let self else { return }
                self.deniedFolderNames = denied
                if !denied.isEmpty {
                    Toast.show("\(denied.joined(separator: "・"))を読む許可がありません。"
                               + "その中のファイルは検索に出ません（システム設定 → プライバシーとセキュリティ → ファイルとフォルダ）",
                               isError: true)
                }
                self.refreshFileHint()
                // 許可を押した直後なら、今の検索をやり直すと間引かれていた分が出てくる
                if !self.searchField.stringValue.trimmingCharacters(in: .whitespaces).isEmpty {
                    self.fileSearcher.search(self.searchField.stringValue, settings: self.store.settings.fileSearch)
                }
            }
        }
    }

    /// files の検索を今の文字で回し直す（打ったときと同じ道）
    private func runFilesSearch() {
        guard mode == .files else { return }
        fileSearcher.search(searchField.stringValue, settings: store.settings.fileSearch)
        if searchField.stringValue.trimmingCharacters(in: .whitespaces).isEmpty {
            fileResults = []
            isSearchingFiles = false
        }
        reload()
        refreshFilterBar()
    }

    @objc private func scopePicked() {
        guard !isRebuildingFilters else { return }
        let index = scopePopup.indexOfSelectedItem
        guard index >= 0, index < FileSearchScope.allCases.count else { return }
        applyEditedQuery(FileQueryEdit.replacingScope(searchField.stringValue,
                                                      with: FileSearchScope.allCases[index]))
    }

    @objc private func kindPicked() {
        guard !isRebuildingFilters else { return }
        let index = kindPopup.indexOfSelectedItem
        let kind: FileKind? = index > 0 ? FileKind.allCases[index - 1] : nil
        applyEditedQuery(FileQueryEdit.replacingKind(searchField.stringValue, with: kind))
    }

    @objc private func datePicked() {
        guard !isRebuildingFilters else { return }
        let index = datePopup.indexOfSelectedItem
        let date: FileDateFilter? = index > 0 ? FileDateFilter.allCases[index - 1] : nil
        applyEditedQuery(FileQueryEdit.replacingDate(searchField.stringValue, with: date))
    }

    @objc private func sortPicked() {
        guard !isRebuildingFilters else { return }
        let index = sortPopup.indexOfSelectedItem
        let sorts = FileSort.allCases.filter { $0 != .recent }
        let sort: FileSort? = index > 0 ? sorts[index - 1] : nil
        applyEditedQuery(FileQueryEdit.replacingSort(searchField.stringValue, with: sort))
    }

    @objc private func placePicked() {
        guard !isRebuildingFilters else { return }
        let index = placePopup.indexOfSelectedItem
        guard index > 0 else {
            applyEditedQuery(FileQueryEdit.replacingPlace(searchField.stringValue, with: nil))
            return
        }
        let title = placePopup.itemTitles[index]
        // 定番の場所はその言葉（デスクトップ等）、設定のフォルダはパスをそのまま
        let word = FileScope.places.first { $0.title == title }.map { $0.words[0] } ?? title
        applyEditedQuery(FileQueryEdit.replacingPlace(searchField.stringValue, with: word))
    }

    /// 今の条件に名前を付けて取っておく。
    /// 保存するのは検索欄の文字そのもの（実行は「入れて打った」と同じにする）。
    @objc private func saveCurrentSearch() {
        let raw = searchField.stringValue.trimmingCharacters(in: .whitespaces)
        guard !raw.isEmpty else {
            Toast.show("先に条件を打つか、プルダウンで選んでください")
            return
        }

        let alert = NSAlert()
        alert.messageText = "この検索条件に名前を付けて保存"
        let summary = FileQuery.parse(raw).summary(searchesContent: store.settings.fileSearch.searchesContent)
        alert.informativeText = summary.isEmpty ? raw : summary
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.placeholderString = "例: 今月の請求書PDF"
        alert.accessoryView = field
        alert.addButton(withTitle: "保存")
        alert.addButton(withTitle: "やめる")
        isShowingDialog = true
        NSApp.activate()
        alert.window.initialFirstResponder = field
        let response = alert.runModal()
        isShowingDialog = false

        // 警告ダイアログが焦点を持っていったので、検索窓へ返す
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(searchField)

        guard response == .alertFirstButtonReturn else { return }
        let name = field.stringValue.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else {
            Toast.show("名前が空だったので保存しませんでした")
            return
        }
        // 同じ名前は同じ場所のまま上書き（並びの決まりは SavedSearchList・検証済み）
        store.settings.fileSearch.saved =
            SavedSearchList.upserting(store.settings.fileSearch.saved, name: name, query: raw)
        store.saveSettings()
        Toast.show("保存しました: \(name)（検索欄を空にすると一覧に出ます）")
    }

    /// 保存した検索を消す（⌘⌫）。
    private func deleteSelectedSavedSearch(_ saved: SavedFileSearch) {
        let row = tableView.selectedRow
        store.settings.fileSearch.saved =
            SavedSearchList.removing(store.settings.fileSearch.saved, name: saved.name)
        store.saveSettings()
        reload()
        if !results.isEmpty {
            let next = min(max(row, 0), results.count - 1)
            tableView.selectRowIndexes(IndexSet(integer: next), byExtendingSelection: false)
        }
        Toast.show("消しました: \(saved.name)")
    }

    /// 定型文を作る・直す（⌘N / ⌘E）。existing が nil なら新規。
    ///
    /// 2026-07-31 作者「定型文、新規作成できない。この画面からできるようにしたい。」
    /// ＝それまで定型文を作る入口がどこにも無かった（初期の4つを使うだけだった）。
    ///
    /// ⚠️ 同日、続けて「保存を押しても保存されない」。
    /// 初版は本文や名前が空だと**打った内容ごと捨てて黙って閉じる**作りだった。
    /// ⏎ が「保存」に化けて本文が空のまま閉じれば、書いたものは戻らない。
    /// 直した点は3つ:
    ///   1. 足りないときは**打った内容を入れたまま開き直す**（何があっても入力を捨てない）
    ///   2. 名前が空なら本文の1行目から付ける（突き返さない。判断は TemotoCore.SnippetDraft）
    ///   3. ⏎ は「次の欄へ」。保存は「保存」ボタンか ⌘⏎（⏎で半端に閉じない）
    private func editSnippet(_ existing: Snippet?) {
        // 鍵が無ければ書き込みは黙って捨てられる。書かせる前に言う
        guard store.canPersistSecrets else {
            Toast.show("暗号鍵が用意できていないので、いま作っても保存できません（メニューの「暗号鍵を作り直す」）", isError: true)
            return
        }

        var draft = SnippetDraftValues(
            title: existing?.title ?? "",
            keyword: existing?.keyword ?? "",
            body: existing?.body ?? ""
        )
        var problem: String?

        // 足りないうちは、打った内容を持ったまま開き直す
        while true {
            guard let filled = runSnippetDialog(isNew: existing == nil, values: draft, problem: problem) else {
                return      // 「やめる」を押したときだけ捨てる
            }
            draft = filled
            if SnippetDraft.isEmptyBody(draft.body) {
                problem = "本文がまだ空です。貼り付けたい文を書いてから「保存」を押してください。"
                continue
            }
            break
        }

        let title = SnippetDraft.resolvedTitle(title: draft.title, body: draft.body)
        let keyword = draft.keyword.trimmingCharacters(in: .whitespaces)

        if let existing, let index = store.snippets.firstIndex(where: { $0.id == existing.id }) {
            store.snippets[index].title = title
            store.snippets[index].keyword = keyword
            store.snippets[index].body = draft.body
        } else {
            store.snippets.append(Snippet(title: title, keyword: keyword, body: draft.body))
        }
        // 書けたかどうかを必ず見る。書けていないのに「保存しました」と言わない
        let wrote = store.saveSnippets()
        reload()
        // 一覧の中の、いま保存したものを選んでおく（保存できたことが目で分かる）
        if let row = results.firstIndex(where: {
            if case .snippet(let s) = $0.item.kind { return s.title == title }
            return false
        }) {
            tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            tableView.scrollRowToVisible(row)
        }
        guard wrote else {
            Toast.show("「\(title)」をファイルに書けませんでした。テモトを開いている間は使えますが、"
                       + "終了すると消えます（メニューの「暗号鍵を作り直す」で直ります）", isError: true)
            return
        }
        Toast.show(existing == nil ? "定型文「\(title)」を作りました" : "定型文「\(title)」を保存しました")
    }

    /// 定型文ダイアログの中身。やめたときだけ nil を返す。
    private func runSnippetDialog(isNew: Bool, values: SnippetDraftValues, problem: String?) -> SnippetDraftValues? {
        let alert = NSAlert()
        alert.messageText = isNew ? "定型文を新しく作る" : "定型文を編集"
        // ⚠️ 足りない理由は必ず一番上に出す。下の小さな帯（Toast）は閉じた後にしか出せず、
        // 「何が足りなかったのか」がダイアログの中で分からないと同じことを繰り返す
        var lines = ["本文には差し込みが使えます: {date} {date:M月d日} {time} {clipboard} {query}",
                     "タグは空白かカンマで区切ります（例: ABC 台帳 共有）。打つと、そのタグのリンクだけ出せます。",
                     "⏎ は次の欄へ移ります。保存は「保存」ボタン（⌘⏎ でも保存）。"]
        if let problem { lines.insert("⚠️ " + problem, at: 0) }
        alert.informativeText = lines.joined(separator: "\n")
        if problem != nil { alert.alertStyle = .warning }

        let container = NSView(frame: NSRect(x: 0, y: 0, width: 360, height: 210))
        let nameLabel = NSTextField(labelWithString: "名前")
        nameLabel.font = .systemFont(ofSize: 11)
        nameLabel.frame = NSRect(x: 0, y: 182, width: 64, height: 16)
        let nameField = NSTextField(frame: NSRect(x: 70, y: 178, width: 290, height: 24))
        nameField.stringValue = values.title
        nameField.placeholderString = "例: 会社の住所（空なら本文の1行目から付けます）"
        let keywordLabel = NSTextField(labelWithString: "読みがな")
        keywordLabel.font = .systemFont(ofSize: 11)
        keywordLabel.frame = NSRect(x: 0, y: 150, width: 64, height: 16)
        let keywordField = NSTextField(frame: NSRect(x: 70, y: 146, width: 290, height: 24))
        keywordField.stringValue = values.keyword
        keywordField.placeholderString = "例: mails（入口で打つと本文が出る合言葉。検索の読みにも使う・空でも可）"
        let bodyLabel = NSTextField(labelWithString: "本文")
        bodyLabel.font = .systemFont(ofSize: 11)
        bodyLabel.frame = NSRect(x: 0, y: 118, width: 64, height: 16)
        let bodyScroll = NSScrollView(frame: NSRect(x: 70, y: 0, width: 290, height: 138))
        bodyScroll.hasVerticalScroller = true
        bodyScroll.borderType = .bezelBorder
        let bodyView = NSTextView(frame: NSRect(origin: .zero, size: bodyScroll.contentSize))
        bodyView.font = .systemFont(ofSize: 13)
        bodyView.isRichText = false
        bodyView.allowsUndo = true
        bodyView.autoresizingMask = [.width]
        bodyView.string = values.body
        bodyScroll.documentView = bodyView
        container.addSubview(nameLabel)
        container.addSubview(nameField)
        container.addSubview(keywordLabel)
        container.addSubview(keywordField)
        container.addSubview(bodyLabel)
        container.addSubview(bodyScroll)
        nameField.nextKeyView = keywordField
        keywordField.nextKeyView = bodyView
        alert.accessoryView = container

        // ⏎ を「次の欄へ」に変える係。ダイアログが閉じるまでこの変数が持ち主
        // （delegate は弱い参照なので、ここで持っていないと即いなくなる）
        let chain = SnippetFieldChain(next: [
            ObjectIdentifier(nameField): keywordField,
            ObjectIdentifier(keywordField): bodyView,
        ])
        nameField.delegate = chain
        keywordField.delegate = chain

        alert.addButton(withTitle: "保存")
        alert.addButton(withTitle: "やめる")
        // ⏎ 単独で閉じないようにする（本文が空のまま閉じて、書いたものを失う道を断つ）
        alert.buttons[0].keyEquivalent = "\r"
        alert.buttons[0].keyEquivalentModifierMask = [.command]

        isShowingDialog = true
        NSApp.activate()
        // 新規は名前から、直すときは本文から（直したいのはたいてい中身）
        alert.window.initialFirstResponder = isNew ? nameField : bodyView
        let response = alert.runModal()
        isShowingDialog = false

        // ダイアログが焦点を持っていったので、検索窓へ返す
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(searchField)

        guard response == .alertFirstButtonReturn else { return nil }
        return SnippetDraftValues(
            title: nameField.stringValue,
            keyword: keywordField.stringValue,
            body: bodyView.string
        )
    }

    /// リンクを作る・直す（⌘N / ⌘E）。existing が nil なら新規。
    ///
    /// 2026-07-31 作者「リンク追加できない。」
    /// ＝定型文と同じで、作る入口がどこにも無かった（初期の5件を使うだけだった）。
    /// 作りは定型文とそろえる（⏎は次の欄・保存はボタンか⌘⏎・足りなければ開き直す）。
    private func editQuicklink(_ existing: Quicklink?) {
        var draft = (title: existing?.title ?? "", url: existing?.url ?? "",
                     tags: existing?.tagLine ?? "")
        var problem: String?

        while true {
            guard let filled = runQuicklinkDialog(isNew: existing == nil, values: draft, problem: problem) else {
                return      // 「やめる」を押したときだけ捨てる
            }
            draft = filled
            let normalized = QuicklinkDraft.normalizedURL(draft.url)
            if normalized.isEmpty {
                problem = "行き先（URL）がまだ空です。開きたいページのURLを入れてください。"
                continue
            }
            guard QuicklinkDraft.isOpenable(normalized) else {
                problem = "この行き先は開けない形です: \(normalized)"
                draft.url = normalized      // 直しやすいように、整えた形を入れて開き直す
                continue
            }
            draft.url = normalized
            break
        }

        let title = QuicklinkDraft.resolvedTitle(title: draft.title, url: draft.url)
        let tags = Quicklink.parseTags(draft.tags)
        if let existing, let index = store.quicklinks.firstIndex(where: { $0.id == existing.id }) {
            store.quicklinks[index].title = title
            store.quicklinks[index].url = draft.url
            store.quicklinks[index].tags = tags
        } else {
            store.quicklinks.append(Quicklink(title: title, url: draft.url, tags: tags))
        }
        // 書けたかどうかを必ず見る。書けていないのに「保存しました」と言わない
        let wrote = store.saveQuicklinks()
        reload()
        if let row = results.firstIndex(where: {
            if case .quicklink(let l) = $0.item.kind { return l.title == title }
            return false
        }) {
            tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            tableView.scrollRowToVisible(row)
        }
        guard wrote else {
            Toast.show("「\(title)」をファイルに書けませんでした。テモトを開いている間は使えますが、終了すると消えます",
                       isError: true)
            return
        }
        Toast.show(existing == nil ? "リンク「\(title)」を作りました" : "リンク「\(title)」を保存しました")
    }

    /// リンクのダイアログ。やめたときだけ nil を返す。
    private func runQuicklinkDialog(
        isNew: Bool,
        values: (title: String, url: String, tags: String),
        problem: String?
    ) -> (title: String, url: String, tags: String)? {
        let alert = NSAlert()
        alert.messageText = isNew ? "リンクを新しく作る" : "リンクを編集"
        var lines = ["URLに {query} を入れると、検索欄に打った続きの言葉を差し込んで開けます"
                     + "（例: https://www.google.com/search?q={query}）。",
                     "⏎ は次の欄へ移ります。保存は「保存」ボタン（⌘⏎ でも保存）。"]
        if let problem { lines.insert("⚠️ " + problem, at: 0) }
        alert.informativeText = lines.joined(separator: "\n")
        if problem != nil { alert.alertStyle = .warning }

        // ⚠️ 3欄になったので背も伸ばす。伸ばし忘れると一番下の欄が枠から出て、
        // 「あるのに見えない欄」になる（押せない・気づけないの最悪の形）
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 380, height: 94))
        func label(_ text: String, y: CGFloat) -> NSTextField {
            let view = NSTextField(labelWithString: text)
            view.font = .systemFont(ofSize: 11)
            view.frame = NSRect(x: 0, y: y, width: 40, height: 16)
            return view
        }
        let nameField = NSTextField(frame: NSRect(x: 46, y: 66, width: 334, height: 24))
        nameField.stringValue = values.title
        nameField.placeholderString = "例: freee会計（空ならURLから付けます）"
        let urlField = NSTextField(frame: NSRect(x: 46, y: 34, width: 334, height: 24))
        urlField.stringValue = values.url
        urlField.placeholderString = "例: secure.freee.co.jp（https:// は省けます）"
        let tagField = NSTextField(frame: NSRect(x: 46, y: 2, width: 334, height: 24))
        tagField.stringValue = values.tags
        tagField.placeholderString = "例: ABC 台帳 共有（空でも構いません）"
        container.addSubview(label("名前", y: 70))
        container.addSubview(nameField)
        container.addSubview(label("URL", y: 38))
        container.addSubview(urlField)
        container.addSubview(label("タグ", y: 6))
        container.addSubview(tagField)
        nameField.nextKeyView = urlField
        urlField.nextKeyView = tagField
        tagField.nextKeyView = nameField
        alert.accessoryView = container

        // ⏎ は「次の欄へ」。最後の欄からは先頭へ戻す（⏎で半端に保存されない）
        let chain = SnippetFieldChain(next: [
            ObjectIdentifier(nameField): urlField,
            ObjectIdentifier(urlField): tagField,
            ObjectIdentifier(tagField): nameField,
        ])
        nameField.delegate = chain
        urlField.delegate = chain
        tagField.delegate = chain

        alert.addButton(withTitle: "保存")
        alert.addButton(withTitle: "やめる")
        alert.buttons[0].keyEquivalent = "\r"
        alert.buttons[0].keyEquivalentModifierMask = [.command]

        isShowingDialog = true
        NSApp.activate()
        alert.window.initialFirstResponder = isNew ? nameField : urlField
        let response = alert.runModal()
        isShowingDialog = false

        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(searchField)

        guard response == .alertFirstButtonReturn else { return nil }
        return (title: nameField.stringValue, url: urlField.stringValue, tags: tagField.stringValue)
    }

    /// リンクを消す（⌘⌫）。定型文と同じく一度だけ確認する
    private func deleteQuicklink(_ link: Quicklink) {
        let alert = NSAlert()
        alert.messageText = "リンク「\(link.title)」を消しますか？"
        alert.informativeText = link.url
        alert.alertStyle = .warning
        alert.addButton(withTitle: "消す")
        alert.addButton(withTitle: "やめる")
        isShowingDialog = true
        NSApp.activate()
        let response = alert.runModal()
        isShowingDialog = false
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(searchField)
        guard response == .alertFirstButtonReturn else { return }

        let row = tableView.selectedRow
        store.quicklinks.removeAll { $0.id == link.id }
        store.saveQuicklinks()
        reload()
        if !results.isEmpty {
            let next = min(max(row, 0), results.count - 1)
            tableView.selectRowIndexes(IndexSet(integer: next), byExtendingSelection: false)
        }
        Toast.show("消しました: \(link.title)")
    }

    /// 定型文を消す（⌘⌫）。
    /// コピー履歴と違って一度だけ確認する。履歴は流れていくものだが、
    /// 定型文は作者が書いたもので、取り戻す道が無い。
    private func deleteSnippet(_ snippet: Snippet) {
        let alert = NSAlert()
        alert.messageText = "定型文「\(snippet.title)」を消しますか？"
        alert.informativeText = "取り戻せません。"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "消す")
        alert.addButton(withTitle: "やめる")
        isShowingDialog = true
        NSApp.activate()
        let response = alert.runModal()
        isShowingDialog = false
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(searchField)
        guard response == .alertFirstButtonReturn else { return }

        let row = tableView.selectedRow
        store.snippets.removeAll { $0.id == snippet.id }
        store.saveSnippets()
        reload()
        if !results.isEmpty {
            let next = min(max(row, 0), results.count - 1)
            tableView.selectRowIndexes(IndexSet(integer: next), byExtendingSelection: false)
        }
        Toast.show("消しました: \(snippet.title)")
    }

    /// 保存した検索を直す（⌘E）。名前も条件もその場で書き換えられる。
    private func editSelectedSavedSearch(_ saved: SavedFileSearch) {
        let alert = NSAlert()
        alert.messageText = "保存した検索を編集"
        alert.informativeText = "名前と条件を書き換えられます。条件は検索欄に打つ言葉と同じ形です。"

        // 名前と条件の2段。ラベルが無いと、どちらの欄か分からない
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 64))
        let nameLabel = NSTextField(labelWithString: "名前")
        nameLabel.font = .systemFont(ofSize: 11)
        nameLabel.frame = NSRect(x: 0, y: 40, width: 40, height: 16)
        let nameField = NSTextField(frame: NSRect(x: 46, y: 36, width: 274, height: 24))
        nameField.stringValue = saved.name
        let queryLabel = NSTextField(labelWithString: "条件")
        queryLabel.font = .systemFont(ofSize: 11)
        queryLabel.frame = NSRect(x: 0, y: 8, width: 40, height: 16)
        let queryField = NSTextField(frame: NSRect(x: 46, y: 4, width: 274, height: 24))
        queryField.stringValue = saved.query
        queryField.placeholderString = "例: 請求書 pdf 今月 名前だけ"
        container.addSubview(nameLabel)
        container.addSubview(nameField)
        container.addSubview(queryLabel)
        container.addSubview(queryField)
        nameField.nextKeyView = queryField
        queryField.nextKeyView = nameField
        alert.accessoryView = container

        alert.addButton(withTitle: "保存")
        alert.addButton(withTitle: "やめる")
        isShowingDialog = true
        NSApp.activate()
        alert.window.initialFirstResponder = nameField
        let response = alert.runModal()
        isShowingDialog = false

        // ダイアログが焦点を持っていったので、検索窓へ返す
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(searchField)

        guard response == .alertFirstButtonReturn else { return }
        let newName = nameField.stringValue.trimmingCharacters(in: .whitespaces)
        let newQuery = queryField.stringValue.trimmingCharacters(in: .whitespaces)
        guard !newName.isEmpty else { Toast.show("名前が空なのでやめました"); return }
        guard !newQuery.isEmpty else { Toast.show("条件が空なのでやめました（消したいときは ⌘⌫）"); return }

        guard let updated = SavedSearchList.updating(
            store.settings.fileSearch.saved,
            originalName: saved.name, newName: newName, newQuery: newQuery) else {
            // 別の条件と同じ名前に改名しようとした。黙って片方を消すより、断って聞き直す
            Toast.show("「\(newName)」という名前は別の条件が使っています", isError: true)
            return
        }
        store.settings.fileSearch.saved = updated
        store.saveSettings()
        let row = tableView.selectedRow
        reload()
        if row >= 0, row < results.count {
            tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        }
        Toast.show("直しました: \(newName)")
    }

    // MARK: - 開閉

    /// - Parameter viaHotkey: 窓を出すキーで呼ばれたか（初めての案内を卒業させる合図）
    func toggle(_ mode: Mode, viaHotkey: Bool = false) {
        // ⚠️ 開く枝でも閉じる枝でも卒業させる。どちらも「キーを押せた」証拠。
        // 開いたときだけにすると、2回目に押して閉じた人が卒業できない
        if viaHotkey, mode == .all, Welcome.graduates(on: .launcherHotkey) {
            graduateWelcome()
        }
        if panel.isVisible && self.mode == mode && pendingItem == nil {
            close(reason: .hotkey)
        } else {
            show(mode)
        }
    }

    /// 初めての案内を終わりにする（1回だけ言葉を出す）
    private func graduateWelcome() {
        guard !store.settings.welcomeDone else { return }
        store.settings.welcomeDone = true
        store.saveSettings()
        Toast.show(Welcome.graduatedToast)
    }

    func show(_ mode: Mode) {
        // ⚠️ 帯を出した回数はここで数える（描く場所で数えると、画面を組み直すたびに増える）。
        // 5回出しても押されなければ諦める。案内が小言になる前にやめる
        if mode == .all, Welcome.shouldShowBand(done: store.settings.welcomeDone,
                                                shows: store.settings.welcomeShows) {
            store.settings.welcomeShows += 1
            store.saveSettings()
        }
        self.mode = mode
        pendingItem = nil
        openGroup = nil

        // 戻り先を覚え、じゃまになる窓（メモ）をどかしてから出す
        coordinator.willOpen(.launcher)

        searchField.stringValue = ""
        if mode == .files {
            rebuildPlacePopup()
            probeProtectedFoldersIfNeeded()
        }
        refreshChrome()
        refreshFilterBar()
        reload()
        positionPanel()

        // ⚠️ **動きは付けない**（2026-08-10 作者「動きは無しで、速度重視で。」）。
        // ふわっと出す・ノッチから落とす、の両方を試したうえでの本人の判断。
        // 1日に何十回も押すキーなので、0.1秒でも「待たされた」と感じる。
        // 押した瞬間にそこに在る、が最速の体験。
        panel.alphaValue = 1
        NSApp.activate()
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(searchField)
        coordinator.didOpen(.launcher)
    }

    // ⚠️ 開くときの動きは持たない（2026-08-10 作者の判断）。
    // 「ふわっと出す」も「ノッチから水玉のように落とす」も作って実際に使ってもらったが、
    // どちらも速さの前では邪魔だった。動きを足したくなったら、まずここを読むこと。

    /// 閉じる。
    ///
    /// reason は「なぜ閉じたか」。焦点を元のアプリへ返すかどうかがこれで変わる
    /// （決まりは TemotoCore.PanelBehavior。メモ・設定と同じ表を見ている）。
    func close(reason: CloseReason) {
        // ⚠️ orderOut すると windowDidResignKey がもう一度来るし、
        // 外クリックの見張りと重なることもある。ここで止める。
        guard panel.isVisible, !isClosing else { return }
        isClosing = true
        defer { isClosing = false }

        panel.orderOut(nil)
        pendingItem = nil
        // 探している途中で閉じたら止める。検索語も結果もここで捨てる（どこにも残さない）。
        fileSearcher.stop()
        fileResults = []
        isSearchingFiles = false
        coordinator.didClose(.launcher, reason: reason)
    }

    /// 外（テモト以外の場所）をクリックして焦点を失ったとき。
    /// 焦点は奪い返さない（クリックした先のアプリを使いたいはずなので）。
    func windowDidResignKey(_ notification: Notification) {
        guard PanelBehavior.closesWhenFocusLost(.launcher) else { return }
        // ⚠️ Quick Look を出した瞬間もここへ来る。閉じるとプレビューだけが宙に浮く。
        // 確認ダイアログ（☆保存・⌘E編集）も同じ（裏で閉じると答えた後に戻れない）。
        guard !isPreviewing, !isShowingDialog else { return }
        close(reason: .focusLost)
    }

    private func positionPanel() {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) }
            ?? NSScreen.main
            ?? NSScreen.screens.first
        guard let screen else { return }
        let visible = screen.visibleFrame
        let size = panel.frame.size
        panel.setFrameOrigin(NSPoint(
            x: (visible.midX - size.width / 2).rounded(),
            y: (visible.maxY - size.height - visible.height * 0.12).rounded()
        ))
    }

    /// 一覧とプレビューの置き場所を今の行き先に合わせる。
    /// コピー履歴・定型文だけ2ペイン、ファイル検索だけ絞り込みの帯付き、他は一覧が幅いっぱい。
    private func layoutContentArea() {
        let width = LauncherController.panelWidth
        var top = LauncherController.panelHeight - LauncherController.searchRowHeight
        let bottom = LauncherController.hintRowHeight
        let listWidth = isTwoPane ? LauncherController.listPaneWidth : width

        // アプリの棚は「入口で、まだ何も打っていないとき」だけ。
        // 打ち始めたら結果に場所を譲る（棚が残ると一覧の頭が1行分動いて落ち着かない）
        let shelfApps = store.settings.appBindings
        // 初めての人への帯。⚠️ 棚と**同時には出さない**。
        // 両方出すと 66+66=132pt を食い、一覧が行き先7つ（352pt）を入れられなくなる。
        // 帯が出るのは最初の数回だけなので、その間は棚を譲る
        let showsWelcome = mode == .all && pendingItem == nil && openGroup == nil
            && searchField.stringValue.isEmpty
            && Welcome.shouldShowBand(done: store.settings.welcomeDone,
                                      shows: store.settings.welcomeShows)
        welcomeBand.isHidden = !showsWelcome
        if showsWelcome {
            welcomeBand.configure(Welcome.bandContent(
                shortcutLabel: store.settings.launcherShortcut.displayString,
                keyFailed: launcherKeyFailed))
            welcomeBand.frame = NSRect(x: 0, y: top - WelcomeBandView.height,
                                       width: width, height: WelcomeBandView.height)
            top -= WelcomeBandView.height
            welcomeBand.onReassign = { [weak self] in self?.onOpenSettings?() }
        }

        let showsShelf = mode == .all && pendingItem == nil && openGroup == nil
            && searchField.stringValue.isEmpty && !shelfApps.isEmpty && !showsWelcome
        appShelf.isHidden = !showsShelf
        if !showsShelf { appShelf.focusedIndex = nil }
        // ⚠️ 棚と一覧の間に線は引かない。検索欄の下に1本あるところへもう1本足すと、
        // 棚が「線で囲われた空の帯」に見える（2026-08-04「余白の使い方好きじゃない」）。
        // 分けるのは線ではなく余白の仕事
        shelfDivider.isHidden = true
        if showsShelf {
            appShelf.focusedIndex = ShelfFocus.valid(appShelf.focusedIndex, count: shelfApps.count)
            appShelf.configure(shelfApps)
            appShelf.frame = NSRect(x: 0, y: top - AppShelfView.height,
                                    width: width, height: AppShelfView.height)
            top -= AppShelfView.height
        }

        let showsFilters = mode == .files && pendingItem == nil
        filterBar.isHidden = !showsFilters
        if showsFilters {
            filterBar.frame = NSRect(x: 0, y: top - LauncherController.filterRowHeight,
                                     width: width, height: LauncherController.filterRowHeight)
            top -= LauncherController.filterRowHeight
        }

        scrollView.frame = NSRect(x: 0, y: bottom, width: listWidth, height: top - bottom)
        emptyState.frame = scrollView.frame
        paneDivider.isHidden = !isTwoPane
        previewPane.isHidden = !isTwoPane
        if isTwoPane {
            paneDivider.frame = NSRect(x: listWidth, y: bottom, width: 1, height: top - bottom)
            previewPane.frame = NSRect(x: listWidth + 1, y: bottom,
                                       width: width - listWidth - 1, height: top - bottom)
        }
        // 幅が変わったら列も追従させる（列が古い幅のままだと題名の右端が切れる）
        tableView.sizeLastColumnToFit()
    }

    /// 見出し・札・下部の説明を今の状態に合わせる
    private func refreshChrome() {
        layoutContentArea()
        let width = LauncherController.panelWidth
        let height = LauncherController.panelHeight
        let searchRow = LauncherController.searchRowHeight

        let edge = Theme.Space.edge
        let searchY = height - searchRow + 15

        let chipText: String?
        if let pendingItem {
            chipText = pendingItem.title
            setPlaceholder("入力して Enter")
            hintBar.status = "この項目は入力を受け取ります"
            hintBar.setActions([HintAction("⏎", "実行"), HintAction("esc", "やめる", isEssential: true)])
        } else if let openGroup {
            // 畳んだコマンドの中。札でどこにいるかを示す
            chipText = openGroup.title
            setPlaceholder("この中を検索")
            hintBar.status = ""
            hintBar.setActions([
                HintAction("⏎", "実行"),
                HintAction("↑↓", "移動"),
                HintAction("esc", "戻る", isEssential: true),
            ])
        } else {
            // ⚠️ 行き先の札は出さない（2026-08-09 の再設計）。
            // いまどこにいるかは**窓の色**が語るので、言葉で言う必要がない。
            // 札が消えると検索欄がどの行き先でも同じ位置から始まり、打ち始める場所が動かない。
            // ⚠️ 入力待ち（pendingItem）と畳みの中（openGroup）の札は**残す**。
            // あちらは色を持たないので、言葉でしか場所を示せない。
            chipText = nil
            setPlaceholder(mode.placeholder)
            hintBar.status = ""
            // 棚が出ているときは「←→ アプリ」も案内する。
            // ⚠️ 書かなければ誰も気付かない。しかも札の ⌃1〜⌃9 は**他のアプリに取られることがある**
            // （2026-08-04 作者「うまく開かない時があります」）。
            // 取られようのない道＝修飾キー無しの矢印を、必ず目に見える場所に置いておく。
            var actions = mode.actions
            if !appShelf.isHidden {
                let arrow = HintAction("←→", "アプリ")
                if let spot = actions.firstIndex(where: { $0.keys == "↑↓" }) {
                    actions.insert(arrow, at: actions.index(after: spot))
                } else {
                    actions.append(arrow)
                }
            }
            hintBar.setActions(actions)
        }

        // ⚠️ いまいる行き先を**窓の色**で示す（2026-08-09 の再設計）。
        // 色の仕事を32ptのタイルの中から窓そのものへ移した。
        // 窓が青ければ「コピー履歴にいる」ことは言葉にしなくても分かるので、
        // 検索欄の左に出していた札は**やめる**（部品が1つ減る）。
        // 入口（すべて）は色を持たない＝何も選んでいないのだから色も無い。
        backdrop?.modeTint = pendingItem == nil && openGroup == nil
            ? ModeTint.tint(for: mode) : nil

        // 札はもう出さない。虫眼鏡だけを置く（どの行き先でも同じ位置から打ち始められる）
        if let chipText {
            chip.text = chipText
            chip.isHidden = false
            searchGlyph.isHidden = true      // 場所を示す札が出ているときは、虫眼鏡は引っ込む
            let chipWidth = min(chip.frame.width, 260)
            chip.setFrameSize(NSSize(width: chipWidth, height: chip.frame.height))
            chip.setFrameOrigin(NSPoint(x: edge, y: searchY + (30 - chip.frame.height) / 2))
            searchField.frame = NSRect(x: edge + chipWidth + 10, y: searchY,
                                       width: width - edge * 2 - chipWidth - 10, height: 30)
        } else {
            chip.isHidden = true
            searchGlyph.isHidden = false
            searchGlyph.frame = NSRect(x: edge, y: searchY + 4, width: 22, height: 22)
            searchField.frame = NSRect(x: edge + 32, y: searchY,
                                       width: width - edge * 2 - 32, height: 30)
        }
    }

    /// 検索欄の薄い案内文を置く。
    ///
    /// ⚠️ `placeholderString` に文字列を入れるだけだと `.placeholderTextColor`（黒の約25%）で
    /// 描かれる。あれは白い紙の上を想定した濃さで、すりガラスの上では消える。
    /// 何を打てばいいのか書いてあるのに読めない、という一番もったいない消え方をするので、
    /// 色は自分で決める。
    private func setPlaceholder(_ text: String) {
        searchField.placeholderAttributedString = NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: 20, weight: .regular),
            .foregroundColor: Theme.Palette.captionText,
        ])
    }

    // MARK: - 一覧

    /// 設定で表示している行き先だけを返す（使わない機能は出さない）。
    /// テモトを作った動機そのものなので、Tab の巡回も⌘1〜4も全部ここを見る。
    private var enabledModes: [Mode] {
        store.settings.visibleModes
    }

    private func sourceItems() -> [LauncherItem] {
        switch mode {
        case .all:
            // 畳んだコマンドの中にいるときは、その中身だけ（文字を打てばこの中で絞られる）
            if let openGroup { return openGroup.items }

            let settings = store.settings
            let entries = settings.visibleEntries.map { entry in
                LauncherItem.entry(entry, number: settings.directNumber(for: entry))
            }
            let organized = CommandGrouping.organize(store.commands)

            // 何も打っていない入口は「行き先」と「コマンド」の2段だけにする。
            //
            // ⚠️ 前はここにリンク・定型文・ウィンドウ操作・全アプリまで並べていて、
            // 入口が数百行の壁になっていた（2026-07-30 作者「リスト表示されている項目が汚い」）。
            // リンクや定型文には自分の行き先があるので、入口にまで並べると二重になる。
            // アプリは名前を打って呼ぶもので、眺めて選ぶものではない。
            // コマンドだけは他に住む場所が無いので、ここに置く（同じ書き出しは畳む）。
            if searchField.stringValue.isEmpty {
                var items: [LauncherItem] = [.header("行き先")]
                items += entries
                if !organized.isEmpty {
                    items.append(.header("コマンド"))
                    for entry in organized {
                        switch entry {
                        case .group(let title, let commands):
                            items.append(.group(title: title, commands: commands))
                        case .single(let command):
                            items.append(LauncherItem.from(command))
                        }
                    }
                }
                return items
            }

            // 文字を打ったら、見出しは消して全部を平らに探す。
            // 畳んだコマンドは**開いて**短い名前で当てる（畳んだままだと「ABC」で作業ログを探せない）。
            // 畳みの行そのものも残す（「フォルダ」と打って畳みごと開きたいときのため）。
            var items: [LauncherItem] = []
            items += entries
            for entry in organized {
                switch entry {
                case .group(let title, let commands):
                    items.append(.group(title: title, commands: commands))
                    items += commands.map {
                        LauncherItem.from($0, displayTitle: CommandGrouping.shortTitle($0.title), badge: title)
                    }
                case .single(let command):
                    items.append(LauncherItem.from(command))
                }
            }
            // 切った機能の中身は、入口を消しても検索に出てきては意味がない
            if store.settings.isVisible(.links) { items += store.quicklinks.map(LauncherItem.from) }
            if store.settings.isVisible(.snippets) { items += store.snippets.map(LauncherItem.from) }
            if store.settings.isVisible(.windows) { items += WindowLayout.allCases.map(LauncherItem.from) }
            items += appItems

            return items
        case .clipboard:
            let pinned = store.clips.filter { $0.pinned }.sorted { $0.copiedAt > $1.copiedAt }
            let rest = store.clips.filter { !$0.pinned }.sorted { $0.copiedAt > $1.copiedAt }
            return (pinned + rest).map(LauncherItem.from)
        case .files:
            // ここだけは中身が非同期で届く。届いた分をそのまま出す。
            return fileResults
        case .snippets:
            return store.snippets.map(LauncherItem.from)
        case .links:
            return store.quicklinks.map(LauncherItem.from)
        case .windows:
            return WindowLayout.allCases.map(LauncherItem.from)

        case .calculator:
            // ⚠️ ここは**あいまい検索を通さない**。打っているのは探しものではなく式なので、
            // 「1234567*1.1」に近い題名を探しても意味が無い。
            // 打った式の答えを先頭に置き、その下に履歴を並べる（呼ぶ側が並べ替えない）
            var items: [LauncherItem] = []
            if let line = CalcLine.line(for: searchField.stringValue, previous: calcLines.first?.value) {
                items.append(LauncherItem.from(line))
            }
            items += calcLines.map(LauncherItem.from)
            return items
        }
    }

    // MARK: - 行き先の移動（窓は閉じない）

    /// 行き先を変える。**窓は開いたまま**、覚えている前面アプリもそのまま。
    /// 計算の結果を履歴に残す。
    ///
    /// ⚠️ 同じ式を打ち直したら、増やさずに一番上へ持ち上げる。
    /// 打ち直しは「間違えたからやり直した」ことが多く、同じ行が並ぶと履歴が読めなくなる。
    /// ⚠️ 上限を切る。計算は何十回も打つので、切らないと一覧が延々伸びる。
    private func rememberCalc(_ line: CalcLine.Line) {
        calcLines.removeAll { $0.input == line.input }
        calcLines.insert(line, at: 0)
        if calcLines.count > 50 { calcLines.removeLast(calcLines.count - 50) }
    }

    /// 選ぶ範囲を1行ずつ広げる（⇧↑↓）。
    ///
    /// ⚠️ 見出しの行は選ばせない。選べない行が選択に混ざると、
    /// 「3件選んだのに2件しか貼れない」という説明のつかない数え違いになる。
    private func extendSelection(by step: Int) {
        let current = tableView.selectedRowIndexes
        guard let anchor = step > 0 ? current.max() : current.min() else {
            moveSelection(by: step)
            return
        }
        var next = anchor + step
        while next >= 0, next < results.count, results[next].item.isHeader {
            next += step
        }
        guard next >= 0, next < results.count else { return }
        tableView.selectRowIndexes(current.union(IndexSet(integer: next)),
                                   byExtendingSelection: false)
        tableView.scrollRowToVisible(next)
        refreshSelectionStatus()
    }

    /// 選んだ履歴をまとめて貼る。
    ///
    /// ⚠️ 順番は**画面に見えているとおり（上から下）**。
    /// 履歴は新しい順に並んでいるので、内部の順のまま繋ぐと選んだのと逆さまに出てくる。
    private func pasteSelectedClips() {
        let rows = tableView.selectedRowIndexes.sorted()
        let clips: [ClipItem] = rows.compactMap { row in
            guard row < results.count, case .clip(let clip) = results[row].item.kind else { return nil }
            return clip
        }
        let plan = ClipJoin.plan(clips.map {
            ClipJoin.Picked(text: $0.kind == .text ? $0.text : nil,
                            isImage: $0.kind == .image, isFile: $0.kind == .file)
        })

        switch plan.way {
        case .nothing:
            Toast.show(ClipJoin.message(for: plan), isError: true, area: "コピー履歴")

        case .text:
            let target = previousApp
            close(reason: .finished)
            Paster.paste(plan.text, into: target, window: previousWindow)
            Toast.show(ClipJoin.message(for: plan))

        case .files:
            // ⚠️ 絵は「まとめて貼る」ことが macOS ではできない（1回の貼り付けに絵は1枚）。
            // だから**ファイルにして渡す**。メールやチャットには添付として、
            // Finder には書類として、そのまま複数まとめて入る。
            // 2026-08-09 作者「画像は一気に選べないですね！テキストはいけました。」
            guard let paths = writeSelectionToFiles(clips: clips, plan: plan) else {
                Toast.show("ファイルを書き出せませんでした", isError: true, area: "コピー履歴")
                return
            }
            let target = previousApp
            close(reason: .finished)
            Paster.pasteFiles(paths, into: target, window: previousWindow) { [weak self] in
                self?.watcher.ignoreCurrentChange()
            }
            Toast.show(ClipJoin.message(for: plan))
        }
    }

    /// 選んだものを一時フォルダに書き出して、その場所を返す。
    ///
    /// ⚠️ 置き場所は毎回新しいフォルダにする。同じ場所に書くと、
    /// 前に渡したファイルを相手がまだ開いている最中に上書きしてしまう。
    /// ⚠️ 名前は連番にする。絵から読み取った文字を名前にすると、
    /// **渡した相手のファイル名に中身が出てしまう**（画面写真の中の言葉が漏れる）。
    private func writeSelectionToFiles(clips: [ClipItem], plan: ClipJoin.Plan) -> [String]? {
        let folder = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("テモト-\(UUID().uuidString.prefix(8))", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            return nil
        }

        var paths: [String] = []
        var imageIndex = 0
        for clip in clips {
            switch clip.kind {
            case .image:
                guard let png = store.loadClipImage(id: clip.id) else { continue }
                imageIndex += 1
                let url = folder.appendingPathComponent("画像-\(imageIndex).png")
                guard (try? png.write(to: url)) != nil else { continue }
                paths.append(url.path)
            case .file:
                // 元のファイルはそのまま渡す（複製を作らない）
                paths += ClipItem.availablePaths(clip.filePaths) {
                    FileManager.default.fileExists(atPath: $0)
                }
            case .text:
                continue      // 文字はまとめて1つの .txt にする（下で1回だけ書く）
            }
        }
        if plan.textCount > 0, !plan.text.isEmpty {
            let url = folder.appendingPathComponent("テキスト.txt")
            if (try? plan.text.write(to: url, atomically: true, encoding: .utf8)) != nil {
                paths.append(url.path)
            }
        }
        return paths.isEmpty ? nil : paths
    }

    private func goTo(_ next: Mode) {
        // ⚠️ 複数選択を持ち越さない。コピー履歴で3件選んだまま定型文へ移ると、
        // 貼れないものが選ばれた状態で ⏎ を押すことになる
        if tableView.selectedRowIndexes.count > 1 {
            tableView.selectRowIndexes(IndexSet(integer: tableView.selectedRow),
                                       byExtendingSelection: false)
        }
        mode = next
        pendingItem = nil
        openGroup = nil
        searchField.stringValue = ""
        // 行き先を変えたら、前の場所で探していた分は捨てる。
        // 残しておくと、定型文の一覧にさっきのファイルが混ざって出る。
        fileSearcher.stop()
        fileResults = []
        isSearchingFiles = false
        if next == .files {
            rebuildPlacePopup()
            probeProtectedFoldersIfNeeded()
        }
        refreshChrome()
        refreshFilterBar()
        reload()
    }

    /// esc を押したとき。入口にいるときだけ閉じる。
    private func goBack() {
        if pendingItem != nil {
            pendingItem = nil
            searchField.stringValue = ""
            refreshChrome()
            reload()
            return
        }
        // 絞り込みの途中なら、まず文字を消す（いきなり閉じない）
        if !searchField.stringValue.isEmpty {
            searchField.stringValue = ""
            refreshFilterBar()
            reload()
            return
        }
        // 畳んだコマンドの中にいたら、まず入口へ出る
        if openGroup != nil {
            openGroup = nil
            refreshChrome()
            reload()
            return
        }
        if let parent = mode.parent {
            goTo(parent)
        } else {
            close(reason: .escape)
        }
    }

    /// 一覧が空のときだけ、真ん中に案内を出す。
    ///
    /// ⚠️ 空白のままにしない。空白は「読み込み中」「壊れた」「まだ無い」の
    /// どれなのか区別できず、使う側はたいていアプリのせいだと受け取る。
    private func refreshEmptyState(hasSource: Bool) {
        guard results.isEmpty else {
            emptyState.isHidden = true
            return
        }
        let message = EmptyState.message(
            mode: mode,
            query: searchField.stringValue,
            isSearching: mode == .files && isSearchingFiles,
            hasSource: hasSource)
        emptyState.configure(symbol: message.symbol, message: message.title, detail: message.detail)
        emptyState.isHidden = false
    }

    private func reload() {
        guard pendingItem == nil else {
            // 引数の入力中は候補を出さない（何を選んだかは札で分かる）
            results = []
            tableView.reloadData()
            emptyState.isHidden = true
            return
        }

        // ⚠️ ファイル検索だけは、ここでさらにあいまい検索を通してはいけない。
        // 「請求書 pdf 今月」の `pdf` や `今月` は絞り込みの言葉であって
        // ファイル名には入っていないので、名前に当てにいくと全部落ちて0件になる。
        // 絞り込みは Spotlight 側で済んでいる。
        if mode == .files {
            let trimmed = searchField.stringValue.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                // 何も打っていない間は、保存した検索を出す（ワンタッチで呼び戻す入口）
                var items: [LauncherItem] = []
                let saved = store.settings.fileSearch.saved
                if !saved.isEmpty {
                    items.append(.header("保存した検索"))
                    items += saved.map {
                        LauncherItem.from($0, searchesContent: store.settings.fileSearch.searchesContent)
                    }
                }
                results = items.map {
                    (item: $0, result: FuzzyMatcher.Result(score: 0, matchedIndices: []))
                }
            } else {
                results = fileResults.map {
                    (item: $0, result: FuzzyMatcher.Result(score: 0, matchedIndices: []))
                }
            }
            tableView.reloadData()
            selectFirstSelectable()
            // ⚠️ ファイル検索は「まだ何も持っていない」状態が無い（毎回その場で探す）。
            // 出るのは「打ってください」か「探しています」か「見つかりません」の3つだけ。
            refreshEmptyState(hasSource: true)
            refreshFileHint()
            return
        }

        // ⚠️ 計算だけは並べ替えない。打っているのは探しものではなく**式**なので、
        // 「1234567*1.1」に近い題名を探しても意味が無い。
        // sourceItems() が既に「答え→履歴」の順で返しているので、そのまま出す
        if mode == .calculator {
            results = sourceItems().map {
                (item: $0, result: FuzzyMatcher.Result(score: 0, matchedIndices: []))
            }
            tableView.reloadData()
            selectFirstSelectable()
            refreshSelectionStatus()
            return
        }

        let source = sourceItems()

        // 表示名で当たらなかったものだけ読みを見る（`teikei` で「定型文」に当てるため）。
        // 読みの作り置きは readings が持つので、同じ名前を何度も変換しない。
        // 別名も見る理由は2つ。
        // ① `teikei` で「定型文」に当てる（ローマ字・ひらがなの読み）
        // ② **絵から読み取った文字**で絵を探す。
        //    題名になるのは読み取った文字の先頭80字だけなので、
        //    題名だけ見ていると絵の下の方に書いてある言葉では探せない。
        let typed = searchField.stringValue
        var ranked = FuzzyMatcher.rank(
            source,
            query: typed,
            key: { $0.title },
            aliases: { [readings] item in readings.keys(for: item.title) + item.searchAliases })
        // 1件も無いときだけ、ローマ字に起こした形でもう一度探す。
        // 日本語入力のまま mailz と打つと検索欄には「まいｌｚ」が来るので、
        // これが無いと IME を切り替えないかぎり英字の名前・読みがなに当たらない
        if ranked.isEmpty, let alternative = SearchQuery.romajiAlternative(for: typed) {
            ranked = FuzzyMatcher.rank(
                source,
                query: alternative,
                key: { $0.title },
                aliases: { [readings] item in readings.keys(for: item.title) + item.searchAliases })
        }
        results = Array(ranked.prefix(200))

        // 「テモトの中に住んでいないもの」（コピー履歴・メモ・Macの操作）は**別に**並べ替えて、
        // 必ず一覧の**下**に、**少しだけ**足す。
        //
        // ⚠️ 2026-08-05 作者「色々と情報が多くなりすぎている気がする。」
        // 最初は本体と混ぜて1つの順位表にしたが、それだと打つたびに1行目が入れ替わる。
        // アプリを呼びたいのに履歴が上に来る画面は、目が休まらない。
        // 上は今までどおり（行き先・コマンド・アプリ）、下に外の世界、と場所で分ける。
        //
        // ⚠️ ファイル（Spotlight）はここに入れない。
        // 遅れて届くので一覧が跳ね、件数も読めない。ファイルは最下段の逃げ道から**行き先ごと**移る。
        if mode == .all, openGroup == nil, pendingItem == nil,
           searchField.stringValue.trimmingCharacters(in: .whitespaces).count >= 2 {
            // ⚠️ 「画面の文字を読み取る」はここに入れない。
            // 2026-08-05 に行き先へ常設したので、上の `items += entries` から必ず1行出る。
            // ここにも足すと**同じ道具が上と下に2行**並ぶ（id が section:capture.text と
            // capture.text で違うので、重複を潰す網にも掛からない）。
            // しかもここは hiddenFeatures を見ないので、設定で切っても検索には出続けてしまう。
            var extras: [LauncherItem] = CaptureShot.all.map(LauncherItem.from)
            extras += SystemPlace.all.map(LauncherItem.from)
            if store.settings.isVisible(.clipboard) { extras += store.clips.map(LauncherItem.from) }
            if store.settings.isNoteVisible { extras += store.notes.map(LauncherItem.from) }
            var rankedExtras = FuzzyMatcher.rank(
                extras, query: typed, key: { $0.title },
                aliases: { [readings] item in readings.keys(for: item.title) + item.searchAliases })
            if rankedExtras.isEmpty, let alternative = SearchQuery.romajiAlternative(for: typed) {
                rankedExtras = FuzzyMatcher.rank(
                    extras, query: alternative, key: { $0.title },
                    aliases: { [readings] item in readings.keys(for: item.title) + item.searchAliases })
            }
            results += rankedExtras.prefix(LauncherController.extraLimit)
        }

        // 「電卓」を探しに来た人に、使い方をその場で出す（行き先に電卓は無い＝式を打つだけ）。
        // 見出しの行なので選べない・Enterを奪わない（読んだら式を打ってもらう）
        if mode == .all, openGroup == nil, QuickAnswer.isCalculatorLookup(searchField.stringValue) {
            results.insert((item: .header(QuickAnswer.calculatorGuide),
                            result: FuzzyMatcher.Result(score: 0, matchedIndices: [])), at: 0)
        }

        // 合言葉（定型文の読みがな）にぴったり一致したら、本文を入口の先頭に出す＝辞書引き。
        // 2026-08-02 作者「mailsと入力したらtaro@example.comと表示されたり」。
        // ぴったり一致だけ（部分一致にすると、打つたびに定型文が入口へ紛れ込む）。
        if mode == .all, openGroup == nil {
            let context = SnippetContext(clipboard: NSPasteboard.general.string(forType: .string) ?? "")
            for snippet in SnippetDictionary.hits(for: searchField.stringValue, in: store.snippets).reversed() {
                let item = LauncherItem(
                    id: "dict:\(snippet.id)",
                    title: SnippetDictionary.displayLine(for: snippet, context: context),
                    subtitle: "定型文「\(snippet.title)」— ⏎ で貼り付け",
                    kindLabel: "合言葉",
                    kind: .snippet(snippet),
                    needsQuery: false
                )
                results.insert((item: item, result: FuzzyMatcher.Result(score: 0, matchedIndices: [])), at: 0)
            }
        }

        // 打った文字がそのまま行き先に見えるなら、いちばん上に出す（URL・実在するフォルダ）。
        //
        // ⚠️ あいまい検索の**あと**に差し込む。`github.com` という題名の行は無いので
        // 点が付かず、順位で競わせても必ず最下位になる。
        // ⚠️ 実在しない場所・普通の言葉は出さない（QuickOpen 側で見張っている）。
        if mode == .all, openGroup == nil, pendingItem == nil {
            let typed = searchField.stringValue
            if let target = QuickOpen.detect(typed, home: NSHomeDirectory(),
                                             exists: { FileManager.default.fileExists(atPath: $0) }) {
                results.insert((item: .openTarget(target),
                                result: FuzzyMatcher.Result(score: 0, matchedIndices: [])), at: 0)
            }
        }

        // 最後に逃げ道を2つ置く。
        //
        // ⚠️ 「当たりが無いときだけ」にはしない。
        // 当たっていても**それが目当てとは限らない**（「請求書」でコマンドに当たったが、
        // 本当は書類を探していた等）。いつも同じ場所に在ることが、迷わない条件。
        // ⚠️ いちばん下に置く。上に置くと ⏎ を奪って、探し当てた行が実行されなくなる。
        if mode == .all, openGroup == nil, pendingItem == nil {
            let typed = searchField.stringValue.trimmingCharacters(in: .whitespaces)
            if typed.count >= 2 {
                let blank = FuzzyMatcher.Result(score: 0, matchedIndices: [])
                if store.settings.isVisible(.files) {
                    results.append((item: .escapeToFiles(typed), result: blank))
                }
                results.append((item: .escapeToWeb(typed), result: blank))
            }
        }

        // 打った文字がそのまま問いに見えるなら、答えを先頭に出す。
        //
        // ⚠️ あいまい検索の**あと**に差し込む。順位を competing させても意味が無い
        // （`1234567*1.1` という題名の行は存在しないので点が付かず、必ず最下位になる）。
        //
        // ⚠️ 入口（すべて）にいるときだけにする。コピー履歴を見ている最中に
        // 計算の行が割り込むと、貼りたかった履歴が1行下にずれて Enter が別物を貼る。
        // 畳んだコマンドの中でも出さない（そこは「この中を探す」場所なので）。
        if mode == .all, openGroup == nil, let answer = QuickAnswer.answer(for: searchField.stringValue) {
            results.insert(
                (item: .answer(answer), result: FuzzyMatcher.Result(score: 0, matchedIndices: [])),
                at: 0)
        }

        tableView.reloadData()
        selectFirstSelectable()
        // ⚠️ 「絞った結果0件」と「そもそも0件」は別の話。
        // 履歴が空の人に「見つかりません」と出すと、探し方が悪いのだと誤解される。
        refreshEmptyState(hasSource: !source.isEmpty)
        // 選び直しの通知は「行が変わったとき」しか来ない。
        // 0件→0件のように行番号が動かない場合も左の文字とプレビューを合わせ直す
        refreshSelectionStatus()
        refreshPreview()
    }

    func numberOfRows(in tableView: NSTableView) -> Int { results.count }

    /// 先頭の「選べる行」を選ぶ（見出しは飛ばす）。
    /// 直前に見出しがあるなら、見出しごと画面に入れる（何の仲間かが分かるように）。
    private func selectFirstSelectable() {
        guard let first = results.firstIndex(where: { !$0.item.isHeader }) else { return }
        tableView.selectRowIndexes(IndexSet(integer: first), byExtendingSelection: false)
        tableView.scrollRowToVisible(max(first - 1, 0))
    }

    /// 行の高さ。項目の行は全種類同じ（RUNBOOKの約束）。
    /// 見出しだけは行ではなく仕切りなので低くする。
    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        guard row >= 0, row < results.count else { return Theme.Row.standard }
        return results[row].item.isHeader ? Theme.Row.header : Theme.Row.standard
    }

    /// 見出しは選べない（選べてしまうと Enter が「何も起きないキー」になる）
    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        guard row >= 0, row < results.count else { return false }
        return !results[row].item.isHeader
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let entry = results[row]

        if entry.item.isHeader {
            let identifier = NSUserInterfaceItemIdentifier("headerRow")
            let header: HeaderRowView
            if let reused = tableView.makeView(withIdentifier: identifier, owner: self) as? HeaderRowView {
                header = reused
            } else {
                header = HeaderRowView(frame: .zero)
                header.identifier = identifier
            }
            header.title = entry.item.title
            return header
        }

        let identifier = NSUserInterfaceItemIdentifier("row")
        let view: LauncherRowView
        if let reused = tableView.makeView(withIdentifier: identifier, owner: self) as? LauncherRowView {
            view = reused
        } else {
            view = LauncherRowView(frame: .zero)
            view.identifier = identifier
        }
        view.configure(item: entry.item, matchedIndices: entry.result.matchedIndices, compact: isTwoPane)
        return view
    }

    /// 選んでいる行の見た目を自前で描くための下地。
    /// ⚠️ ここを返さないと、macOS 既定の「窓の端まで届く角ばった青帯」に戻る。
    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let identifier = NSUserInterfaceItemIdentifier("rowBackground")
        if let reused = tableView.makeView(withIdentifier: identifier, owner: self) as? LauncherRowBackground {
            return reused
        }
        let view = LauncherRowBackground()
        view.identifier = identifier
        return view
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        refreshSelectionStatus()
        refreshPreview()
        // 保存した検索の行だけ下の帯の操作が変わるので、選び直しでも合わせる
        if mode == .files { refreshFileHint() }
    }

    /// 右半分に、選んでいる1件の中身を出す。
    ///
    /// 何を出すかは TemotoCore.ItemPreview が決める（そちらは検証済み）。
    /// ここは「絵の実体を開いて渡す」だけを受け持つ。
    private func refreshPreview() {
        guard isTwoPane else { return }
        guard let item = selectedItem else {
            previewPane.clear()
            return
        }
        switch item.kind {
        case .clip(let clip):
            let spec = ItemPreview.spec(for: clip)
            if clip.kind == .image {
                // 原寸が開けないとき（鍵を作り直した後）は一覧用の小さい絵で代用。
                // それも無ければ nil を渡して、プレビュー側が理由を出す
                let image = PreviewImageCache.image(for: clip.id) ?? ClipThumbnailCache.image(for: clip.id)
                previewPane.show(spec, image: image)
            } else {
                previewPane.show(spec, image: nil)
            }
        case .snippet(let snippet):
            // ⚠️ 「入っているか」も一緒に渡す。登録されていることと、今それが効くことは別
            previewPane.show(ItemPreview.spec(
                for: snippet,
                expandsEverywhere: store.settings.expandSnippets
                    && store.settings.isVisible(.snippets)), image: nil)
        default:
            previewPane.clear()
        }
    }

    /// 下の帯の左に「いま ⏎ を押すと何が起きるか」を出す。
    ///
    /// ⚠️ 行の色だけでは足りない。一覧を下までたどると、選んでいる行が視野の端に行く。
    /// 手元（下の帯）に名前が残っていれば、目を戻さずに Enter を押せる。
    private func refreshSelectionStatus() {
        // ファイル検索の左側は件数と絞り込みの内訳。そちらのほうが情報量が多いので譲る
        guard mode != .files, pendingItem == nil else { return }
        let row = tableView.selectedRow
        guard row >= 0, row < results.count else {
            hintBar.status = ""
            return
        }
        // 複数選んでいるときは、件数と次の一手を出す（何が起きるか分からないまま⏎を押させない）
        let selectedCount = tableView.selectedRowIndexes.count
        if mode == .clipboard, selectedCount > 1 {
            hintBar.status = ClipJoin.status(count: selectedCount)
            return
        }
        // 棚を選んでいるときは、そのアプリの名前を出す（一覧ではなく棚を操作していることが分かる）
        if let index = ShelfFocus.valid(appShelf.focusedIndex, count: appShelf.paths.count) {
            let name = FileManager.default.displayName(atPath: appShelf.paths[index])
            hintBar.status = (name.hasSuffix(".app") ? String(name.dropLast(4)) : name) + " を開く"
            return
        }
        let item = results[row].item
        // 行に副題を出していないもの（行き先）は、ここに説明を出す。
        // 全行に説明を並べると入口が文字の壁になるが、選んだ1行の説明なら読める
        if !item.subtitleInRow, !item.subtitle.isEmpty {
            hintBar.status = item.subtitle
        } else {
            hintBar.status = item.title
        }
    }

    // MARK: - キー操作

    func controlTextDidChange(_ obj: Notification) {
        guard pendingItem == nil else { return }
        if mode == .files {
            // 打つたびに Spotlight を叩かない（FileSearcher が0.2秒待つ）
            fileSearcher.search(searchField.stringValue, settings: store.settings.fileSearch)
            if searchField.stringValue.trimmingCharacters(in: .whitespaces).isEmpty {
                fileResults = []
                isSearchingFiles = false
            }
            // 打った言葉をプルダウンにも映す（文字が正・プルダウンは鏡）
            refreshFilterBar()
        }
        reload()
    }

    /// ファイル検索のときだけ、下の説明を「どう受け取ったか」に差し替える。
    ///
    /// ⚠️ 黙って絞ると、出てこない理由が分からないまま「使えない」と判断される。
    /// 何件見つけたか・何で絞ったかを必ず出す。
    private func refreshFileHint() {
        guard mode == .files, pendingItem == nil else { return }
        // ⚠️ 操作のキーは何があっても消さない。
        // 件数のために右側を消すと「次に何を押せるか」が分からなくなる。
        // 左（報告）と右（操作）を分けたのは、まさにこの取り合いをやめるため。
        hintBar.setActions(mode.actions)

        let raw = searchField.stringValue.trimmingCharacters(in: .whitespaces)
        guard !raw.isEmpty else {
            // 保存した検索を選んでいるときは、その行でできることに差し替える。
            // ⌘⌫で消せることも⌘Eで直せることも、ここに書かなければ誰にも見つけられない
            // （2026-07-30 作者「削除や編集できる様にして」＝⌘⌫は前からあったが伝わっていなかった）。
            if let item = selectedItem, case .savedSearch(let saved) = item.kind {
                hintBar.setActions([
                    HintAction("⏎", "この条件で探す"),
                    HintAction("⌘E", "編集"),
                    HintAction("⌘⌫", "削除"),
                    HintAction("esc", "戻る", isEssential: true),
                ])
                // 左には保存してある文字そのものを出す（行の副題は解釈後の説明なので、生の形はここで見せる）
                hintBar.status = saved.query
                return
            }
            // ⚠️ ここで例を出さない。同じ例が真ん中（EmptyStateView）にも出て、
            // 同じ文が2つ並ぶ。読む側は「どちらを読めばいいのか」で一瞬止まる。
            // ただし「読めていない場所がある」ことだけは、探す前に言っておく
            hintBar.status = deniedFolderNames.isEmpty
                ? ""
                : "⚠️ \(deniedFolderNames.joined(separator: "・"))は許可が無く探せません（システム設定 → ファイルとフォルダ）"
            return
        }
        let parsed = FileQuery.parse(raw)
        let searchesContent = store.settings.fileSearch.searchesContent
        // ⚠️ 「中身も探す」を切ったまま `中身:` で探すと、必ず0件になる。
        // 理由を言わずに0件を出すと「テモトが壊れている」と思われて、そこで使うのをやめられる。
        if parsed.isContentSearchBlocked(searchesContent: searchesContent) {
            hintBar.status = "「中身も探す」を設定で切っています（⌘, → ファイル検索）"
            return
        }
        let summary = parsed.summary(searchesContent: searchesContent)
        if isSearchingFiles {
            hintBar.status = summary.isEmpty ? "探しています…" : "探しています… \(summary)"
            return
        }
        let count = fileResults.isEmpty ? "見つかりません" : "\(fileResults.count)件"
        var status = summary.isEmpty ? count : "\(count)（\(summary)）"
        // 読めていない場所があるなら、件数を「全部を探した結果」のような顔で出さない
        if !deniedFolderNames.isEmpty {
            status += "／⚠️ \(deniedFolderNames.joined(separator: "・"))は許可が無く探せていません"
        }
        hintBar.status = status
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        // ← → で棚のアプリを選ぶ。
        // ⚠️ 修飾キーを付けない。⌃←→ は macOS の「スペース移動」、⌥←→ は「単語単位の移動」で
        // すでに使われている（2026-08-04 実機の設定で確認）。何も付けなければ誰とも取り合わない。
        case #selector(NSResponder.moveRight(_:)), #selector(NSResponder.moveLeft(_:)):
            guard !appShelf.isHidden, searchField.stringValue.isEmpty else { return false }
            let step = selector == #selector(NSResponder.moveRight(_:)) ? 1 : -1
            appShelf.focusedIndex = ShelfFocus.move(from: appShelf.focusedIndex,
                                                    count: appShelf.paths.count, step: step)
            refreshSelectionStatus()
            return true
        // ⇧↑ / ⇧↓ で選ぶ範囲を広げる。
        // ⚠️ 文字の入力欄が前面にいても、この2つは別の合図（…AndModifySelection）で来るので
        // 打っている文字を邪魔しない。
        case #selector(NSResponder.moveDownAndModifySelection(_:)),
             #selector(NSResponder.moveUpAndModifySelection(_:)):
            guard mode == .clipboard, pendingItem == nil else { return true }
            extendSelection(by: selector == #selector(NSResponder.moveDownAndModifySelection(_:)) ? 1 : -1)
            return true
        case #selector(NSResponder.moveDown(_:)):
            // 棚から降りて一覧へ戻る
            if appShelf.focusedIndex != nil { appShelf.focusedIndex = nil; refreshSelectionStatus(); return true }
            moveSelection(by: 1)
            return true
        case #selector(NSResponder.moveUp(_:)):
            if appShelf.focusedIndex != nil { appShelf.focusedIndex = nil; refreshSelectionStatus(); return true }
            moveSelection(by: -1)
            return true
        case #selector(NSResponder.insertNewline(_:)):
            // 複数選んでいるなら、まとめて貼る
            if mode == .clipboard, tableView.selectedRowIndexes.count > 1 {
                pasteSelectedClips()
                return true
            }
            // 棚を選んでいるなら、そのアプリを開く
            if let index = ShelfFocus.valid(appShelf.focusedIndex, count: appShelf.paths.count) {
                let path = appShelf.paths[index]
                appShelf.focusedIndex = nil
                close(reason: .finished)
                ActionRunner.open(appPath: path)
                return true
            }
            activateSelection()
            return true
        case #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)):
            // ⌥⏎。ファイル検索のときだけ「ファイルそのものをコピー」に使う。
            // ⚠️ ⌘ が付かないので handleKeyEquivalent には来ない。ここで拾うしかない。
            guard mode == .files, let item = selectedItem, case .file(let hit) = item.kind else { return true }
            copyFileItself(hit)
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            // 棚にいるなら、まず棚から出る（いきなり窓を閉じない）
            if appShelf.focusedIndex != nil { appShelf.focusedIndex = nil; refreshSelectionStatus(); return true }
            goBack()
            return true
        case #selector(NSResponder.insertTab(_:)):
            // Tab で次の行き先へ。窓は閉じない＝「別アプリ」感を消す要
            guard pendingItem == nil else { return true }
            goTo(mode.next(within: enabledModes))
            return true
        case #selector(NSResponder.insertBacktab(_:)):
            guard pendingItem == nil else { return true }
            goTo(mode.previous(within: enabledModes))
            return true
        case #selector(NSResponder.deleteBackward(_:)):
            // 行き先の中で、文字が無い状態でさらに消したら入口へ戻る。
            // 札（履歴・定型文・畳んだコマンド）を消す感覚で戻れるようにする。
            if pendingItem == nil, searchField.stringValue.isEmpty, openGroup != nil {
                openGroup = nil
                refreshChrome()
                reload()
                return true
            }
            if pendingItem == nil, searchField.stringValue.isEmpty, let parent = mode.parent {
                goTo(parent)
                return true
            }
            return false
        default:
            return false
        }
    }

    private func handleKeyEquivalent(_ event: NSEvent) -> Bool {
        guard panel.isVisible else { return false }

        // ⌃1〜⌃9＝棚のアプリ。窓が開いている間だけ効く（決まりは TemotoCore.ShelfKeys）。
        // ⚠️ 行き先の ⌘1〜⌘6 と数字はぶつかるが、修飾キーが違うので別物として通る。
        // 「⌘は行き先・⌃は棚」で1度で覚えられる並びにしてある。
        if !appShelf.isHidden,
           event.modifierFlags.contains(.control),
           !event.modifierFlags.contains(.command),
           let character = event.charactersIgnoringModifiers,
           let index = ShelfKeys.index(forCharacter: character, count: appShelf.paths.count) {
            let path = appShelf.paths[index]
            close(reason: .finished)
            ActionRunner.open(appPath: path)
            return true
        }

        guard event.modifierFlags.contains(.command) else { return false }
        // ⌫（keyCode 51）だけは文字が取れないのでキーコードで見る
        if event.keyCode == 51 {
            if let item = selectedItem, case .savedSearch(let saved) = item.kind {
                deleteSelectedSavedSearch(saved)
            } else if let item = selectedItem, case .snippet(let snippet) = item.kind {
                deleteSnippet(snippet)
            } else if let item = selectedItem, case .quicklink(let link) = item.kind {
                deleteQuicklink(link)
            } else {
                deleteSelectedClips()
            }
            return true
        }
        // ⌘⏎（Return 36 / テンキーの Enter 76）＝ Finder で表示
        if event.keyCode == 36 || event.keyCode == 76 {
            guard let item = selectedItem, case .file(let hit) = item.kind else { return false }
            close(reason: .finished)
            ActionRunner.reveal(hit.path)
            return true
        }
        let key = event.charactersIgnoringModifiers?.lowercased()

        // ⌘1〜⌘9 で行き先へ直接。
        // ⚠️ どの番号がどこかは並べ替えで変わる。設定に聞く（画面に出ている札と必ず一致する）
        if let key, let number = Int(key), let target = store.settings.entry(forDirectNumber: number) {
            switch target {
            case .mode(let mode):
                goTo(mode)
            case .note:
                // 先に閉じない（開く側が閉じてくれる。閉じると前面から外れて窓が後ろに回る）
                onOpenNote?()
            case .captureText:
                // ⚠️ ここは逆に**先に閉じる**。テモトの窓が出たままだと、その窓ごと撮ってしまう
                close(reason: .finished)
                ActionRunner.captureTextToClipboard()
            }
            return true
        }

        switch key {
        case ",":
        // ⚠️ 先に閉じない。閉じると窓が1つも無くなってテモトが前面から外れ、
        // そのあとの「前に出る」がmacOSに拒否されて、開いた窓が**後ろに回る**
        // （2026-08-04「＋ボタン押しても何も反応しない」＝実は後ろで開いていた）。
        // 開く側（PanelCoordinator.willOpen）が先に閉じてくれるので、任せる。
            onOpenSettings?()
            return true
        case "c":
            copySelectionOnly()
            return true
        case "p":
            togglePinOnSelection()
            return true
        case "y":
            previewSelection()
            return true
        case "e":
            // 保存した検索と定型文の編集。それ以外の行では何もしない（キーを取らない）
            if let item = selectedItem, case .savedSearch(let saved) = item.kind {
                editSelectedSavedSearch(saved)
                return true
            }
            if let item = selectedItem, case .snippet(let snippet) = item.kind {
                editSnippet(snippet)
                return true
            }
            if let item = selectedItem, case .quicklink(let link) = item.kind {
                editQuicklink(link)
                return true
            }
            return false
        case "n":
            // 新規作成。帯に ⌘N を書いてある画面でだけ効かせる（書いてある場所と動きを一致させる）
            if mode == .snippets { editSnippet(nil); return true }
            if mode == .links { editQuicklink(nil); return true }
            return false
        default:
            return false
        }
    }

    private func moveSelection(by step: Int) {
        guard !results.isEmpty else { return }
        // 見出しは飛ばして次の選べる行へ（見出しで止まると ↑↓ が効かなく見える）
        var next = tableView.selectedRow
        repeat {
            next += step
        } while next >= 0 && next < results.count && results[next].item.isHeader
        guard next >= 0, next < results.count else { return }
        tableView.selectRowIndexes(IndexSet(integer: next), byExtendingSelection: false)
        // 見出しの直後の行なら、見出しごと見せる
        let reveal = next > 0 && results[next - 1].item.isHeader ? next - 1 : next
        tableView.scrollRowToVisible(reveal)
    }

    @objc private func rowDoubleClicked() {
        activateSelection()
    }

    private var selectedItem: LauncherItem? {
        let row = tableView.selectedRow
        guard row >= 0, row < results.count else { return nil }
        return results[row].item
    }

    /// 右クリックしたときの品書き。
    ///
    /// ⚠️ キーの割り当てと**同じことしか出さない**。ここにしか無い操作を作ると、
    /// 「右クリックしないとできないこと」が生まれて、キーで使う人が損をする。
    /// 逆に、キーを覚えていない人はここだけで一通りできる。
    private func contextMenu(forRow row: Int) -> NSMenu? {
        guard row >= 0, row < results.count else { return nil }
        let kind = results[row].item.kind
        let menu = NSMenu()

        func add(_ title: String, _ keys: String, _ action: @escaping () -> Void) {
            let item = NSMenuItem(title: title, action: #selector(runMenuAction(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = MenuAction(run: action)
            // ⚠️ キーは「押せる印」ではなく**覚書き**として題名に混ぜる。
            // keyEquivalent に入れると品書きが閉じたあとも効いてしまい、二重に登録されたのと同じになる
            item.title = "\(title)　\(keys)"
            menu.addItem(item)
        }

        switch kind {
        case .clip(let clip):
            let count = tableView.selectedRowIndexes.count
            add(count > 1 ? "\(count)件を貼り付け" : "貼り付け", "⏎") { [weak self] in self?.activateSelection() }
            add("コピー", "⌘C") { [weak self] in self?.copySelectionOnly() }
            add(clip.pinned ? "ピン留めを外す" : "ピン留め", "⌘P") { [weak self] in self?.togglePinOnSelection() }
            menu.addItem(.separator())
            add(count > 1 ? "\(count)件を削除" : "削除", "⌘⌫") { [weak self] in self?.deleteSelectedClips() }

        case .snippet(let snippet):
            add("貼り付け", "⏎") { [weak self] in self?.activateSelection() }
            add("編集", "⌘E") { [weak self] in self?.editSnippet(snippet) }
            menu.addItem(.separator())
            add("削除", "⌘⌫") { [weak self] in self?.deleteSnippet(snippet) }

        case .quicklink(let link):
            add("開く", "⏎") { [weak self] in self?.activateSelection() }
            add("編集", "⌘E") { [weak self] in self?.editQuicklink(link) }
            menu.addItem(.separator())
            add("削除", "⌘⌫") { [weak self] in self?.deleteQuicklink(link) }

        case .savedSearch(let saved):
            add("この条件で探す", "⏎") { [weak self] in self?.activateSelection() }
            add("編集", "⌘E") { [weak self] in self?.editSelectedSavedSearch(saved) }
            menu.addItem(.separator())
            add("削除", "⌘⌫") { [weak self] in self?.deleteSelectedSavedSearch(saved) }

        default:
            // 消したり直したりできない行（アプリ・コマンド・ファイル）には品書きを出さない。
            // 「実行」しか無い品書きは、出す意味より「押したのに何も無い」の方が大きい
            return nil
        }
        return menu
    }

    @objc private func runMenuAction(_ sender: NSMenuItem) {
        (sender.representedObject as? MenuAction)?.run()
    }

    private func activateSelection() {
        if let pending = pendingItem {
            let query = searchField.stringValue
            pendingItem = nil
            execute(pending, query: query)
            return
        }
        guard let item = selectedItem else { return }
        if item.needsQuery {
            pendingItem = item
            searchField.stringValue = ""
            refreshChrome()
            reload()
            return
        }
        execute(item, query: "")
    }

    private func execute(_ item: LauncherItem, query: String) {
        switch item.kind {
        case .header:
            return  // 見出しは選べないので来ないはずだが、来ても何もしない

        case .commandGroup(let title, let commands):
            // 畳みを開く。窓は閉じない
            openGroup = (title: title, items: commands.map {
                LauncherItem.from($0, displayTitle: CommandGrouping.shortTitle($0.title), badge: "")
            })
            searchField.stringValue = ""
            refreshChrome()
            reload()

        case .savedSearch(let saved):
            // 保存した条件を検索欄に入れて、打ったのと同じ道で実行する
            searchField.stringValue = saved.query
            runFilesSearch()

        case .section(let target):
            // 窓は閉じない。中身だけ入れ替える。
            goTo(target)

        case .openNote:
        // ⚠️ 先に閉じない。閉じると窓が1つも無くなってテモトが前面から外れ、
        // そのあとの「前に出る」がmacOSに拒否されて、開いた窓が**後ろに回る**
        // （2026-08-04「＋ボタン押しても何も反応しない」＝実は後ろで開いていた）。
        // 開く側（PanelCoordinator.willOpen）が先に閉じてくれるので、任せる。
            onOpenNote?()

        case .captureText:
            // ⚠️ 先に閉じる。テモトの窓が出たままだと、その窓ごと撮ってしまう
            close(reason: .finished)
            ActionRunner.captureTextToClipboard()

        case .shot(let shot):
            // ⚠️ 同じ理由で先に閉じる。とくに「画面全体」は窓が写り込むと台無しになる
            let target = previousApp
            close(reason: .finished)
            // ⚠️ 閉じ切ってから撮る。閉じる動きが残っていると、消えかけの窓が写る
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                if shot.target == .scrollingPage {
                    // ⚠️ 相手が前に出るのを待ってから測る（閉じた直後はまだ入れ替わっていない）
                    target?.activate()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        ScrollCapture.run(target: target)
                    }
                } else {
                    ActionRunner.capture(shot)
                }
            }

        case .systemPlace(let place):
            // Mac そのものの操作。設定画面はURLで開く（アプリを名指ししない＝macOSの版に強い）
            close(reason: .finished)
            ActionRunner.runSystemPlace(place)

        case .openTarget(let target):
            // 打った文字がそのまま行き先
            close(reason: .finished)
            switch target {
            case .url(let url): ActionRunner.run(.openURL(url), query: "")
            case .path(let path): ActionRunner.run(.openPath(path), query: "")
            }

        case .escapeToFiles(let text):
            // 窓は閉じない。ファイル検索へ移って、打った言葉をそのまま渡す
            goTo(.files)
            searchField.stringValue = text
            runFilesSearch()

        case .escapeToWeb(let text):
            close(reason: .finished)
            ActionRunner.run(.openURL(QuickOpen.webSearchURL(for: text)), query: "")

        case .note(let note):
            // ⚠️ 先に閉じない（.openNote と同じ理由。閉じると開いた窓が後ろに回る）
            onOpenNoteItem?(note)

        case .app(let path):
            close(reason: .finished)
            ActionRunner.open(appPath: path)

        case .command(let command):
            close(reason: .finished)
            ActionRunner.run(command.action, query: query)

        case .quicklink(let link):
            close(reason: .finished)
            ActionRunner.openURL(link.resolvedURL(query: query))

        case .snippet(let snippet):
            let text = SnippetExpander.expand(snippet.body, context: SnippetContext(
                clipboard: NSPasteboard.general.string(forType: .string) ?? "",
                query: query
            ))
            pasteAndClose(text)

        case .clip(let clip):
            pasteClip(clip)

        case .calc(let line):
            // ⚠️ 貼るのは display（1,234,567）ではなく生の数。
            // 桁区切りは読むための飾りで、表計算やfreeeに入れると文字として扱われる
            rememberCalc(line)
            pasteAndClose(CalcLine.trimZeros(line.value))

        case .answer(let answer):
            // ⚠️ 貼るのは display（1,234,567）ではなく value（1234567）。
            // 桁区切りは読むための飾りで、表計算やfreeeに入れると文字として扱われる。
            pasteAndClose(answer.value)

        case .file(let hit):
            close(reason: .finished)
            ActionRunner.openPath(hit.path)

        case .layout(let layout):
            close(reason: .handOffToPreviousApp)
            // 前のアプリが前面に戻ってからでないと、その手前のウィンドウを掴んでしまう
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
                guard let self else { return }
                if let failure = self.windowManager.apply(layout) {
                    Toast.show(failure.message, isError: true)
                }
            }
        }
    }

    private func pasteAndClose(_ text: String) {
        // 貼り付け先は閉じる前に押さえておく。
        // 焦点はこちらから触らない（Paster が自分で前面に出して貼るので、二重に動かすと取り合いになる）
        let target = previousApp
        close(reason: .finished)
        Paster.paste(text, into: target, window: previousWindow) { [weak self] in
            self?.watcher.ignoreCurrentChange()
        }
    }

    /// 履歴の1件を貼る。文字・絵・ファイルで置き方が違う。
    private func pasteClip(_ clip: ClipItem) {
        switch clip.kind {
        case .text:
            pasteAndClose(clip.text)

        case .image:
            guard let png = store.loadClipImage(id: clip.id) else {
                // 鍵を作り直した後など、絵の実体が開けないとき。
                // 黙って何もしないと「押しても反応しない」と見えるので、理由を出す。
                Toast.show("この画像は開けませんでした（鍵が変わった可能性があります）", isError: true)
                return
            }
            let target = previousApp
            close(reason: .finished)
            Paster.pasteImage(png, into: target, window: previousWindow) { [weak self] in
                self?.watcher.ignoreCurrentChange()
            }

        case .file:
            let available = ClipItem.availablePaths(clip.filePaths) { FileManager.default.fileExists(atPath: $0) }
            guard !available.isEmpty else {
                Toast.show("元のファイルが見つかりません（移動または削除されています）", isError: true)
                return
            }
            let target = previousApp
            close(reason: .finished)
            Paster.pasteFiles(available, into: target, window: previousWindow) { [weak self] in
                self?.watcher.ignoreCurrentChange()
            }
            if available.count < clip.filePaths.count {
                Toast.show("\(clip.filePaths.count - available.count)件は見つからないので外しました")
            }
        }
    }

    // MARK: - 履歴の操作

    private func copySelectionOnly() {
        guard let item = selectedItem else { return }

        // ファイル検索では ⌘C は「置き場所（パス）を文字でコピー」。
        // ファイルそのものが欲しいときは ⌥⏎（Finder の ⌘C と同じ結果になる）。
        if case .file(let hit) = item.kind {
            Paster.copy(hit.path)
            watcher.ignoreCurrentChange()
            close(reason: .handOffToPreviousApp)
            Toast.show("パスをコピーしました")
            return
        }

        guard case .clip(let clip) = item.kind else { return }
        switch clip.kind {
        case .text:
            Paster.copy(clip.text)
        case .image:
            guard let png = store.loadClipImage(id: clip.id) else {
                Toast.show("この画像は開けませんでした（鍵が変わった可能性があります）", isError: true)
                return
            }
            Paster.copyImage(png)
        case .file:
            let available = ClipItem.availablePaths(clip.filePaths) { FileManager.default.fileExists(atPath: $0) }
            guard !available.isEmpty else {
                Toast.show("元のファイルが見つかりません（移動または削除されています）", isError: true)
                return
            }
            Paster.copyFiles(available)
        }
        watcher.ignoreCurrentChange()
        close(reason: .handOffToPreviousApp)
        Toast.show("コピーしました")
    }

    // MARK: - ファイルの操作

    /// ⌥⏎。ファイルそのものをコピーする（中身ではなく置き場所を渡す＝Finder の ⌘C と同じ）。
    /// ここで今回作ったクリップボードのファイル対応がそのまま効く。
    private func copyFileItself(_ hit: FileHit) {
        guard FileManager.default.fileExists(atPath: hit.path) else {
            Toast.show("見つかりません（移動または削除されています）", isError: true)
            return
        }
        Paster.copyFiles([hit.path])
        watcher.ignoreCurrentChange()
        close(reason: .handOffToPreviousApp)
        Toast.show("ファイルをコピーしました")
    }

    /// ⌘Y。中身をその場で見る（Quick Look）。
    ///
    /// ⚠️ Quick Look は自分がキーウィンドウになる。何もしないと
    /// windowDidResignKey が走って検索窓が閉じ、プレビューだけが残る。
    /// isPreviewing の間だけ「焦点を失っても閉じない」ようにしている。
    private func previewSelection() {
        guard let item = selectedItem, case .file(let hit) = item.kind else { return }
        guard FileManager.default.fileExists(atPath: hit.path) else {
            Toast.show("見つかりません（移動または削除されています）", isError: true)
            return
        }
        guard let previewPanel = QLPreviewPanel.shared() else { return }
        previewURLs = [URL(fileURLWithPath: hit.path)]
        isPreviewing = true
        previewPanel.dataSource = self
        previewPanel.delegate = self
        previewPanel.reloadData()
        // 閉じたことを知る道。これが無いと isPreviewing が立ちっぱなしになり、
        // 以後どこをクリックしても検索窓が閉じなくなる。
        NotificationCenter.default.addObserver(
            self, selector: #selector(previewPanelClosed),
            name: NSWindow.willCloseNotification, object: previewPanel)
        previewPanel.makeKeyAndOrderFront(nil)
    }

    @objc private func previewPanelClosed(_ notification: Notification) {
        NotificationCenter.default.removeObserver(
            self, name: NSWindow.willCloseNotification, object: notification.object)
        isPreviewing = false
        previewURLs = []
        // 見終わったら検索窓に戻す（プレビューを閉じたら消えていた、では続けて探せない）
        guard panel.isVisible else { return }
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(searchField)
    }

    private func togglePinOnSelection() {
        guard let item = selectedItem, case .clip(let clip) = item.kind,
              let index = store.clips.firstIndex(where: { $0.id == clip.id }) else { return }
        store.clips[index].pinned.toggle()
        let pinned = store.clips[index].pinned
        store.saveClips()
        let row = tableView.selectedRow
        reload()
        if row >= 0, row < results.count {
            tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        }
        Toast.show(pinned ? "ピン留めしました" : "ピン留めを外しました")
    }

    /// いま選んでいる履歴を消す。
    ///
    /// ⚠️ 複数選んでいたら**全部**消す。
    /// 前は1件だけだった。⇧↑↓ で3件選んで ⌘⌫ を押すと1件しか消えず、
    /// 残った2件が「消したはずなのに残っている」ように見える
    /// （見られたくないものを消す場面では、これは危ない外れ方）。
    ///
    /// ⚠️ 2件以上のときだけ一度きく。1件は迷わず消す（消したい場面で確認は邪魔）。
    /// まとめて消すのは取り返しがつかないので、そこだけ足を止める。
    private func deleteSelectedClips() {
        let rows = tableView.selectedRowIndexes.sorted()
        let clips: [ClipItem] = rows.compactMap { row in
            guard row < results.count, case .clip(let clip) = results[row].item.kind else { return nil }
            return clip
        }
        guard !clips.isEmpty else { return }

        if clips.count > 1 {
            let alert = NSAlert()
            alert.messageText = "\(clips.count)件を消しますか？"
            alert.informativeText = "元には戻せません。"
            alert.alertStyle = .warning
            alert.addButton(withTitle: "消す")
            alert.addButton(withTitle: "やめる")
            NSApp.activate()
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }

        let doomed = Set(clips.map(\.id))
        let firstRow = rows.first ?? tableView.selectedRow
        store.clips.removeAll { doomed.contains($0.id) }
        store.saveClips()
        // ⚠️ 絵は履歴とは別ファイル。行を消しただけではディスクに残る。
        // 「見られたくないものを消した」つもりで残っているのが、いちばんまずい消え残り
        for clip in clips where clip.kind == .image {
            store.deleteClipImage(id: clip.id)
            ClipThumbnailCache.forget(clip.id)
            PreviewImageCache.forget(clip.id)
        }
        reload()
        if !results.isEmpty {
            let next = min(max(firstRow, 0), results.count - 1)
            tableView.selectRowIndexes(IndexSet(integer: next), byExtendingSelection: false)
        }
        Toast.show(clips.count == 1 ? "1件を消しました" : "\(clips.count)件を消しました",
                   area: "コピー履歴")
    }
}

// MARK: - Quick Look

/// ⌘Y で中身をその場で見るための橋渡し。
///
/// ⚠️ 本来は responder chain 越しに Quick Look へ「私が面倒を見ます」と名乗る作りだが、
/// テモトの検索窓は borderless の NSPanel で、名乗る場所（acceptsPreviewPanelControl）に
/// 届かない。そこで dataSource / delegate を直接差している。
/// 代わりに「閉じたこと」を自分で見張る必要がある（previewPanelClosed）。
extension LauncherController: QLPreviewPanelDataSource, QLPreviewPanelDelegate {

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        previewURLs.count
    }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        guard index >= 0, index < previewURLs.count else { return nil }
        return previewURLs[index] as NSURL
    }
}

/// 定型文ダイアログで打つ値
struct SnippetDraftValues {
    var title: String
    var keyword: String
    var body: String
}

/// 定型文ダイアログの ⏎ を「次の欄へ」に変える係。
///
/// ⚠️ 既定のままだと ⏎ が「保存」に化ける。名前を打って ⏎ を押した人は
/// 「次の欄へ行く」つもりなのに、本文が空のまま保存が走る
/// （2026-07-31「保存を押しても保存されない」の正体になりうる道）。
final class SnippetFieldChain: NSObject, NSTextFieldDelegate {
    private let next: [ObjectIdentifier: NSResponder]

    init(next: [ObjectIdentifier: NSResponder]) {
        self.next = next
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard selector == #selector(NSResponder.insertNewline(_:)),
              let target = next[ObjectIdentifier(control)] else { return false }
        control.window?.makeFirstResponder(target)
        return true
    }
}


/// 品書きの1行が持つ「押したら何をするか」。
/// ⚠️ NSMenuItem の representedObject は Any なので、閉包をそのまま入れられない。
/// 小さな入れ物に包んで持たせる
private final class MenuAction {
    let run: () -> Void
    init(run: @escaping () -> Void) { self.run = run }
}
