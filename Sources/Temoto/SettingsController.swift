import AppKit
import TemotoCore
import UniformTypeIdentifiers

/// 設定画面。
///
/// ⚠️ ここが無かったことが、作者の「全然ダメ」の中身のひとつ。
///   「設定画面もないし、ショートカットも設定できないし」
///
/// 前の作りでは settings.json を手で開いて、キーコードの数字を書き換えるしかなかった。
/// それは作った人にしか使えない＝設定できないのと同じなので、
/// 画面から押して決められるようにする。
///
/// 方針:
///   ・日本語だけで書く（英語のラベルは1つも出さない）
///   ・押したその場で効かせる（「保存」ボタンを押し忘れて効かない、を作らない）
///   ・押せない案内はしない（「許可してください」と書いて許可できなかった件の反省）
final class SettingsController: NSObject, NSWindowDelegate, NSTextFieldDelegate {

    private let store: Store
    /// ショートカットを変えたら呼ぶ。AppDelegate がホットキーを登録し直す。
    private let onShortcutsChanged: () -> Void
    /// 使う機能を変えたら呼ぶ。メニューと検索窓を作り直す。
    private let onFeaturesChanged: () -> Void

    /// 見つかったアプリ全部を取りに行く（出していないものも含む）
    private let appRecords: () -> [AppRecord]
    /// ディスクを読み直す
    private let rescanApps: () -> Void
    /// メニューから移ってきた「コピー履歴をすべて消す」。実体は AppDelegate が持つ
    private let onClearClips: () -> Void
    /// 警告のしるし（メニューバー）を合わせ直してもらう合図。ログイン項目を切り替えたときに呼ぶ
    private let onStatusChanged: () -> Void
    /// 窓の交通整理（戻り先の記録と、他の窓をどかす手配）
    private let coordinator: PanelCoordinator

    private var window: SettingsWindow?
    /// タブを外から選ぶために持っておく（棚の「＋」→「アプリのキー」）
    private weak var tabView: NSTabView?
    /// キーの重なりを知らせる赤い文字。
    /// ⚠️ 1つではなく全部持つ。キーを決められる画面が2つ（ショートカット／アプリのキー）あり、
    /// 片方にしか出さないと、見ていない方のタブで重ねたときに何も言わないことになる。
    private var conflictLabels: [NSTextField] = []
    private var shortcutFields: [ShortcutField] = []

    /// 「Macの起動時に開く」の印と、その下の一言と、システム設定を開くボタン。
    /// 状態は覚えずに毎回OSへ聞くので、聞いた結果を映すためにここを持っておく。
    private var loginItemBox: NSButton?
    private var loginItemNote: NSTextField?
    private var loginItemButton: NSButton?

    /// 行き先の並べ替え一覧。押すたびにまるごと作り直すので入れ物を持っておく
    private var entryList: NSStackView?
    private var entryResetButton: NSButton?

    init(
        store: Store,
        coordinator: PanelCoordinator,
        onShortcutsChanged: @escaping () -> Void,
        onFeaturesChanged: @escaping () -> Void,
        appRecords: @escaping () -> [AppRecord],
        rescanApps: @escaping () -> Void,
        onClearClips: @escaping () -> Void,
        onStatusChanged: @escaping () -> Void
    ) {
        self.store = store
        self.coordinator = coordinator
        self.onShortcutsChanged = onShortcutsChanged
        self.onFeaturesChanged = onFeaturesChanged
        self.appRecords = appRecords
        self.rescanApps = rescanApps
        self.onClearClips = onClearClips
        self.onStatusChanged = onStatusChanged
        super.init()
        coordinator.register(
            .settings,
            isVisible: { [weak self] in self?.window?.isVisible ?? false },
            close: { [weak self] reason in self?.close(reason: reason) }
        )
    }

    // MARK: - 開閉

    /// タブを指定して開く（棚の「＋」から「アプリのキー」へ直接連れていくため）
    func show(selecting tabTitle: String) {
        show()
        guard let tabView,
              let index = tabView.tabViewItems.firstIndex(where: { $0.label == tabTitle }) else { return }
        tabView.selectTabViewItem(at: index)
    }

    func show() {
        // ⚠️ 検索窓とメモは浮く窓（.floating）で、設定は普通の窓。
        // 出したまま設定を開くと設定の手前に被って押せないので、先にどかす。
        coordinator.willOpen(.settings)

        if window == nil {
            window = buildWindow()
            window?.center()   // 動かした位置は覚える。開くたびに真ん中へ戻さない。
        }
        refreshConflicts()
        // ⚠️ ログイン項目はシステム設定から直接外せる。
        // 窓は作り直さず使い回すので、開くたびにOSへ聞き直さないと古い印が残る
        refreshLoginItem()
        // メニューバーだけのアプリなので、自分で前面に出ないと後ろに隠れたままになる
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
        coordinator.didOpen(.settings)
    }

    /// 閉じる。
    ///
    /// 設定は枠のある普通の窓なので、外をクリックしても閉じない
    /// （他のアプリを見ながら設定を変えることがあるため）。
    /// 決まりは TemotoCore.PanelBehavior にまとめてある。
    func close(reason: CloseReason) {
        guard let window, window.isVisible else { return }
        window.close()   // windowWillClose で書きかけを保存する
        coordinator.didClose(.settings, reason: reason)
    }

    func windowWillClose(_ notification: Notification) {
        // 「保存しない条件」を書いたまま閉じられても取りこぼさない。
        // 閉じる操作で知らせを出すとうるさいので、ここでは黙って保存する。
        window?.makeFirstResponder(nil)
        applyClipboard(notify: false)
        applyFileSearch(notify: false)
    }

    // MARK: - 窓の組み立て

    private static let contentWidth: CGFloat = 620
    private static let contentHeight: CGFloat = 540

    private func buildWindow() -> SettingsWindow {
        let w = SettingsWindow(
            contentRect: NSRect(x: 0, y: 0, width: SettingsController.contentWidth, height: SettingsController.contentHeight),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        w.title = "テモトの設定"
        w.delegate = self
        w.isReleasedWhenClosed = false
        // ⚠️ 見出しの棒を透かして、下の地色と地続きに見せる。
        // 灰色の帯で上を区切ると、検索窓・メモの2つ（枠なし・すりガラス）と並べたときに
        // ここだけ古い作りに見え、作者の言う「一つ一つが別アプリみたい」に戻る。
        w.titlebarAppearsTransparent = true
        // 閉じるボタンだけでなく、手が覚えている esc と ⌘W でも閉じられるようにする
        w.onDismiss = { [weak self] reason in self?.close(reason: reason) }

        let tabs = NSTabView(frame: NSRect(x: 0, y: 0, width: SettingsController.contentWidth, height: SettingsController.contentHeight))
        tabView = tabs
        // ⚠️ 既定は中身を灰色の箱で囲う（`tabViewBorderType = .bezel`）。
        // 箱の中に箱が入って見えるうえ、後ろの地色を塗り潰すので枠を外す。
        tabs.tabViewBorderType = .none
        tabs.autoresizingMask = [.width, .height]
        tabs.addTabViewItem(tab("一般", view: buildGeneralTab()))
        tabs.addTabViewItem(tab("ショートカット", view: buildShortcutTab()))
        tabs.addTabViewItem(tab("アプリのキー", view: buildAppShortcutTab()))
        tabs.addTabViewItem(tab("使う機能", view: buildFeatureTab()))
        tabs.addTabViewItem(tab("出すアプリ", view: buildAppTab()))
        tabs.addTabViewItem(tab("コピー履歴", view: buildClipboardTab()))
        tabs.addTabViewItem(tab("ファイル検索", view: buildFileSearchTab()))

        // 地にすりガラスを敷く。
        // ⚠️ ここだけ BackdropView を使わないのは、設定は**枠のある普通の窓**で、
        // 角丸も縁も macOS が描くため（自前で描くと角が二重になる）。
        // 材質が `.windowBackground` なのは、腰を据えて読む画面だから
        // （呼び出してすぐ消える検索窓の `.popover` より、地に落ち着きがある）。
        let background = NSVisualEffectView(frame: tabs.frame)
        background.material = .windowBackground
        background.blendingMode = .behindWindow
        background.state = .active
        background.autoresizesSubviews = true
        background.addSubview(tabs)
        w.contentView = background
        return w
    }

    private func tab(_ label: String, view: NSView) -> NSTabViewItem {
        let item = NSTabViewItem(identifier: label)
        item.label = label
        item.view = view
        return item
    }

    // MARK: - ショートカット

    private func buildShortcutTab() -> NSView {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: SettingsController.contentWidth, height: SettingsController.contentHeight))

        let footerHeight: CGFloat = 60
        let scroll = NSScrollView(frame: NSRect(x: 0, y: footerHeight, width: container.bounds.width,
                                                height: container.bounds.height - footerHeight - 40))
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.autoresizingMask = [.width, .height]

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 20, bottom: 16, right: 20)

        stack.addArrangedSubview(heading("開くもの"))
        // この4つは「割り当てなし」を許さない（無くすと開く手段が消える）ので、
        // set に nil が来ることはない。来ても何もしない。
        stack.addArrangedSubview(shortcutRow("検索を開く",
            get: { [store] in store.settings.launcherShortcut },
            set: { [store] value in if let value { store.settings.launcherShortcut = value } }))
        stack.addArrangedSubview(shortcutRow("コピー履歴",
            get: { [store] in store.settings.clipboardShortcut },
            set: { [store] value in if let value { store.settings.clipboardShortcut = value } }))
        stack.addArrangedSubview(shortcutRow("定型文",
            get: { [store] in store.settings.snippetShortcut },
            set: { [store] value in if let value { store.settings.snippetShortcut = value } }))
        stack.addArrangedSubview(shortcutRow("メモ",
            get: { [store] in store.settings.noteShortcut },
            set: { [store] value in if let value { store.settings.noteShortcut = value } }))

        stack.addArrangedSubview(spacer(10))
        stack.addArrangedSubview(heading("ウィンドウを動かす"))
        // 割り当ての無い配置も並べる。⌫ で消せて、押せば付けられる。
        for layout in WindowLayout.allCases {
            stack.addArrangedSubview(shortcutRow(
                layout.title,
                allowsEmpty: true,
                get: { [store] in store.settings.windowBindings.first { $0.layout == layout }?.shortcut },
                set: { [store] value in
                    store.settings.windowBindings.removeAll { $0.layout == layout }
                    if let value {
                        store.settings.windowBindings.append(WindowBinding(layout: layout, shortcut: value))
                    }
                }
            ))
        }

        stack.addArrangedSubview(spacer(10))
        stack.addArrangedSubview(heading("画面をまたぐ"))
        for step in [1, -1] {
            stack.addArrangedSubview(shortcutRow(
                step > 0 ? "次の画面へ移す" : "前の画面へ移す",
                allowsEmpty: true,
                get: { [store] in store.settings.displayBindings.first { $0.step == step }?.shortcut },
                set: { [store] value in
                    store.settings.displayBindings.removeAll { $0.step == step }
                    if let value {
                        store.settings.displayBindings.append(DisplayBinding(step: step, shortcut: value))
                    }
                }
            ))
        }

        stack.addArrangedSubview(spacer(10))
        stack.addArrangedSubview(heading("文字を変換"))
        let convertNote = NSTextField(labelWithString:
            "どのアプリでも、選んでいる文字をその場で置き換えます（コピー→変換→貼り付けを1押しで）。")
        convertNote.font = .systemFont(ofSize: 11)
        convertNote.textColor = .secondaryLabelColor
        convertNote.lineBreakMode = .byWordWrapping
        convertNote.maximumNumberOfLines = 2
        stack.addArrangedSubview(convertNote)
        for transform in TextTransform.allCases {
            stack.addArrangedSubview(shortcutRow(
                "\(transform.title)に変換",
                allowsEmpty: true,
                get: { [store] in store.settings.convertBindings.first { $0.transform == transform }?.shortcut },
                set: { [store] value in
                    store.settings.convertBindings.removeAll { $0.transform == transform }
                    if let value {
                        store.settings.convertBindings.append(ConvertBinding(transform: transform, shortcut: value))
                    }
                }
            ))
        }

        stack.addArrangedSubview(spacer(10))
        stack.addArrangedSubview(heading("貼り付け"))
        let pasteNote = NSTextField(labelWithString:
            "コピー中の文字から色や書式を落として、そのまま貼り付けます（Webやメールからのコピーに）。")
        pasteNote.font = .systemFont(ofSize: 11)
        pasteNote.textColor = .secondaryLabelColor
        pasteNote.lineBreakMode = .byWordWrapping
        pasteNote.maximumNumberOfLines = 2
        stack.addArrangedSubview(pasteNote)
        stack.addArrangedSubview(shortcutRow(
            "書式なしで貼り付け",
            allowsEmpty: true,
            get: { [store] in store.settings.pastePlainShortcut },
            set: { [store] value in store.settings.pastePlainShortcut = value }
        ))
        // 合言葉の自動展開。⚠️ キーの流れを見る仕組みなので、何を見て何を見ないかを明記する
        let expandToggle = NSButton(checkboxWithTitle: "合言葉の自動展開（どのアプリでも、打った瞬間に本文へ置き換える）",
                                    target: self, action: #selector(toggleExpandSnippets(_:)))
        expandToggle.state = store.settings.expandSnippets ? .on : .off
        stack.addArrangedSubview(expandToggle)
        let expandNote = NSTextField(labelWithString:
            "定型文の「読みがな」を英数で打つと、その場で本文に置き換わります（例: mailz）。"
            + "打った文字はどこにも保存・送信しません。パスワード欄と日本語入力の変換中は動きません。"
            + "アクセシビリティの許可が必要です。")
        expandNote.font = .systemFont(ofSize: 11)
        expandNote.textColor = .secondaryLabelColor
        expandNote.lineBreakMode = .byWordWrapping
        expandNote.maximumNumberOfLines = 3
        stack.addArrangedSubview(expandNote)
        stack.addArrangedSubview(spacer(8))

        // 不具合の記録。⚠️ どこにも自動で送らないことを、ボタンのそばに書く
        // （書かないと「勝手に送られているのでは」と思われる。通信ゼロが看板なので致命的）
        let problemButton = NSButton(title: "問題を報告する…", target: self,
                                     action: #selector(showProblems))
        problemButton.bezelStyle = .rounded
        stack.addArrangedSubview(problemButton)
        let problemNote = NSTextField(labelWithString:
            "うまくいかなかったことを手元に記録しています。中身を読んでから、"
            + "コピーかファイルで渡せます。どこにも自動では送りません。")
        problemNote.font = .systemFont(ofSize: 11)
        problemNote.textColor = .secondaryLabelColor
        problemNote.lineBreakMode = .byWordWrapping
        problemNote.maximumNumberOfLines = 3
        stack.addArrangedSubview(problemNote)
        stack.addArrangedSubview(spacer(8))

        stack.addArrangedSubview(shortcutRow(
            "画面の文字を読み取る",
            allowsEmpty: true,
            get: { [store] in store.settings.captureTextShortcut },
            set: { [store] value in store.settings.captureTextShortcut = value }
        ))

        let documentView = NSView()
        documentView.addSubview(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        documentView.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = documentView
        NSLayoutConstraint.activate([
            documentView.widthAnchor.constraint(equalTo: scroll.widthAnchor),
            stack.topAnchor.constraint(equalTo: documentView.topAnchor),
            stack.leadingAnchor.constraint(equalTo: documentView.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: documentView.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: documentView.bottomAnchor),
        ])
        container.addSubview(scroll)

        let help = NSTextField(labelWithString:
            "枠を押してから、使いたいキーを押してください。⌘⌃⌥⇧ のどれかと組み合わせます（単独のキーは使えません）。"
            + "⌫ で割り当てを外す、esc でやめる。")
        help.font = .systemFont(ofSize: 11)
        help.textColor = .secondaryLabelColor
        help.lineBreakMode = .byWordWrapping
        help.maximumNumberOfLines = 2
        help.frame = NSRect(x: 20, y: 30, width: container.bounds.width - 40, height: 30)
        help.autoresizingMask = [.width, .maxYMargin]
        container.addSubview(help)

        let conflict = NSTextField(labelWithString: "")
        conflict.font = .systemFont(ofSize: 11, weight: .medium)
        conflict.textColor = .systemRed
        conflict.lineBreakMode = .byTruncatingTail
        conflict.frame = NSRect(x: 20, y: 10, width: container.bounds.width - 160, height: 16)
        conflict.autoresizingMask = [.width, .maxYMargin]
        container.addSubview(conflict)
        conflictLabels.append(conflict)

        let reset = NSButton(title: "はじめの設定に戻す", target: self, action: #selector(resetShortcuts))
        reset.bezelStyle = .rounded
        reset.frame = NSRect(x: container.bounds.width - 160, y: 4, width: 145, height: 26)
        reset.autoresizingMask = [.minXMargin, .maxYMargin]
        container.addSubview(reset)

        return container
    }

    /// 名前 ＋ ショートカットの枠 の1行
    private func shortcutRow(
        _ title: String,
        allowsEmpty: Bool = false,
        get: @escaping () -> Shortcut?,
        set: @escaping (Shortcut?) -> Void
    ) -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.spacing = 12
        row.alignment = .centerY

        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 13)
        label.alignment = .right
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        label.widthAnchor.constraint(equalToConstant: 230).isActive = true

        let field = ShortcutField()
        field.translatesAutoresizingMaskIntoConstraints = false
        field.allowsEmpty = allowsEmpty
        field.shortcut = get()
        field.onChange = { [weak self] value in
            set(value)
            self?.store.saveSettings()
            self?.onShortcutsChanged()
            self?.refreshConflicts()
        }
        field.widthAnchor.constraint(equalToConstant: 170).isActive = true
        field.heightAnchor.constraint(equalToConstant: 26).isActive = true
        shortcutFields.append(field)

        row.addArrangedSubview(label)
        row.addArrangedSubview(field)
        return row
    }

    @objc private func resetShortcuts() {
        let alert = NSAlert()
        alert.messageText = "ショートカットをはじめの設定に戻しますか？"
        // ⚠️ アプリのキーはここで消さない。
        // あれは作者が1つずつ選んだもの＝作り直すのに手間がかかる。
        // 「はじめの設定に戻す」を押しただけで消えると、取り戻せない。
        alert.informativeText = "自分で決めたキーの組み合わせは消えます。"
            + "アプリのキー・履歴・定型文・メモには触りません。"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "戻す")
        alert.addButton(withTitle: "やめる")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let d = Settings()
        store.settings.launcherShortcut = d.launcherShortcut
        store.settings.clipboardShortcut = d.clipboardShortcut
        store.settings.snippetShortcut = d.snippetShortcut
        store.settings.noteShortcut = d.noteShortcut
        store.settings.windowBindings = d.windowBindings
        store.settings.displayBindings = d.displayBindings
        store.settings.convertBindings = d.convertBindings
        store.settings.pastePlainShortcut = d.pastePlainShortcut
        store.settings.captureTextShortcut = d.captureTextShortcut
        store.saveSettings()
        onShortcutsChanged()

        // 画面の札も戻す。作り直すのが一番確実（16個の枠を1つずつ書き換えない）。
        let old = window
        window = nil
        shortcutFields.removeAll()
        conflictLabels.removeAll()
        old?.delegate = nil          // 閉じる処理で今の設定を上書きしないように外す
        old?.close()
        show()
        Toast.show("ショートカットをはじめの設定に戻しました")
    }

    /// 同じキーを2つに割り当ててしまったときに、その場で知らせる。
    /// 黙って片方だけ効く状態が一番分かりにくいので、必ず名前を出す。
    private func refreshConflicts() {
        let conflicts = store.settings.conflicts()
        let text = conflicts.isEmpty ? "" : conflicts
            .map { "\($0.shortcut.displayString) が重なっています（\($0.names.joined(separator: "・"))）" }
            .joined(separator: "　")
        for label in conflictLabels { label.stringValue = text }
    }

    // MARK: - アプリのキー
    //
    // 2026-07-29 作者「よくアクセスするアプリについてアプリ別にショートカットを設けて欲しい。」
    //
    // ⚠️「ショートカット」タブと分けている理由。
    // あちらは"テモトの機能"に振るキーで、数が決まっている（16個）。
    // こちらは作者が選んだアプリに振るキーで、増えたり減ったりする。
    // 同じ画面に混ぜると、決まったものと増えるものが同じ見た目で並び、
    // 「消していいのはどれか」が読み取れなくなる。

    private var appShortcutList: NSStackView?
    private var appShortcutEmptyLabel: NSTextField?

    private func buildAppShortcutTab() -> NSView {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: SettingsController.contentWidth, height: SettingsController.contentHeight))

        let lead = NSTextField(labelWithString:
            "よく開くアプリにキーを割り当てます。テモトを開かずに、押しただけでそのアプリへ移ります。\n"
            + AppHotKey.note)
        lead.font = .systemFont(ofSize: 12)
        lead.textColor = .secondaryLabelColor
        lead.lineBreakMode = .byWordWrapping
        lead.maximumNumberOfLines = 3
        lead.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(lead)

        let scroll = NSScrollView(frame: .zero)
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(scroll)

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 10, left: 8, bottom: 10, right: 8)
        stack.translatesAutoresizingMaskIntoConstraints = false
        appShortcutList = stack

        let documentView = FlippedView()
        documentView.translatesAutoresizingMaskIntoConstraints = false
        documentView.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: documentView.topAnchor),
            stack.leadingAnchor.constraint(equalTo: documentView.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: documentView.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: documentView.bottomAnchor),
        ])
        scroll.documentView = documentView
        NSLayoutConstraint.activate([
            documentView.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
        ])

        // 1件も無いときの言葉。空の白い箱だけ出して「壊れている」と思わせない
        let empty = NSTextField(labelWithString:
            "まだ1つも割り当てていません。下の「アプリを選ぶ…」から選ぶと、"
            + "空いている ⌃⌥⌘1 から順に自動で割り当てます（あとから変えられます）。")
        empty.font = .systemFont(ofSize: 12)
        empty.textColor = .tertiaryLabelColor
        empty.lineBreakMode = .byWordWrapping
        empty.maximumNumberOfLines = 2
        empty.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(empty)
        appShortcutEmptyLabel = empty

        let conflict = NSTextField(labelWithString: "")
        conflict.font = .systemFont(ofSize: 11, weight: .medium)
        conflict.textColor = .systemRed
        conflict.lineBreakMode = .byTruncatingTail
        conflict.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(conflict)
        conflictLabels.append(conflict)

        let add = NSButton(title: "アプリを選ぶ…", target: self, action: #selector(addAppShortcut))
        add.bezelStyle = .rounded
        add.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(add)

        NSLayoutConstraint.activate([
            lead.topAnchor.constraint(equalTo: container.topAnchor, constant: 16),
            lead.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20),
            lead.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -20),

            empty.topAnchor.constraint(equalTo: lead.bottomAnchor, constant: 14),
            empty.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 22),
            empty.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -22),

            scroll.topAnchor.constraint(equalTo: lead.bottomAnchor, constant: 12),
            scroll.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20),
            scroll.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -20),
            scroll.bottomAnchor.constraint(equalTo: conflict.topAnchor, constant: -8),

            conflict.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20),
            conflict.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -20),
            conflict.bottomAnchor.constraint(equalTo: add.topAnchor, constant: -8),

            add.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20),
            add.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -16),
        ])

        rebuildAppShortcutList()
        return container
    }

    /// 一覧をまるごと作り直す。
    /// ⚠️ 行が増減する画面なので、1行だけ差し替える作りにしない
    /// （消した行の下がずれて、別のアプリのキーを外してしまう）。
    private func rebuildAppShortcutList() {
        guard let stack = appShortcutList else { return }
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let bindings = store.settings.appBindings
        for binding in bindings {
            stack.addArrangedSubview(appShortcutRow(binding))
        }
        appShortcutEmptyLabel?.isHidden = !bindings.isEmpty
        refreshConflicts()
    }

    private func appShortcutRow(_ binding: AppBinding) -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 10

        let icon = NSImageView()
        icon.image = IconCache.appIcon(binding.path)
        icon.imageScaling = .scaleProportionallyDown
        icon.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: 22),
            icon.heightAnchor.constraint(equalToConstant: 22),
        ])

        // ⚠️ 消えたアプリも一覧に残して、消えたことをその場に書く。
        // 黙って行ごと消すと、押しても何も起きないキーだけが残り、
        // 作者は「テモトが壊れた」としか読めない。
        let exists = FileManager.default.fileExists(atPath: binding.path)
        let name = NSTextField(labelWithString: exists ? binding.name : "\(binding.name)（見つかりません）")
        name.font = .systemFont(ofSize: 13)
        name.textColor = exists ? .labelColor : .systemRed
        name.lineBreakMode = .byTruncatingTail
        name.translatesAutoresizingMaskIntoConstraints = false
        name.widthAnchor.constraint(equalToConstant: 260).isActive = true

        let path = binding.path
        let field = ShortcutField()
        field.translatesAutoresizingMaskIntoConstraints = false
        field.allowsEmpty = false      // 空にする＝外すことなので、⌫ ではなく「外す」ボタンでやってもらう
        field.shortcut = binding.shortcut
        field.onChange = { [weak self] value in
            guard let self, let value else { return }
            // 名前は入れ直さない（選んだときの呼び名のまま）
            let current = self.store.settings.appBindings.first { $0.path == path }?.name
                ?? AppBinding.displayName(path: path)
            self.store.settings.setAppShortcut(path: path, name: current, shortcut: value)
            self.store.saveSettings()
            self.onShortcutsChanged()
            self.refreshConflicts()
        }
        field.widthAnchor.constraint(equalToConstant: 150).isActive = true
        field.heightAnchor.constraint(equalToConstant: 26).isActive = true
        shortcutFields.append(field)

        let remove = NSButton(title: "外す", target: self, action: #selector(removeAppShortcut(_:)))
        remove.bezelStyle = .rounded
        remove.identifier = NSUserInterfaceItemIdentifier(path)

        row.addArrangedSubview(icon)
        row.addArrangedSubview(name)
        row.addArrangedSubview(field)
        row.addArrangedSubview(remove)
        return row
    }

    /// アプリを選ぶ。
    ///
    /// ⚠️ 見つかったアプリを並べた一覧ではなく Finder の選び方にしてある。
    /// 一覧だと、テモトがまだ数えていないアプリ（入れたばかり・変わった場所にあるもの）を
    /// 選べない。「一覧に無い＝割り当てられない」は、理由が画面から読み取れない。
    @objc private func addAppShortcut() {
        guard let shortcut = store.settings.suggestedAppShortcut() else {
            let alert = NSAlert()
            alert.messageText = "空いているキーがありません"
            alert.informativeText = Settings.appShortcutFullMessage
            alert.alertStyle = .informational
            alert.addButton(withTitle: "わかりました")
            alert.runModal()
            return
        }

        let panel = NSOpenPanel()
        panel.title = "キーを割り当てるアプリを選ぶ"
        panel.prompt = "選ぶ"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        guard panel.runModal() == .OK, let url = panel.url else { return }

        let path = url.path
        // 選んだのが既に登録済みなら、キーは振り直さない（今のキーを覚えているので勝手に変えない）
        if store.settings.appShortcut(for: path) != nil {
            Toast.show("\(AppBinding.displayName(path: path)) はすでに割り当ててあります")
            rebuildAppShortcutList()
            return
        }

        let name = FileManager.default.displayName(atPath: path)
        store.settings.setAppShortcut(
            path: path,
            name: name.hasSuffix(".app") ? String(name.dropLast(4)) : name,
            shortcut: shortcut
        )
        store.saveSettings()
        onShortcutsChanged()
        rebuildAppShortcutList()
        Toast.show("\(shortcut.displayString) で \(name) を開けるようにしました")
    }

    @objc private func removeAppShortcut(_ sender: NSButton) {
        guard let path = sender.identifier?.rawValue else { return }
        store.settings.removeAppShortcut(path: path)
        store.saveSettings()
        onShortcutsChanged()
        rebuildAppShortcutList()
    }

    // MARK: - 一般
    //
    // ⚠️ なぜこの画面が要るか（2026-07-29）。
    // テモトには自動起動の仕組みが1行も無く、動いていたのは手で起動したものだけだった。
    // Raycast はログイン項目に入っているので、乗り換えてから再起動すると
    // 「Raycastは消した・テモトも立ち上がらない」で何も呼び出せなくなる。

    private func buildGeneralTab() -> NSView {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: SettingsController.contentWidth, height: SettingsController.contentHeight))

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: container.topAnchor, constant: 24),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -24),
        ])

        stack.addArrangedSubview(heading("起動"))

        let box = NSButton(checkboxWithTitle: "Macの起動時にテモトを開く",
                           target: self, action: #selector(loginItemToggled(_:)))
        box.font = .systemFont(ofSize: 13)
        loginItemBox = box
        stack.addArrangedSubview(box)

        // 説明はチェックの文字に揃える（「使う機能」タブと同じ理由で横の並びに包む）
        let note = NSTextField(labelWithString: "")
        note.font = .systemFont(ofSize: 11)
        note.textColor = .secondaryLabelColor
        note.lineBreakMode = .byWordWrapping
        note.preferredMaxLayoutWidth = SettingsController.contentWidth - 70
        loginItemNote = note
        let indented = NSStackView(views: [note])
        indented.orientation = .horizontal
        indented.edgeInsets = NSEdgeInsets(top: 0, left: 20, bottom: 0, right: 0)
        stack.addArrangedSubview(indented)

        let open = NSButton(title: "システム設定を開く", target: self, action: #selector(openLoginItemSettings))
        open.bezelStyle = .rounded
        open.font = .systemFont(ofSize: 12)
        loginItemButton = open
        let openRow = NSStackView(views: [open])
        openRow.orientation = .horizontal
        openRow.edgeInsets = NSEdgeInsets(top: 0, left: 20, bottom: 0, right: 0)
        stack.addArrangedSubview(openRow)

        stack.addArrangedSubview(spacer(14))

        // ⚠️ ここは黙っていられない話なので、設定画面にも書いておく。
        // 作り直すたびに許可が外れるのは今の署名（ad-hoc）の性質で、直すには
        // Apple の Developer ID 証明書が要る。作者が検討中。
        let caution = NSTextField(labelWithString:
            "テモトを作り直すと、Macから見て「別のアプリ」になります。"
            + "そのときはここの設定とアクセシビリティの許可が外れるので、入れ直してください。")
        caution.font = .systemFont(ofSize: 11)
        caution.textColor = .tertiaryLabelColor
        caution.lineBreakMode = .byWordWrapping
        caution.preferredMaxLayoutWidth = SettingsController.contentWidth - 50
        stack.addArrangedSubview(caution)

        stack.addArrangedSubview(spacer(8))
        // メニューの常設項目から移ってきた。メニュー側は「壊れているとき」しか出さないので、
        // 許可済みのまま入れ直したいとき（作り直しの後の予防）はここが入口
        let ax = NSButton(title: "アクセシビリティの設定を開く", target: self, action: #selector(openAccessibilityPane))
        ax.bezelStyle = .rounded
        stack.addArrangedSubview(ax)

        // メニューバーから移ってきた（⌥を押しながらメニューを開いても出る）。
        // settings.json 等の置き場。壊れたときに Claude やバックアップから触るための入口
        let folder = NSButton(title: "設定フォルダを開く", target: self, action: #selector(openStoreFolder))
        folder.bezelStyle = .rounded
        stack.addArrangedSubview(folder)

        refreshLoginItem()
        return container
    }

    @objc private func openStoreFolder() {
        NSWorkspace.shared.open(store.directory)
    }

    @objc private func openAccessibilityPane() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    /// OSに聞いた状態を画面へ映す。
    /// ⚠️ 作者はシステム設定から直接外せるので、こちらで覚えず毎回聞く。
    private func refreshLoginItem() {
        let state = LoginItemService.state
        loginItemBox?.state = LoginItem.isChecked(state) ? .on : .off
        loginItemBox?.isEnabled = LoginItem.isEnabled(state)

        let note = LoginItem.note(state)
        loginItemNote?.stringValue = note
        loginItemNote?.isHidden = note.isEmpty
        // 押しても意味のあることが起きないときはボタンを出さない
        loginItemButton?.isHidden = (state != .needsApproval && state != .unavailable)
    }

    @objc private func loginItemToggled(_ sender: NSButton) {
        let turningOn = sender.state == .on
        if !LoginItemService.setEnabled(turningOn) {
            loginItemNote?.stringValue = LoginItem.failureMessage(turningOn: turningOn)
            loginItemNote?.isHidden = false
            loginItemButton?.isHidden = false
        }
        // 成否にかかわらず、最後は必ずOSに聞いた本当の状態に戻す
        refreshLoginItem()
        // メニューバーの警告のしるしを、切り替えた直後に合わせ直す
        onStatusChanged()
    }

    @objc private func openLoginItemSettings() {
        LoginItemService.openSystemSettings()
    }

    // MARK: - 使う機能

    private func buildFeatureTab() -> NSView {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: SettingsController.contentWidth, height: SettingsController.contentHeight))

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: container.topAnchor, constant: 24),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -24),
        ])

        stack.addArrangedSubview(heading("検索窓に出すもの"))

        let lead = NSTextField(labelWithString:
            "上から並んでいる順に出ます。↑↓で入れ替え、チェックを外すと出なくなります。")
        lead.font = .systemFont(ofSize: 12)
        lead.textColor = .secondaryLabelColor
        stack.addArrangedSubview(lead)
        stack.addArrangedSubview(spacer(4))

        // 並べ替えのたびに作り直す入れ物。
        // ⚠️ 中身だけ差し替えるのは、外側の余白と並びの制約を作り直さずに済ませるため
        let list = NSStackView()
        list.orientation = .vertical
        list.alignment = .leading
        list.spacing = 6
        entryList = list
        stack.addArrangedSubview(list)
        rebuildEntryList()

        stack.addArrangedSubview(spacer(6))

        let reset = NSButton(title: "並び順を元に戻す", target: self, action: #selector(resetEntryOrder))
        reset.bezelStyle = .rounded
        reset.font = .systemFont(ofSize: 12)
        entryResetButton = reset
        stack.addArrangedSubview(reset)
        refreshEntryResetButton()

        stack.addArrangedSubview(spacer(8))
        let note = NSTextField(labelWithString:
            "左の ⌘数字 は上から順に振り直されます。"
            + "「すべて」は入口なので、この一覧には出ません（esc で戻る先）。\n"
            // ⚠️ この一覧には「移動」と「実行」が混ざっている。書いておかないと、
            // 押した人がメモと同じ（窓が残る）挙動を期待して面食らう
            + "「画面の文字を読み取る」だけは行き先ではなく道具です"
            + "（押すと窓が閉じて、範囲を選ぶ画面になります）。")
        note.font = .systemFont(ofSize: 11)
        note.textColor = .tertiaryLabelColor
        note.lineBreakMode = .byWordWrapping
        note.preferredMaxLayoutWidth = SettingsController.contentWidth - 50
        stack.addArrangedSubview(note)

        return container
    }

    /// 一覧を今の設定どおりに作り直す。
    /// ⚠️ 1行だけ直すのではなく毎回まるごと作る。
    /// 入れ替えると番号も上下の押せる/押せないも全部ずれるので、部分更新は必ず取りこぼす。
    @objc private func showProblems() { ErrorReporter.showReport() }

    @objc private func toggleExpandSnippets(_ sender: NSButton) {
        store.settings.expandSnippets = sender.state == .on
        store.saveSettings()
        onShortcutsChanged()      // AppDelegate 側で見張りの入切が走る
    }

    private func rebuildEntryList() {
        guard let list = entryList else { return }
        for view in list.arrangedSubviews {
            list.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        let entries = store.settings.orderedEntries
        for (index, entry) in entries.enumerated() {
            list.addArrangedSubview(entryRow(entry, index: index, total: entries.count))
        }
    }

    private func entryRow(_ entry: LauncherEntry, index: Int, total: Int) -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 6

        let up = NSButton(title: "▲", target: self, action: #selector(moveEntryUp(_:)))
        let down = NSButton(title: "▼", target: self, action: #selector(moveEntryDown(_:)))
        for (button, disabled) in [(up, index == 0), (down, index == total - 1)] {
            button.bezelStyle = .rounded
            button.font = .systemFont(ofSize: 10)
            button.identifier = NSUserInterfaceItemIdentifier(entry.key)
            // ⚠️ 端の行で押せてしまうと「押したのに動かない」になる。押させない
            button.isEnabled = !disabled
            button.setContentHuggingPriority(.required, for: .horizontal)
            row.addArrangedSubview(button)
        }

        // 番号は出している行だけに付く（隠した行に ⌘3 と書くと、押しても何も起きない嘘になる）
        let number = store.settings.directNumber(for: entry)
        let numberLabel = NSTextField(labelWithString: number.map { "⌘\($0)" } ?? "－")
        numberLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        numberLabel.textColor = number == nil ? .tertiaryLabelColor : .secondaryLabelColor
        numberLabel.alignment = .right
        numberLabel.widthAnchor.constraint(equalToConstant: 30).isActive = true
        row.addArrangedSubview(numberLabel)

        let column = NSStackView()
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 1

        let box = NSButton(checkboxWithTitle: entry.title, target: self, action: #selector(featureToggled(_:)))
        box.identifier = NSUserInterfaceItemIdentifier(entry.key)
        box.state = store.settings.isVisible(entry: entry) ? .on : .off
        box.font = .systemFont(ofSize: 13)

        let sub = NSTextField(labelWithString: entry.summary)
        sub.font = .systemFont(ofSize: 11)
        sub.textColor = .secondaryLabelColor

        // 説明はチェックの文字に揃える。
        // 縦の並びに直接足して制約でずらすと、並びが作る制約とぶつかるので、
        // 左に余白を持った横の並びで包む。
        let indented = NSStackView(views: [sub])
        indented.orientation = .horizontal
        indented.edgeInsets = NSEdgeInsets(top: 0, left: 20, bottom: 0, right: 0)

        column.addArrangedSubview(box)
        column.addArrangedSubview(indented)
        row.addArrangedSubview(column)
        return row
    }

    private func refreshEntryResetButton() {
        // 動かしていないときに「元に戻す」を出しても押す意味がない
        entryResetButton?.isHidden = !store.settings.hasCustomEntryOrder
    }

    @objc private func featureToggled(_ sender: NSButton) {
        guard let key = sender.identifier?.rawValue else { return }
        store.settings.setVisible(key, sender.state == .on)
        store.saveSettings()
        // 隠すと番号が繰り上がるので、一覧ごと作り直す
        rebuildEntryList()
        onFeaturesChanged()
    }

    @objc private func moveEntryUp(_ sender: NSButton) { moveEntry(sender, by: -1) }
    @objc private func moveEntryDown(_ sender: NSButton) { moveEntry(sender, by: 1) }

    private func moveEntry(_ sender: NSButton, by delta: Int) {
        guard let key = sender.identifier?.rawValue else { return }
        store.settings.moveEntry(key, by: delta)
        store.saveSettings()
        rebuildEntryList()
        refreshEntryResetButton()
        onFeaturesChanged()
    }

    @objc private func resetEntryOrder() {
        store.settings.resetEntryOrder()
        store.saveSettings()
        rebuildEntryList()
        refreshEntryResetButton()
        onFeaturesChanged()
    }

    // MARK: - 出すアプリ
    //
    // ⚠️ なぜこの画面が要るか（2026-07-28 作者）。
    //   「このアプリに表示されるアプリを選択したい。不要なアプリは表示されない様にしたい。」
    //
    // 自動の判断だけでは足りない。人によって「要らないもの」は違うので、
    // 最後は1つずつ押して決められるようにする。
    //
    // ⚠️ 一覧には**出していないものも並べる**。
    // 出ていないものを一覧から消すと、戻す場所が画面のどこにも無くなる
    // （settings.json を手で開くしかない＝設定できないのと同じ）。

    private var appFilterField: NSTextField?
    private var appListStack: NSStackView?
    private var appCountLabel: NSTextField?
    /// 並べ替えの手間を省くため、開いている間だけ持っておく
    private var cachedRecords: [AppRecord] = []
    /// 読みの作り置き。1文字打つたびに200件ぶんの読みを作り直すと、絞り込み欄が引っかかる。
    private let readings = ReadingIndex()

    private func buildAppTab() -> NSView {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: SettingsController.contentWidth, height: SettingsController.contentHeight))

        let lead = NSTextField(labelWithString:
            "チェックを外したアプリは検索に出てきません。macOSの裏方（画面を持たない補助プログラム）は最初から外してあります。")
        lead.font = .systemFont(ofSize: 12)
        lead.textColor = .secondaryLabelColor
        lead.lineBreakMode = .byWordWrapping
        lead.maximumNumberOfLines = 2
        lead.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(lead)

        let filter = NSTextField(frame: .zero)
        filter.placeholderString = "アプリ名で絞り込む"
        filter.font = .systemFont(ofSize: 13)
        filter.target = self
        filter.action = #selector(appFilterChanged)
        // 打つそばから絞り込む（Enterを押さないと効かない、を作らない）
        filter.delegate = self
        filter.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(filter)
        appFilterField = filter

        let count = NSTextField(labelWithString: "")
        count.font = .systemFont(ofSize: 11)
        count.textColor = .tertiaryLabelColor
        count.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(count)
        appCountLabel = count

        let scroll = NSScrollView(frame: .zero)
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(scroll)

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 2
        stack.edgeInsets = NSEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)
        stack.translatesAutoresizingMaskIntoConstraints = false
        appListStack = stack

        let documentView = FlippedView()
        documentView.translatesAutoresizingMaskIntoConstraints = false
        documentView.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: documentView.topAnchor),
            stack.leadingAnchor.constraint(equalTo: documentView.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: documentView.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: documentView.bottomAnchor),
        ])
        scroll.documentView = documentView
        NSLayoutConstraint.activate([
            documentView.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
        ])

        let reset = NSButton(title: "おすすめの状態に戻す", target: self, action: #selector(resetAppChoices))
        reset.bezelStyle = .rounded
        reset.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(reset)

        let addFolder = NSButton(title: "探すフォルダを追加…", target: self, action: #selector(addAppFolder))
        addFolder.bezelStyle = .rounded
        addFolder.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(addFolder)

        let rescan = NSButton(title: "アプリを数え直す", target: self, action: #selector(rescanAppsTapped))
        rescan.bezelStyle = .rounded
        rescan.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(rescan)

        // ボタンの意味を画面に書く（2026-07-31 作者「アプリを数え直すとは？？」）
        let buttonsNote = NSTextField(labelWithString:
            "自分で作ったアプリは「探すフォルダを追加…」で置き場所を足すと出てきます")
        buttonsNote.font = .systemFont(ofSize: 11)
        buttonsNote.textColor = .secondaryLabelColor
        buttonsNote.lineBreakMode = .byTruncatingTail
        buttonsNote.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(buttonsNote)

        NSLayoutConstraint.activate([
            lead.topAnchor.constraint(equalTo: container.topAnchor, constant: 16),
            lead.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20),
            lead.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -20),

            filter.topAnchor.constraint(equalTo: lead.bottomAnchor, constant: 12),
            filter.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20),
            filter.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -20),

            count.topAnchor.constraint(equalTo: filter.bottomAnchor, constant: 6),
            count.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 22),

            scroll.topAnchor.constraint(equalTo: count.bottomAnchor, constant: 6),
            scroll.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20),
            scroll.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -20),
            scroll.bottomAnchor.constraint(equalTo: reset.topAnchor, constant: -12),

            reset.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20),
            reset.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -16),
            rescan.leadingAnchor.constraint(equalTo: reset.trailingAnchor, constant: 10),
            rescan.centerYAnchor.constraint(equalTo: reset.centerYAnchor),
            addFolder.leadingAnchor.constraint(equalTo: rescan.trailingAnchor, constant: 10),
            addFolder.centerYAnchor.constraint(equalTo: reset.centerYAnchor),
            buttonsNote.leadingAnchor.constraint(equalTo: rescan.trailingAnchor, constant: 12),
            buttonsNote.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -20),
            buttonsNote.centerYAnchor.constraint(equalTo: reset.centerYAnchor),
        ])

        reloadAppList()
        return container
    }

    /// 一覧を作り直す。絞り込み・チェック・数え直しの後に呼ぶ。
    private func reloadAppList() {
        guard let stack = appListStack else { return }
        cachedRecords = appRecords()

        let needle = (appFilterField?.stringValue ?? "").trimmingCharacters(in: .whitespaces)
        let shown = needle.isEmpty
            ? cachedRecords
            // 検索窓と同じあいまい検索を使う。ここだけ別の探し方だと戸惑うので
            : FuzzyMatcher.rank(cachedRecords, query: needle, key: { $0.name },
                                aliases: { [readings] in readings.keys(for: $0.name) }).map { $0.item }

        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for record in shown {
            stack.addArrangedSubview(appRow(record))
        }

        let visible = cachedRecords.filter { store.settings.isAppVisible($0) }.count
        let choices = store.settings.appChoiceCount
        let tail = choices > 0 ? "・自分で決めたもの \(choices)件" : ""
        appCountLabel?.stringValue =
            "検索に出るのは \(visible)件（見つかったアプリ \(cachedRecords.count)件）\(tail)"
    }

    private func appRow(_ record: AppRecord) -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8

        let box = NSButton(checkboxWithTitle: "", target: self, action: #selector(appToggled(_:)))
        box.identifier = NSUserInterfaceItemIdentifier(record.path)
        box.state = store.settings.isAppVisible(record) ? .on : .off

        let icon = NSImageView()
        icon.image = IconCache.appIcon(record.path)
        icon.imageScaling = .scaleProportionallyDown
        // ⚠️ 先に自動の大きさ合わせを切ること。
        // 切らずに幅と高さを決めると、自動で作られる決まりとぶつかって
        // 「制約を同時に満たせない」と言われ、絵が18pxにならないことがある。
        icon.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: 18),
            icon.heightAnchor.constraint(equalToConstant: 18),
        ])

        let name = NSTextField(labelWithString: record.name)
        name.font = .systemFont(ofSize: 13)
        name.lineBreakMode = .byTruncatingTail
        // 名前の幅を揃える。揃えないと、右の「どこに入っているか」が
        // 名前の長さに合わせてバラバラの位置に出て、200件並ぶと目で追えない。
        name.translatesAutoresizingMaskIntoConstraints = false
        name.widthAnchor.constraint(equalToConstant: 300).isActive = true

        let place = NSTextField(labelWithString: record.isHelper ? "\(record.placeLabel)・裏方" : record.placeLabel)
        place.font = .systemFont(ofSize: 11)
        place.textColor = .tertiaryLabelColor
        place.lineBreakMode = .byTruncatingTail

        row.addArrangedSubview(box)
        row.addArrangedSubview(icon)
        row.addArrangedSubview(name)
        row.addArrangedSubview(place)
        return row
    }

    @objc private func appToggled(_ sender: NSButton) {
        guard let path = sender.identifier?.rawValue,
              let record = cachedRecords.first(where: { $0.path == path }) else { return }
        store.settings.setAppVisible(record, sender.state == .on)
        store.saveSettings()
        onFeaturesChanged()
        // 一覧は作り直さない（押した行が消えて位置が飛ぶと、続けて何件も外せない）。
        // 数だけ直す。
        let visible = cachedRecords.filter { store.settings.isAppVisible($0) }.count
        let choices = store.settings.appChoiceCount
        let tail = choices > 0 ? "・自分で決めたもの \(choices)件" : ""
        appCountLabel?.stringValue =
            "検索に出るのは \(visible)件（見つかったアプリ \(cachedRecords.count)件）\(tail)"
    }

    @objc private func appFilterChanged() {
        reloadAppList()
    }

    /// 絞り込み欄を打つそばから効かせる。
    ///
    /// ⚠️ この画面には他にも文字を打つ欄がある（コピー履歴の「覚えない相手」）。
    /// 送り主を見ないと、そちらを打つたびにアプリ一覧を作り直してしまう。
    func controlTextDidChange(_ notification: Notification) {
        guard let field = notification.object as? NSTextField, field === appFilterField else { return }
        reloadAppList()
    }

    @objc private func resetAppChoices() {
        store.settings.resetAppChoices()
        store.saveSettings()
        onFeaturesChanged()
        reloadAppList()
    }

    @objc private func rescanAppsTapped() {
        rescanApps()
        reloadAppList()
    }

    /// アプリを探すフォルダを足す。
    ///
    /// 2026-08-04 作者「シワケ、シオリ、finderのアプリなど、テモトから簡単に
    /// アクセスできる様にしたい。」＝自分で作ったアプリは作った場所に置いたままなので、
    /// /Applications しか見ていないと永久に出てこない。
    @objc private func addAppFolder() {
        let panel = NSOpenPanel()
        panel.title = "アプリを探すフォルダを選ぶ"
        panel.message = "この中（下の階層も）にある .app を探して、検索に出します"
        panel.prompt = "選ぶ"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.directoryURL = URL(fileURLWithPath: NSHomeDirectory())

        // ⚠️ 設定はふつうの窓なので、検索窓のような「外を押したら閉じる」の守りは要らない
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }

        var added: [String] = []
        for url in panel.urls where !store.settings.appFolders.contains(url.path) {
            store.settings.appFolders.append(url.path)
            added.append(url.lastPathComponent)
        }
        guard !added.isEmpty else {
            Toast.show("そのフォルダはすでに足してあります")
            return
        }
        store.saveSettings()
        rescanApps()
        reloadAppList()
        onFeaturesChanged()
        Toast.show("\(added.joined(separator: "・"))の中のアプリを探すようにしました")
    }

    // MARK: - コピー履歴

    private var maxCountField: NSTextField?
    private var maxAgeField: NSTextField?
    private var maxImageCountField: NSTextField?
    private var captureImagesBox: NSButton?
    private var readImageTextBox: NSButton?
    private var captureFilesBox: NSButton?
    private var patternsView: NSTextView?
    private var bundlesView: NSTextView?

    private func buildClipboardTab() -> NSView {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: SettingsController.contentWidth, height: SettingsController.contentHeight))

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: container.topAnchor, constant: 22),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -24),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: container.bottomAnchor, constant: -20),
        ])

        stack.addArrangedSubview(heading("どこまで残すか"))

        let count = numberRow("残す件数", value: store.settings.clipboard.maxCount, suffix: "件（これより古いものから消えます）")
        maxCountField = count.field
        stack.addArrangedSubview(count.view)

        let age = numberRow("残す日数", value: store.settings.clipboard.maxAgeDays, suffix: "日（過ぎたものは自動で消えます）")
        maxAgeField = age.field
        stack.addArrangedSubview(age.view)

        stack.addArrangedSubview(spacer(8))
        stack.addArrangedSubview(heading("文字のほかに残すもの"))

        let images = NSButton(checkboxWithTitle: "画像も残す（スクリーンショットなど）",
                              target: self, action: #selector(applyClipboardSettings))
        images.state = store.settings.clipboard.captureImages ? .on : .off
        captureImagesBox = images
        stack.addArrangedSubview(images)

        let readText = NSButton(checkboxWithTitle: "画像の中の文字を読む（何の画像か題名で分かるようになります）",
                                target: self, action: #selector(applyClipboardSettings))
        readText.state = store.settings.clipboard.readImageText ? .on : .off
        readImageTextBox = readText
        stack.addArrangedSubview(readText)

        // ここは正直に書いておく。隠すと、危ないと知らずに使うことになる。
        let imageNote = NSTextField(labelWithString:
            "読み取りはこのMacの中だけで行い、どこにも送りません。読めた文字で画像を探せるようにもなります。"
            + "ただし読めた文字は一覧にそのまま出るので、人に画面を見せる場面では中身が読まれます。"
            + "パスワードらしい形を見つけたときは文字を出さず「⚠️」に変えますが、写り方によっては読み落とします。"
            + "⚠️ ここを外すと、画像には「保存しない」の判定がまったく働きません。")
        imageNote.font = .systemFont(ofSize: 11)
        imageNote.textColor = .secondaryLabelColor
        imageNote.lineBreakMode = .byWordWrapping
        imageNote.maximumNumberOfLines = 4
        imageNote.preferredMaxLayoutWidth = SettingsController.contentWidth - 60
        stack.addArrangedSubview(imageNote)

        let imageCount = numberRow("残す画像", value: store.settings.clipboard.maxImageCount,
                                   suffix: "枚（画像だけの枠。1枚で数MBになるため文字とは別に数えます）")
        maxImageCountField = imageCount.field
        stack.addArrangedSubview(imageCount.view)

        let files = NSButton(checkboxWithTitle: "ファイルも残す（Finderでコピーしたもの）",
                             target: self, action: #selector(applyClipboardSettings))
        files.state = store.settings.clipboard.captureFiles ? .on : .off
        captureFilesBox = files
        stack.addArrangedSubview(files)

        let fileNote = NSTextField(labelWithString:
            "ファイルは中身ではなく置き場所だけを覚えます。元を動かしたり消したりすると貼り付けられません。")
        fileNote.font = .systemFont(ofSize: 11)
        fileNote.textColor = .secondaryLabelColor
        fileNote.lineBreakMode = .byWordWrapping
        fileNote.maximumNumberOfLines = 2
        fileNote.preferredMaxLayoutWidth = SettingsController.contentWidth - 60
        stack.addArrangedSubview(fileNote)

        stack.addArrangedSubview(spacer(8))
        stack.addArrangedSubview(heading("保存しないもの"))

        let guardNote = NSTextField(labelWithString:
            "パスワードらしい形の文字と、パスワード管理アプリからのコピーは、はじめから保存しません。"
            + "それでも残したくないものがあれば、ここに足してください。")
        guardNote.font = .systemFont(ofSize: 11)
        guardNote.textColor = .secondaryLabelColor
        guardNote.lineBreakMode = .byWordWrapping
        guardNote.maximumNumberOfLines = 2
        guardNote.preferredMaxLayoutWidth = SettingsController.contentWidth - 60
        stack.addArrangedSubview(guardNote)

        let patterns = textArea(
            "この言葉を含むコピーは保存しない（1行に1つ）",
            text: store.settings.clipboard.excludedPatterns.joined(separator: "\n"),
            height: 68
        )
        patternsView = patterns.textView
        stack.addArrangedSubview(patterns.view)

        let bundles = textArea(
            "このアプリからのコピーは保存しない（バンドルID・1行に1つ）",
            text: store.settings.clipboard.excludedBundleIDs.joined(separator: "\n"),
            height: 88
        )
        bundlesView = bundles.textView
        stack.addArrangedSubview(bundles.view)

        let apply = NSButton(title: "保存しない条件を反映する", target: self, action: #selector(applyClipboardSettings))
        apply.bezelStyle = .rounded
        stack.addArrangedSubview(apply)

        stack.addArrangedSubview(spacer(8))
        stack.addArrangedSubview(heading("片付け"))
        // メニューバーから移ってきた（2026-07-30 メニューの再設計）。
        // 破壊的な操作は毎日開く場所に置かない。ここなら来た人は消す気で来ている
        let clear = NSButton(title: "コピー履歴をすべて消す…", target: self, action: #selector(clearClipsTapped))
        clear.bezelStyle = .rounded
        stack.addArrangedSubview(clear)

        return container
    }

    @objc private func clearClipsTapped() {
        onClearClips()
    }

    // MARK: - ファイル検索

    private var fileSearchContentBox: NSButton?
    private var fileMaxResultsField: NSTextField?
    private var fileFoldersView: NSTextView?

    private func buildFileSearchTab() -> NSView {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: SettingsController.contentWidth, height: SettingsController.contentHeight))

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: container.topAnchor, constant: 22),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -24),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: container.bottomAnchor, constant: -20),
        ])

        stack.addArrangedSubview(heading("どう探すか"))

        // ⚠️ ここに「ファイル検索を使う」は置かない。
        // 使う／使わないは「使う機能」タブ1か所で決める（2か所あると必ず食い違う）。
        stack.addArrangedSubview(note(
            "使う／使わないは「使う機能」タブで切り替えます。ここは探し方の細かい決めごとです。"))

        let content = NSButton(checkboxWithTitle: "中身も探す（名前に出てこない言葉でも見つかる）",
                               target: self, action: #selector(applyFileSearchSettings))
        content.state = store.settings.fileSearch.searchesContent ? .on : .off
        fileSearchContentBox = content
        stack.addArrangedSubview(content)

        stack.addArrangedSubview(note(
            "外すと名前だけを見ます（そのぶん速い）。ただし「中身:見積」の書き方は効かなくなります。"
            + "探すのは macOS が元から持っている索引なので、テモトがパソコン中を舐め直すことはありません。"))

        let results = numberRow("出す件数", value: store.settings.fileSearch.maxResults,
                                suffix: "件（多くしても読み切れないので、既定は100件）")
        // numberRow は履歴タブと共用。Enter を押したときの行き先だけこちらに向け直す
        results.field.action = #selector(applyFileSearchSettings)
        fileMaxResultsField = results.field
        stack.addArrangedSubview(results.view)

        stack.addArrangedSubview(spacer(8))
        stack.addArrangedSubview(heading("どこを探すか"))

        stack.addArrangedSubview(note(
            "空のままならホームの中を全部探します。「デスクトップ」「書類」のような言葉でも、"
            + "「~/Documents/Claude」のようなパスでも書けます。"))

        let folders = textArea(
            "探す場所（1行に1つ）",
            text: store.settings.fileSearch.folders.joined(separator: "\n"),
            height: 88
        )
        fileFoldersView = folders.textView
        stack.addArrangedSubview(folders.view)

        // 出せない場所があることは先に言っておく。黙っていると「テモトが壊れている」と思われる。
        stack.addArrangedSubview(note(
            "⚠️ デスクトップとダウンロードは macOS が守っているので、はじめて探すときに許可を聞かれます。"
            + "許可しないとその場所だけ0件になります。"))
        stack.addArrangedSubview(note(
            "node_modules・Library・ゴミ箱・ドットで始まるフォルダは、はじめから結果に出しません"
            + "（出すと本命が沈むため）。"))

        let apply = NSButton(title: "ファイル検索の設定を反映する", target: self, action: #selector(applyFileSearchSettings))
        apply.bezelStyle = .rounded
        stack.addArrangedSubview(apply)

        return container
    }

    @objc private func applyFileSearchSettings() {
        applyFileSearch(notify: true)
    }

    private func applyFileSearch(notify: Bool) {
        var fileSearch = store.settings.fileSearch

        if let box = fileSearchContentBox { fileSearch.searchesContent = (box.state == .on) }
        // 0件や何千件を入れられると使い物にならなくなるので、下限と上限はこちらで決める
        if let text = fileMaxResultsField?.stringValue, let n = Int(text) {
            fileSearch.maxResults = min(max(n, 10), 500)
        }
        fileMaxResultsField?.stringValue = String(fileSearch.maxResults)
        fileSearch.folders = SettingsLines.split(fileFoldersView?.string)

        guard fileSearch != store.settings.fileSearch else { return }

        store.settings.fileSearch = fileSearch
        store.saveSettings()
        onFeaturesChanged()
        if notify {
            let place = fileSearch.folders.isEmpty ? "ホーム全体" : "\(fileSearch.folders.count)か所"
            Toast.show("ファイル検索の設定を保存しました（\(place)・\(fileSearch.maxResults)件）")
        }
    }

    /// 説明の小さい文字。折り返す幅を決めておかないと1行に伸びて窓からはみ出す。
    private func note(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
        label.lineBreakMode = .byWordWrapping
        label.maximumNumberOfLines = 3
        label.preferredMaxLayoutWidth = SettingsController.contentWidth - 60
        return label
    }

    private func numberRow(_ title: String, value: Int, suffix: String) -> (view: NSView, field: NSTextField) {
        let row = NSStackView()
        row.orientation = .horizontal
        row.spacing = 10
        row.alignment = .centerY

        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 13)
        label.alignment = .right
        label.translatesAutoresizingMaskIntoConstraints = false
        label.widthAnchor.constraint(equalToConstant: 90).isActive = true

        let field = NSTextField(string: String(value))
        field.alignment = .right
        field.target = self
        field.action = #selector(applyClipboardSettings)
        field.translatesAutoresizingMaskIntoConstraints = false
        field.widthAnchor.constraint(equalToConstant: 70).isActive = true

        let tail = NSTextField(labelWithString: suffix)
        tail.font = .systemFont(ofSize: 11)
        tail.textColor = .secondaryLabelColor

        row.addArrangedSubview(label)
        row.addArrangedSubview(field)
        row.addArrangedSubview(tail)
        return (row, field)
    }

    private static let textAreaWidth: CGFloat = 520

    private func textArea(_ title: String, text: String, height: CGFloat) -> (view: NSView, textView: NSTextView) {
        let column = NSStackView()
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 4

        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 12)

        let width = SettingsController.textAreaWidth
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.widthAnchor.constraint(equalToConstant: width).isActive = true
        scroll.heightAnchor.constraint(equalToConstant: height).isActive = true

        // 手で組み立てるときは、この5行が要る。
        // 抜かすと文字が1行目しか見えない／打った先が切れる（既定の入れ物が広がらないため）。
        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        textView.minSize = NSSize(width: 0, height: height)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                                  height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.containerSize = NSSize(width: width, height: .greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true

        textView.string = text
        textView.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        textView.isRichText = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        scroll.documentView = textView

        column.addArrangedSubview(label)
        column.addArrangedSubview(scroll)
        return (column, textView)
    }

    @objc private func applyClipboardSettings() {
        applyClipboard(notify: true)
    }

    /// 閉じるときにも同じ処理を通すので、知らせを出すかどうかだけ分けている。
    private func applyClipboard(notify: Bool) {
        var clipboard = store.settings.clipboard

        // 0や空を入れられると履歴が全部消えるので、下限をこちらで決める
        if let text = maxCountField?.stringValue, let n = Int(text) {
            clipboard.maxCount = min(max(n, 10), 5000)
        }
        if let text = maxAgeField?.stringValue, let n = Int(text) {
            clipboard.maxAgeDays = min(max(n, 1), 3650)
        }
        if let text = maxImageCountField?.stringValue, let n = Int(text) {
            clipboard.maxImageCount = min(max(n, 1), 300)
        }
        maxCountField?.stringValue = String(clipboard.maxCount)
        maxAgeField?.stringValue = String(clipboard.maxAgeDays)
        maxImageCountField?.stringValue = String(clipboard.maxImageCount)

        if let box = captureImagesBox { clipboard.captureImages = (box.state == .on) }
        if let box = readImageTextBox { clipboard.readImageText = (box.state == .on) }
        if let box = captureFilesBox { clipboard.captureFiles = (box.state == .on) }

        clipboard.excludedPatterns = SettingsLines.split(patternsView?.string)
        clipboard.excludedBundleIDs = SettingsLines.split(bundlesView?.string)

        // 中身が変わっていないなら書かない（閉じるたびに保存しにいかない）
        guard clipboard != store.settings.clipboard else { return }

        store.settings.clipboard = clipboard
        store.saveSettings()
        onFeaturesChanged()
        if notify {
            Toast.show("コピー履歴の設定を保存しました（\(clipboard.maxCount)件・\(clipboard.maxAgeDays)日）")
        }
    }

    // MARK: - 部品

    private func heading(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 13, weight: .semibold)
        return label
    }

    private func spacer(_ height: CGFloat) -> NSView {
        let view = NSView()
        view.translatesAutoresizingMaskIntoConstraints = false
        view.heightAnchor.constraint(equalToConstant: height).isActive = true
        return view
    }
}

// MARK: - ショートカットを押して決める枠

/// クリックしてからキーを押すと、その組み合わせを覚える枠。
///
/// 気をつけている点:
///   ・録っている間は ⌘Q や ⌘W を横取りする（設定中にアプリが終わると設定できない）
///   ・修飾キーの無い組み合わせは受け取らない（単独キーをグローバルに奪うのは事故のもと）
///   ・押している修飾キーをその場で出す（何が効いているか見えないと打ち直せない）
final class ShortcutField: NSView {

    var shortcut: Shortcut? { didSet { refresh() } }
    /// 割り当て無しを許すか（ウィンドウ操作は「付けない」も選べる）
    var allowsEmpty = false
    var onChange: ((Shortcut?) -> Void)?

    private let label = NSTextField(labelWithString: "")
    private var recording = false { didSet { refresh() } }
    private var liveModifiers: UInt32 = 0

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        // キーを表す枠なので、下の帯のキーキャップと同じ丸みにそろえる
        layer?.cornerRadius = Theme.Radius.keyCap
        layer?.borderWidth = 1
        label.alignment = .center
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.lineBreakMode = .byTruncatingTail
        addSubview(label)
        refresh()
    }

    required init?(coder: NSCoder) { fatalError("使わない") }

    override func layout() {
        super.layout()
        label.frame = NSRect(x: 6, y: (bounds.height - 17) / 2, width: bounds.width - 12, height: 17)
    }

    override var acceptsFirstResponder: Bool { true }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
    }

    override func becomeFirstResponder() -> Bool {
        liveModifiers = 0
        recording = true
        return true
    }

    override func resignFirstResponder() -> Bool {
        recording = false
        return true
    }

    /// 録っている間は ⌘つきのキーもここで受け取る。
    /// これが無いと ⌘Q でアプリが終わり、⌘W で窓が閉じて、設定できない。
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard recording else { return false }
        keyDown(with: event)
        return true
    }

    override func flagsChanged(with event: NSEvent) {
        guard recording else { return }
        liveModifiers = Shortcut.carbonModifiers(fromCocoaRawFlags: event.modifierFlags.rawValue)
        refresh()
    }

    override func keyDown(with event: NSEvent) {
        guard recording else { return super.keyDown(with: event) }

        // esc はやめる。録っている最中の逃げ道は必ず用意する。
        if event.keyCode == KeyCode.esc {
            window?.makeFirstResponder(nil)
            return
        }

        // ⌫ 単独は割り当てを外す
        let modifiers = Shortcut.carbonModifiers(fromCocoaRawFlags: event.modifierFlags.rawValue)
        if event.keyCode == KeyCode.del, modifiers == 0 {
            if allowsEmpty {
                shortcut = nil
                onChange?(nil)
                window?.makeFirstResponder(nil)
            } else {
                flash("これは外せません")
            }
            return
        }

        guard modifiers != 0 else {
            // 単独キーを奪うと、そのキーが他のアプリで一切打てなくなる
            flash("⌘⌃⌥⇧ と一緒に")
            return
        }

        let candidate = Shortcut(
            keyCode: UInt32(event.keyCode),
            carbonModifiers: modifiers,
            keyLabel: Shortcut.label(keyCode: UInt32(event.keyCode), characters: event.charactersIgnoringModifiers)
        )
        shortcut = candidate
        onChange?(candidate)
        window?.makeFirstResponder(nil)
    }

    private func flash(_ message: String) {
        label.stringValue = message
        label.textColor = .systemRed
        // すぐ元に戻すと読めないので、少しだけ出しておく
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            self?.refresh()
        }
    }

    private func refresh() {
        let accent = NSColor.controlAccentColor
        layer?.borderColor = (recording ? accent : NSColor.separatorColor).cgColor
        layer?.backgroundColor = (recording ? accent.withAlphaComponent(0.10) : NSColor.controlBackgroundColor).cgColor

        if recording {
            label.textColor = .secondaryLabelColor
            let live = Shortcut(keyCode: 0, carbonModifiers: liveModifiers, keyLabel: "").displayString
            label.stringValue = live.isEmpty ? "キーを押す" : live + "…"
        } else if let shortcut {
            label.textColor = .labelColor
            label.stringValue = shortcut.displayString
        } else {
            label.textColor = .tertiaryLabelColor
            label.stringValue = "割り当てなし"
        }
    }
}

// MARK: - 上から下へ並ぶ入れ物

/// スクロールの中身に使う枠。
///
/// ⚠️ AppKit の座標は既定で「左下が原点」なので、そのままスクロールに入れると
/// 一覧が下から積まれて、開いた瞬間に最後の行が見えている状態になる。
/// `isFlipped` を true にすると「左上が原点」になり、上から順に並ぶ。
final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

/// 設定の窓。
///
/// ⚠️ テモトはメニューバーだけのアプリ（.accessory）で、画面上部のメニューを持たない。
/// つまり macOS が普通に用意する「ファイル > 閉じる ⌘W」が存在せず、
/// 何もしなければ ⌘W でも esc でも閉じられない。閉じるボタンを探して押すしかない。
/// 手が覚えている閉じ方は、窓の側で自分で拾う。
final class SettingsWindow: NSWindow {

    /// esc / ⌘W が来たときに呼ぶ
    var onDismiss: ((CloseReason) -> Void)?

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        // ⚠️ 先に中身へ渡すこと。
        // ショートカットを録っている最中の欄は ⌘つきのキーを横取りするので、
        // ここで先に ⌘W を食べてしまうと「⌘W を割り当てる」ができなくなる。
        if super.performKeyEquivalent(with: event) { return true }

        guard PanelBehavior.closesOnCommandW(.settings),
              event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
              event.charactersIgnoringModifiers?.lowercased() == "w"
        else { return false }
        onDismiss?(.commandW)
        return true
    }

    /// esc。
    /// 文字を打っている最中の esc は、その欄が先に受け取って編集をやめるので、
    /// ここまで来るのは「どこも編集していないとき」だけ。
    override func cancelOperation(_ sender: Any?) {
        guard PanelBehavior.closesOnEscape(.settings) else { return }
        onDismiss?(.escape)
    }
}
