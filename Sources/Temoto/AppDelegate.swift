import AppKit
import TemotoCore

final class AppDelegate: NSObject, NSApplicationDelegate {

    private let store = Store()
    private let windowManager = WindowManager()
    /// 窓の交通整理。3つの窓（検索窓・メモ・設定）が同じ決まりで開き閉じするようにする。
    /// 決まりそのものは TemotoCore.PanelBehavior。
    private let panels = PanelCoordinator()
    private var watcher: ClipboardWatcher!
    private var launcher: LauncherController!
    private var note: NoteController!
    private var settingsUI: SettingsController!

    private var statusItem: NSStatusItem!
    /// 登録できなかったショートカット（他アプリに取られている）
    private var failedShortcuts: [(shortcut: Shortcut, action: HotKeyAction)] = []

    /// 鍵を取り出すまでは false。この間は履歴の取り込みを始めない。
    private var secretsReady = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        // ⚠️ いちばん先に組む。これが無いと、テモトの**すべての入力欄**で
        // ⌘C も ⌘V も効かない（2026-08-09 作者「リンクを貼り付けることができない。」）。
        // メニューバーに出ないアプリ（LSUIElement）は自分でメニューを作らないと、
        // 編集のキーがどこにも届かない。
        EditMenu.install()

        // ここは2段構えにしてある。
        //
        // 鍵はキーチェーンにあり、取り出すときにmacOSが許可をたずねてくることがある
        // （アプリを作り直すと署名が変わるので、そのたびに聞かれる）。
        // このダイアログは答えるまで返ってこない。
        // 以前は起動の先頭で鍵を取っていたので、答えるまでメニューバーのアイコンすら出ず、
        // アプリが固まったようにしか見えなかった。
        //
        // なので、鍵の要らないもの（設定・リンク・コマンド）だけ先に読んで画面を立て、
        // 鍵は別スレッドで取りに行く。ダイアログを放置しても、
        // ウィンドウ操作とランチャーはその間ずっと使える。
        let isFirstRun = store.loadPlaintext()

        watcher = ClipboardWatcher(settings: store.settings.clipboard)
        watcher.onDecision = { [weak self] decision, capture in
            self?.handleClip(decision: decision, capture: capture)
        }

        // 一覧に出す小さな絵と、プレビューに出す原寸の取り出し口を繋ぐ。
        // Store は AppKit を知らない土台なので、NSImage への変換はこちら側でやる。
        ClipThumbnailCache.loader = { [weak self] id in self?.store.loadClipThumbnail(id: id) }
        PreviewImageCache.loader = { [weak self] id in self?.store.loadClipImage(id: id) }

        launcher = LauncherController(store: store, windowManager: windowManager, watcher: watcher, coordinator: panels)
        note = NoteController(store: store, coordinator: panels)

        // 設定を変えたら、その場で効かせる。
        // 「変えたのに次に起動するまで効かない」は、設定できていないのと同じ。
        settingsUI = SettingsController(
            store: store,
            coordinator: panels,
            onShortcutsChanged: { [weak self] in self?.reloadShortcuts() },
            onFeaturesChanged: { [weak self] in self?.reloadFeatures() },
            // 設定画面には「見つかった全部」を渡す。出していないものも一覧に出して、
            // チェックを入れれば戻せるようにするため
            appRecords: { [weak self] in self?.launcher.allAppRecords ?? [] },
            rescanApps: { [weak self] in self?.launcher.rescanApps() },
            // 「履歴をすべて消す」はメニューから設定画面へ移した（実体はこちらに残す）
            onClearClips: { [weak self] in self?.clearClips() },
            // ログイン項目を設定画面で切り替えた直後に、メニューバーの警告のしるしを合わせる
            onStatusChanged: { [weak self] in self?.refreshStatusIcon() },
            failedShortcuts: { [weak self] in self?.failedShortcuts.map(\.shortcut) ?? [] }
        )

        // 検索窓の中から、メモと設定へ抜けられるようにする。
        // ここを繋がないと、メモだけ別のホットキーを覚えないと開けず、
        // 「一つ一つが別アプリみたい」に逆戻りする。
        // 検索窓から選んで来ているので、toggle（開いていたら閉じる）ではなく必ず開く
        launcher.onOpenNote = { [weak self] in
            guard let self, self.requireSecrets() else { return }
            self.note.show()
        }
        // 入口の検索から、書き置きの1枚を名指しで開く（探した1枚にそのまま着地させる）
        launcher.onOpenNoteItem = { [weak self] note in
            guard let self, self.requireSecrets() else { return }
            self.note.show(selecting: note)
        }
        // メモから入口へ戻る（左上の矢印・検索欄が空のときの ⌫）。
        // ⚠️ `show(.all)` が先に PanelCoordinator.willOpen を通るので、メモ側は自分で閉じなくてよい
        note.onGoBack = { [weak self] in self?.launcher.show(.all) }
        launcher.onOpenSettings = { [weak self] in self?.openSettings() }
        launcher.onShowProblems = { ErrorReporter.showReport() }
        // 棚の「＋」＝アプリを足しに行く（タブまで指定して連れていく）
        launcher.onAddShelfApp = { [weak self] in self?.settingsUI.show(selecting: .appKeys) }

        buildStatusItem()
        registerHotKeys()

        HotKeyManager.shared.onTrigger = { [weak self] action in
            self?.perform(action)
        }

        // 画面が増減したら、次のウィンドウ操作から新しい構成で計算されるように覚え直す
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screensChanged),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )

        // ⚠️ 初回に**説明なしの許可ダイアログを出さない**（前はここで出していた）。
        // 何のアプリが何のために求めているのか分からない許可は、まず断られる。
        //
        // ⚠️ 代わりに**窓を自分で1回だけ開く**。常駐アプリは入れた直後に何も起きないので
        // 「入れたのに動かない」と思われて終わる。実物を出して、その中で開き方を教える
        // （2026-08-06〜09 の設計。3案＋3審査の結論）。
        if Welcome.shouldOpenOnLaunch(done: store.settings.welcomeDone,
                                      shows: store.settings.welcomeShows) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
                self?.launcher.show(.all)
            }
        } else if !AXWindow.isTrusted(prompt: false) {
            // 作り直すと署名が変わり、macOSは前の許可を無効にする（テモトの中身は同じでも別物と見なす）。
            // 困るのはウィンドウ操作だけなので、他は使えることまで伝える。
            Toast.show(
                "ウィンドウ操作だけ動きません（アクセシビリティ未許可）。"
                + "履歴・検索窓・定型文はそのまま使えます。メニューの「アクセシビリティを許可」から入れ直せます。",
                isError: true)
        }

        prepareSecrets()

        // 合言葉の自動展開（設定で入れた人だけ）。
        // 定型文そのものを切っている人には、設定が残っていても動かさない
        AutoExpandMonitor.storeProvider = { [unowned store] in store }
        AutoExpandMonitor.update(enabled: store.settings.expandSnippets
                                 && store.settings.isVisible(.snippets))
    }

    /// 鍵を用意する。
    ///
    /// 前のビルドが作った鍵を読みに行くと、キーチェーンのパスワードを求める
    /// 許可ダイアログが出て、答えるまで消えない。作者はこれに答えられなかった。
    /// なので「出てから対処する」のではなく、読みに行く前に持ち主を確かめて避ける。
    private func prepareSecrets() {
        switch store.planForVault() {
        case .readOurs:
            // 自分が作った鍵。読んでもダイアログは出ないが、念のため別スレッドで。
            loadSecretsInBackground()

        case .recreate:
            // 他のビルドが作った鍵か、持ち主が分からない。読まずに作り直す。
            // ここは一瞬で終わるので、そのままメインスレッドでよい。
            let hadKeyFiles = store.hasEncryptedFiles
            if store.recreateVault() {
                secretsReady = true
                // 前の鍵で書いた絵はもう開けない。覚えている分を捨てて、読み直させる
                ClipThumbnailCache.forgetAll()
                PreviewImageCache.forgetAll()
                watcher.seed(with: store.clips.first)
                watcher.update(settings: store.settings.clipboard)
                if hadKeyFiles {
                    Toast.show("作り直したビルドなので、暗号鍵を新しくしました。前の履歴と定型文は読めません（消さずに残してあります）。")
                }
            } else {
                secretsReady = true
                Toast.show(store.vaultProblem ?? "暗号鍵を用意できませんでした", isError: true)
            }
            refreshStatusIcon()
        }
    }

    /// 鍵の取り出しと、暗号化してあるものの読み込み。
    ///
    /// isRetry は、鍵が取れずに一度あきらめたあと、メニューから取り直したとき。
    /// その間にコピーしたものがメモリに貯まっているので、消さないように読み方を変える。
    private func loadSecretsInBackground(isRetry: Bool = false) {
        DispatchQueue.global(qos: .userInitiated).async { [store] in
            // makeVault は Store の中身を書き換えないので、別スレッドから呼んで安全。
            let result = store.makeVault()
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                // 読み込みは必ずメインスレッドで。
                if isRetry {
                    store.adoptVaultKeepingMemory(result)
                } else {
                    store.adoptVault(result)
                }
                self.secretsReady = true
                // 鍵が来た＝これまで開けなかった絵が開ける。覚えた「開けない」を捨てる
                ClipThumbnailCache.forgetAll()
                PreviewImageCache.forgetAll()

                // 履歴の監視はここで初めて始める。
                // 先に始めてしまうと、拾った1件を直後の読み込みが上書きして消してしまう。
                self.watcher.seed(with: store.clips.first)
                self.watcher.update(settings: store.settings.clipboard)

                if let problem = store.vaultProblem {
                    Toast.show(problem, isError: true)
                } else if isRetry {
                    Toast.show("暗号鍵を取り直したので、履歴 \(store.clips.count)件を保存できます。")
                }
                self.refreshStatusIcon()

                // 鍵が来て初めて前からある絵を開ける。
                // 文字をまだ読んでいない絵に、ここで追い付く（1枚ずつ裏で読む）
                self.catchUpImageText()
            }
        }
    }

    /// 鍵を作り直す。
    ///
    /// アプリを作り直すと署名が変わり、macOSは前のビルドが作った鍵を「他人のもの」と見なす。
    /// 読もうとすると出る許可ダイアログはキーチェーンのパスワードを求めてきて、
    /// 作者の環境ではこれに答えられなかった。読めない鍵はここで捨てて作り直す。
    /// パスワードもダイアログも出ない（旧APIなら持ち主の確認をしないため）。
    @objc private func recreateVault() {
        let alert = NSAlert()
        alert.messageText = "暗号鍵を作り直しますか？"

        if store.canPersistSecrets {
            alert.informativeText = """
                今の鍵は問題なく使えています。作り直す必要はありません。

                作り直すと、いま画面に出ている履歴 \(store.clips.count)件・定型文 \(store.snippets.count)件は \
                新しい鍵で保存し直すので残ります。
                ただしディスクにしか無い分（読み込む前のもの）は読めなくなります。
                """
            alert.alertStyle = .warning
        } else {
            alert.informativeText = """
                前のビルドが作った鍵が残っていて、今のテモトからは読めません。
                作り直すと、キーチェーンのパスワードを聞かれずに保存できるようになります。

                ・起動してから拾った履歴 \(store.clips.count)件と定型文 \(store.snippets.count)件は、新しい鍵で保存します
                ・前の鍵で書いたファイルは読めなくなります（消さずに .broken として残します）
                """
            alert.alertStyle = .informational
        }

        alert.addButton(withTitle: "作り直す")
        alert.addButton(withTitle: "やめる")
        NSApp.activate()
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        if store.recreateVault() {
            secretsReady = true
            watcher.seed(with: store.clips.first)
            watcher.update(settings: store.settings.clipboard)
            Toast.show("暗号鍵を作り直しました。履歴 \(store.clips.count)件・定型文 \(store.snippets.count)件を保存できます。")
        } else {
            Toast.show(store.vaultProblem ?? "暗号鍵を作り直せませんでした", isError: true)
        }
        refreshStatusIcon()
    }

    func applicationWillTerminate(_ notification: Notification) {
        note.flush()
        HotKeyManager.shared.unregisterAll()
        watcher.stop()
    }

    // MARK: - ホットキー

    private func registerHotKeys(announceFailures: Bool = true) {
        let settings = store.settings

        // 使わないことにした機能はキーを押さえない。
        // 切った機能がショートカットだけ握っていると、そのキーが他のアプリで使えないまま
        // 何も起きず、原因の分からない「効かないキー」になる。
        var bindings: [(shortcut: Shortcut, action: HotKeyAction)] = [
            (settings.launcherShortcut, .launcher),
        ]
        if settings.isVisible(.clipboard) { bindings.append((settings.clipboardShortcut, .clipboard)) }
        if settings.isVisible(.snippets) { bindings.append((settings.snippetShortcut, .snippets)) }
        if settings.isNoteVisible { bindings.append((settings.noteShortcut, .note)) }
        if settings.isVisible(.windows) {
            bindings += settings.windowBindings.map { ($0.shortcut, HotKeyAction.layout($0.layout)) }
            bindings += settings.displayBindings.map { ($0.shortcut, HotKeyAction.moveToDisplay(step: $0.step)) }
        }
        // アプリのキーは「使う機能」に関係なく効かせる。
        // これは行き先ではなく、テモトを開かずに直接アプリへ飛ぶための道なので、
        // どの機能を切っても消えない（切ったつもりのない機能が消えるのが一番困る）。
        bindings += settings.appBindings.map {
            ($0.shortcut, HotKeyAction.openApp(path: $0.path, name: $0.name))
        }
        // 文字の変換も「使う機能」に関係なく効かせる（アプリのキーと同じ理屈）
        bindings += settings.convertBindings.map {
            ($0.shortcut, HotKeyAction.convert($0.transform))
        }
        // ⚠️ メニュー側と同じく「出す/出さない」に従う。
        // 切った機能がキーだけ握っていると、そのキーが他のアプリでも使えないまま何も起きない
        // （この段の冒頭に自分で書いた方針。行き先に昇格して切れるようになった分、ここも合わせる）
        if settings.isCaptureTextVisible, let capture = settings.captureTextShortcut {
            bindings.append((capture, .captureText))
        }
        if let pastePlain = settings.pastePlainShortcut {
            bindings.append((pastePlain, .pastePlain))
        }

        failedShortcuts = HotKeyManager.shared.register(bindings)
        // ⚠️ 押しても出ないキーを初めての人に教えない。取られていたら帯は「決め直す」に変わる
        launcher.launcherKeyFailed = failedShortcuts.contains { $0.action == .launcher }
        guard announceFailures, !failedShortcuts.isEmpty else { return }
        let list = failedShortcuts.map { $0.shortcut.displayString }.joined(separator: " ")
        Toast.show("他のアプリに取られていて登録できないショートカットがあります: \(list)", isError: true)
    }

    /// ショートカットを変えた直後に呼ぶ。押し直さなくても、次のひと押しから新しいキーで効く。
    private func reloadShortcuts() {
        // 設定が変わった＝自動展開の入切も見直す
        AutoExpandMonitor.update(enabled: store.settings.expandSnippets
                                 && store.settings.isVisible(.snippets))
        HotKeyManager.shared.unregisterAll()
        registerHotKeys(announceFailures: false)
        // メニューは開くたびに組み直すので、ここで作り直す必要は無い
        if let failure = failedShortcuts.first {
            Toast.show("\(failure.shortcut.displayString) は他のアプリに取られていて登録できません", isError: true)
        }
        refreshStatusIcon()
    }

    /// 使う機能を変えた直後に呼ぶ。
    /// アプリが前に出たとき（パネルを開いたとき等）。
    /// システム設定で許可を直して戻ってきた場面を拾って、しるしを合わせ直す
    func applicationDidBecomeActive(_ notification: Notification) {
        refreshStatusIcon()
    }

    private func reloadFeatures() {
        reloadShortcuts()
        launcher.settingsChanged()
        watcher.update(settings: store.settings.clipboard)
        refreshStatusIcon()
        // 「絵の中の文字を読む」を後からONにしたとき、それまでに溜まった絵にも読みに行く。
        // ここが無いと、設定を入れた効果が次にコピーした絵からしか出ず、
        // 「入れたのに何も変わらない」と見える。
        catchUpImageText()
    }

    private func perform(_ action: HotKeyAction) {
        switch action {
        // ⚠️ viaHotkey: true は「窓を出すキーを押せた」証拠。初めての案内はこれで終わる
        case .launcher: launcher.toggle(.all, viaHotkey: true)
        case .clipboard: if requireSecrets() { launcher.toggle(.clipboard) }
        case .snippets: if requireSecrets() { launcher.toggle(.snippets) }
        case .note: if requireSecrets() { note.toggle() }
        case .layout(let layout):
            if let failure = windowManager.apply(layout) { Toast.show(failure.message, isError: true) }
        case .moveToDisplay(let step):
            if let failure = windowManager.moveToNeighborDisplay(step: step) { Toast.show(failure.message, isError: true) }
        case .openApp(let path, let name):
            openBoundApp(path: path, name: name)
        case .convert(let transform):
            TextConverter.convertSelection(transform, watcher: watcher)
        case .captureText:
            // ⚠️ 窓は開かない。撮る道具をそのまま出す（テモトを見せると、その窓ごと撮ってしまう）
            ActionRunner.captureTextToClipboard()
        case .pastePlain:
            TextConverter.pastePlain(watcher: watcher)
        }
    }

    /// アプリのキーを押したとき。
    ///
    /// ⚠️ 「動いているか」ではなく「いちばん前にいるか」で分ける。
    /// 動いているかで分けると、裏で起動しっぱなしのアプリは押しても出てこない。
    private func openBoundApp(path: String, name: String) {
        let running = NSWorkspace.shared.runningApplications.first {
            $0.bundleURL?.resolvingSymlinksInPath().path == URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        }
        let exists = FileManager.default.fileExists(atPath: path) || running != nil

        switch AppHotKey.outcome(exists: exists, isFrontmost: running?.isActive == true) {
        case .missing:
            Toast.show(AppHotKey.missingMessage(name: name), isError: true)
        case .hide:
            // ⚠️ `running.hide()` だけに頼らない。今のmacOSは背面のプロセスが他アプリを
            // しまうことを黙って拒否する（2026-07-31 実測・最前面の相手でも false）。
            // アクセシビリティ越し（ウィンドウ分割と同じ許可）なら通るので、そちらを先に使う。
            guard let running else { return }
            let hidden = (AXWindow.isTrusted(prompt: false) && AXWindow.hideApp(pid: running.processIdentifier))
                || running.hide()
            if !hidden {
                Toast.show("しまうには「アクセシビリティ」の許可が必要です", isError: true)
            }
        case .activate:
            // ⚠️ `NSRunningApplication.activate` を使わない。true を返すのに前に出ない
            // （今のmacOSは背面のプロセスによる他アプリの前面化を黙って拒否し、
            // 戻り値が嘘をつく。2026-07-31 実測）。Dock や Spotlight と同じ
            // LaunchServices の道なら前に出るうえ、窓が1枚も無いアプリ（Finder等）には
            // 「開き直し」が届いて窓も作られる。
            // 動いているのにディスクから消えたアプリは、動いている実体の場所で開く
            ActionRunner.open(appPath: running?.bundleURL?.path ?? path)
        }
    }

    @objc private func screensChanged() {
        windowManager.forgetPrevious()
    }

    // MARK: - クリップボード

    private func handleClip(decision: ClipDecision, capture: ClipCapture?) {
        guard let capture else {
            // 捨てた理由は、秘密を検知したときだけ知らせる（空・重複でいちいち出すとうるさい）
            if case .skipSecret = decision {
                Toast.show(decision.reason, isError: true)
            }
            return
        }
        let item = capture.item

        // 絵は先に置いてから行を足す。順番が逆だと、一覧が先に描かれて
        // 「まだ無い絵」を読みに行き、開けなかったものとして覚えてしまう。
        if item.kind == .image, let original = capture.originalPNG {
            let saved = store.saveClipImage(
                id: item.id,
                original: original,
                thumbnail: capture.thumbnailPNG ?? original
            )
            if !saved && store.vaultProblem != nil {
                // 鍵が無いときはメモリにだけ持つ（Store 側でそう振る舞う）。
                // アプリを終えると消えることだけ伝えておく。
                Toast.show("画像は保存できないので、アプリを終えるまでの間だけ持ちます")
            }
        }

        let imagesBefore = imageIDs(store.clips)
        store.clips.insert(item, at: 0)
        store.clips = ClipRetention.prune(
            store.clips,
            maxCount: store.settings.clipboard.maxCount,
            maxAgeDays: store.settings.clipboard.maxAgeDays,
            maxImageCount: store.settings.clipboard.maxImageCount
        )
        store.saveClips()

        // 履歴から落ちた絵は実体も片付ける。
        // 文字を1つコピーしただけでも、件数の枠から古い絵が押し出されることがあるので、
        // 「今回入れたのが絵かどうか」ではなく「絵の顔ぶれが変わったか」で見る。
        // 消したつもりの絵がディスクに残り続けるのが一番まずい。
        if imagesBefore != imageIDs(store.clips) { store.pruneClipImages() }

        // 絵の中の文字を読む。
        // ⚠️ ここで待たない（0.2〜0.4秒かかる）。コピーの直後は次の操作が来る瞬間なので、
        // ここで止めると「コピーすると一瞬固まるアプリ」になる。
        if item.kind == .image, let original = capture.originalPNG,
           store.settings.clipboard.readImageText {
            readImageText(id: item.id, png: original)
        }
    }

    private func imageIDs(_ clips: [ClipItem]) -> Set<UUID> {
        Set(clips.filter { $0.kind == .image }.map(\.id))
    }

    // MARK: - 絵の中の文字

    /// 古い絵をまとめて読んでいる最中か（同じ絵を二重に読みに行かないための印）
    private var isCatchingUpImageText = false

    /// 1枚読んで、結果を履歴に書き戻す。
    ///
    /// ⚠️ 書き戻すときに id で探し直すのは、読んでいる間に履歴が動くから。
    /// 0.3秒あれば次のコピーが入って並びが変わるし、件数の枠から押し出されて消えてもいる。
    /// 添え字を覚えておくと、別の履歴に他人の絵の文字を書き込むことになる。
    private func readImageText(id: UUID, png: Data) {
        ImageTextReader.readInBackground(png: png) { [weak self] raw in
            guard let self else { return }
            guard let index = self.store.clips.firstIndex(where: { $0.id == id }),
                  var info = self.store.clips[index].image else { return }

            info.textScanned = true
            if let raw {
                switch ImageTextReader.verdict(for: raw, guardian: self.store.settings.clipboard.makeGuard()) {
                case .text(let text):
                    info.recognizedText = text
                    info.secretHint = nil
                case .noText:
                    info.recognizedText = nil
                    info.secretHint = nil
                case .secret(let label):
                    // 文字は持たない。理由だけ残して一覧に ⚠️ を出す。
                    // 絵そのものは消さない（誤検知で作者の画面写真が黙って消える方がまずい）
                    info.recognizedText = nil
                    info.secretHint = label
                    Toast.show("画像に秘密が写っている可能性があります（\(label)）", isError: true)
                }
            }

            self.store.clips[index].image = info
            self.store.saveClips()
            self.launcher.clipsChanged()
        }
    }

    /// 前からある絵にも、あとから文字を読みに行く。
    ///
    /// ⚠️ 起動のたびに全部読み直さないよう、textScanned を立てて覚える。
    /// ⚠️ 1枚ずつ順に読む。まとめて投げると Mac が起動直後に何本も走らせることになる。
    private func catchUpImageText() {
        guard store.settings.clipboard.readImageText else { return }
        // ⚠️ すでに読んでいる最中なら足さない。
        // 設定を保存するたびにここへ来るので、印を付けないと同じ絵を何本も並行で読みに行く。
        guard !isCatchingUpImageText else { return }
        let pending = store.clips
            .filter { $0.kind == .image }
            .filter { $0.image.map(ImageCaption.needsScan) ?? false }
            .prefix(ImageTextReader.catchUpLimit)
            .map(\.id)
        guard !pending.isEmpty else { return }
        isCatchingUpImageText = true
        readNextPendingImage(Array(pending))
    }

    private func readNextPendingImage(_ queue: [UUID]) {
        guard let id = queue.first else {
            isCatchingUpImageText = false
            launcher.clipsChanged()
            return
        }
        let rest = Array(queue.dropFirst())
        guard let png = store.loadClipImage(id: id) else {
            // 絵が開けない（鍵を作り直した後など）。二度と読みに来ないよう印だけ付ける
            if let index = store.clips.firstIndex(where: { $0.id == id }), var info = store.clips[index].image {
                info.textScanned = true
                store.clips[index].image = info
                store.saveClips()
            }
            readNextPendingImage(rest)
            return
        }
        ImageTextReader.readInBackground(png: png) { [weak self] raw in
            guard let self else { return }
            if let index = self.store.clips.firstIndex(where: { $0.id == id }),
               var info = self.store.clips[index].image {
                info.textScanned = true
                if let raw {
                    switch ImageTextReader.verdict(for: raw, guardian: self.store.settings.clipboard.makeGuard()) {
                    case .text(let text): info.recognizedText = text
                    case .noText: break
                    // 起動時の読み直しでは知らせを出さない（何枚も一度に出ると読めない）。
                    // 一覧の ⚠️ で気付けるようにしてある
                    case .secret(let label): info.secretHint = label
                    }
                }
                self.store.clips[index].image = info
                self.store.saveClips()
            }
            self.readNextPendingImage(rest)
        }
    }

    // MARK: - メニューバー

    private func buildStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        refreshStatusIcon()
        // 中身は開くたびに menuWillOpen で組み直す（警告の出入り・件数を最新にするため）
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
    }

    /// いまの状態から、警告の出し分けに要る材料を集める
    private func menuState() -> MenuPlan.State {
        MenuPlan.State(
            secretsReady: secretsReady,
            vaultBroken: store.vaultProblem != nil || !store.canPersistSecrets,
            loginState: LoginItemService.state,
            accessibilityGranted: AXWindow.isTrusted(prompt: false),
            failedShortcutCount: failedShortcuts.count,
            clipboardVisible: store.settings.isVisible(.clipboard),
            snippetsVisible: store.settings.isVisible(.snippets),
            noteVisible: store.settings.isNoteVisible,
            windowsVisible: store.settings.isVisible(.windows)
        )
    }

    /// メニューを今の状態で組み直す。
    ///
    /// ⚠️ 前の作り（2026-07-30 作者「このメニュー画面、構成が汚い」で作り直した）:
    /// - 灰色の1行に件数と警告を「・」で詰め込み、右端で切れていた → 廃止。
    ///   警告は最上部の「要対応」節の**押して直せる行**に、履歴の件数はバッジになった
    /// - ショートカットを題名に全角スペースで連結していた → keyEquivalent の右寄せ表示に
    /// - 「履歴をすべて消す…」「設定フォルダを開く」等の管理系 → 設定画面へ移した
    ///   （設定フォルダは ⌥ を押しながらメニューを開くと「設定…」の位置に出る）
    private func rebuildMenu(_ menu: NSMenu) {
        menu.removeAllItems()
        let settings = store.settings

        // ── 要対応（警告0件なら節ごと出さない。沈黙＝健康）
        let warnings = MenuPlan.warnings(menuState())
        if !secretsReady || !warnings.isEmpty {
            menu.addItem(.sectionHeader(title: MenuPlan.warningSectionTitle))
            if !secretsReady {
                menu.addItem(NSMenuItem(title: "鍵の確認中…", action: nil, keyEquivalent: ""))
                // ⚠️ 逃げ道を必ず残す。キーチェーンの許可ダイアログに答えられず
                // 鍵の確認が返ってこない事故が実際に起きている（prepareSecrets参照）。
                // このとき唯一の出口がこの行（requireSecrets のトーストもここへ案内している）
                let escape = NSMenuItem(title: "鍵の確認が終わらないとき — 暗号鍵を作り直す…",
                                        action: #selector(recreateVault), keyEquivalent: "")
                escape.target = self
                escape.image = NSImage(systemSymbolName: "exclamationmark.triangle",
                                       accessibilityDescription: "要対応")
                escape.image?.isTemplate = true
                menu.addItem(escape)
            }
            // 鍵と関係ない警告（自動起動・アクセシビリティ等）は確認中でも出す。
            // 出さないと、警告のしるしを見てメニューを開いたのに原因の行が無い、になる
            for warning in warnings {
                let item = NSMenuItem(title: warning.title,
                                      action: warningSelector(for: warning.kind), keyEquivalent: "")
                item.target = self
                // アイコンは警告にしか付けない＝絵が出たら異常のサイン（無彩色のまま重みを出す）
                item.image = NSImage(systemSymbolName: "exclamationmark.triangle",
                                     accessibilityDescription: "要対応")
                item.image?.isTemplate = true
                menu.addItem(item)
            }
            menu.addItem(.separator())
        }

        // ── 入口（設定で切った機能は出さない。押しても何も起きない行が一番分かりにくい）
        add(to: menu, title: "検索を開く", shortcut: settings.launcherShortcut, action: #selector(openLauncher))
        if settings.isVisible(.clipboard) {
            let item = add(to: menu, title: "コピー履歴",
                           shortcut: settings.clipboardShortcut, action: #selector(openClipboard))
            // 件数は文字ではなくバッジで。0件でも出す（「動いているが空」と「機能オフ」を見分けるため）
            item.badge = NSMenuItemBadge(count: store.clips.count)
            if !secretsReady { item.action = nil }
        }
        if settings.isVisible(.snippets) {
            let item = add(to: menu, title: "定型文", shortcut: settings.snippetShortcut, action: #selector(openSnippets))
            if !secretsReady { item.action = nil }
        }
        if settings.isNoteVisible {
            let item = add(to: menu, title: "メモ", shortcut: settings.noteShortcut, action: #selector(openNote))
            if !secretsReady { item.action = nil }
        }
        // 画面の文字読み取りは鍵（secrets）に関係しないので、暗号鍵が無くても押せる
        add(to: menu, title: Welcome.revisitTitle, shortcut: nil, action: #selector(replayWelcome))
        if settings.isCaptureTextVisible {
            add(to: menu, title: "画面の文字を読み取る",
                shortcut: settings.captureTextShortcut, action: #selector(captureText))
        }

        // ── ウィンドウ（17種の羅列はサブメニューに畳む。中は節見出しと形のしるしで走査できるように）
        if settings.isVisible(.windows) {
            menu.addItem(.separator())
            var shortcutByLayout: [WindowLayout: Shortcut] = [:]
            for binding in settings.windowBindings { shortcutByLayout[binding.layout] = binding.shortcut }

            let windowMenu = NSMenu()
            windowMenu.addItem(.sectionHeader(title: "配置"))
            for layout in WindowLayout.allCases {
                let item = NSMenuItem(title: layout.title, action: #selector(applyLayout(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = layout.rawValue
                if let shortcut = shortcutByLayout[layout], let key = shortcut.menuKeyEquivalent {
                    item.keyEquivalent = key
                    item.keyEquivalentModifierMask = NSEvent.ModifierFlags(rawValue: shortcut.cocoaModifierRawFlags)
                }
                // 形は文字より速い。17種を言葉だけで探させない（無彩色の template で色は増やさない）
                if let symbol = AppDelegate.layoutSymbols[layout] {
                    item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: layout.title)
                    item.image?.isTemplate = true
                }
                windowMenu.addItem(item)
            }
            if !settings.displayBindings.isEmpty {
                windowMenu.addItem(.separator())
                windowMenu.addItem(.sectionHeader(title: "別の画面へ"))
                for binding in settings.displayBindings {
                    let title = binding.step > 0 ? "次の画面へ移す" : "前の画面へ移す"
                    let item = NSMenuItem(title: title, action: #selector(moveDisplay(_:)), keyEquivalent: "")
                    item.target = self
                    item.representedObject = binding.step
                    if let key = binding.shortcut.menuKeyEquivalent {
                        item.keyEquivalent = key
                        item.keyEquivalentModifierMask = NSEvent.ModifierFlags(rawValue: binding.shortcut.cocoaModifierRawFlags)
                    }
                    windowMenu.addItem(item)
                }
            }
            let windowItem = NSMenuItem(title: "ウィンドウ", action: nil, keyEquivalent: "")
            windowItem.submenu = windowMenu
            menu.addItem(windowItem)
        }

        // ── アプリ
        menu.addItem(.separator())
        let settingsItem = NSMenuItem(title: "設定…", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)
        // ⌥ を押しながら開くと「設定…」がこれに変わる（Wi-Fiメニューの ⌥ と同じ流儀）。
        // 正規の入口は設定画面の「一般」タブにもある
        let folderItem = NSMenuItem(title: "設定フォルダを開く", action: #selector(openSettingsFolder), keyEquivalent: ",")
        folderItem.target = self
        folderItem.isAlternate = true
        // ⚠️ 畳みの条件は「同じキーで修飾だけ違う」。キーを空にすると畳まれず2行並ぶことがある
        folderItem.keyEquivalentModifierMask = [.command, .option]
        menu.addItem(folderItem)

        menu.addItem(.separator())
        // ⚠️ 終了にショートカットを付けない。メニューを開いたまま反射で ⌘Q を押すと
        // 常駐ごと落ちる（アプリを閉じたつもりでテモトが消えるのは事故）
        add(to: menu, title: "テモトを終了", shortcut: nil, action: #selector(quit))
    }

    /// 警告の種類 → 押したときの動き
    private func warningSelector(for kind: MenuPlan.Warning.Kind) -> Selector {
        switch kind {
        case .vault: return #selector(recreateVault)
        case .loginOff: return #selector(enableLoginItem)
        case .loginNeedsApproval: return #selector(openLoginItemSettings)
        case .accessibility: return #selector(openAccessibilitySettings)
        case .shortcuts: return #selector(openSettings)
        }
    }

    /// ウィンドウ配置の形のしるし（SF Symbols・無彩色）。無い名前なら付かないだけ
    private static let layoutSymbols: [WindowLayout: String] = [
        .leftHalf: "rectangle.lefthalf.filled",
        .rightHalf: "rectangle.righthalf.filled",
        .topHalf: "rectangle.tophalf.filled",
        .bottomHalf: "rectangle.bottomhalf.filled",
        .topLeft: "rectangle.inset.topleft.filled",
        .topRight: "rectangle.inset.topright.filled",
        .bottomLeft: "rectangle.inset.bottomleft.filled",
        .bottomRight: "rectangle.inset.bottomright.filled",
        .leftThird: "rectangle.leadingthird.inset.filled",
        .centerThird: "rectangle.center.inset.filled",
        .rightThird: "rectangle.trailingthird.inset.filled",
        .leftTwoThirds: "rectangle.leadinghalf.inset.filled",
        .rightTwoThirds: "rectangle.trailinghalf.inset.filled",
        .maximize: "rectangle.fill",
        .almostMaximize: "rectangle.inset.filled",
        .center: "square.grid.3x3.middle.filled",
        .restore: "arrow.uturn.backward",
    ]

    /// メニューバーのしるしを今の状態に合わせる。
    /// 警告がある間はしるし自体が変わる（メニューを開かない限り警告が見えない穴を塞ぐ）
    private func refreshStatusIcon() {
        guard let button = statusItem?.button else { return }
        let symbol = MenuPlan.statusSymbol(warningCount: MenuPlan.warnings(menuState()).count)
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "テモト")
        button.image?.isTemplate = true
    }

    /// 鍵がまだ来ていない間は、履歴・定型文・メモを触らせない。
    /// 空のまま見せると「消えた」と誤解させるし、
    /// その状態で保存すると本物のファイルを空で上書きしかねない。
    private func requireSecrets() -> Bool {
        if secretsReady { return true }
        Toast.show("鍵の確認中です。数秒待っても変わらなければ、メニューの「暗号鍵を作り直す…」を押してください。", isError: true)
        return false
    }

    @discardableResult
    private func add(to menu: NSMenu, title: String, shortcut: Shortcut?, action: Selector) -> NSMenuItem {
        // ショートカットは keyEquivalent で右寄せのネイティブ表示にする。
        // ⚠️ 題名に全角スペースで連結しない（右端が揃わず「構成が汚い」の一因だった）。
        // メニュー表示中しか発火しないので、グローバルの登録とはぶつからない
        let item = NSMenuItem(title: title, action: action, keyEquivalent: shortcut?.menuKeyEquivalent ?? "")
        if let shortcut {
            if shortcut.menuKeyEquivalent != nil {
                item.keyEquivalentModifierMask = NSEvent.ModifierFlags(rawValue: shortcut.cocoaModifierRawFlags)
            } else {
                // 出せないキーだけ、昔ながらの文字連結で妥協する
                item.title = "\(title)　\(shortcut.displayString)"
            }
        }
        item.target = self
        menu.addItem(item)
        return item
    }

    // MARK: - メニューの動作

    @objc private func openLauncher() { launcher.show(.all) }
    @objc private func openClipboard() { if requireSecrets() { launcher.show(.clipboard) } }
    @objc private func openSnippets() { if requireSecrets() { launcher.show(.snippets) } }
    @objc private func openNote() { if requireSecrets() { note.show() } }
    @objc private func captureText() { ActionRunner.captureTextToClipboard() }
    @objc private func replayWelcome() { launcher.replayWelcome() }

    @objc private func applyLayout(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let layout = WindowLayout(rawValue: raw) else { return }
        if let failure = windowManager.apply(layout) { Toast.show(failure.message, isError: true) }
    }

    @objc private func moveDisplay(_ sender: NSMenuItem) {
        guard let step = sender.representedObject as? Int else { return }
        if let failure = windowManager.moveToNeighborDisplay(step: step) { Toast.show(failure.message, isError: true) }
    }

    @objc private func clearClips() {
        // 鍵が来る前に消すと、画面上は空になるのにディスクの本物は残り、
        // 鍵が来た瞬間にまた出てきてしまう。消したつもりが消えていないのが一番まずい。
        guard requireSecrets() else { return }
        let alert = NSAlert()
        alert.messageText = "コピー履歴をすべて消しますか？"
        alert.informativeText = "\(store.clips.count)件を消します。ピン留めしたものも消えます。元には戻せません。"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "消す")
        alert.addButton(withTitle: "やめる")
        NSApp.activate()
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        store.clips.removeAll()
        store.saveClips()
        // 絵は履歴とは別ファイルなので、ここで一緒に消さないと残ってしまう
        store.deleteAllClipImages()
        ClipThumbnailCache.forgetAll()
        PreviewImageCache.forgetAll()
        watcher.ignoreCurrentChange()
        Toast.show("コピー履歴を消しました")
    }

    @objc private func openSettings() {
        settingsUI.show()
    }

    @objc private func openSettingsFolder() {
        NSWorkspace.shared.open(store.directory)
    }

    @objc private func openAccessibilitySettings() {
        // 権限が無い状態なら、まずシステムのダイアログを出す（そこから許可すると再起動なしで効く）
        if !AXWindow.isTrusted(prompt: true) {
            let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
            if let url { NSWorkspace.shared.open(url) }
            // 作り直した後は、一覧に「テモト」が残ったまま中身だけ別物になっている。
            // スイッチを入れ直すだけで効くこともあるが、古い記録が残って効かないことがある。
            // そのときは消してから足し直す（パスワードは要らない。指紋で通る）。
            Toast.show(
                "一覧の「Temoto」を ⊖ で一度消してから、＋ で ~/Applications/Temoto.app を足し直してください（指紋でOK）。"
                + "スイッチの入れ直しだけでは、古い記録が残って効かないことがあります。")
        } else {
            Toast.show("アクセシビリティ権限は許可されています")
        }
    }

    /// 警告「再起動すると立ち上がりません」を押したとき。その場で自動起動を入にする
    @objc private func enableLoginItem() {
        if LoginItemService.setEnabled(true) {
            // ⚠️ 登録が通っても、OS側の許可待ち（needsApproval）で止まることがある。
            // そのまま「立ち上がります」と言うと、次に開いたメニューの警告と矛盾する
            if LoginItemService.state == .needsApproval {
                Toast.show("あと一歩: システム設定のログイン項目で「テモト」を許可してください", isError: true)
                LoginItemService.openSystemSettings()
            } else {
                Toast.show("次のMac起動からテモトが自動で立ち上がります")
            }
        } else {
            Toast.show("自動起動を入にできませんでした（設定 → 一般 から入れ直せます）", isError: true)
        }
        refreshStatusIcon()
    }

    /// 警告「ログイン項目の許可が必要です」を押したとき
    @objc private func openLoginItemSettings() {
        LoginItemService.openSystemSettings()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}

extension AppDelegate: NSMenuDelegate {
    /// 開くたびに丸ごと組み直す（警告の出入り・バッジの件数を最新にする）。
    /// サブメニュー（ウィンドウ）にも同じ通知が来るので、大元のメニューだけ組み直す
    func menuWillOpen(_ menu: NSMenu) {
        guard menu === statusItem?.menu else { return }
        rebuildMenu(menu)
        refreshStatusIcon()
    }
}
