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
final class SettingsController: NSObject, NSWindowDelegate, NSTextFieldDelegate, NSToolbarDelegate {

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
    /// 登録できなかったキー（他のアプリに先に押さえられているもの）。
    /// ⚠️ これが「かぶり」のいちばん確かな証拠。設定画面の重複チェックは
    /// テモトの中しか見られないが、こちらは**他アプリに取られた事実**そのもの
    private let failedShortcuts: () -> [Shortcut]
    /// 窓の交通整理（戻り先の記録と、他の窓をどかす手配）
    private let coordinator: PanelCoordinator

    private var window: SettingsWindow?
    /// タブを外から選ぶために持っておく（棚の「＋」→「アプリのキー」）
    private weak var sidebar: SettingsSidebar?
    /// 画面ごとの中身。一度作ったら使い回す（作り直すと入力中の字が消える）
    private var paneViews: [SettingsPane: NSView] = [:]
    private weak var paneHost: NSView?
    private var currentPane: SettingsPane?
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
        onStatusChanged: @escaping () -> Void,
        failedShortcuts: @escaping () -> [Shortcut] = { [] }
    ) {
        self.store = store
        self.coordinator = coordinator
        self.onShortcutsChanged = onShortcutsChanged
        self.onFeaturesChanged = onFeaturesChanged
        self.appRecords = appRecords
        self.rescanApps = rescanApps
        self.onClearClips = onClearClips
        self.onStatusChanged = onStatusChanged
        self.failedShortcuts = failedShortcuts
        super.init()
        coordinator.register(
            .settings,
            isVisible: { [weak self] in self?.window?.isVisible ?? false },
            close: { [weak self] reason in self?.close(reason: reason) }
        )
    }

    // MARK: - 開閉

    /// タブを指定して開く（棚の「＋」から「アプリのキー」へ直接連れていくため）
    /// 外から画面を指して開く。
    /// ⚠️ 文字列で受けない。前は "アプリのキー" と書いており、名前を変えた瞬間に
    /// **黙って何も起きない**状態になる。列挙で受ければ組み立てのときに見つかる
    func show(selecting pane: SettingsPane) {
        show()
        sidebar?.select(pane)
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

    /// 左右の余白。見出し・説明・行の名前・ボタンを、すべてこの位置から始める
    /// （揃えないと「文字の始まりがバラバラ」に見える）
    private static let gutter: CGFloat = 20
    /// 行の名前の欄。ここを固定すると、右のキーの枠も一直線に並ぶ
    /// （実測：一番長い「画面の文字を読み取る」で121pt）
    private static let labelColumn: CGFloat = 140
    /// 説明文を折り返す幅。
    /// ⚠️ 折り返す幅を渡さない説明文は「1行で全部描ける幅」を要求し、**窓ごと横に広がる**。
    /// 2026-08-19 実測：ショートカットの説明1行が設定窓を 620 → 1013pt に広げていた。
    /// 説明文を折り返す幅。
    /// ⚠️ `contentWidth`（620）は窓を組むときの目安で、分割ビューが実際に中身へ渡すのは
    /// **612**（横メニュー216＋仕切り＝828のうち）。8pt 多く見積もると、
    /// 説明文が右端ぎりぎりまで伸びて窮屈に見える（2026-08-23 実測）
    /// 分割ビューが実際に中身へ渡す幅（実測 612。`contentWidth` の 620 ではない）
    private static let paneWidth: CGFloat = contentWidth - 8
    /// まとまりを載せる面の幅
    private static let cardWidth: CGFloat = paneWidth - gutter * 2
    /// 面の内側の余白
    private static let cardInset: CGFloat = 16
    /// 面の中に置く文章の折り返し幅
    private static let cardTextWidth: CGFloat = cardWidth - cardInset * 2

    private static let captionWidth: CGFloat = contentWidth - 8 - gutter * 2 - 16

    private func buildWindow() -> SettingsWindow {
        let w = SettingsWindow(
            contentRect: NSRect(x: 0, y: 0,
                                width: SettingsSidebar.width + SettingsController.contentWidth,
                                // 見出し棒に食われるぶんを足して、中身の高さ（540）を確保する
                                height: SettingsController.contentHeight + 38),
            // ⚠️ `.fullSizeContentView` を足すのが横メニューの肝。
            // これが無いと、横メニューが灰色の見出し棒の下で切られて**貼り付けた板**に見える。
            // 上まで通すと、閉じるボタンの後ろまですりガラスが続く（システム設定と同じ）
            styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        w.delegate = self
        w.isReleasedWhenClosed = false
        w.titlebarAppearsTransparent = true
        // 中身の側の見出し棒に、今いる画面の名前が出る（横メニューの上には出ない）。
        // ⚠️ これは NSSplitViewItem(sidebarWithViewController:) を使ったときだけの働き。
        // 自前で横に並べると、名前は窓の真ん中＝横メニューの上に出てしまう
        w.title = SettingsPane.allCases[0].title
        // 中身をスクロールしたときだけ細い線が出る。止まっているときは線を引かない
        w.titlebarSeparatorStyle = .automatic

        // ⚠️ 空の道具棒を付ける。見た目には何も足さないが、これが無いと
        // macOS 26 の横メニューのガラスの板が**窓の上端から32pt下**から始まり、
        // その上に素の窓地が24pt残る＝「上辺を切り落とした板」に見える
        // （2026-08-23 に絵で確認。横メニューの上に白い帯が残っていた正体）。
        // 道具棒があると、板が上端まで通る
        let toolbar = NSToolbar(identifier: "settings")
        toolbar.delegate = self
        toolbar.allowsUserCustomization = false
        w.toolbar = toolbar
        // ⚠️ 型は `.unified`。実測（2026-08-23 macOS 26.5.2、横メニューの板の frame）:
        //   道具棒なし        → (8, 8, 208, 538) ＝ 窓の上端から 32pt 下から始まる
        //   `.unifiedCompact` → (8, 8, 208, 530) ＝ **40pt 下**。道具棒なしより悪化する
        //   `.unified`        → (8, 8, 208, 562) ＝ 上下左右すべて 8pt（システム設定と同じ）
        // ⚠️ 私は一度ここに「unifiedCompact なら板は上端まで通ったまま」と書いたが、
        // 測ると**まるで逆**だった。見た目の話は必ず測ってから書くこと
        w.toolbarStyle = .unified
        w.onDismiss = { [weak self] reason in self?.close(reason: reason) }

        let bar = SettingsSidebar(frame: NSRect(x: 0, y: 0,
                                                width: SettingsSidebar.width,
                                                height: SettingsController.contentHeight))
        bar.onSelect = { [weak self] pane, reveal in self?.showPane(pane, revealing: reveal) }
        sidebar = bar
        let barVC = NSViewController()
        barVC.view = bar

        // ⚠️ 中身の地。検索窓・メモと**同じ部品**（BackdropView）を使う。
        //
        // それまでは `material = .windowBackground` だった。これは名前に反して
        // **まったく透けない**（実測: 後ろに壁紙を敷いて撮ると RGB(30,30,30) の無地。
        // `.popover` は (53,50,59) で後ろの色を拾う）。
        // 2026-08-23 作者「おしゃれさが足りない。もっと透け感とかアイコンとかもっと改善して」
        // の「透け感」は、ここが原因だった。
        //
        // ⚠️ `.hudWindow` は使わない。いちばん透けるが、明るい見た目のとき
        // 「灰色の地に黒い文字」になる（2026-07-29 作者「すごく見づらくなった」）。
        // `.popover` は見た目に合わせて明るくも暗くもなる。
        // 覆い（backdropVeil）が乗るので、後ろが色物でも文字は読める。
        let host = BackdropView(frame: NSRect(x: 0, y: 0,
                                              width: SettingsController.contentWidth,
                                              height: SettingsController.contentHeight),
                                framed: false)

        // ⚠️ 中身を入れる枠。ここが**押し返す壁**になる。
        // 画面を制約で直に貼ると、中身が窓より大きいとき Auto Layout は窓のほうを広げる
        // （2026-08-14、出すアプリの説明文1行で 831→886 に広がった）。
        // 枠だけを制約で留め、画面は昔ながらの frame + autoresizingMask で入れると、
        // 中身の望みは窓まで伝わらない。はみ出すぶんは `scrollable(_:)` がスクロールで受ける
        let clip = NSView()
        clip.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(clip)
        NSLayoutConstraint.activate([
            clip.topAnchor.constraint(equalTo: host.safeAreaLayoutGuide.topAnchor),
            clip.bottomAnchor.constraint(equalTo: host.bottomAnchor),
            clip.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            clip.trailingAnchor.constraint(equalTo: host.trailingAnchor),
        ])
        paneHost = clip
        let hostVC = NSViewController()
        hostVC.view = host

        let split = NSSplitViewController()
        let barItem = NSSplitViewItem(sidebarWithViewController: barVC)
        // 幅を動かせないようにする。中身の側は既定の横幅（620）で字の折り返しを決めているので、
        // 横メニューを広げられると、説明文だけが先に折り返して見た目が崩れる
        barItem.minimumThickness = SettingsSidebar.width
        barItem.maximumThickness = SettingsSidebar.width
        barItem.canCollapse = false
        split.addSplitViewItem(barItem)
        split.addSplitViewItem(NSSplitViewItem(viewController: hostVC))
        w.contentViewController = split
        // ⚠️ `contentViewController` を入れると、窓は**中の view の大きさに合わせて縮む**。
        // contentRect に書いた高さは無視されるので、ここで言い直す。
        // これを抜かすと、見出し棒に食われた 32 のぶんだけ中身が足りず、下が切れる
        let size = NSSize(width: SettingsSidebar.width + SettingsController.contentWidth,
                          height: SettingsController.contentHeight + 38)
        w.setContentSize(size)
        // ⚠️ 大きさを錠で留める。中身が窓より大きいと Auto Layout は窓のほうを広げるので、
        // 画面を切り替えるたびに窓が跳ねる（設定の窓は手で戻せないので、一度伸びたら戻らない）。
        // はみ出す中身は `scrollable(_:)` で包んでスクロールさせる。
        // 破れていないかは `Temoto --check-settings-index` が7画面ぶん測って確かめる
        w.contentMinSize = size
        w.contentMaxSize = size

        showPane(SettingsPane.allCases[0])
        return w
    }

    /// 画面を1つ出す。中身は作り置きして使い回す
    private func showPane(_ pane: SettingsPane, revealing title: String? = nil) {
        guard let host = paneHost else { return }
        // ⚠️ 同じ画面でも、探して当たった設定が指定されていれば素通りしない。
        // 「使う機能」を開いたまま別の設定を探したとき、そこまで送り届けるため
        guard currentPane != pane || title != nil else { return }
        let samePane = (currentPane == pane)
        currentPane = pane
        window?.title = pane.title

        let view = paneViews[pane] ?? build(pane)
        paneViews[pane] = view

        // 同じ画面のままなら貼り直さない（貼り直すと入力中の字と、いま見ている位置が飛ぶ）
        if samePane, view.superview === host {
            if let title { DispatchQueue.main.async { [weak self] in self?.reveal(title, in: view) } }
            return
        }

        host.subviews.forEach { $0.removeFromSuperview() }
        // ⚠️ 制約で貼らない（上の「押し返す壁」の説明を参照）。
        // 枠のほうが見出し棒ぶんを避けて置かれているので、ここは枠いっぱいでよい
        view.translatesAutoresizingMaskIntoConstraints = true
        view.frame = host.bounds
        view.autoresizingMask = [.width, .height]
        host.addSubview(view)

        // 探して当たった設定なら、そこまでスクロールして見せる。
        // ⚠️ 画面を出しただけでは足りない。「合言葉の自動展開」は画面のいちばん下にあり、
        // 出しただけでは見えず、結局「無い」と思われる（2026-08-23 の入口そのもの）。
        // ⚠️ 並べ終わってから測る必要があるので、次の回に回す
        guard let title else { return }
        DispatchQueue.main.async { [weak self] in self?.reveal(title, in: view) }
    }

    /// 画面の中から、その名前の行を探して見える位置まで送る。
    ///
    /// ⚠️ `scrollToVisible` は使わない。あれは「見えさえすればよい」ので、
    /// 下にある設定は**画面の下端に貼り付いた状態**で止まり、下に続く説明文が切れる
    /// （2026-08-14 に実際そうなった）。少し上に置いて、前後ごと読める形にする。
    private func reveal(_ title: String, in view: NSView) {
        guard let target = SettingsController.find(title, in: view),
              let scroll = target.enclosingScrollView,
              let document = scroll.documentView else { return }
        let clip = scroll.contentView
        let rect = target.convert(target.bounds, to: document)
        // 上に見出しぶんの余白を残す。行きすぎないよう、中身の下端で止める
        let limit = max(0, document.bounds.height - clip.bounds.height)
        let y = min(max(0, rect.minY - 40), limit)
        clip.scroll(to: NSPoint(x: 0, y: y))
        scroll.reflectScrolledClipView(clip)
    }

    private static func find(_ title: String, in view: NSView) -> NSView? {
        if let field = view as? NSTextField, field.stringValue == title { return view }
        if let button = view as? NSButton, button.title == title { return view }
        for child in view.subviews {
            if let found = find(title, in: child) { return found }
        }
        return nil
    }

    /// 画面ごとの中身を組み立てる。
    /// ⚠️ `default:` を書かない。書くと、画面を足したときに**中身の無い画面**が黙って開く
    /// （`LauncherItem.entry()` で実際にやった失敗。既定値に落ちる書き方は必ず後で刺さる）
    /// 絵にするとき用。探している最中の姿を作る（`--render-settings --query …`）
    func previewSearch(_ text: String) { sidebar?.preview(query: text) }

    /// 検査用に、画面を1つ組み立てて返す（`--check-settings-index`）
    func paneView(for pane: SettingsPane) -> NSView { build(pane) }

    private func build(_ pane: SettingsPane) -> NSView {
        switch pane {
        case .general: return buildGeneralTab()
        case .shortcuts: return buildShortcutTab()
        case .appKeys: return buildAppShortcutTab()
        case .features: return buildFeatureTab()
        case .apps: return buildAppTab()
        case .clipboard: return buildClipboardTab()
        case .fileSearch: return buildFileSearchTab()
        case .hotkeys: return buildHotkeyTab()
        }
    }

    // MARK: - キーのかぶり

    /// 「どのキーが誰に取られているか」を1画面で見せる。
    ///
    /// 2026-08-30 作者「テモトにかかわらず全てのショートカットを確認できる仕組みにできないかな？？
    /// ショートカットがかぶっているので、設定できなかったり、動かなかったりする」。
    ///
    /// ⚠️ できること・できないことを画面にも正直に書く:
    /// - ✅ macOS 自身のショートカット: 設定ファイルに全部書いてあるので読める
    /// - ✅ テモトの割り当て・登録に失敗したキー
    /// - ❌ **他のアプリ（Raycast等）が押さえているキーの一覧**: macOS に聞く窓口が無い。
    ///   ただし「登録できなかった」という事実からは分かるので、それを出す。
    /// 「全部見える」と書いて実際は見えないのが、いちばん信用を失う。
    private func buildHotkeyTab() -> NSView {
        let pane = PaneBuilder(self)

        let system = SystemHotkeys.active(systemHotkeyDomain())
        let mine = store.settings.allShortcuts
        let failed = failedShortcuts()
        let crossHits = SystemHotkeys.conflicts(between: system, and: mine)
        let selfHits = store.settings.conflicts()

        // ── ぶつかっているもの（あるときだけ・いちばん上）
        if !failed.isEmpty || !crossHits.isEmpty || !selfHits.isEmpty {
            pane.section("ぶつかっています")

            for shortcut in failed {
                let name = mine.first { $0.shortcut == shortcut }?.name ?? "どれか"
                pane.add(conflictRow(
                    shortcut.displayString,
                    "「\(name)」に割り当てましたが、**他のアプリが先に押さえていて登録できません**。"
                    + "そのアプリ側で外すか、テモトのキーを変えてください。"))
            }
            for hit in selfHits {
                pane.add(conflictRow(
                    hit.shortcut.displayString,
                    "テモトの中で重なっています（\(hit.names.joined(separator: "・"))）。"
                    + "先に登録した方だけが効きます。"))
            }
            for hit in crossHits {
                pane.add(conflictRow(
                    hit.system.shortcut?.displayString ?? "",
                    "macOS の「\(hit.system.name)」と同じです（テモトでは「\(hit.mineName)」）。"
                    + "macOS が先に取るので、テモト側は効かないことがあります。"))
            }
            pane.add(openKeyboardSettingsRow())
        } else {
            pane.section("ぶつかっています")
            pane.add(caption("いまのところ、ぶつかっているキーはありません。", lines: 1))
        }

        // ── テモトの割り当て
        pane.section("テモトが使っているキー")
        if mine.isEmpty {
            pane.add(caption("まだ何も割り当てていません。", lines: 1))
        } else {
            for assignment in mine.sorted(by: { $0.name < $1.name }) {
                pane.add(keyRow(assignment.shortcut.displayString, assignment.name,
                                warn: failed.contains(assignment.shortcut)))
            }
        }

        // ── macOS 自身
        pane.section("macOS が使っているキー")
        pane.add(caption(
            "システム設定 → キーボード → キーボードショートカット の中身です（入になっているものだけ）。"
            + "ここに出ているキーは macOS が先に取るので、テモトや他のアプリでは効きません。", lines: 3))
        // ⚠️ 番号のままのものが必ず出る。理由を書かないと「作りかけ」に見える
        pane.add(caption(
            "後ろの「システムの機能 #番号」は、Apple が名前を公にしていない機能です。"
            + "何かは分かりませんが、そのキーが取られていることは確かです。", lines: 2))
        if system.isEmpty {
            pane.add(caption("読めませんでした。", lines: 1))
        } else {
            // ⚠️ ここで並べ直さない。`active(_:)` が
            // 「名前が分かるもの → 番号だけのもの」に並べてある
            let taken = Set(crossHits.compactMap { $0.system.shortcut })
            for entry in system {
                guard let shortcut = entry.shortcut else { continue }
                pane.add(keyRow(shortcut.displayString, entry.name, warn: taken.contains(shortcut)))
            }
        }
        pane.add(openKeyboardSettingsRow())

        // ── 見えないもの（正直に書く）
        pane.section("ここに出ないもの")
        pane.add(caption(
            "他のアプリ（Raycast・Alfred など）が押さえているキーは、macOS に聞く方法がないため一覧にできません。"
            + "ただしテモトが登録できなかったキーは、上の「ぶつかっています」に必ず出ます。"
            + "「設定したのに効かない」ときは、まずそこを見てください。", lines: 4))

        return pane.build()
    }

    /// macOS のショートカットの設定を読む。
    /// ⚠️ 読めなくても落とさない（他人の設定ファイルなので、形が変わることがある）
    private func systemHotkeyDomain() -> [String: Any] {
        UserDefaults(suiteName: "com.apple.symbolichotkeys")?
            .dictionary(forKey: "AppleSymbolicHotKeys") ?? [:]
    }

    /// キー1つの行（左に札・右に名前）
    private func keyRow(_ keys: String, _ name: String, warn: Bool) -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.spacing = 10
        row.alignment = .centerY

        let cap = NSTextField(labelWithString: keys)
        cap.font = .monospacedSystemFont(ofSize: 11, weight: .medium)
        cap.alignment = .right
        cap.textColor = warn ? .systemRed : .labelColor
        cap.translatesAutoresizingMaskIntoConstraints = false
        cap.widthAnchor.constraint(equalToConstant: 110).isActive = true

        let label = NSTextField(labelWithString: name)
        label.font = .systemFont(ofSize: 12)
        label.textColor = Theme.Palette.captionText
        label.lineBreakMode = .byTruncatingTail
        label.preferredMaxLayoutWidth = SettingsController.cardTextWidth - 120

        row.addArrangedSubview(cap)
        row.addArrangedSubview(label)
        return row
    }

    /// ぶつかっている1件（札＋説明）
    private func conflictRow(_ keys: String, _ message: String) -> NSView {
        let column = NSStackView()
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 2

        let cap = NSTextField(labelWithString: keys)
        cap.font = .monospacedSystemFont(ofSize: 12, weight: .semibold)
        cap.textColor = .systemRed

        let label = caption(message.replacingOccurrences(of: "**", with: ""), lines: 3)
        label.preferredMaxLayoutWidth = SettingsController.cardTextWidth

        column.addArrangedSubview(cap)
        column.addArrangedSubview(label)
        return column
    }

    private func openKeyboardSettingsRow() -> NSView {
        ChipButton(title: "キーボードの設定を開く", target: self, action: #selector(openKeyboardPane))
    }

    @objc private func openKeyboardPane() {
        // ⚠️ 直に「ショートカット」の段まで開く道はOSが用意していないので、
        // キーボードの画面まで連れて行く（そこから1回押せば着く）
        guard let url = URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension") else { return }
        NSWorkspace.shared.open(url)
    }

    // MARK: - 道具棒（中身は空）

    /// ⚠️ 項目は1つも出さない。道具棒を付けるのは、横メニューのガラスの板を
    /// 窓の上端まで通すためだけ（buildWindow の説明を参照）
    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { [] }
    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { [] }

    // MARK: - ショートカット

    private func buildShortcutTab() -> NSView {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: SettingsController.contentWidth, height: SettingsController.contentHeight))

        let footerHeight: CGFloat = 60
        // ⚠️ 上に余白を足さない。タブの帯の下がそのまま中身の上端になる。
        // （以前は高さから 40 引いていたので、使われない帯ができたうえ、
        //   上端で行が途中から切れて「壊れている」ように見えていた）
        let scroll = NSScrollView(frame: NSRect(x: 0, y: footerHeight, width: container.bounds.width,
                                                height: container.bounds.height - footerHeight))
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.autoresizingMask = [.width, .height]

        let pane = PaneBuilder(self)
        // ⚠️ この画面は自前でスクロールと足元（説明・重なりの知らせ・戻す）を組んでいるので、
        // 縦並びの内側の余白もここで持つ（`scrollable(_:)` を通らない）
        pane.stack.edgeInsets = NSEdgeInsets(top: 16, left: SettingsController.gutter,
                                             bottom: 16, right: SettingsController.gutter)

        pane.section("開くもの")
        // この4つは「割り当てなし」を許さない（無くすと開く手段が消える）ので、
        // set に nil が来ることはない。来ても何もしない。
        pane.add(shortcutRow("検索を開く",
            get: { [store] in store.settings.launcherShortcut },
            set: { [store] value in if let value { store.settings.launcherShortcut = value } }))
        pane.add(shortcutRow("コピー履歴",
            get: { [store] in store.settings.clipboardShortcut },
            set: { [store] value in if let value { store.settings.clipboardShortcut = value } }))
        pane.add(shortcutRow("定型文",
            get: { [store] in store.settings.snippetShortcut },
            set: { [store] value in if let value { store.settings.snippetShortcut = value } }))
        pane.add(shortcutRow("メモ",
            get: { [store] in store.settings.noteShortcut },
            set: { [store] value in if let value { store.settings.noteShortcut = value } }))

        pane.section("ウィンドウを動かす")
        // 割り当ての無い配置も並べる。⌫ で消せて、押せば付けられる。
        for layout in WindowLayout.allCases {
            pane.add(shortcutRow(
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

        pane.section("画面をまたぐ")
        for step in [1, -1] {
            pane.add(shortcutRow(
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

        pane.section("文字を変換")
        pane.add(caption(
            "どのアプリでも、選んでいる文字をその場で置き換えます（コピー→変換→貼り付けを1押しで）。", lines: 2))
        pane.add(spacer(4))
        for transform in TextTransform.allCases {
            pane.add(shortcutRow(
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

        pane.section("貼り付け")
        pane.add(caption(
            "コピー中の文字から色や書式を落として、そのまま貼り付けます（Webやメールからのコピーに）。", lines: 2))
        pane.add(spacer(4))
        pane.add(shortcutRow(
            "書式なしで貼り付け",
            allowsEmpty: true,
            get: { [store] in store.settings.pastePlainShortcut },
            set: { [store] value in store.settings.pastePlainShortcut = value }
        ))

        // 見出しの無い迷子の行だったので、まとまりを与える
        pane.section("画面を読み取る")
        pane.add(shortcutRow(
            "画面の文字を読み取る",
            allowsEmpty: true,
            get: { [store] in store.settings.captureTextShortcut },
            set: { [store] value in store.settings.captureTextShortcut = value }
        ))

        let stack = pane.buildStack()
        stack.translatesAutoresizingMaskIntoConstraints = false
        let documentView = FlippedView()
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
        help.textColor = Theme.Palette.captionText
        help.lineBreakMode = .byWordWrapping
        help.maximumNumberOfLines = 2
        help.frame = NSRect(x: SettingsController.gutter, y: 30,
                            width: container.bounds.width - SettingsController.gutter * 2, height: 30)
        help.autoresizingMask = [.width, .maxYMargin]
        container.addSubview(help)

        let conflict = NSTextField(labelWithString: "")
        conflict.font = .systemFont(ofSize: 11, weight: .medium)
        conflict.textColor = .systemRed
        conflict.lineBreakMode = .byTruncatingTail
        conflict.frame = NSRect(x: SettingsController.gutter, y: 10,
                                width: container.bounds.width - 160 - SettingsController.gutter, height: 16)
        conflict.autoresizingMask = [.width, .maxYMargin]
        container.addSubview(conflict)
        conflictLabels.append(conflict)

        let reset = ChipButton(title: "はじめの設定に戻す", target: self, action: #selector(resetShortcuts))
        reset.frame = NSRect(x: container.bounds.width - 145 - SettingsController.gutter, y: 4, width: 145, height: 26)
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
        // ⚠️ 右寄せにしない。名前の長さがまちまちなので、右で揃えると
        // 文字の始まりが1行ごとにずれて、目で追えなくなる（2026-08-19 作者の指摘）。
        label.alignment = .left
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        label.widthAnchor.constraint(equalToConstant: SettingsController.labelColumn).isActive = true

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
        lead.textColor = Theme.Palette.captionText
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
        layCard(under: scroll, in: container)

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
        empty.textColor = Theme.Palette.captionText   // 文章なので読める濃さで
        empty.lineBreakMode = .byWordWrapping
        empty.maximumNumberOfLines = 2
        // ⚠️ これが無いと「1行に収まる幅」を自分の望みの大きさとして主張し、
        // Auto Layout は**窓のほうを広げて**辻褄を合わせる（831→981 になっていた）
        empty.preferredMaxLayoutWidth = SettingsController.captionWidth
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

        let add = ChipButton(title: "アプリを選ぶ…", target: self, action: #selector(addAppShortcut))
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

        let remove = ChipButton(title: "外す", target: self, action: #selector(removeAppShortcut(_:)))
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
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6

        // ── 起動
        stack.addArrangedSubview(heading("起動"))

        let box = NSButton(checkboxWithTitle: "Macの起動時にテモトを開く",
                           target: self, action: #selector(loginItemToggled(_:)))
        box.font = .systemFont(ofSize: 13)
        loginItemBox = box

        // 説明はチェックの文字に揃える（横の並びに包んで字下げする）
        let note = NSTextField(labelWithString: "")
        note.font = .systemFont(ofSize: 11)
        note.textColor = Theme.Palette.captionText
        note.lineBreakMode = .byWordWrapping
        note.preferredMaxLayoutWidth = SettingsController.cardTextWidth - 20
        loginItemNote = note
        let indented = NSStackView(views: [note])
        indented.orientation = .horizontal
        indented.edgeInsets = NSEdgeInsets(top: 0, left: 20, bottom: 0, right: 0)

        let open = ChipButton(title: "システム設定を開く", target: self, action: #selector(openLoginItemSettings))
        loginItemButton = open
        let openRow = NSStackView(views: [open])
        openRow.orientation = .horizontal
        openRow.edgeInsets = NSEdgeInsets(top: 0, left: 20, bottom: 0, right: 0)

        stack.addArrangedSubview(card([box, indented, openRow]))
        stack.addArrangedSubview(spacer(18))

        // ── 許可とファイル
        stack.addArrangedSubview(heading("許可とファイル"))

        // メニューの常設項目から移ってきた。メニュー側は「壊れているとき」しか出さないので、
        // 許可済みのまま入れ直したいとき（作り直しの後の予防）はここが入口
        let ax = ChipButton(title: "アクセシビリティの設定を開く", target: self, action: #selector(openAccessibilityPane))
        // メニューバーから移ってきた（⌥を押しながらメニューを開いても出る）。
        // settings.json 等の置き場。壊れたときに Claude やバックアップから触るための入口
        let folder = ChipButton(title: "設定フォルダを開く", target: self, action: #selector(openStoreFolder))

        // ⚠️ ここは黙っていられない話なので、設定画面にも書いておく
        let caution = caption(
            "テモトを作り直すと、Macから見て「別のアプリ」になります。"
            + "そのときはここの設定とアクセシビリティの許可が外れるので、入れ直してください。",
            lines: 3)
        caution.preferredMaxLayoutWidth = SettingsController.cardTextWidth

        stack.addArrangedSubview(card([ax, folder, caution]))
        stack.addArrangedSubview(spacer(18))

        // ── うまくいかないとき
        // ⚠️ 元は「ショートカット」画面の末尾にあった。キーの話ではないので一般へ移した
        stack.addArrangedSubview(heading("うまくいかないとき"))
        let problemButton = ChipButton(title: "問題を報告する…", target: self,
                                       action: #selector(showProblems))
        // ⚠️ どこにも自動で送らないことを、ボタンのそばに書く
        // （書かないと「勝手に送られているのでは」と思われる。通信ゼロが看板なので致命的）
        let problemNote = caption(
            "うまくいかなかったことを手元に記録しています。中身を読んでから、"
            + "コピーかファイルで渡せます。どこにも自動では送りません。")
        problemNote.preferredMaxLayoutWidth = SettingsController.cardTextWidth
        stack.addArrangedSubview(card([problemButton, problemNote]))

        refreshLoginItem()
        return scrollable(stack)
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
        let pane = PaneBuilder(self)

        pane.section("検索窓に出すもの")

        let lead = NSTextField(labelWithString:
            "上から並んでいる順に出ます。↑↓で入れ替え、チェックを外すと出なくなります。")
        lead.font = .systemFont(ofSize: 12)
        lead.textColor = Theme.Palette.captionText
        pane.add(lead)
        pane.add(spacer(4))

        // 並べ替えのたびに作り直す入れ物。
        // ⚠️ 中身だけ差し替えるのは、外側の余白と並びの制約を作り直さずに済ませるため
        let list = NSStackView()
        list.orientation = .vertical
        list.alignment = .leading
        list.spacing = 6
        entryList = list
        pane.add(list)
        rebuildEntryList()

        pane.add(spacer(6))

        let reset = ChipButton(title: "並び順を元に戻す", target: self, action: #selector(resetEntryOrder))
        reset.font = .systemFont(ofSize: 12)
        entryResetButton = reset
        pane.add(reset)
        refreshEntryResetButton()

        pane.add(spacer(8))
        let note = NSTextField(labelWithString:
            "左の ⌘数字 は上から順に振り直されます。"
            + "「すべて」は入口なので、この一覧には出ません（esc で戻る先）。\n"
            // ⚠️ この一覧には「移動」と「実行」が混ざっている。書いておかないと、
            // 押した人がメモと同じ（窓が残る）挙動を期待して面食らう
            + "「画面の文字を読み取る」だけは行き先ではなく道具です"
            + "（押すと窓が閉じて、範囲を選ぶ画面になります）。")
        note.font = .systemFont(ofSize: 11)
        note.textColor = Theme.Palette.captionText   // 説明なので読ませる
        note.lineBreakMode = .byWordWrapping
        note.preferredMaxLayoutWidth = SettingsController.contentWidth - 50
        // ⚠️ ここは元は「ショートカット」画面の、貼り付けと画面読み取りの間にあった。
        // キーの割り当てに混ざっていたせいで**誰にも見つからない**設定になっていた
        // （2026-08-23 作者「スニペット機能は実装されていますか？？」＝入っているのに気づけない）。
        // 機能のオン・オフは機能の画面に置く。ショートカットはキーの割り当てだけにする
        pane.section("合言葉の自動展開")
        let expandToggle = NSButton(checkboxWithTitle: "どのアプリでも、打った瞬間に本文へ置き換える",
                                    target: self, action: #selector(toggleExpandSnippets(_:)))
        expandToggle.state = store.settings.expandSnippets ? .on : .off
        pane.add(expandToggle)
        pane.add(caption(
            "定型文の「読みがな」を英数で打つと、その場で本文に置き換わります（例: mailz）。"
            + "打った文字はどこにも保存・送信しません。パスワード欄と日本語入力の変換中は動きません。"
            + "アクセシビリティの許可が必要です。", lines: 4))
        pane.add(spacer(8))

        pane.add(note)

        return pane.build()
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

        // ⚠️ 設定の押せるものは全部カプセル（ChipButton）にしたのに、ここだけ
        // 標準ベゼル＝灰色の四角が2個混じっていた。記号もカプセルに合わせる
        let up = ChipButton(title: "", target: self, action: #selector(moveEntryUp(_:)))
        let down = ChipButton(title: "", target: self, action: #selector(moveEntryDown(_:)))
        for (button, name, label, disabled) in
            [(up, "chevron.up", "上へ", index == 0),
             (down, "chevron.down", "下へ", index == total - 1)] {
            button.image = NSImage(systemSymbolName: name, accessibilityDescription: label)
            button.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 10, weight: .semibold)
            button.imagePosition = .imageOnly
            // ⚠️ 文字を捨てたので、読み上げから名前が消える。ここで名前を与え直す
            button.setAccessibilityLabel(label)
            button.identifier = NSUserInterfaceItemIdentifier(entry.key)
            // ⚠️ 端の行で押せてしまうと「押したのに動かない」になる。押させない
            button.isEnabled = !disabled
            button.translatesAutoresizingMaskIntoConstraints = false
            button.widthAnchor.constraint(equalToConstant: 24).isActive = true
            button.heightAnchor.constraint(equalToConstant: 24).isActive = true
            row.addArrangedSubview(button)
        }

        // 番号は出している行だけに付く（隠した行に ⌘3 と書くと、押しても何も起きない嘘になる）
        let number = store.settings.directNumber(for: entry)
        let numberLabel = NSTextField(labelWithString: number.map { "⌘\($0)" } ?? "－")
        numberLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        numberLabel.textColor = number == nil ? Theme.Palette.faintText : Theme.Palette.captionText
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
        sub.textColor = Theme.Palette.captionText

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
        lead.textColor = Theme.Palette.captionText
        lead.lineBreakMode = .byWordWrapping
        lead.maximumNumberOfLines = 2
        // ⚠️ 折り返す幅を教えないと「1行に収まる幅（634）」を望んで窓を押し広げる
        lead.preferredMaxLayoutWidth = SettingsController.captionWidth
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
        count.textColor = Theme.Palette.captionText   // 件数は読ませる
        count.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(count)
        appCountLabel = count

        let scroll = NSScrollView(frame: .zero)
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(scroll)
        layCard(under: scroll, in: container)

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

        let reset = ChipButton(title: "おすすめの状態に戻す", target: self, action: #selector(resetAppChoices))
        reset.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(reset)

        let addFolder = ChipButton(title: "探すフォルダを追加…", target: self, action: #selector(addAppFolder))
        addFolder.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(addFolder)

        let rescan = ChipButton(title: "アプリを数え直す", target: self, action: #selector(rescanAppsTapped))
        rescan.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(rescan)

        // ボタンの意味を画面に書く（2026-07-31 作者「アプリを数え直すとは？？」）
        // ⚠️ ボタンの右に置かない。3つのボタンと横一列に並べると、
        // required な横並びが窓の幅より長くなり、窓そのものが横に伸びる
        // （2026-08-19 実測：この行だけで 620 → 708pt）。ボタンの上の段に置く。
        let buttonsNote = caption(
            "自分で作ったアプリは「探すフォルダを追加…」で置き場所を足すと出てきます", lines: 2)
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
            scroll.bottomAnchor.constraint(equalTo: buttonsNote.topAnchor, constant: -10),

            buttonsNote.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20),
            buttonsNote.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -20),
            buttonsNote.bottomAnchor.constraint(equalTo: reset.topAnchor, constant: -8),

            reset.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20),
            reset.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -16),
            rescan.leadingAnchor.constraint(equalTo: reset.trailingAnchor, constant: 10),
            rescan.centerYAnchor.constraint(equalTo: reset.centerYAnchor),
            addFolder.leadingAnchor.constraint(equalTo: rescan.trailingAnchor, constant: 10),
            addFolder.centerYAnchor.constraint(equalTo: reset.centerYAnchor),
            addFolder.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -20),
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
        place.textColor = Theme.Palette.captionText   // どの画面かは読ませる
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
        let pane = PaneBuilder(self)

        pane.section("どこまで残すか")

        let count = numberRow("残す件数", value: store.settings.clipboard.maxCount, suffix: "件（これより古いものから消えます）")
        maxCountField = count.field
        pane.add(count.view)

        let age = numberRow("残す日数", value: store.settings.clipboard.maxAgeDays, suffix: "日（過ぎたものは自動で消えます）")
        maxAgeField = age.field
        pane.add(age.view)

        pane.add(spacer(8))
        pane.section("文字のほかに残すもの")

        let images = NSButton(checkboxWithTitle: "画像も残す（スクリーンショットなど）",
                              target: self, action: #selector(applyClipboardSettings))
        images.state = store.settings.clipboard.captureImages ? .on : .off
        captureImagesBox = images
        pane.add(images)

        let readText = NSButton(checkboxWithTitle: "画像の中の文字を読む（何の画像か題名で分かるようになります）",
                                target: self, action: #selector(applyClipboardSettings))
        readText.state = store.settings.clipboard.readImageText ? .on : .off
        readImageTextBox = readText
        pane.add(readText)

        // ここは正直に書いておく。隠すと、危ないと知らずに使うことになる。
        let imageNote = NSTextField(labelWithString:
            "読み取りはこのMacの中だけで行い、どこにも送りません。読めた文字で画像を探せるようにもなります。"
            + "ただし読めた文字は一覧にそのまま出るので、人に画面を見せる場面では中身が読まれます。"
            + "パスワードらしい形を見つけたときは文字を出さず「⚠️」に変えますが、写り方によっては読み落とします。"
            + "⚠️ ここを外すと、画像には「保存しない」の判定がまったく働きません。")
        imageNote.font = .systemFont(ofSize: 11)
        imageNote.textColor = Theme.Palette.captionText
        imageNote.lineBreakMode = .byWordWrapping
        imageNote.maximumNumberOfLines = 4
        imageNote.preferredMaxLayoutWidth = SettingsController.contentWidth - 60
        pane.add(imageNote)

        let imageCount = numberRow("残す画像", value: store.settings.clipboard.maxImageCount,
                                   suffix: "枚（画像だけの枠。1枚で数MBになるため文字とは別に数えます）")
        maxImageCountField = imageCount.field
        pane.add(imageCount.view)

        let files = NSButton(checkboxWithTitle: "ファイルも残す（Finderでコピーしたもの）",
                             target: self, action: #selector(applyClipboardSettings))
        files.state = store.settings.clipboard.captureFiles ? .on : .off
        captureFilesBox = files
        pane.add(files)

        let fileNote = NSTextField(labelWithString:
            "ファイルは中身ではなく置き場所だけを覚えます。元を動かしたり消したりすると貼り付けられません。")
        fileNote.font = .systemFont(ofSize: 11)
        fileNote.textColor = Theme.Palette.captionText
        fileNote.lineBreakMode = .byWordWrapping
        fileNote.maximumNumberOfLines = 2
        fileNote.preferredMaxLayoutWidth = SettingsController.contentWidth - 60
        pane.add(fileNote)

        pane.add(spacer(8))
        pane.section("保存しないもの")

        let guardNote = NSTextField(labelWithString:
            "パスワードらしい形の文字と、パスワード管理アプリからのコピーは、はじめから保存しません。"
            + "それでも残したくないものがあれば、ここに足してください。")
        guardNote.font = .systemFont(ofSize: 11)
        guardNote.textColor = Theme.Palette.captionText
        guardNote.lineBreakMode = .byWordWrapping
        guardNote.maximumNumberOfLines = 2
        guardNote.preferredMaxLayoutWidth = SettingsController.contentWidth - 60
        pane.add(guardNote)

        let patterns = textArea(
            "この言葉を含むコピーは保存しない（1行に1つ）",
            text: store.settings.clipboard.excludedPatterns.joined(separator: "\n"),
            height: 68
        )
        patternsView = patterns.textView
        pane.add(patterns.view)

        let bundles = textArea(
            "このアプリからのコピーは保存しない（バンドルID・1行に1つ）",
            text: store.settings.clipboard.excludedBundleIDs.joined(separator: "\n"),
            height: 88
        )
        bundlesView = bundles.textView
        pane.add(bundles.view)

        let apply = ChipButton(title: "保存しない条件を反映する", target: self, action: #selector(applyClipboardSettings))
        pane.add(apply)

        pane.add(spacer(8))
        pane.section("片付け")
        // メニューバーから移ってきた（2026-07-30 メニューの再設計）。
        // 破壊的な操作は毎日開く場所に置かない。ここなら来た人は消す気で来ている
        let clear = ChipButton(title: "コピー履歴をすべて消す…", target: self, action: #selector(clearClipsTapped))
        pane.add(clear)

        return pane.build()
    }

    @objc private func clearClipsTapped() {
        onClearClips()
    }

    // MARK: - ファイル検索

    private var fileSearchContentBox: NSButton?
    private var fileMaxResultsField: NSTextField?
    private var fileFoldersView: NSTextView?

    private func buildFileSearchTab() -> NSView {
        let pane = PaneBuilder(self)

        pane.section("どう探すか")

        // ⚠️ ここに「ファイル検索を使う」は置かない。
        // 使う／使わないは「使う機能」タブ1か所で決める（2か所あると必ず食い違う）。
        pane.add(note(
            "使う／使わないは「使う機能」タブで切り替えます。ここは探し方の細かい決めごとです。"))

        let content = NSButton(checkboxWithTitle: "中身も探す（名前に出てこない言葉でも見つかる）",
                               target: self, action: #selector(applyFileSearchSettings))
        content.state = store.settings.fileSearch.searchesContent ? .on : .off
        fileSearchContentBox = content
        pane.add(content)

        pane.add(note(
            "外すと名前だけを見ます（そのぶん速い）。ただし「中身:見積」の書き方は効かなくなります。"
            + "探すのは macOS が元から持っている索引なので、テモトがパソコン中を舐め直すことはありません。"))

        let results = numberRow("出す件数", value: store.settings.fileSearch.maxResults,
                                suffix: "件（多くしても読み切れないので、既定は100件）")
        // numberRow は履歴タブと共用。Enter を押したときの行き先だけこちらに向け直す
        results.field.action = #selector(applyFileSearchSettings)
        fileMaxResultsField = results.field
        pane.add(results.view)

        pane.add(spacer(8))
        pane.section("どこを探すか")

        pane.add(note(
            "空のままならホームの中を全部探します。「デスクトップ」「書類」のような言葉でも、"
            + "「~/Documents/Claude」のようなパスでも書けます。"))

        let folders = textArea(
            "探す場所（1行に1つ）",
            text: store.settings.fileSearch.folders.joined(separator: "\n"),
            height: 88
        )
        fileFoldersView = folders.textView
        pane.add(folders.view)

        // 出せない場所があることは先に言っておく。黙っていると「テモトが壊れている」と思われる。
        pane.add(note(
            "⚠️ デスクトップとダウンロードは macOS が守っているので、はじめて探すときに許可を聞かれます。"
            + "許可しないとその場所だけ0件になります。"))
        pane.add(note(
            "node_modules・Library・ゴミ箱・ドットで始まるフォルダは、はじめから結果に出しません"
            + "（出すと本命が沈むため）。"))

        let apply = ChipButton(title: "ファイル検索の設定を反映する", target: self, action: #selector(applyFileSearchSettings))
        pane.add(apply)

        return pane.build()
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
        fileSearch.folders = SettingsLines.lines(keeping: fileSearch.folders, from: fileFoldersView?.string)

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
        label.textColor = Theme.Palette.captionText
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
        tail.textColor = Theme.Palette.captionText

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
        // ⚠️ 枠を描かない。すりガラスの上だと線だけが浮いて「段ボール箱」に見える
        // （Theme.swift の HairlineView の説明と同じ理由）。形は地の濃さで作る
        scroll.borderType = .noBorder
        scroll.drawsBackground = false
        // ⚠️ 角丸は下の面（FieldWellView）に任せる。ここで丸めると二重になる
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
        // ⚠️ 中身の地を描かせない。既定では `.textBackgroundColor`（不透明）で塗るので、
        // すりガラスの上に真っ白（真っ黒）な箱が出る
        textView.drawsBackground = false
        textView.isRichText = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        scroll.documentView = textView

        column.addArrangedSubview(label)
        // 打てる場所であることを、わずかに沈んだ面で示す（枠は描かない）
        let well = FieldWellView(frame: .zero)
        well.translatesAutoresizingMaskIntoConstraints = false
        well.addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: well.topAnchor, constant: 1),
            scroll.bottomAnchor.constraint(equalTo: well.bottomAnchor, constant: -1),
            scroll.leadingAnchor.constraint(equalTo: well.leadingAnchor, constant: 1),
            scroll.trailingAnchor.constraint(equalTo: well.trailingAnchor, constant: -1),
        ])
        column.addArrangedSubview(well)
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

        clipboard.excludedPatterns = SettingsLines.lines(keeping: clipboard.excludedPatterns, from: patternsView?.string)
        clipboard.excludedBundleIDs = SettingsLines.lines(keeping: clipboard.excludedBundleIDs, from: bundlesView?.string)

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

    /// 縦に伸びる中身を、はみ出したときだけスクロールできる形に包む。
    ///
    /// ⚠️ 2026-08-14 に「使う機能」へ合言葉の自動展開を移したら、窓の高さを超えて
    /// **下が切れた**（絵に撮って気づいた）。設定は今後も増えるので、
    /// 決め打ちの高さに収める作りをやめる。
    /// まとまりを1枚の面に載せる。
    ///
    /// ⚠️ 幅は**必ず定数**にする。`greaterThanOrEqual` や中身まかせにすると、
    /// 中の説明文が「1行に収まる幅」を望んで**窓のほうが広がる**
    /// （2026-08-14 に 831→886 で実際に起きた。`--check-settings-index` が見張っている）
    fileprivate func card(_ rows: [NSView]) -> NSView {
        let box = NSStackView(views: rows)
        box.orientation = .vertical
        box.alignment = .leading
        box.spacing = 8
        box.edgeInsets = NSEdgeInsets(top: 14, left: SettingsController.cardInset,
                                      bottom: 14, right: SettingsController.cardInset)
        box.translatesAutoresizingMaskIntoConstraints = false

        let face = CardView(frame: .zero)
        face.translatesAutoresizingMaskIntoConstraints = false
        face.addSubview(box)
        NSLayoutConstraint.activate([
            face.widthAnchor.constraint(equalToConstant: SettingsController.cardWidth),
            box.topAnchor.constraint(equalTo: face.topAnchor),
            box.bottomAnchor.constraint(equalTo: face.bottomAnchor),
            box.leadingAnchor.constraint(equalTo: face.leadingAnchor),
            box.trailingAnchor.constraint(equalTo: face.trailingAnchor),
        ])
        return face
    }

    /// 画面を「見出し＋面」の並びで組み立てる道具。
    ///
    /// ⚠️ 面（カード）を画面ごとに手で並べると、必ずどこかで余白がばらつく。
    /// `section(_:)` を呼ぶたびに、それまでに足した行を1枚の面に流し込む。
    /// 見出しは面の**外**（上）に出す＝字の大きさを変えずに階層が立つ。
    final class PaneBuilder {
        let stack = NSStackView()
        private unowned let owner: SettingsController
        private var pending: [NSView] = []
        private var started = false

        init(_ owner: SettingsController) {
            self.owner = owner
            stack.orientation = .vertical
            stack.alignment = .leading
            stack.spacing = 6
        }

        /// 新しいまとまりを始める（それまでの行は1枚の面になる）
        func section(_ title: String) {
            flush()
            if started { stack.addArrangedSubview(owner.spacer(18)) }
            stack.addArrangedSubview(owner.heading(title))
            started = true
        }

        /// いまのまとまりに1行足す
        func add(_ view: NSView) { pending.append(view) }
        func add(_ views: [NSView]) { pending.append(contentsOf: views) }

        /// 面に載せずに、そのまま置く（一覧や説明の見出しなど）
        func addBare(_ view: NSView) {
            flush()
            stack.addArrangedSubview(view)
        }

        private func flush() {
            guard !pending.isEmpty else { return }
            stack.addArrangedSubview(owner.card(pending))
            pending = []
        }

        /// 縦並びだけを返す（自前でスクロールと足元を組む画面用）
        func buildStack() -> NSStackView {
            flush()
            return stack
        }

        /// 組み上げる
        func build() -> NSView {
            flush()
            return owner.scrollable(stack)
        }
    }

    /// 一覧の**下に**面を敷く。
    ///
    /// ⚠️ 「アプリのキー」「出すアプリ」は一覧が主役で、他の画面のように
    /// 「見出し＋面」を積む形にならない。一覧そのものを面に載せて、
    /// 他の5画面と同じ「ガラスの上に紙が乗る」層を作る。
    /// ⚠️ 一覧を面の**中に入れない**（制約を全部書き直すことになる）。
    /// 同じ位置に面を敷いて、一覧の下に潜らせるだけにする
    private func layCard(under view: NSView, in container: NSView, outset: CGFloat = 6) {
        let face = CardView(frame: .zero)
        face.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(face, positioned: .below, relativeTo: view)
        NSLayoutConstraint.activate([
            face.topAnchor.constraint(equalTo: view.topAnchor, constant: -outset),
            face.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: outset),
            face.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: -outset),
            face.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: outset),
        ])
    }

    fileprivate func scrollable(_ stack: NSStackView) -> NSView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        // ⚠️ 素の NSView にしない。AppKit の座標は「左下が原点」なので、
        // 中身が窓より短いとき**下に沈んで**上に大きな空きができる（実際そうなった）
        let document = FlippedView()
        document.translatesAutoresizingMaskIntoConstraints = false
        stack.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(stack)
        scroll.documentView = document
        NSLayoutConstraint.activate([
            document.widthAnchor.constraint(equalTo: scroll.widthAnchor),
            stack.topAnchor.constraint(equalTo: document.topAnchor, constant: 24),
            stack.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: document.trailingAnchor, constant: -24),
            stack.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -24),
        ])
        return scroll
    }

    /// まとまりの見出し。
    ///
    /// ⚠️ 13pt semibold だったのを 15pt semibold にした（2026-08-23）。
    /// 本文が 13pt、説明が 11pt なので、見出しが 13pt だと**本文と同じ大きさ**で、
    /// 太さの違いしか手がかりが無い。ひと目で「ここから別の話」と分からないと、
    /// 設定がただの縦一列に見える（作者「おしゃれさが足りない」の一因）。
    /// ⚠️ これ以上大きくしない。17pt にすると窓の名前（見出し棒の「一般」）と
    /// 同じ大きさになり、どちらが上位か分からなくなる
    fileprivate func heading(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 15, weight: .semibold)
        return label
    }

    /// 説明文。
    /// ⚠️ preferredMaxLayoutWidth を必ず渡すこと（渡さないと窓が横に伸びる）。
    /// 押し合いに負ける側にもしておく（窓の幅より説明の都合を優先させない）。
    private func caption(_ text: String, lines: Int = 3) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 11)
        label.textColor = Theme.Palette.captionText
        label.lineBreakMode = .byWordWrapping
        label.maximumNumberOfLines = lines
        // ⚠️ 行送りを広げる。漢字かなが混ざる説明文は、既定のままだと詰まって読みにくい
        label.attributedStringValue = NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: 11),
            .foregroundColor: Theme.Palette.captionText,
            .paragraphStyle: Theme.Text.paragraph(),
        ])
        label.preferredMaxLayoutWidth = SettingsController.captionWidth
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return label
    }

    /// まとまりの境目に引く細い線

    /// 「線 → 間 → 見出し → 間」を毎回同じ間合いで積む。
    /// 手で spacer を置くと、まとまりごとに間隔がずれて雑に見える。
    /// まとまりの見出しを足す。
    ///
    /// ⚠️ 前は間に細い線（divider）を引いていた。やめた理由は2つ:
    /// ① このアプリの決まりは「枠で形を作らない／区切りは余白の仕事」。
    ///    設定だけ線で切っていたのは、単に古い作りが残っていただけ
    /// ② 2026-08-23 に中身の地をすりガラス（.popover）にした。
    ///    透けている地の上に線を引くと、線だけが浮いて**紙に定規を当てた**ように見える
    private func addSection(_ title: String, to stack: NSStackView, first: Bool = false) {
        if first {
            stack.addArrangedSubview(heading(title))
        } else {
            stack.addArrangedSubview(spacer(22))
            stack.addArrangedSubview(heading(title))
        }
        stack.addArrangedSubview(spacer(2))
    }

    fileprivate func spacer(_ height: CGFloat) -> NSView {
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

    /// ⚠️ `.cgColor` は**書いた瞬間の見た目で固まる**。`refresh()` はキーが変わったときしか
    /// 呼ばれないので、設定を開いたままシステム設定で明↔暗を切り替えると、
    /// 十数個のキー欄だけ前の見た目の色で取り残される（Theme.swift が名指しで警告している罠）
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refresh()
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
        // ⚠️ `.controlBackgroundColor` は**どの見た目でも不透明**（明1.000／暗0.118）。
        // 中身の地をすりガラスにした 2026-08-23 以降、これを敷くと
        // 透けた地の上に**真っ白（真っ黒）な箱**が十数枚貼り付いた見た目になる。
        // キーを表す場所なので、アプリ共通の「キーの札」（keyCapFill・枠は控えめ）に合わせる。
        // ⚠️ `.cgColor` は書いた瞬間の見た目で固まるので、必ず今の見た目の下で解く
        let accent = NSColor.controlAccentColor
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.borderColor = (recording ? accent : Theme.Palette.keyCapEdge).cgColor
            layer?.backgroundColor = (recording
                ? accent.withAlphaComponent(0.16)
                : Theme.Palette.keyCapFill).cgColor
        }

        if recording {
            label.textColor = Theme.Palette.captionText
            let live = Shortcut(keyCode: 0, carbonModifiers: liveModifiers, keyLabel: "").displayString
            label.stringValue = live.isEmpty ? "キーを押す" : live + "…"
        } else if let shortcut {
            label.textColor = .labelColor
            label.stringValue = shortcut.displayString
        } else {
            // ⚠️ faint（0.34/0.40）は「読ませない飾り」専用で最悪比 2.06。
            // 「割り当てなし」は**状態を読ませる文字**なので 4.5 側に置く
            label.textColor = Theme.Palette.captionText
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
