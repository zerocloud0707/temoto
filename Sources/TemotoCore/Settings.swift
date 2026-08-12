import Foundation

/// ウィンドウ操作に割り当てるショートカット1件
public struct WindowBinding: Codable, Equatable, Sendable {
    public var layout: WindowLayout
    public var shortcut: Shortcut

    public init(layout: WindowLayout, shortcut: Shortcut) {
        self.layout = layout
        self.shortcut = shortcut
    }
}

/// 画面間の移動に割り当てるショートカット
public struct DisplayBinding: Codable, Equatable, Sendable {
    public var step: Int          // +1 = 次の画面 / -1 = 前の画面
    public var shortcut: Shortcut

    public init(step: Int, shortcut: Shortcut) {
        self.step = step
        self.shortcut = shortcut
    }
}

public struct ClipboardSettings: Codable, Equatable, Sendable {
    public var enabled: Bool
    public var maxCount: Int
    public var maxAgeDays: Int
    /// 中身を見ずに捨てるアプリ（バンドルID）
    public var excludedBundleIDs: [String]
    /// この語を含むコピーは保存しない（自分で足せる安全網）
    public var excludedPatterns: [String]

    /// 画像も履歴に残すか。
    public var captureImages: Bool

    /// 絵の中の文字を読むか（既定: 入）。
    ///
    /// 入にすると2つ変わる。
    /// 1. 一覧の題名が「画像 912×592」から中身の言葉になる（どの絵か目で選べる）
    /// 2. **絵にも秘密の検知が効くようになる**。
    ///    切っている間は、パスワードやカード番号を写したスクリーンショットが
    ///    そうと分からずに残る（絵の中の文字は誰にも読めないので止めようがない）。
    ///
    /// 読むのは自分の Mac の中だけで、どこにも送らない（Apple の Vision をそのまま呼ぶ）。
    public var readImageText: Bool
    /// ファイル（Finderからのコピー）も履歴に残すか。中身は持たず置き場所だけ覚える。
    public var captureFiles: Bool
    /// 1枚あたりの上限（MB）。これより大きい画像は残さない。
    public var maxImageMB: Int
    /// 画像だけの件数の枠。画像は1件が重いので、文字と同じ枠では持たない。
    public var maxImageCount: Int

    public init(
        enabled: Bool = true,
        maxCount: Int = 300,
        maxAgeDays: Int = 30,
        excludedBundleIDs: [String] = Array(ClipboardGuard.defaultExcludedBundleIDs).sorted(),
        excludedPatterns: [String] = [],
        captureImages: Bool = true,
        readImageText: Bool = true,
        captureFiles: Bool = true,
        maxImageMB: Int = 12,
        maxImageCount: Int = 30
    ) {
        self.enabled = enabled
        self.maxCount = maxCount
        self.maxAgeDays = maxAgeDays
        self.excludedBundleIDs = excludedBundleIDs
        self.excludedPatterns = excludedPatterns
        self.captureImages = captureImages
        self.readImageText = readImageText
        self.captureFiles = captureFiles
        self.maxImageMB = maxImageMB
        self.maxImageCount = maxImageCount
    }

    public func makeGuard() -> ClipboardGuard {
        ClipboardGuard(
            excludedBundleIDs: Set(excludedBundleIDs),
            userPatterns: excludedPatterns,
            capturesImages: captureImages,
            capturesFiles: captureFiles,
            maxImageBytes: max(1, maxImageMB) * 1024 * 1024
        )
    }

    /// 設定ファイルに無い項目は既定値で埋める（下の Settings と同じ理由）
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = ClipboardSettings()
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? d.enabled
        maxCount = try c.decodeIfPresent(Int.self, forKey: .maxCount) ?? d.maxCount
        maxAgeDays = try c.decodeIfPresent(Int.self, forKey: .maxAgeDays) ?? d.maxAgeDays
        excludedBundleIDs = try c.decodeIfPresent([String].self, forKey: .excludedBundleIDs) ?? d.excludedBundleIDs
        excludedPatterns = try c.decodeIfPresent([String].self, forKey: .excludedPatterns) ?? d.excludedPatterns
        captureImages = try c.decodeIfPresent(Bool.self, forKey: .captureImages) ?? d.captureImages
        readImageText = try c.decodeIfPresent(Bool.self, forKey: .readImageText) ?? d.readImageText
        captureFiles = try c.decodeIfPresent(Bool.self, forKey: .captureFiles) ?? d.captureFiles
        maxImageMB = try c.decodeIfPresent(Int.self, forKey: .maxImageMB) ?? d.maxImageMB
        maxImageCount = try c.decodeIfPresent(Int.self, forKey: .maxImageCount) ?? d.maxImageCount
    }
}

/// ファイル検索の設定。
///
/// ⚠️ 中身検索を既定で入にしている理由。
/// 名前だけの検索なら Finder でもできる。中身まで探せて初めて
/// 「あの数字が入っていた資料」を思い出せずに探せる。テモトの取り柄はそこ。
/// ただし Spotlight の索引に本文が無いファイル（暗号化PDF等）は当たらない。
/// ⚠️ ここに「使う／使わない」は置かない。
/// 機能を出すか出さないかは `hiddenFeatures`（設定の「使う機能」）1か所で決める。
/// 同じことを2か所で切り替えられると、片方を切ったのにもう片方が入ったままになり、
/// 「切ったのに出る」「入れたのに出ない」で必ず迷う。
public struct FileSearchSettings: Codable, Equatable, Sendable {
    /// 本文まで見にいくか。切ると速いが「中身:」が効かなくなる。
    public var searchesContent: Bool
    /// 一覧に出す上限。多くしても人は読まないので、既定は控えめ。
    public var maxResults: Int
    /// 探しにいく場所（空ならホーム全体）。
    /// 「デスクトップ」「~/Documents/Claude」のどちらの書き方でも受ける。
    public var folders: [String]
    /// 名前を付けて取っておいた検索条件（2026-07-30 作者「検索条件を保存したり」）
    public var saved: [SavedFileSearch]

    public init(
        searchesContent: Bool = true,
        maxResults: Int = 100,
        folders: [String] = [],
        saved: [SavedFileSearch] = []
    ) {
        self.searchesContent = searchesContent
        self.maxResults = maxResults
        self.folders = folders
        self.saved = saved
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = FileSearchSettings()
        searchesContent = try c.decodeIfPresent(Bool.self, forKey: .searchesContent) ?? d.searchesContent
        maxResults = try c.decodeIfPresent(Int.self, forKey: .maxResults) ?? d.maxResults
        folders = try c.decodeIfPresent([String].self, forKey: .folders) ?? d.folders
        saved = try c.decodeIfPresent([SavedFileSearch].self, forKey: .saved) ?? d.saved
    }
}

/// メモの設定。
public struct NoteSettings: Codable, Equatable, Sendable {
    /// フォルダ保存（.md）の置き場。空＝まだ選んでいない。
    /// ⚠️ ここに置いた .md は**平文**。秘密を書くメモは「このアプリの中」に置く。
    public var folderPath: String

    public init(folderPath: String = "") {
        self.folderPath = folderPath
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = NoteSettings()
        folderPath = try c.decodeIfPresent(String.self, forKey: .folderPath) ?? d.folderPath
    }
}

/// 設定画面の「1行に1つ」書く欄を配列にする。
///
/// 画面の部品はテストできない（実行ファイル側にあるので import できない）ので、
/// 間違えると困る読み取りだけこちらに置いている。
public enum SettingsLines {
    public static func split(_ text: String?) -> [String] {
        (text ?? "")
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }
}

public struct Settings: Codable, Equatable, Sendable {
    public var launcherShortcut: Shortcut
    public var clipboardShortcut: Shortcut
    public var snippetShortcut: Shortcut
    public var noteShortcut: Shortcut
    public var windowBindings: [WindowBinding]
    public var displayBindings: [DisplayBinding]
    /// よく使うアプリに割り当てたキー。既定は空（誰が何を使うかは人による）
    public var appBindings: [AppBinding]
    /// 文字の変換（ひらがな・カタカナ・全角・半角）に割り当てたキー。既定は空
    public var convertBindings: [ConvertBinding]
    /// 書式なし貼り付け（コピー中の文字から色・書式を落として貼る）。既定は未割り当て
    public var pastePlainShortcut: Shortcut?
    /// 合言葉の自動展開（どのアプリでも、打った瞬間に定型文の本文へ置き換える）。
    /// ⚠️ 既定は**切**。キーの流れを見る仕組みなので、本人が意味を分かって入れる形にする
    /// （どこにも書かない・送らないが、それでも「勝手に見ている」は既定にしない）。
    public var expandSnippets: Bool

    /// 初めての案内（帯）を、もう出さなくてよいか。
    /// ⚠️ 「窓を出すキーを実際に押せた」ときだけ true にする。時間や回数では立てない
    public var welcomeDone: Bool
    /// 初めての案内を出した回数。上限（Welcome.maxShows）を超えたら諦める
    public var welcomeShows: Int

    /// 画面を撮ってその中の文字をコピーする。既定は未割り当て
    /// （撮る系のキーは ⇧⌘4 等と取り合いになりやすいので、割り当ては本人に決めてもらう）
    public var captureTextShortcut: Shortcut?
    public var clipboard: ClipboardSettings
    public var fileSearch: FileSearchSettings
    public var note: NoteSettings

    /// 使わない機能。ここに入れたものは検索窓に出さず、Tab でも通らない。
    ///
    /// テモトを作った理由そのものが「使わない機能が多い」なので、
    /// 消す側を設定で持てるようにしてある。
    ///
    /// ⚠️ 持つのは「隠すもの」であって「出すもの」ではない。
    /// 逆にすると、あとで機能を足したときに古い設定ファイルにその名前が無く、
    /// 足した機能が誰の画面にも出てこない（設定を開くまで気づけない）。
    public var hiddenFeatures: [String]

    /// 出さないアプリ（本当ならは出るが、作者が外したもの）
    ///
    /// ⚠️ 「出すもの」ではなく「既定からの差」を持つ。
    /// 出すものを持つと、新しくアプリを入れたときに名前が無くて出てこない。
    public var hiddenApps: [String]

    /// 出すアプリ（本当なら裏方として隠れるが、作者が出したもの）
    public var shownApps: [String]

    /// アプリを探すフォルダ（自分で作った・自分で置いたアプリの置き場所）。
    /// 既定は空＝/Applications 等の決まった場所だけ見る
    public var appFolders: [String]

    /// 検索窓の先頭に並ぶ行き先の順番（`LauncherEntry.key` を並べたもの）。
    ///
    /// 2026-07-29 作者「順番とか、不要なものは非表示。」
    /// 隠す方は `hiddenFeatures` が持っている。ここが持つのは順番だけ。
    ///
    /// ⚠️ 空なら既定の順。ここに書いていない名前は
    /// `LauncherEntry.ordered` が既定の順のまま後ろに足す（新しい機能が消えない）。
    public var entryOrder: [String]

    public init(
        launcherShortcut: Shortcut = Settings.defaultLauncher,
        clipboardShortcut: Shortcut = Settings.defaultClipboard,
        snippetShortcut: Shortcut = Settings.defaultSnippet,
        noteShortcut: Shortcut = Settings.defaultNote,
        windowBindings: [WindowBinding] = Settings.defaultWindowBindings,
        displayBindings: [DisplayBinding] = Settings.defaultDisplayBindings,
        appBindings: [AppBinding] = [],
        convertBindings: [ConvertBinding] = [],
        pastePlainShortcut: Shortcut? = nil,
        captureTextShortcut: Shortcut? = nil,
        expandSnippets: Bool = false,
        welcomeDone: Bool = false,
        welcomeShows: Int = 0,
        clipboard: ClipboardSettings = ClipboardSettings(),
        fileSearch: FileSearchSettings = FileSearchSettings(),
        note: NoteSettings = NoteSettings(),
        // ⚠️ 既定は最小構成（2026-08-12 公開監査。「シンプル」が売りなのに初期状態で
        // 全機能が並ぶと多機能ランチャーに見える）。隠した機能は設定の「使う機能」で足せる。
        // 既に settings.json を持っている人には効かない（保存済みの値が勝つ）
        hiddenFeatures: [String] = [LauncherMode.links.rawValue,
                                    LauncherMode.windows.rawValue,
                                    LauncherMode.calculator.rawValue],
        hiddenApps: [String] = [],
        shownApps: [String] = [],
        appFolders: [String] = [],
        entryOrder: [String] = []
    ) {
        self.launcherShortcut = launcherShortcut
        self.clipboardShortcut = clipboardShortcut
        self.snippetShortcut = snippetShortcut
        self.noteShortcut = noteShortcut
        self.windowBindings = windowBindings
        self.displayBindings = displayBindings
        self.appBindings = appBindings
        self.convertBindings = convertBindings
        self.pastePlainShortcut = pastePlainShortcut
        self.captureTextShortcut = captureTextShortcut
        self.expandSnippets = expandSnippets
        self.welcomeDone = welcomeDone
        self.welcomeShows = welcomeShows
        self.clipboard = clipboard
        self.fileSearch = fileSearch
        self.note = note
        self.hiddenFeatures = hiddenFeatures
        self.hiddenApps = hiddenApps
        self.shownApps = shownApps
        self.appFolders = appFolders
        self.entryOrder = entryOrder
    }

    /// 設定ファイルに無い項目は既定値で埋める。
    ///
    /// ⚠️ 自前で書いている理由。
    /// 既定の読み方だと、項目が1つでも欠けると Settings 全体の読み込みが失敗する。
    /// Store はその場合まるごと既定値に戻すので、**機能を1つ足しただけで、
    /// 利用者が変えたショートカットが黙って全部消える**。
    /// 1項目ずつ「無ければ既定」で読めば、古い settings.json のままでも壊れない。
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Settings()
        launcherShortcut = try c.decodeIfPresent(Shortcut.self, forKey: .launcherShortcut) ?? d.launcherShortcut
        clipboardShortcut = try c.decodeIfPresent(Shortcut.self, forKey: .clipboardShortcut) ?? d.clipboardShortcut
        snippetShortcut = try c.decodeIfPresent(Shortcut.self, forKey: .snippetShortcut) ?? d.snippetShortcut
        noteShortcut = try c.decodeIfPresent(Shortcut.self, forKey: .noteShortcut) ?? d.noteShortcut
        windowBindings = try c.decodeIfPresent([WindowBinding].self, forKey: .windowBindings) ?? d.windowBindings
        displayBindings = try c.decodeIfPresent([DisplayBinding].self, forKey: .displayBindings) ?? d.displayBindings
        appBindings = try c.decodeIfPresent([AppBinding].self, forKey: .appBindings) ?? d.appBindings
        convertBindings = try c.decodeIfPresent([ConvertBinding].self, forKey: .convertBindings) ?? d.convertBindings
        pastePlainShortcut = try c.decodeIfPresent(Shortcut.self, forKey: .pastePlainShortcut) ?? d.pastePlainShortcut
        captureTextShortcut = try c.decodeIfPresent(Shortcut.self, forKey: .captureTextShortcut) ?? d.captureTextShortcut
        // ⚠️ decodeIfPresent。前の版の settings.json にこの欄は無いので、
        // 必須にすると読み込みごと失敗して**設定が丸ごと初期化される**
        expandSnippets = try c.decodeIfPresent(Bool.self, forKey: .expandSnippets) ?? d.expandSnippets
        welcomeDone = try c.decodeIfPresent(Bool.self, forKey: .welcomeDone) ?? d.welcomeDone
        welcomeShows = try c.decodeIfPresent(Int.self, forKey: .welcomeShows) ?? d.welcomeShows
        clipboard = try c.decodeIfPresent(ClipboardSettings.self, forKey: .clipboard) ?? d.clipboard
        fileSearch = try c.decodeIfPresent(FileSearchSettings.self, forKey: .fileSearch) ?? d.fileSearch
        note = try c.decodeIfPresent(NoteSettings.self, forKey: .note) ?? d.note
        // ⚠️ 読み込みだけは「無ければ空＝全部出す」。
        // 新規の既定（最小構成）をここに使うと、hiddenFeatures の欄が無い古い設定ファイルの人から
        // **上書き導入した日に機能が突然消える**。新規と持ち越しで既定を分ける
        hiddenFeatures = try c.decodeIfPresent([String].self, forKey: .hiddenFeatures) ?? []
        hiddenApps = try c.decodeIfPresent([String].self, forKey: .hiddenApps) ?? d.hiddenApps
        shownApps = try c.decodeIfPresent([String].self, forKey: .shownApps) ?? d.shownApps
        appFolders = try c.decodeIfPresent([String].self, forKey: .appFolders) ?? d.appFolders
        entryOrder = try c.decodeIfPresent([String].self, forKey: .entryOrder) ?? d.entryOrder
    }

    // MARK: - 出すアプリの選び方

    /// このアプリを検索窓に出すか。
    /// 手で決めたものがあればそれを優先し、無ければ自動の判断に従う。
    public func isAppVisible(_ record: AppRecord) -> Bool {
        if shownApps.contains(record.path) { return true }
        if hiddenApps.contains(record.path) { return false }
        return AppVisibility.isVisibleByDefault(path: record.path, isHelper: record.isHelper)
    }

    /// 設定画面のチェックを反映する。
    ///
    /// ⚠️ 自動の判断と同じ状態に戻したときは、どちらの一覧からも消す。
    /// 差分だけを持たせておかないと、settings.json が「全アプリの一覧」に育っていき、
    /// あとで既定を直しても古い設定に上書きされて効かなくなる。
    public mutating func setAppVisible(_ record: AppRecord, _ visible: Bool) {
        hiddenApps.removeAll { $0 == record.path }
        shownApps.removeAll { $0 == record.path }
        let byDefault = AppVisibility.isVisibleByDefault(path: record.path, isHelper: record.isHelper)
        guard visible != byDefault else { return }
        if visible {
            shownApps.append(record.path)
        } else {
            hiddenApps.append(record.path)
        }
    }

    /// 手で決めた分を全部捨てて、自動の判断に戻す
    public mutating func resetAppChoices() {
        hiddenApps.removeAll()
        shownApps.removeAll()
    }

    /// 手で決めた件数（設定画面に「何件いじったか」を出すため）
    public var appChoiceCount: Int { hiddenApps.count + shownApps.count }

    // MARK: - 使う機能のオン/オフ

    /// メモは行き先（LauncherMode）ではないので、隠す対象としての名前だけ持たせる
    public static let noteFeature = "note"

    /// 画面の文字読み取りも行き先（LauncherMode）ではない。
    /// 2026-08-05 作者「これコピー履歴や定型文と同じメニューに追加お願い！これよく使うと思うので。」
    /// ⚠️ 名前に `.` を含めるのは、行き先の名前（LauncherMode.rawValue＝clipboard 等）と
    /// 絶対にぶつからないようにするため。
    public static let captureTextFeature = "capture.text"

    /// 隠せない行き先。入口を隠せてしまうと、どこにも行けなくなる。
    public static let alwaysVisible: LauncherMode = .all

    public func isVisible(_ mode: LauncherMode) -> Bool {
        mode == Settings.alwaysVisible || !hiddenFeatures.contains(mode.rawValue)
    }

    public var isNoteVisible: Bool {
        !hiddenFeatures.contains(Settings.noteFeature)
    }

    public var isCaptureTextVisible: Bool {
        !hiddenFeatures.contains(Settings.captureTextFeature)
    }

    /// 検索窓に出す行き先。入口は必ず含む。
    ///
    /// ⚠️ 並びは作者が決めた順（`entryOrder`）に従う。宣言順ではない。
    /// Tab の巡回も ⌘1〜 の番号もここを見るので、
    /// ここが並べ替えを無視すると「1番上に置いたのに⌘3」になる。
    public var visibleModes: [LauncherMode] {
        [.all] + visibleEntries.compactMap(\.mode)
    }

    // MARK: - 行き先の並び順

    /// 隠したものも含めた全部を、決めた順に。設定画面の並べ替えはこれを出す。
    public var orderedEntries: [LauncherEntry] {
        LauncherEntry.ordered(entryOrder)
    }

    /// 検索窓に実際に並ぶもの（隠したものを除いて、決めた順に）
    public var visibleEntries: [LauncherEntry] {
        orderedEntries.filter { !hiddenFeatures.contains($0.key) }
    }

    public func isVisible(entry: LauncherEntry) -> Bool {
        !hiddenFeatures.contains(entry.key)
    }

    /// ⌘1〜⌘9。**並べた順に上から振る**。
    ///
    /// ⚠️ 番号を機能ごとに固定するのをやめた理由。
    /// 固定していると、作者が「コピー履歴」を1番上へ動かしても札は ⌘1 のままとは限らず、
    /// 「1番上なのに⌘3」という読めない画面になる。番号は見た目の順に従わせる。
    ///
    /// ⚠️ 9を超えたぶんには番号を振らない（⌘10 は押せないので、札を出すと嘘になる）。
    public func directNumber(for entry: LauncherEntry) -> Int? {
        guard let index = visibleEntries.firstIndex(of: entry), index < 9 else { return nil }
        return index + 1
    }

    public func entry(forDirectNumber number: Int) -> LauncherEntry? {
        let list = visibleEntries
        guard number >= 1, number <= min(list.count, 9) else { return nil }
        return list[number - 1]
    }

    /// 設定画面の▲▼。その行を抜いて、指定の位置に差し込む。
    ///
    /// ⚠️ 入れ替え（swap）ではなく**抜き差し（move）**にしてある。
    /// 1つ動かすぶんには同じ結果だが、2つ以上動かしたとき swap は
    /// 「動かしたものと、動かした先にいたもの」が入れ替わるだけで、
    /// 間にいたものは置いてけぼりになる。名前が move なのに距離によって
    /// 意味が変わるのは、あとで掴んで動かす操作を足したときに必ず事故になる。
    ///
    /// ⚠️ 動かした結果を**全部の名前**で書き戻す。差分では持たない。
    /// 順番は「どれが何番目か」が全部そろって初めて意味を持つので、
    /// 一部だけ持つと、書いていないものの位置が場面によって変わる。
    public mutating func moveEntry(_ key: String, by delta: Int) {
        var keys = orderedEntries.map(\.key)
        guard let index = keys.firstIndex(of: key) else { return }
        let target = index + delta
        guard target >= 0, target < keys.count else { return }
        let moved = keys.remove(at: index)
        keys.insert(moved, at: target)
        entryOrder = keys
    }

    /// 並べ替えを既定に戻す
    public mutating func resetEntryOrder() {
        entryOrder = []
    }

    /// 既定の順から動かしてあるか（設定画面に「戻す」を出すかの判断）
    public var hasCustomEntryOrder: Bool {
        orderedEntries.map(\.key) != LauncherEntry.allCases.map(\.key)
    }

    /// 機能の表示/非表示を切り替える。入口（すべて）は隠せない。
    public mutating func setVisible(_ key: String, _ visible: Bool) {
        guard key != Settings.alwaysVisible.rawValue else { return }
        if visible {
            hiddenFeatures.removeAll { $0 == key }
        } else if !hiddenFeatures.contains(key) {
            hiddenFeatures.append(key)
        }
    }

    // MARK: - ショートカットの一覧と重複

    /// 今割り当てている全ショートカットを「名前つき」で返す。
    /// 設定画面の重複チェックと、登録の失敗を人に説明するために使う。
    public var allShortcuts: [(name: String, shortcut: Shortcut)] {
        var list: [(String, Shortcut)] = [
            ("検索を開く", launcherShortcut),
            ("コピー履歴", clipboardShortcut),
            ("定型文", snippetShortcut),
            ("メモ", noteShortcut),
        ]
        list += windowBindings.map { ($0.layout.title, $0.shortcut) }
        list += displayBindings.map { ($0.step > 0 ? "次の画面へ移す" : "前の画面へ移す", $0.shortcut) }
        // ⚠️ アプリのキーもここに必ず混ぜる。
        // 混ぜ忘れると、⌃⌥S を定型文とアプリの両方に割り当てても設定画面は何も言わず、
        // 後から登録した方だけが黙って効かない（原因の分からない「効かないキー」になる）。
        list += appBindings.map { ($0.name, $0.shortcut) }
        // ⚠️ 「既定は未割り当て」のキーも必ず混ぜる。
        // 2026-08-05 に見つけた漏れ: 書式なし貼り付け・文字の変換・画面の文字読み取りが
        // この一覧に入っておらず、同じキーを別の機能と重ねても設定画面が何も言わなかった。
        // すぐ上に「混ぜ忘れると黙って効かない」と自分で書いてあるのに、増やすときに忘れていた。
        list += convertBindings.map { ($0.transform.title + "に変換", $0.shortcut) }
        if let pastePlainShortcut { list.append(("書式なしで貼り付け", pastePlainShortcut)) }
        if let captureTextShortcut { list.append(("画面の文字を読み取る", captureTextShortcut)) }
        return list.map { (name: $0.0, shortcut: $0.1) }
    }

    // MARK: - アプリのキー

    /// 1つのアプリに割り当て直す（既にあれば差し替え）。
    ///
    /// ⚠️ 同じアプリで2行にしない。2行あると設定画面では両方効きそうに見えるのに、
    /// 実際は先に登録した方だけが効く。どちらが「先」かは画面から読み取れない。
    public mutating func setAppShortcut(path: String, name: String, shortcut: Shortcut) {
        if let index = appBindings.firstIndex(where: { $0.path == path }) {
            appBindings[index].name = name
            appBindings[index].shortcut = shortcut
        } else {
            appBindings.append(AppBinding(path: path, name: name, shortcut: shortcut))
        }
    }

    public mutating func removeAppShortcut(path: String) {
        appBindings.removeAll { $0.path == path }
    }

    public func appShortcut(for path: String) -> Shortcut? {
        appBindings.first { $0.path == path }?.shortcut
    }

    /// アプリを選んだ直後に自動で振るキー（⌃⌥⌘1 から順に、空いているもの）。
    ///
    /// ⚠️ 選んだ時点で押せる状態にするための仕組み。
    /// 「アプリを選ぶ」と「キーを決める」を2段にすると、選んだだけで満足して
    /// キーを決めずに閉じ、あとで「設定したのに効かない」になる。
    ///
    /// ⚠️ 空きが無ければ `nil`。適当に埋めて重複させない
    /// （重なると先に登録した方だけが黙って効く＝原因が読み取れない）。
    public func suggestedAppShortcut() -> Shortcut? {
        let taken = Set(allShortcuts.map(\.shortcut))
        let modifiers = Shortcut.controlBit | Shortcut.optionBit | Shortcut.cmdBit
        for digit in KeyCode.digits {
            let candidate = Shortcut(keyCode: digit.code, carbonModifiers: modifiers, keyLabel: digit.label)
            if !taken.contains(candidate) { return candidate }
        }
        return nil
    }

    /// 空きが尽きたときに出す言葉。何をすれば足せるかまで書く。
    public static let appShortcutFullMessage =
        "⌃⌥⌘1〜0 が全部ふさがっています。使っていないアプリのキーを外すか、"
        + "すでにあるキーの枠を押して別の組み合わせに変えてください。"

    /// 2つ以上に割り当ててしまったショートカット。
    ///
    /// 重なっていると、先に登録した方だけが効いて後ろは黙って無視される。
    /// 「設定したのに効かない」の原因がこれなので、設定画面でその場で知らせる。
    public func conflicts() -> [(shortcut: Shortcut, names: [String])] {
        var byShortcut: [Shortcut: [String]] = [:]
        for entry in allShortcuts {
            byShortcut[entry.shortcut, default: []].append(entry.name)
        }
        return byShortcut
            .filter { $0.value.count > 1 }
            .map { (shortcut: $0.key, names: $0.value) }
            .sorted { $0.shortcut.displayString < $1.shortcut.displayString }
    }

    // MARK: 既定のショートカット
    //
    // Raycastを起動したまま使い比べる前提なので、Raycastの既定と重なりにくい組み合わせを選んでいる。
    // Raycastは ⌘Space（ランチャー）と ⌃⌥＋矢印（ウィンドウ操作）を既定で使うことが多いため、
    // ランチャーは ⌥Space、ウィンドウ操作は ⌃⌥⇧ を足した3修飾キーにしてある。
    // 取られていて登録に失敗したものはメニューバーに「×」で出るので、settings.json で変更できる。

    public static let defaultLauncher = Shortcut(keyCode: KeyCode.space, carbonModifiers: Shortcut.optionBit, keyLabel: "Space")
    public static let defaultClipboard = Shortcut(keyCode: KeyCode.v, carbonModifiers: Shortcut.controlBit | Shortcut.optionBit, keyLabel: "V")
    public static let defaultSnippet = Shortcut(keyCode: KeyCode.s, carbonModifiers: Shortcut.controlBit | Shortcut.optionBit, keyLabel: "S")
    public static let defaultNote = Shortcut(keyCode: KeyCode.n, carbonModifiers: Shortcut.controlBit | Shortcut.optionBit, keyLabel: "N")

    private static let winMods = Shortcut.controlBit | Shortcut.optionBit | Shortcut.shiftBit

    public static let defaultWindowBindings: [WindowBinding] = [
        WindowBinding(layout: .leftHalf, shortcut: Shortcut(keyCode: KeyCode.left, carbonModifiers: winMods, keyLabel: "←")),
        WindowBinding(layout: .rightHalf, shortcut: Shortcut(keyCode: KeyCode.right, carbonModifiers: winMods, keyLabel: "→")),
        WindowBinding(layout: .topHalf, shortcut: Shortcut(keyCode: KeyCode.up, carbonModifiers: winMods, keyLabel: "↑")),
        WindowBinding(layout: .bottomHalf, shortcut: Shortcut(keyCode: KeyCode.down, carbonModifiers: winMods, keyLabel: "↓")),
        WindowBinding(layout: .maximize, shortcut: Shortcut(keyCode: KeyCode.ret, carbonModifiers: winMods, keyLabel: "Return")),
        WindowBinding(layout: .center, shortcut: Shortcut(keyCode: KeyCode.c, carbonModifiers: winMods, keyLabel: "C")),
        WindowBinding(layout: .topLeft, shortcut: Shortcut(keyCode: KeyCode.one, carbonModifiers: winMods, keyLabel: "1")),
        WindowBinding(layout: .topRight, shortcut: Shortcut(keyCode: KeyCode.two, carbonModifiers: winMods, keyLabel: "2")),
        WindowBinding(layout: .bottomLeft, shortcut: Shortcut(keyCode: KeyCode.three, carbonModifiers: winMods, keyLabel: "3")),
        WindowBinding(layout: .bottomRight, shortcut: Shortcut(keyCode: KeyCode.four, carbonModifiers: winMods, keyLabel: "4")),
    ]

    public static let defaultDisplayBindings: [DisplayBinding] = [
        DisplayBinding(step: 1, shortcut: Shortcut(keyCode: KeyCode.right, carbonModifiers: Shortcut.controlBit | Shortcut.optionBit | Shortcut.cmdBit, keyLabel: "→")),
        DisplayBinding(step: -1, shortcut: Shortcut(keyCode: KeyCode.left, carbonModifiers: Shortcut.controlBit | Shortcut.optionBit | Shortcut.cmdBit, keyLabel: "←")),
    ]
}
