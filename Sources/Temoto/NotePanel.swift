import AppKit
import TemotoCore

/// メモ。左に一覧、右に書く場所。
///
/// ⚠️ 2026-07-30 作者の依頼で「1枚の走り書き」から作り直した。
/// 「保存ボタンが欲しい」「メモしたことを検索できる様に」「メモがリストに出る様に」
/// 「保存先を選択できる様に（md形式で所定のフォルダーに保存や、このアプリ上に保存など）」。
///
/// 保存先は1枚ごとに2択:
/// - **このアプリの中** … 暗号化して notes.enc へ。打つたびに保存（今までどおり）。
///   振込先など秘密を書いてよいのはこちらだけ
/// - **フォルダ（.md）** … 作者が選んだフォルダに**平文**の .md で置く。
///   Obsidian や他の道具からも読める代わりに、秘密を書いてはいけない
///
/// 見た目は検索窓とそろえる（枠なし・角丸・すりガラス・同じ大きさ・同じ位置）。
/// ここだけ違う顔にすると「別のアプリが開いた」ように見える。
final class NoteController: NSObject, NSWindowDelegate, NSTextViewDelegate, NSTextFieldDelegate,
                            NSTableViewDataSource, NSTableViewDelegate {

    private let store: Store
    /// 窓の交通整理（戻り先の記録と、他の窓をどかす手配）
    private let coordinator: PanelCoordinator
    private let panel: KeyPanel

    private let chip = ChipView(text: "メモ")

    /// 入口（検索窓）へ戻るときに呼ぶ。
    ///
    /// ⚠️ これが要る理由（2026-08-30 作者「メモの画面からバックスペースや
    /// 左上に矢印があってメニューに戻れる様にして欲しい」）。
    /// メモは検索窓から入ってくるのに、**戻る道が esc（＝閉じる）しか無かった**。
    /// 閉じると入口も消えるので、続けて別のことをするには呼び出しからやり直しになる。
    /// 検索窓の中の行き先は ⌫ で親へ戻れるのに、メモだけ行き止まりだった。
    var onGoBack: (() -> Void)?

    /// 左上の戻る矢印
    private let backButton = ChipButton(title: "")
    private let searchField = NSTextField()
    /// 選んでいるメモの保存先。切り替えると**そのメモが引っ越す**
    private let destinationPopup = ChipPopUpButton()
    private let saveButton = ChipButton(title: "保存")

    private let listScroll = NSScrollView()
    private let tableView = NonFocusingTableView()
    private let paneDivider = HairlineView(frame: .zero)
    private let editorScroll = NSScrollView()
    private let textView = NSTextView()
    private let emptyState = EmptyStateView()
    private let hintBar = HintBarView()
    /// 検索欄のカプセルの地（見た目の切り替えで塗り直すため持っておく）
    private var searchBackView: NSView?

    /// どのメモを開いているか
    private enum Selection: Equatable {
        case app(UUID)
        case file(String)     // ファイル名（.md）
        /// フォルダ行きの新しいメモ。書き始めたときに初めてファイルが生まれる
        case newFile
    }

    /// 一覧の1行
    private struct Row {
        let selection: Selection
        let title: String
        let subtitle: String
    }

    private var folderNotes: [FolderNote] = []
    private var rows: [Row] = []
    private var current: Selection?
    /// アプリの中行きの新しいメモ（まだ store に入れていない下書き）。
    /// ⚠️ 作った瞬間に store に入れると、空のまま閉じたとき「無題のメモ」が積もっていく。
    /// 書き始めたときに初めて store に入れる（フォルダ行きの .newFile と同じ理屈）。
    private var draftNote: Note?
    private var saveWork: DispatchWorkItem?
    private var isClosing = false
    /// 確認ダイアログやフォルダ選択を出している最中か。
    /// ⚠️ ダイアログが前に出ると、この窓は「焦点を失った」ことになり、
    /// 外クリックで閉じる仕組みが誤発動して**ダイアログの裏で窓が閉じる**
    /// （2026-07-30 作者「削除ボタン押しても戻れない」の正体。Quick Look と同じ罠）。
    private var isShowingDialog = false
    /// 一覧を組み直している最中は選択の通知を無視する（無限ループよけ）
    private var isRebuilding = false

    private static let panelWidth: CGFloat = 720
    private static let panelHeight: CGFloat = 460
    private static let headerHeight: CGFloat = 60
    private static let hintRowHeight: CGFloat = 38
    private static let listWidth: CGFloat = 220

    init(store: Store, coordinator: PanelCoordinator) {
        self.store = store
        self.coordinator = coordinator
        panel = KeyPanel(
            contentRect: NSRect(x: 0, y: 0,
                                width: NoteController.panelWidth,
                                height: NoteController.panelHeight),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        super.init()
        buildPanel()
        coordinator.register(
            .note,
            isVisible: { [weak self] in self?.panel.isVisible ?? false },
            close: { [weak self] reason in self?.close(reason: reason) }
        )
    }

    // MARK: - 画面の組み立て

    private func buildPanel() {
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.delegate = self
        panel.isReleasedWhenClosed = false
        panel.keyEquivalentHandler = { [weak self] event in self?.handleKeyEquivalent(event) ?? false }

        let width = NoteController.panelWidth
        let height = NoteController.panelHeight
        let header = NoteController.headerHeight
        let hintRow = NoteController.hintRowHeight
        let listWidth = NoteController.listWidth

        let container = BackdropView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        panel.contentView = container

        // ── 上段: 札・検索・保存先・保存ボタン
        let headerY = height - header + 15

        // ⚠️ 矢印は札の**左**に置く。macOS のどのアプリでも戻るは左上で、
        // そこに無いと「戻れない画面」に見える（実際そう思われた）
        backButton.image = NSImage(systemSymbolName: "chevron.left", accessibilityDescription: "戻る")
        backButton.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 11, weight: .semibold)
        backButton.imagePosition = .imageOnly
        backButton.setAccessibilityLabel("戻る")
        backButton.toolTip = "検索窓に戻る（⌫）"
        backButton.target = self
        backButton.action = #selector(goBack)
        backButton.frame = NSRect(x: Theme.Space.edge, y: headerY + 3, width: 26, height: 24)
        container.addSubview(backButton)

        let chipX = Theme.Space.edge + 26 + 8
        let chipWidth = min(chip.frame.width, 120)
        chip.setFrameSize(NSSize(width: chipWidth, height: chip.frame.height))
        chip.setFrameOrigin(NSPoint(x: chipX, y: headerY + (30 - chip.frame.height) / 2))
        container.addSubview(chip)

        saveButton.target = self
        saveButton.action = #selector(saveNow)
        saveButton.sizeToFit()
        let saveWidth = saveButton.frame.width
        saveButton.frame = NSRect(x: width - Theme.Space.edge - saveWidth,
                                  y: headerY + 3, width: saveWidth, height: 24)
        container.addSubview(saveButton)

        destinationPopup.addItem(withTitle: "アプリの中（暗号化）")
        destinationPopup.addItem(withTitle: "フォルダ（.md）")
        destinationPopup.addItem(withTitle: "フォルダを選ぶ…")
        destinationPopup.target = self
        destinationPopup.action = #selector(destinationPicked)
        let popupWidth: CGFloat = 158
        destinationPopup.frame = NSRect(x: width - Theme.Space.edge - saveWidth - 8 - popupWidth,
                                        y: headerY + 3, width: popupWidth, height: 24)
        container.addSubview(destinationPopup)

        // 検索欄にはカプセルの淡い地を敷く（macOS 26 の Search Field の形）。
        // ⚠️ 検索窓（ランチャー）の大きな検索欄は裸のまま＝Spotlight と同じ顔が正しい。
        // こちらは補助の検索なので、枠が無いと「打てる場所」だと気づかれない
        let searchX = chipX + chipWidth + 10
        let searchWidth = width - searchX - Theme.Space.edge - saveWidth - popupWidth - 26
        let searchBack = NSView(frame: NSRect(x: searchX - 2, y: headerY + 1, width: searchWidth + 4, height: 28))
        searchBack.wantsLayer = true
        searchBack.layer?.cornerRadius = 14
        searchBackView = searchBack
        container.addSubview(searchBack)

        searchField.isBordered = false
        searchField.drawsBackground = false
        searchField.focusRingType = .none
        searchField.font = .systemFont(ofSize: 15, weight: .regular)
        searchField.delegate = self
        searchField.cell?.usesSingleLineMode = true
        searchField.placeholderAttributedString = NSAttributedString(
            string: "メモを検索", attributes: [
                .font: NSFont.systemFont(ofSize: 15, weight: .regular),
                .foregroundColor: Theme.Palette.captionText,
            ])
        searchField.frame = NSRect(x: searchX + 10, y: headerY + 4,
                                   width: searchWidth - 20,
                                   height: 22)
        container.addSubview(searchField)
        applySearchBackColor()

        container.addSubview(HairlineView.full(y: height - header, width: width))

        // ── 左: 一覧
        listScroll.frame = NSRect(x: 0, y: hintRow, width: listWidth, height: height - header - hintRow)
        listScroll.hasVerticalScroller = true
        listScroll.autohidesScrollers = true
        listScroll.drawsBackground = false
        listScroll.automaticallyAdjustsContentInsets = false
        listScroll.contentInsets = NSEdgeInsets(top: 6, left: 0, bottom: 6, right: 0)

        tableView.headerView = nil
        tableView.rowHeight = 44
        tableView.backgroundColor = .clear
        tableView.style = .plain
        tableView.selectionHighlightStyle = .regular
        tableView.allowsEmptySelection = false
        tableView.allowsMultipleSelection = false
        tableView.intercellSpacing = NSSize(width: 0, height: 2)
        tableView.dataSource = self
        tableView.delegate = self
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("note"))
        column.width = listWidth
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        tableView.autoresizingMask = [.width]
        tableView.sizeLastColumnToFit()
        listScroll.documentView = tableView
        container.addSubview(listScroll)

        emptyState.frame = listScroll.frame
        emptyState.isHidden = true
        container.addSubview(emptyState)

        paneDivider.frame = NSRect(x: listWidth, y: hintRow, width: 1, height: height - header - hintRow)
        container.addSubview(paneDivider)

        // ── 右: 書く場所
        editorScroll.frame = NSRect(x: listWidth + 1, y: hintRow,
                                    width: width - listWidth - 1, height: height - header - hintRow)
        editorScroll.hasVerticalScroller = true
        editorScroll.autohidesScrollers = true
        editorScroll.drawsBackground = false

        textView.frame = NSRect(x: 0, y: 0, width: width - listWidth - 1, height: height - header - hintRow)
        textView.autoresizingMask = [.width]
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                                  height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.textContainer?.widthTracksTextView = true
        textView.font = .systemFont(ofSize: 14)
        textView.textContainerInset = NSSize(width: 16, height: 12)
        textView.drawsBackground = false
        // 「-」が「—」に化けたり、引用符が全角になったりすると、パスやコマンドを貼ったとき壊れる
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.delegate = self
        editorScroll.documentView = textView
        container.addSubview(editorScroll)

        container.addSubview(HairlineView.full(y: hintRow, width: width))

        hintBar.frame = NSRect(x: 0, y: 0, width: width, height: hintRow)
        hintBar.autoresizingMask = [.width]
        hintBar.setActions([
            HintAction("⌘S", "保存"),
            HintAction("⌘N", "新規"),
            HintAction("⌘F", "検索"),
            HintAction("⌘⇧⌫", "削除"),
            // ⚠️ 「戻る」と「閉じる」は違う。戻る＝入口へ、閉じる＝テモトごと消える。
            // 左上の矢印を置いたうえで、ここにも書く（矢印に気づかない人のために）
            HintAction("⌫", "戻る"),
            HintAction("esc", "閉じる", isEssential: true),
        ])
        // 札はクリックでも効く（キーの説明とボタンを同じ札が兼ねる）
        hintBar.onAction = { [weak self] action in self?.runHintAction(action.keys) }
        container.addSubview(hintBar)
    }

    private func applySearchBackColor() {
        guard let view = searchBackView else { return }
        view.effectiveAppearance.performAsCurrentDrawingAppearance {
            view.layer?.backgroundColor = Theme.Palette.keyCapFill.cgColor
            view.layer?.borderWidth = 0
        }
    }

    // MARK: - 開閉

    func toggle() {
        if panel.isVisible {
            close(reason: .hotkey)
        } else {
            show()
        }
    }

    /// 入口の検索で選んだ1枚を開いて、その行に着地する。
    /// 2026-08-05「全ての入り口としてテモトを利用したい」＝メモも入口から直接引けるようにした分の受け口
    func show(selecting note: Note) {
        landing = .app(note.id)
        show()
    }

    /// 開いた直後にどの行へ着地するか（1回だけ効く）
    private var landing: Selection?

    func show() {
        coordinator.willOpen(.note)

        searchField.stringValue = ""
        folderNotes = NoteFolder.scan(store.settings.note.folderPath)
        // ⚠️ landing は使ったら必ず捨てる。残すと次に ⌃M で開いたときも同じ1枚に戻る
        let target = landing ?? mostRecentSelection()
        landing = nil
        rebuildList(select: target)
        if rows.isEmpty {
            newAppNote()
        }
        positionPanel()

        let finalFrame = panel.frame
        panel.alphaValue = 0
        panel.setFrame(NSRect(x: finalFrame.origin.x, y: finalFrame.origin.y - 8,
                              width: finalFrame.width, height: finalFrame.height), display: false)

        NSApp.activate()
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(textView)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().setFrame(finalFrame, display: true)
            panel.animator().alphaValue = 1
        } completionHandler: { [weak self] in
            self?.panel.alphaValue = 1
        }
        coordinator.didOpen(.note)
    }

    func close(reason: CloseReason) {
        guard panel.isVisible, !isClosing else { return }
        isClosing = true
        defer { isClosing = false }

        endEditing()
        flush()
        panel.orderOut(nil)
        coordinator.didClose(.note, reason: reason)
    }

    /// 日本語入力の変換中に窓が消えると、未確定の分の行き場が無くなる。先に確定させる
    private func endEditing() {
        guard PanelBehavior.commitsInputBeforeClose(.note) else { return }
        if textView.hasMarkedText() { textView.unmarkText() }
        panel.makeFirstResponder(nil)
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

    // MARK: - 一覧

    /// いちばん最近さわったメモ（開いたときに選んでおく）
    private func mostRecentSelection() -> Selection? {
        let newestApp = store.notes.max { $0.updatedAt < $1.updatedAt }
        let newestFile = folderNotes.first     // scan が新しい順で返す
        switch (newestApp, newestFile) {
        case (nil, nil): return nil
        case (let app?, nil): return .app(app.id)
        case (nil, let file?): return .file(file.fileName)
        case (let app?, let file?):
            return app.updatedAt >= file.modifiedAt ? .app(app.id) : .file(file.fileName)
        }
    }

    /// 一覧を組み直す。アプリの中とフォルダの両方を、新しい順にひとつの列へ。
    private func rebuildList(select: Selection?) {
        isRebuilding = true
        defer { isRebuilding = false }

        let query = searchField.stringValue
        var entries: [(date: Date, row: Row)] = []

        for note in store.notes {
            let title = NoteText.title(for: note.body)
            guard NoteText.matches(title: title, body: note.body, query: query) else { continue }
            entries.append((note.updatedAt, Row(
                selection: .app(note.id),
                title: title,
                subtitle: "\(ClipFormatter.relative(note.updatedAt))・暗号化")))
        }
        for file in folderNotes {
            guard NoteText.matches(title: file.title, body: file.body, query: query) else { continue }
            entries.append((file.modifiedAt, Row(
                selection: .file(file.fileName),
                title: file.title,
                subtitle: "\(ClipFormatter.relative(file.modifiedAt))・.md")))
        }
        var built = entries.sorted { $0.date > $1.date }.map(\.row)

        // 書きかけ（まだどこにも無い）は先頭に出す
        if current == .newFile {
            built.insert(Row(selection: .newFile, title: NoteText.untitled, subtitle: "書き始めると .md を作ります"), at: 0)
        }
        if let draft = draftNote, current == .app(draft.id) {
            built.insert(Row(selection: .app(draft.id), title: NoteText.untitled,
                             subtitle: "書き始めると保存します（暗号化）"), at: 0)
        }
        rows = built
        tableView.reloadData()

        let target = select ?? current
        if let target, let index = rows.firstIndex(where: { $0.selection == target }) {
            tableView.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
            tableView.scrollRowToVisible(index)
            if current != target { adopt(target) }
        } else if let first = rows.first {
            tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
            adopt(first.selection)
        } else {
            current = nil
            textView.string = ""
        }

        emptyState.isHidden = !rows.isEmpty
        if rows.isEmpty {
            emptyState.configure(
                symbol: "note.text",
                message: query.isEmpty ? "メモがありません" : "見つかりません",
                detail: query.isEmpty ? "⌘N で新しく作れます" : "言葉を変えてみてください")
        }
        refreshStatus()
    }

    /// 選んだメモを右に開く（開く前に、前のメモの書きかけを保存する）
    private func adopt(_ selection: Selection) {
        current = selection
        switch selection {
        case .app(let id):
            textView.string = store.notes.first { $0.id == id }?.body ?? ""
            // store に無ければ下書き（本文はまだ無い）
        case .file(let name):
            textView.string = folderNotes.first { $0.fileName == name }?.body ?? ""
        case .newFile:
            textView.string = ""
        }
        refreshStatus()
    }

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let identifier = NSUserInterfaceItemIdentifier("noteRow")
        let view: NoteRowView
        if let reused = tableView.makeView(withIdentifier: identifier, owner: self) as? NoteRowView {
            view = reused
        } else {
            view = NoteRowView(frame: .zero)
            view.identifier = identifier
        }
        view.configure(title: rows[row].title, subtitle: rows[row].subtitle)
        return view
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let identifier = NSUserInterfaceItemIdentifier("noteRowBackground")
        if let reused = tableView.makeView(withIdentifier: identifier, owner: self) as? LauncherRowBackground {
            return reused
        }
        let view = LauncherRowBackground()
        view.identifier = identifier
        return view
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !isRebuilding else { return }
        let row = tableView.selectedRow
        guard row >= 0, row < rows.count else { return }
        let next = rows[row].selection
        guard next != current else { return }
        // 前のメモの書きかけを置いてから移る
        flush()
        // 空のまま離れた書きかけは行ごと消す（幽霊の「無題のメモ」を残さない）
        var dropped = false
        if let draft = draftNote, current == .app(draft.id), next != .app(draft.id) {
            draftNote = nil
            dropped = true
        }
        if current == .newFile, next != .newFile {
            dropped = true
        }
        adopt(next)
        if dropped { rebuildList(select: next) }
    }

    // MARK: - 保存

    /// 打つたびに呼ばれる。手が止まって0.8秒たってから保存する
    func textDidChange(_ notification: Notification) {
        refreshStatus()
        saveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.flush() }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: work)
    }

    /// いま書き込む。閉じるとき・メモを移るとき・⌘S のとき（アプリ終了時は外からも呼ぶ）。
    func flush() {
        saveWork?.cancel()
        saveWork = nil
        guard let current else { return }
        let body = textView.string

        switch current {
        case .app(let id):
            if let index = store.notes.firstIndex(where: { $0.id == id }) {
                guard store.notes[index].body != body else { return }
                store.notes[index].body = body
                store.notes[index].updatedAt = Date()
                store.saveNotes()
                rebuildList(select: current)
            } else if var draft = draftNote, draft.id == id {
                // 下書きに初めて中身が入った。ここで store に入る
                guard !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
                draft.body = body
                draft.updatedAt = Date()
                store.notes.append(draft)
                draftNote = nil
                store.saveNotes()
                rebuildList(select: .app(draft.id))
            }

        case .file(let name):
            guard let index = folderNotes.firstIndex(where: { $0.fileName == name }) else { return }
            guard folderNotes[index].body != body else { return }
            if NoteFolder.write(body, fileName: name, folderPath: store.settings.note.folderPath) {
                folderNotes[index].body = body
                folderNotes[index].modifiedAt = Date()
                rebuildList(select: current)
            } else {
                Toast.show("書き込めませんでした: \(name)", isError: true)
            }

        case .newFile:
            // 書き始めて初めてファイルが生まれる（空のファイルをばら撒かない）
            guard !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            let folder = store.settings.note.folderPath
            let stamp = NoteController.stampFormatter.string(from: Date())
            let name = NoteText.fileName(for: body,
                                         existing: NoteFolder.existingNames(folder),
                                         fallback: "メモ \(stamp)")
            if NoteFolder.write(body, fileName: name, folderPath: folder) {
                folderNotes = NoteFolder.scan(folder)
                self.current = .file(name)
                rebuildList(select: .file(name))
            } else {
                Toast.show("書き込めませんでした（フォルダを確かめてください）", isError: true)
            }
        }
    }

    private static let stampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ja_JP")
        f.dateFormat = "yyyy-MM-dd HHmm"
        return f
    }()

    /// 保存ボタン・⌘S。自動でも保存しているが、「いま保存できた」と手応えを返す
    @objc private func saveNow() {
        endEditingKeepingFocus()
        flush()
        switch current {
        case .app(let id):
            if store.notes.contains(where: { $0.id == id }) {
                Toast.show("保存しました（このアプリの中・暗号化）")
            } else {
                Toast.show("まだ空です。書き始めると保存します")
            }
        case .file(let name): Toast.show("保存しました: \(name)")
        case .newFile: Toast.show("まだ空です。書き始めると .md を作ります")
        case nil: break
        }
    }

    /// 変換中の文字だけ確定させる（焦点は編集エリアに残す）
    private func endEditingKeepingFocus() {
        if textView.hasMarkedText() { textView.unmarkText() }
    }

    // MARK: - 新規・削除・保存先

    /// ⌘N。今の場所（アプリの中／フォルダ）と同じ側に作る
    @objc private func newNote() {
        flush()
        switch current {
        case .file, .newFile:
            guard !store.settings.note.folderPath.isEmpty else {
                newAppNote()
                return
            }
            current = .newFile
            textView.string = ""
            rebuildList(select: .newFile)
        default:
            newAppNote()
        }
        panel.makeFirstResponder(textView)
    }

    private func newAppNote() {
        let note = Note()
        draftNote = note
        current = .app(note.id)
        textView.string = ""
        rebuildList(select: .app(note.id))
    }

    /// ⌘⇧⌫。編集中の ⌘⌫（行頭まで消す）とぶつからないよう、⇧を足してある
    private func deleteCurrent() {
        guard let current else { return }

        if let draft = draftNote, current == .app(draft.id) {
            draftNote = nil
            self.current = nil
            rebuildList(select: nil)
            if rows.isEmpty { newAppNote() }
            return
        }
        let title: String
        switch current {
        case .app(let id): title = NoteText.title(for: store.notes.first { $0.id == id }?.body ?? "")
        case .file(let name): title = name
        case .newFile:
            self.current = nil
            rebuildList(select: nil)
            return
        }

        let alert = NSAlert()
        alert.messageText = "「\(title)」を消しますか？"
        alert.informativeText = {
            switch current {
            case .file: return ".md ファイルはゴミ箱へ移します（完全には消しません）。"
            default: return "このアプリの中から消します。元には戻せません。"
            }
        }()
        alert.alertStyle = .warning
        alert.addButton(withTitle: "消す")
        alert.addButton(withTitle: "やめる")
        isShowingDialog = true
        NSApp.activate()
        let response = alert.runModal()
        isShowingDialog = false
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(textView)
        guard response == .alertFirstButtonReturn else { return }

        switch current {
        case .app(let id):
            store.notes.removeAll { $0.id == id }
            store.saveNotes()
        case .file(let name):
            if !NoteFolder.trash(name, folderPath: store.settings.note.folderPath) {
                Toast.show("ゴミ箱へ移せませんでした", isError: true)
                return
            }
            folderNotes = NoteFolder.scan(store.settings.note.folderPath)
            Toast.show("ゴミ箱へ移しました: \(name)")
        case .newFile:
            break
        }
        self.current = nil
        rebuildList(select: nil)
        if rows.isEmpty { newAppNote() }
    }

    /// 保存先の切り替え＝選んでいるメモの引っ越し
    @objc private func destinationPicked() {
        let index = destinationPopup.indexOfSelectedItem
        if index == 2 {
            chooseFolder()
            refreshStatus()   // 選び直しても今のメモの場所は変わらない。表示を戻す
            return
        }
        guard let current else { refreshStatus(); return }

        switch (current, index) {
        case (.app(let id), 1):
            moveAppNoteToFolder(id: id)
        case (.file(let name), 0):
            moveFileNoteToApp(fileName: name)
        case (.newFile, 0):
            flush()
            newAppNote()
        default:
            refreshStatus()   // 既に同じ場所。表示だけ合わせ直す
        }
    }

    private func moveAppNoteToFolder(id: UUID) {
        flush()
        if store.settings.note.folderPath.isEmpty {
            guard chooseFolder() else { refreshStatus(); return }
        }
        let folder = store.settings.note.folderPath
        guard let note = store.notes.first(where: { $0.id == id }) else { return }

        // ⚠️ 暗号化 → 平文 への引っ越し。ここだけは黙ってやらない
        let alert = NSAlert()
        alert.messageText = "平文の .md に移しますか？"
        alert.informativeText = "フォルダの .md は暗号化されません。振込先やパスワードが書いてあるメモは移さないでください。"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "移す")
        alert.addButton(withTitle: "やめる")
        isShowingDialog = true
        NSApp.activate()
        let response = alert.runModal()
        isShowingDialog = false
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(textView)
        guard response == .alertFirstButtonReturn else { refreshStatus(); return }

        let stamp = NoteController.stampFormatter.string(from: Date())
        let name = NoteText.fileName(for: note.body,
                                     existing: NoteFolder.existingNames(folder),
                                     fallback: "メモ \(stamp)")
        guard NoteFolder.write(note.body, fileName: name, folderPath: folder) else {
            Toast.show("書き込めませんでした（フォルダを確かめてください）", isError: true)
            refreshStatus()
            return
        }
        store.notes.removeAll { $0.id == id }
        store.saveNotes()
        folderNotes = NoteFolder.scan(folder)
        current = .file(name)
        rebuildList(select: .file(name))
        Toast.show("移しました: \(name)")
    }

    private func moveFileNoteToApp(fileName: String) {
        flush()
        guard let file = folderNotes.first(where: { $0.fileName == fileName }) else { return }
        let note = Note(body: file.body)
        store.notes.append(note)
        store.saveNotes()
        // 元の .md はゴミ箱へ（残すと同じメモが2枚に見え、どちらが本物か分からなくなる）
        if NoteFolder.trash(fileName, folderPath: store.settings.note.folderPath) {
            Toast.show("アプリの中へ移しました（元の .md はゴミ箱にあります）")
        } else {
            Toast.show("アプリの中へ写しました（元の .md はそのまま残っています）")
        }
        folderNotes = NoteFolder.scan(store.settings.note.folderPath)
        current = .app(note.id)
        rebuildList(select: .app(note.id))
    }

    /// .md の置き場を選ぶ。選べたら true
    @discardableResult
    private func chooseFolder() -> Bool {
        let open = NSOpenPanel()
        open.canChooseDirectories = true
        open.canChooseFiles = false
        open.canCreateDirectories = true
        open.prompt = "この場所に保存"
        open.message = "メモ（.md）の置き場を選んでください。ここに置いたメモは暗号化されません。"
        if !store.settings.note.folderPath.isEmpty {
            open.directoryURL = URL(fileURLWithPath: store.settings.note.folderPath)
        }
        isShowingDialog = true
        NSApp.activate()
        let response = open.runModal()
        isShowingDialog = false
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(textView)
        guard response == .OK, let url = open.url else { return false }
        store.settings.note.folderPath = url.path
        store.saveSettings()
        folderNotes = NoteFolder.scan(url.path)
        rebuildList(select: current)
        Toast.show("メモの置き場: \(url.path)")
        return true
    }

    // MARK: - 検索

    func controlTextDidChange(_ obj: Notification) {
        rebuildList(select: current)
    }

    /// 検索欄で ↑↓ したら一覧を動かし、⏎ で書く場所へ移る
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.moveDown(_:)):
            moveListSelection(by: 1)
            return true
        case #selector(NSResponder.moveUp(_:)):
            moveListSelection(by: -1)
            return true
        case #selector(NSResponder.insertNewline(_:)):
            panel.makeFirstResponder(self.textView)
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            if !searchField.stringValue.isEmpty {
                searchField.stringValue = ""
                rebuildList(select: current)
                return true
            }
            close(reason: .escape)
            return true
        case #selector(NSResponder.deleteBackward(_:)):
            // ⚠️ 空のときだけ。打った字がある間は、ふつうに1文字消す。
            // 検索窓の中の行き先（コピー履歴・定型文…）とまったく同じ決まりにしてある。
            // ⚠️ 本文（textView）の ⌫ には触らない。あそこで戻ったら文章が書けない
            guard searchField.stringValue.isEmpty else { return false }
            goBack()
            return true
        default:
            return false
        }
    }

    private func moveListSelection(by step: Int) {
        guard !rows.isEmpty else { return }
        let next = min(max(tableView.selectedRow + step, 0), rows.count - 1)
        tableView.selectRowIndexes(IndexSet(integer: next), byExtendingSelection: false)
        tableView.scrollRowToVisible(next)
    }

    /// 入口（検索窓）へ戻る。
    /// ⚠️ 先に保存する。メモは打つたびに保存しているが、
    /// 変換中の字など「まだ確定していない分」が残っていることがある
    @objc private func goBack() {
        saveNow()
        onGoBack?()
    }

    // MARK: - キー

    private func handleKeyEquivalent(_ event: NSEvent) -> Bool {
        guard panel.isVisible, event.modifierFlags.contains(.command) else { return false }

        // ⌘⇧⌫ = 削除（⌘⌫は編集中の「行頭まで消す」なので取らない）
        if event.keyCode == 51, event.modifierFlags.contains(.shift) {
            deleteCurrent()
            return true
        }
        switch event.charactersIgnoringModifiers?.lowercased() {
        case "s":
            saveNow()
            return true
        case "n":
            newNote()
            return true
        case "f":
            panel.makeFirstResponder(searchField)
            return true
        case "w":
            guard PanelBehavior.closesOnCommandW(.note) else { return false }
            close(reason: .commandW)
            return true
        default:
            return false
        }
    }

    /// 下の帯の札がクリックされたとき。キーを押したのと同じことを起こす
    private func runHintAction(_ keys: String) {
        switch keys {
        case "⌘S": saveNow()
        case "⌘N": newNote()
        case "⌘F": panel.makeFirstResponder(searchField)
        case "⌘⇧⌫": deleteCurrent()
        case "esc": close(reason: .escape)
        default: break
        }
    }

    /// esc で閉じる（NSTextView の中では esc が入力補完に化けるので両方受ける）
    func textView(_ view: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.cancelOperation(_:)),
             #selector(NSStandardKeyBindingResponding.complete(_:)):
            guard PanelBehavior.closesOnEscape(.note) else { return false }
            close(reason: .escape)
            return true
        default:
            return false
        }
    }

    func windowDidResignKey(_ notification: Notification) {
        guard PanelBehavior.closesWhenFocusLost(.note) else { return }
        // ダイアログに焦点が移っただけなら閉じない（裏で閉じると「戻れない」になる）
        guard !isShowingDialog else { return }
        close(reason: .focusLost)
    }

    func windowWillClose(_ notification: Notification) {
        flush()
    }

    // MARK: - 状態の表示

    private func refreshStatus() {
        let count = textView.string.count
        var parts: [String] = ["\(rows.count)枚"]
        parts.append("\(count)文字")

        switch current {
        case .app:
            destinationPopup.selectItem(at: 0)
            if store.canPersistSecrets {
                parts.append("打つたびに暗号化して保存")
            } else {
                parts.append("⚠️ 鍵が無いため保存しません（起動中だけ保持）")
            }
        case .file(let name):
            destinationPopup.selectItem(at: 1)
            parts.append("手が止まると \(name) へ保存（平文）")
        case .newFile:
            destinationPopup.selectItem(at: 1)
            parts.append("書き始めるとフォルダに .md を作ります")
        case nil:
            break
        }
        hintBar.status = parts.joined(separator: "・")
    }
}

/// メモ一覧の1行（題名＋いつ・どこ）
final class NoteRowView: NSTableCellView {
    private let titleField = NSTextField(labelWithString: "")
    private let subtitleField = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        titleField.font = .systemFont(ofSize: 13, weight: .medium)
        titleField.textColor = .labelColor
        titleField.lineBreakMode = .byTruncatingTail
        subtitleField.font = .systemFont(ofSize: 10.5)
        subtitleField.textColor = Theme.Palette.captionText
        subtitleField.lineBreakMode = .byTruncatingTail
        addSubview(titleField)
        addSubview(subtitleField)
    }

    required init?(coder: NSCoder) { fatalError("使わない") }

    func configure(title: String, subtitle: String) {
        titleField.stringValue = title
        subtitleField.stringValue = subtitle
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let x = Theme.Space.rowInset + 10
        let width = max(bounds.width - x * 2, 40)
        titleField.frame = NSRect(x: x, y: bounds.height - 22, width: width, height: 17)
        subtitleField.frame = NSRect(x: x, y: 5, width: width, height: 14)
    }
}
