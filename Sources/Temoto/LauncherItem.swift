import AppKit
import TemotoCore

/// ランチャーの1行
struct LauncherItem {
    enum Kind {
        case app(path: String)
        case command(CustomCommand)
        case quicklink(Quicklink)
        case snippet(Snippet)
        case clip(ClipItem)
        /// Spotlight が見つけたファイル
        case file(FileHit)
        case layout(WindowLayout)
        /// 「コピー履歴を見る」のような、窓を閉じずに行き先を変えるだけの行
        case section(LauncherMode)
        /// メモを開く行（メモだけは一覧ではなく書く画面なので別扱い）
        case openNote
        /// 打った文字がそのまま問いに見えるときの答え（計算・和暦・桁）
        case answer(QuickAnswer.Answer)
        /// 一覧の中の見出し（「行き先」「コマンド」）。選べない・押せない
        case header
        /// 同じ書き出しのコマンドを畳んだ1行（Enterで中に入る）
        case commandGroup(title: String, commands: [CustomCommand])
        /// 保存したファイル検索の条件（Enterで検索欄に入れて実行）
        case savedSearch(SavedFileSearch)
        /// Mac そのものの操作・システム設定の1画面
        case systemPlace(SystemPlace)
        /// 打った文字がそのまま行き先（URL・フォルダ）
        case openTarget(QuickOpen.Target)
        /// 見つからなかったときの逃げ道（ファイルとして探す / Webで検索）
        case escapeToFiles(String)
        case escapeToWeb(String)
        /// 書き置き（メモ）の1枚
        case note(Note)
        /// 画面を撮って、その中の文字をコピーする
        case captureText
        /// 画面を撮る（範囲・全体・ウィンドウ）
        case shot(CaptureShot)
        /// 計算の1行（打った式と答え）
        case calc(CalcLine.Line)
    }

    let id: String
    let title: String
    let subtitle: String
    /// 右端に出す種類の札
    let kindLabel: String
    let kind: Kind
    /// {query} を含む＝実行前にもう一段入力を待つ
    let needsQuery: Bool
    /// 2ペイン（一覧＋プレビュー）の狭い一覧に出す短い副題。
    /// ⚠️ 大きさや容量はここに入れない。詳しい話は右の情報欄が引き受けるので、
    /// 狭い行で「テモト・38分前・1446×950・309 KB」と全部並べると何も読めなくなる。
    var compactSubtitle: String? = nil
    /// 2ペインの一覧に出す札。ピン留めだけ残し、「画像」「履歴」の札は消す
    /// （左のアイコンと右のプレビューで種類は分かる。狭い行では札が題名を圧迫する）。
    var compactKindLabel: String? = nil
    /// 副題を行の中に出すか。
    /// 行き先の行だけ false（説明は選んだときに下の帯へ出す。
    /// 全行に説明を並べると入口が文字の壁になる＝2026-07-30「汚い」の一因）。
    var subtitleInRow: Bool = true

    var image: NSImage? {
        switch kind {
        case .app(let path): return IconCache.appIcon(path)
        case .command(let c): return IconCache.symbol(LauncherItem.commandSymbol(c))
        case .quicklink: return IconCache.symbol("link")
        case .snippet: return IconCache.symbol("text.quote")
        case .clip(let clip):
            switch clip.kind {
            case .text: return IconCache.symbol("doc.on.clipboard")
            case .image:
                // 小さな絵が出せないとき（鍵を作り直した後など）は絵のしるしで代用する
                return ClipThumbnailCache.image(for: clip.id) ?? IconCache.symbol("photo")
            case .file:
                return clip.filePaths.first.flatMap { IconCache.fileIcon($0) }
                    ?? IconCache.symbol("doc")
            }
        case .file(let hit): return IconCache.fileIcon(hit.path) ?? IconCache.symbol("doc")
        case .layout: return IconCache.symbol("rectangle.split.2x1")
        case .section(let mode): return IconCache.symbol(mode.symbolName)
        case .openNote: return IconCache.symbol("note.text")
        case .answer: return IconCache.symbol("equal.square")
        case .header: return nil
        // 畳んだ行は中身と同じしるし（中がフォルダならフォルダ）。開ける印は右の札が担う
        case .commandGroup(_, let commands):
            return IconCache.symbol(commands.first.map(LauncherItem.commandSymbol) ?? "folder")
        case .savedSearch: return IconCache.symbol("star")
        case .systemPlace(let place): return IconCache.symbol(place.symbol)
        case .openTarget(let target):
            if case .path(let path) = target { return IconCache.fileIcon(path) ?? IconCache.symbol("folder") }
            return IconCache.symbol("safari")
        case .escapeToFiles: return IconCache.symbol("doc.text.magnifyingglass")
        case .escapeToWeb: return IconCache.symbol("globe")
        case .note: return IconCache.symbol("note.text")
        case .captureText: return IconCache.symbol("text.viewfinder")
        case .shot(let shot): return IconCache.symbol(shot.symbol)
        case .calc: return IconCache.symbol("equal.square")
        }
    }

    private static func commandSymbol(_ command: CustomCommand) -> String {
        switch command.action {
        case .openPath: return "folder"
        case .openURL: return "link"
        case .runScript: return "terminal"
        }
    }

    /// 行き先の持ち色（システム設定式＝色のタイルに白い記号）。行き先の行だけが持つ
    var tint: ModeTint? {
        switch kind {
        case .section(let mode): return ModeTint.tint(for: mode)
        case .openNote: return ModeTint.note
        case .note: return ModeTint.note
        // 行き先として並ぶときも、打って探して出たときも同じ色にする（同じものに見せる）
        case .captureText: return ModeTint.captureText
        default: return nil
        }
    }

    /// 見出しの行か（選べない・押せない）
    var isHeader: Bool {
        if case .header = kind { return true }
        return false
    }

    /// 絵やファイルの行だけ、左のアイコンを大きく出す（中身が見えないと選べないため）
    var usesLargeIcon: Bool {
        if case .clip(let clip) = kind { return clip.kind != .text }
        if case .file = kind { return true }
        return false
    }

    /// この行がコピーした絵かどうか。絵の縁の描き方だけ、ここで別扱いにする。
    /// ⚠️ 行の高さはもう変えない（2026-07-30）。絵の行だけ80ptに高くしてみたが、
    /// それでも画面写真の中身は読めなかった。見分けは右のプレビューに任せる。
    var isClipImage: Bool {
        if case .clip(let clip) = kind { return clip.kind == .image }
        return false
    }

    /// 左に置くアイコンの一辺
    var iconEdge: CGFloat {
        usesLargeIcon ? Theme.Row.fileIcon : Theme.Row.standardIcon
    }

    /// 絵の縦横比（横 ÷ 縦）。枠にぴったり合わせて縁を描くために要る。
    ///
    /// ⚠️ 正方形の枠に縦長の絵を入れると、絵の左右に余白ができる。
    /// そこに縁を描くと「絵より大きい額縁」になって、絵が浮いて見える。
    /// 実際に描かれる寸法を先に計算して、縁をその形に合わせる。
    var imageAspect: CGFloat? {
        guard case .clip(let clip) = kind, clip.kind == .image, let info = clip.image else { return nil }
        guard info.pixelWidth > 0, info.pixelHeight > 0 else { return nil }
        return CGFloat(info.pixelWidth) / CGFloat(info.pixelHeight)
    }

    /// 題名以外で検索に当てにいく文字（絵から読み取った本文など）
    var searchAliases: [String] {
        if case .clip(let clip) = kind { return clip.searchAliases }
        // 定型文は読みがなと本文でも当てる（読みがなは「検索で当てるための欄」なのに
        // 見ていなかった＝2026-08-02「スニペット機能がうまく機能していない」の正体）
        if case .snippet(let snippet) = kind { return SnippetSearch.aliases(for: snippet) }
        // ⚠️ タグは「探すためのもの」。題名に無い言葉で引けることがタグの値打ちなので、
        // 検索の当て先に必ず入れる（入れないと、付けたのに何も変わらない飾りになる）
        if case .quicklink(let link) = kind { return link.tags }
        // Mac の操作は呼び方が人によって違う（音／おと／oto／ボリューム）ので、言い換えを全部渡す
        if case .systemPlace(let place) = kind { return place.aliases }
        // 行き先・メモ・道具は「別の呼び方」でも当てる。
        // 2026-08-05 作者「そもそもスニペットって何？？」＝表示は日本語のまま、
        // 呼び方だけ人に合わせる（`snippet` でも `すにぺっと` でも定型文に当たる）。
        // ⚠️ 言葉は Core（LauncherEntry.aliases）に1か所だけ置く。ここに書き写すと必ず食い違う。
        if case .section(let mode) = kind { return mode.aliases }
        if case .openNote = kind { return LauncherEntry.note.aliases }
        if case .captureText = kind { return LauncherEntry.captureText.aliases }
        if case .shot(let shot) = kind { return shot.aliases }
        // 書き置きは中身でも当てる（題名は本文の1行目なので、2行目以降が拾えなくなる）
        if case .note(let note) = kind { return [String(note.body.prefix(400))] }
        return []
    }

    /// アイコンが SF Symbols（＝線で描いた記号）かどうか。
    ///
    /// ⚠️ これを見分けたい理由は、記号の下にだけ色の四角を敷くため。
    /// アプリのアイコンや写真の下に四角を敷くと、元の絵が持っている影や角丸と
    /// ぶつかって「四角の中に四角」に見え、かえって汚くなる。
    ///
    /// 記号は線が細くて小さいので、逆に何も敷かないと一覧の中で埋もれる。
    var usesSymbolIcon: Bool {
        switch kind {
        case .app: return false
        case .file: return false
        case .header: return false
        case .clip(let clip):
            switch clip.kind {
            // 小さな絵が出せているなら本物の絵。出せないときだけ記号で代用している
            case .image: return ClipThumbnailCache.image(for: clip.id) == nil
            // ファイルのアイコンが取れれば本物。取れなければ記号
            case .file: return clip.filePaths.first.flatMap { IconCache.fileIcon($0) } == nil
            case .text: return true
            }
        case .command, .quicklink, .snippet, .layout, .section, .openNote, .answer,
             .commandGroup, .savedSearch, .systemPlace, .escapeToFiles, .escapeToWeb, .note,
             .captureText, .shot, .calc:
            return true
        // 打った文字がそのままの行き先。フォルダなら本物のアイコンが取れる
        case .openTarget(let target):
            if case .path(let path) = target { return IconCache.fileIcon(path) == nil }
            return true
        }
    }

    /// 打った文字がそのまま問いに見えるときの答え。
    ///
    /// ⚠️ この行だけは**あいまい検索を通さない**。
    /// `1234567*1.1` に「1234567*1.1」という題名を当てても点は付かないし、
    /// そもそも探しものではないので順位を競わせる相手がいない。
    /// 呼ぶ側が並べ替えのあとで先頭に差し込む。
    static func answer(_ answer: QuickAnswer.Answer) -> LauncherItem {
        LauncherItem(
            id: "answer:\(answer.value)",
            title: answer.display,
            subtitle: answer.detail,
            kindLabel: "答え",
            kind: .answer(answer),
            needsQuery: false
        )
    }

    /// 行き先への入口。窓は閉じずに中身だけ入れ替える。
    ///
    /// ⚠️ 札の番号は呼ぶ側から渡してもらう。ここで決めない。
    /// 番号は並べ替えた順で決まるので、設定を知らないこの層では正しい数字を出せない。
    /// 前は `mode.directNumber` を直に読んでいて、それが並べ替えを入れられなかった理由。
    static func entry(_ entry: LauncherEntry, number: Int?) -> LauncherItem {
        // ⚠️ ここは switch で書く。前は `entry.mode.map { .section($0) } ?? .openNote` だった＝
        // **モードでない行き先は何であれメモになる**作りで、行き先を3つ目に増やした瞬間、
        // 「画面の文字を読み取る」を押すとメモが開く、という黙った間違いになるところだった
        // （2026-08-05 追加時に発見。列挙を増やしたらコンパイラに漏れを教えてもらう形にする）。
        let kind: LauncherItem.Kind
        switch entry {
        case .mode(let mode): kind = .section(mode)
        case .note: kind = .openNote
        case .captureText: kind = .captureText
        }
        return LauncherItem(
            id: "section:\(entry.key)",
            title: entry.title,
            subtitle: entry.summary,
            kindLabel: number.map { "⌘\($0)" } ?? "",
            kind: kind,
            needsQuery: false,
            // 説明は行に並べない。選んだときに下の帯へ出す（入口を文字の壁にしない）
            subtitleInRow: false
        )
    }

    /// 一覧の中の見出し。選べない・押せない
    static func header(_ title: String) -> LauncherItem {
        LauncherItem(
            id: "header:\(title)",
            title: title,
            subtitle: "",
            kindLabel: "",
            kind: .header,
            needsQuery: false
        )
    }

    /// 同じ書き出しのコマンドを畳んだ1行
    static func group(title: String, commands: [CustomCommand]) -> LauncherItem {
        LauncherItem(
            id: "group:\(title)",
            title: title,
            subtitle: CommandGrouping.memberSummary(commands),
            kindLabel: "\(commands.count)件",
            kind: .commandGroup(title: title, commands: commands),
            needsQuery: false
        )
    }

    /// 保存したファイル検索の条件
    static func from(_ saved: SavedFileSearch, searchesContent: Bool) -> LauncherItem {
        let summary = FileQuery.parse(saved.query).summary(searchesContent: searchesContent)
        return LauncherItem(
            id: "saved:\(saved.name)",
            title: saved.name,
            subtitle: summary.isEmpty ? saved.query : summary,
            kindLabel: "保存済み",
            kind: .savedSearch(saved),
            needsQuery: false
        )
    }

    static func from(_ command: CustomCommand) -> LauncherItem {
        LauncherItem(
            id: "command:\(command.id.uuidString)",
            title: command.title,
            subtitle: command.subtitle ?? command.action.kindLabel,
            kindLabel: "コマンド",
            kind: .command(command),
            needsQuery: command.action.needsQuery
        )
    }

    /// 畳んだ中の1件（短い題名で出す）。
    /// badge には畳みの名前を渡す（検索で平らに出たとき「ABC」がフォルダなのか
    /// 作業ログなのか、右の札で見分けるため）。
    static func from(_ command: CustomCommand, displayTitle: String, badge: String) -> LauncherItem {
        LauncherItem(
            id: "command:\(command.id.uuidString)",
            title: displayTitle,
            subtitle: command.subtitle ?? command.action.kindLabel,
            kindLabel: badge,
            kind: .command(command),
            needsQuery: command.action.needsQuery
        )
    }

    /// 計算の1行。⚠️ 題名は**答え**（打った式ではない）。
    /// 一覧を見返すときに知りたいのは答えで、式は思い出すための添え物
    static func from(_ line: CalcLine.Line) -> LauncherItem {
        LauncherItem(
            id: "calc:\(line.input)",
            title: line.display,
            subtitle: line.detail.isEmpty ? line.input : "\(line.input)　=　\(line.detail)",
            kindLabel: "",
            kind: .calc(line),
            needsQuery: false
        )
    }

    /// 画面を撮る1行
    static func from(_ shot: CaptureShot) -> LauncherItem {
        LauncherItem(
            id: shot.id,
            title: shot.title,
            subtitle: shot.subtitle,
            kindLabel: "道具",
            kind: .shot(shot),
            needsQuery: false
        )
    }

    /// Mac そのものの操作・システム設定の1画面
    static func from(_ place: SystemPlace) -> LauncherItem {
        LauncherItem(
            id: place.id,
            title: place.title,
            subtitle: place.subtitle,
            kindLabel: "Mac",
            kind: .systemPlace(place),
            needsQuery: false
        )
    }

    /// 書き置き（メモ）の1枚
    static func from(_ note: Note) -> LauncherItem {
        LauncherItem(
            id: "note:\(note.id.uuidString)",
            title: NoteText.title(for: note.body),
            // 副題は2行目以降のさわり（題名は1行目なので、同じ文字を2度出さない）
            subtitle: note.body.split(separator: "\n", omittingEmptySubsequences: true)
                .dropFirst().first.map { String($0.prefix(60)) } ?? "",
            kindLabel: "メモ",
            kind: .note(note),
            needsQuery: false
        )
    }

    /// 打った文字がそのまま行き先（URL・フォルダ）
    static func openTarget(_ target: QuickOpen.Target) -> LauncherItem {
        switch target {
        case .url(let url):
            return LauncherItem(id: "open:url", title: url, subtitle: "このリンクを開く",
                                kindLabel: "開く", kind: .openTarget(target), needsQuery: false)
        case .path(let path):
            return LauncherItem(id: "open:path", title: (path as NSString).lastPathComponent,
                                subtitle: path, kindLabel: "開く",
                                kind: .openTarget(target), needsQuery: false)
        }
    }

    /// 逃げ道。**当たらなかったときに行き止まりを作らない**ための2行
    static func escapeToFiles(_ query: String) -> LauncherItem {
        LauncherItem(id: "escape:files", title: "「\(query)」をファイルとして探す",
                     subtitle: "Mac の中の書類を探しに行く", kindLabel: "探す",
                     kind: .escapeToFiles(query), needsQuery: false)
    }

    static func escapeToWeb(_ query: String) -> LauncherItem {
        LauncherItem(id: "escape:web", title: "「\(query)」を Web で検索",
                     subtitle: "ブラウザを開いて調べる", kindLabel: "探す",
                     kind: .escapeToWeb(query), needsQuery: false)
    }

    static func from(_ link: Quicklink) -> LauncherItem {
        LauncherItem(
            id: "link:\(link.id.uuidString)",
            title: link.title,
            subtitle: link.url,
            // ⚠️ 右端の札を「リンク」からタグに差し替える。
            // 行き先が「リンク」なのは見れば分かるので、同じ言葉を全行に並べても何も伝えない。
            // タグを出せば、その1行が何のリンクなのかが分かる
            kindLabel: link.badgeLabel,
            kind: .quicklink(link),
            needsQuery: link.needsQuery
        )
    }

    static func from(_ snippet: Snippet) -> LauncherItem {
        LauncherItem(
            id: "snippet:\(snippet.id.uuidString)",
            title: snippet.title,
            subtitle: snippet.keyword.isEmpty ? snippet.body.prefix(80).description : "\(snippet.keyword) — \(snippet.body.prefix(60))",
            kindLabel: "定型文",
            kind: .snippet(snippet),
            needsQuery: snippet.body.contains("{query}"),
            // 2ペインでは本文の走り書きを副題に出さない（全文が右に出るので二重になる）
            compactSubtitle: snippet.keyword,
            compactKindLabel: ""
        )
    }

    static func from(_ clip: ClipItem) -> LauncherItem {
        // 「どこから・いつ・どのくらい（どこに）」を中黒でつなぐ。
        // detailLine は画像なら大きさ、ファイルなら置き場所のフォルダ（絶対パスは出さない）。
        let parts = [clip.sourceAppName, ClipFormatter.relative(clip.copiedAt), clip.detailLine]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
        // 狭い一覧用は「どこから・いつ」だけ。大きさ・容量・場所は右の情報欄に出る
        let shortParts = [clip.sourceAppName, ClipFormatter.relative(clip.copiedAt)]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
        return LauncherItem(
            id: "clip:\(clip.id.uuidString)",
            title: clip.previewLine,
            subtitle: parts.joined(separator: "・"),
            kindLabel: clip.pinned ? "ピン留め" : clip.kindLabel,
            kind: .clip(clip),
            needsQuery: false,
            compactSubtitle: shortParts.joined(separator: "・"),
            compactKindLabel: clip.pinned ? "ピン留め" : ""
        )
    }

    /// Spotlight が見つけた1件を行に変える。
    /// ⚠️ 副題に絶対パスは出さない（ホーム以下は ~ に畳む）。画面を人に見せたときに漏れるため。
    static func from(_ hit: FileHit, home: String, now: Date = Date()) -> LauncherItem {
        LauncherItem(
            id: "file:\(hit.path)",
            title: hit.name,
            subtitle: hit.subtitle(home: home, now: now),
            kindLabel: hit.isFolder ? "フォルダ" : FileTypeLabel.of(hit.contentType),
            kind: .file(hit),
            needsQuery: false
        )
    }

    static func from(_ layout: WindowLayout) -> LauncherItem {
        LauncherItem(
            id: "layout:\(layout.rawValue)",
            title: "ウィンドウ: \(layout.title)",
            subtitle: "今いちばん前のウィンドウに適用する",
            kindLabel: "ウィンドウ",
            kind: .layout(layout),
            needsQuery: false
        )
    }
}

enum IconCache {
    private static var apps: [String: NSImage] = [:]
    private static var files: [String: NSImage] = [:]
    private static var symbols: [String: NSImage] = [:]

    static func appIcon(_ path: String) -> NSImage? {
        if let cached = apps[path] { return cached }
        let icon = NSWorkspace.shared.icon(forFile: path)
        icon.size = NSSize(width: 26, height: 26)
        apps[path] = icon
        return icon
    }

    /// ファイルの見た目のしるし。実在しなくても種類なりの絵が返るので、
    /// 元が消えた履歴でも行が空にはならない（貼れないことは貼るときに伝える）。
    static func fileIcon(_ path: String) -> NSImage? {
        if let cached = files[path] { return cached }
        let icon = NSWorkspace.shared.icon(forFile: path)
        icon.size = NSSize(width: 36, height: 36)
        files[path] = icon
        return icon
    }

    static func symbol(_ name: String) -> NSImage? {
        if let cached = symbols[name] { return cached }
        guard let image = NSImage(systemSymbolName: name, accessibilityDescription: nil) else { return nil }
        // ⚠️ medium にしてある。regular の細い線は、透けたすりガラスの上で背後に食われる
        // （2026-07-30 作者「アイコンやその他視認性をあげて」）
        let configured = image.withSymbolConfiguration(.init(pointSize: 18, weight: .medium)) ?? image
        symbols[name] = configured
        return configured
    }
}

/// 履歴の絵（小さい方）の置き場。
///
/// 絵は暗号化して1件1ファイルで置いてあるので、一覧を描くたびに開くと重い。
/// 一度開いたものはここに持っておく。開けなかったものも覚えておき、二度と開きに行かない。
///
/// Store（AppKit を知らない土台）から NSImage を返させないための橋渡しでもある。
enum ClipThumbnailCache {

    /// 起動時に Store の loadClipThumbnail を差し込む
    static var loader: ((UUID) -> Data?)?

    private static var images: [UUID: NSImage] = [:]
    private static var missing: Set<UUID> = []

    static func image(for id: UUID) -> NSImage? {
        if let cached = images[id] { return cached }
        if missing.contains(id) { return nil }
        guard let data = loader?(id), let image = NSImage(data: data) else {
            missing.insert(id)
            return nil
        }
        images[id] = image
        return image
    }

    static func forget(_ id: UUID) {
        images[id] = nil
        missing.remove(id)
    }

    /// 鍵が変わったとき・履歴を空にしたときに呼ぶ
    static func forgetAll() {
        images.removeAll()
        missing.removeAll()
    }
}

/// インストール済みアプリの一覧。
///
/// ⚠️ 見つけたものを全部出さない（2026-07-28 作者の指摘で変更）。
/// 実機で211件が出ていて、その大半が `/System/Library/CoreServices` の裏方だった。
/// どれを出すかの決め方は `TemotoCore/AppVisibility.swift` に置いてある（そちらは検証できる）。
enum AppCatalog {

    /// 見つけた全部（隠すものも含む）。設定画面はこれを使う。
    ///
    /// ディスクを読むので呼ぶ回数を絞ること。起動時と「アプリを数え直す」のときだけ。
    static func scanAll(extraFolders: [String] = []) -> [AppRecord] {
        let fm = FileManager.default
        var seenPaths = Set<String>()
        var records: [AppRecord] = []

        func add(path: String, entry: String, isOwn: Bool) {
            guard seenPaths.insert(path).inserted else { return }
            let name = fm.displayName(atPath: path)
            records.append(AppRecord(
                path: path,
                name: name.isEmpty ? String(entry.dropLast(4)) : name,
                // 自分で置き場所を足したフォルダの中身は「自分のアプリ」。
                // 裏方かどうかの判定（LSUIElement）に関わらず出す
                // ＝わざわざ足した人の意図を、こちらの判定で握りつぶさない
                isHelper: isOwn ? false : readIsHelper(appPath: path)
            ))
        }

        for directory in AppVisibility.searchDirectories(home: NSHomeDirectory()) {
            guard let entries = try? fm.contentsOfDirectory(atPath: directory) else { continue }
            for entry in entries where entry.hasSuffix(".app") {
                add(path: directory + "/" + entry, entry: entry, isOwn: false)
            }
        }

        // 自分で足したフォルダは、中まで潜って探す（規則は TemotoCore.AppFolderScan）
        for folder in extraFolders {
            var found = 0
            var stack: [(path: String, depth: Int)] = [(folder, 0)]
            while let current = stack.popLast(), found < AppFolderScan.maxApps {
                guard let entries = try? fm.contentsOfDirectory(atPath: current.path) else { continue }
                for entry in entries {
                    if AppFolderScan.isApp(name: entry) {
                        add(path: current.path + "/" + entry, entry: entry, isOwn: true)
                        found += 1
                        continue      // ⚠️ .app の中へは入らない（中は裏方だらけ）
                    }
                    guard AppFolderScan.shouldDescend(name: entry, depth: current.depth) else { continue }
                    var isDirectory: ObjCBool = false
                    let child = current.path + "/" + entry
                    if fm.fileExists(atPath: child, isDirectory: &isDirectory), isDirectory.boolValue {
                        stack.append((child, current.depth + 1))
                    }
                }
            }
        }
        return records.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// 検索窓に出す分だけを行に変える
    ///
    /// ⚠️ キーを割り当てたアプリは、右の札に「アプリ」ではなくそのキーを出す。
    /// 設定画面を開かないと自分が何を割り当てたか思い出せない機能は、
    /// 決めたその日しか使われない。探しに来たついでに目に入る場所に書く。
    static func items(from records: [AppRecord], settings: Settings) -> [LauncherItem] {
        records
            .filter { settings.isAppVisible($0) }
            .map { record in
                LauncherItem(
                    id: "app:\(record.path)",
                    title: record.name,
                    subtitle: record.placeLabel,
                    kindLabel: settings.appShortcut(for: record.path)?.displayString ?? "アプリ",
                    kind: .app(path: record.path),
                    needsQuery: false
                )
            }
    }

    /// Info.plist を読んで裏方かどうかを見る。
    /// 読めなければ「裏方ではない」とする（読めないことを理由に消すと、
    /// 作者が入れたアプリが黙って出てこなくなる方が困る）。
    private static func readIsHelper(appPath: String) -> Bool {
        let plistPath = appPath + "/Contents/Info.plist"
        guard let dict = NSDictionary(contentsOfFile: plistPath) as? [String: Any] else { return false }
        return AppVisibility.isHelper(infoPlist: dict)
    }
}

/// 選んだものを実際に動かす。
enum ActionRunner {

    static func open(appPath: String) {
        let url = URL(fileURLWithPath: appPath)
        let configuration = NSWorkspace.OpenConfiguration()
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, error in
            if let error {
                DispatchQueue.main.async {
                    Toast.show("開けませんでした: \(error.localizedDescription)", isError: true)
                }
            }
        }
    }

    /// 画面の一部を撮って、その中の文字をコピーする。
    ///
    /// 2026-08-05 作者「キャプチャーを取ったらそれをテキストにする仕組みも追加できないかな？？」
    ///
    /// ⚠️ 撮るのは macOS の標準の道具（`screencapture -i`）に任せる。
    /// 自前で範囲選択の窓を描くと、複数画面・拡大表示・スペースの扱いを全部自分で持つことになる。
    /// 標準の道具なら、人が普段 ⇧⌘4 でやっている操作とまったく同じ見え方になる。
    ///
    /// ⚠️ 撮った絵はいったんクリップボードに載る（`-c`）。そのあと文字で上書きする。
    /// 絵のほうもコピー履歴に残るので、読み取りが外れても撮り直しにはならない。
    static func captureTextToClipboard() {
        capture(CaptureShot(id: "shot.text", title: "", subtitle: "", symbol: "",
                            aliases: [], target: .region, output: .text))
    }

    /// 画面を撮る（範囲・全体・ウィンドウ／絵のまま・文字にする）。
    ///
    /// ⚠️ 撮ったものは必ずクリップボードに載る。載れば ClipboardWatcher が拾って
    /// 履歴に残し、絵なら中の文字まで読む。**撮る側は「載せる」だけでよい**
    /// （履歴に入れる処理をここに書くと、同じ仕事が2か所になる）。
    static func capture(_ shot: CaptureShot) {
        let before = NSPasteboard.general.changeCount
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        task.arguments = shot.arguments
        // ⚠️ 標準エラーを受け取る理由。
        // 「撮るのをやめた（esc）」と「許可が無くて撮れない」は、終了コードがどちらも同じで
        // 見分けが付かない。実測（2026-08-06）では許可が無いときだけ
        // `could not create image from rect` が出る。**黙って何も起きないのが一番困る**ので、
        // ここを読んで、失敗のときだけ理由を伝える。
        let errorPipe = Pipe()
        task.standardError = errorPipe
        task.terminationHandler = { _ in
            let message = String(data: errorPipe.fileHandleForReading.readDataToEndOfFile(),
                                 encoding: .utf8) ?? ""
            DispatchQueue.main.async {
                finishCapture(shot, pasteboardBefore: before, stderr: message)
            }
        }
        do {
            try task.run()
        } catch {
            Toast.show("画面を撮れませんでした: \(error.localizedDescription)", isError: true)
        }
    }

    private static func finishCapture(_ shot: CaptureShot, pasteboardBefore: Int, stderr: String) {
        let board = NSPasteboard.general
        // ⚠️ 撮るのをやめた（esc）ときはクリップボードが変わらない。
        // 中身の有無ではなく**変わったかどうか**で見る（前に撮った絵が残っていると
        // 「やめたのに成功した」と誤判定するため）
        guard board.changeCount != pasteboardBefore,
              let image = board.data(forType: .tiff) ?? board.data(forType: .png) else {
            // 何か言ってきたら、それは取り消しではなく失敗。理由と行き先を伝える
            if !stderr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Toast.show("画面を撮れませんでした。システム設定 → プライバシーとセキュリティ → 画面収録 で"
                           + "テモトを許可し、テモトを起動しなおしてください", isError: true)
            }
            // 何も言ってこなければ、自分でやめた＝黙って終わる
            return
        }

        guard shot.output == .text else {
            Toast.show("撮りました。⌘V で貼れます（コピー履歴にも残ります）")
            return
        }

        Toast.show("文字を読んでいます…")
        ImageTextReader.readInBackground(png: image) { text in
            DispatchQueue.main.async {
                let trimmed = (text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else {
                    Toast.show("文字は見つかりませんでした（絵はコピーしてあります）", isError: true)
                    return
                }
                board.clearContents()
                board.setString(trimmed, forType: .string)
                let head = trimmed.replacingOccurrences(of: "\n", with: " ").prefix(24)
                Toast.show("文字をコピーしました: \(head)\(trimmed.count > 24 ? "…" : "")")
            }
        }
    }


    /// Mac そのものの操作。
    ///
    /// ⚠️ ロックは「スクリーンセーバを出す」で実現する。
    /// macOS には公開された「今すぐロック」の呼び出しが無く、
    /// スクリーンセーバは（システム設定で「スリープ後すぐパスワードを要求」にしていれば）
    /// そのままロックになる。人が普段やっている操作と同じ道を通る。
    static func runSystemPlace(_ place: SystemPlace) {
        switch place.action {
        case .settingsPane:
            guard let text = place.settingsURL, let url = URL(string: text) else { return }
            NSWorkspace.shared.open(url)
        case .lockScreen:
            lockScreen()
        case .sleep:
            // ⚠️ シェルは通さない。引数の配列でそのまま渡す（打った文字が混ざる余地を作らない）
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
            task.arguments = ["sleepnow"]
            do {
                try task.run()
            } catch {
                Toast.show("スリープできませんでした: \(error.localizedDescription)", isError: true)
            }
        }
    }

    /// 画面をロックする。
    ///
    /// ⚠️ **スクリーンセーバを出すだけではロックにならない。**
    /// 2026-08-06 実測: このMacの `sysadminctl -screenLock status` は
    /// 「screenLock delay is 300 seconds」＝スクリーンセーバが出てから
    /// **5分間はパスワードを聞かれない**。席を立つために押した人にとっては嘘になる。
    ///
    /// ⚠️ 「今すぐロックする」公開APIは macOS に無い（知られている手段は非公開API）。
    /// そこで、人が普段使っている macOS 標準のロックのキー **⌃⌘Q** をそのまま送る。
    /// これは Apple メニューの「画面をロック」と同じ道なので、遅延の設定に関係なく即座にロックされる。
    ///
    /// ⚠️ キーを送るには「アクセシビリティ」の許可が要る。無いときは黙って失敗せず、
    /// スクリーンセーバに切り替えたうえで**ロックされないかもしれないこと**を伝える。
    private static func lockScreen() {
        if AXWindow.isTrusted(prompt: false) {
            let source = CGEventSource(stateID: .combinedSessionState)
            // 12 = Q
            if let down = CGEvent(keyboardEventSource: source, virtualKey: 12, keyDown: true),
               let up = CGEvent(keyboardEventSource: source, virtualKey: 12, keyDown: false) {
                down.flags = [.maskCommand, .maskControl]
                up.flags = [.maskCommand, .maskControl]
                down.post(tap: .cghidEventTap)
                up.post(tap: .cghidEventTap)
                return
            }
        }
        // 許可が無いときの逃げ道。スクリーンセーバは出せるが、ロックされるとは限らない
        let engine = URL(fileURLWithPath: "/System/Library/CoreServices/ScreenSaverEngine.app")
        NSWorkspace.shared.openApplication(at: engine, configuration: NSWorkspace.OpenConfiguration()) { _, error in
            DispatchQueue.main.async {
                if let error {
                    Toast.show("ロックできませんでした: \(error.localizedDescription)", isError: true)
                } else {
                    Toast.show("スクリーンセーバを出しました。すぐロックするにはアクセシビリティの許可が要ります"
                               + "（システム設定 → ロック画面 の「パスワードを要求」も確認してください）", isError: true)
                }
            }
        }
    }

    static func run(_ action: CommandAction, query: String) {
        switch action.resolved(query: query) {
        case .openPath(let path): openPath(path)
        case .openURL(let url): openURL(url)
        case .runScript(let path, let arguments): runScript(path: path, arguments: arguments)
        }
    }

    static func openPath(_ path: String) {
        let fm = FileManager.default
        if fm.fileExists(atPath: path) {
            NSWorkspace.shared.open(URL(fileURLWithPath: path))
            return
        }

        // 「今日の日次作業ログ」のように、その日にまだ作られていないファイルがある。
        // 親フォルダが実在するテキストファイルに限って作ってから開く（既存を上書きすることはない）。
        let url = URL(fileURLWithPath: path)
        let parent = url.deletingLastPathComponent().path
        let isTextFile = ["md", "txt"].contains(url.pathExtension.lowercased())
        guard isTextFile, fm.fileExists(atPath: parent) else {
            Toast.show("見つかりません: \(url.lastPathComponent)", isError: true)
            return
        }
        guard fm.createFile(atPath: path, contents: Data(), attributes: nil) else {
            Toast.show("作れませんでした: \(url.lastPathComponent)", isError: true)
            return
        }
        NSWorkspace.shared.open(url)
        Toast.show("新しく作りました: \(url.lastPathComponent)")
    }

    /// Finder で場所を開いて、そのファイルを選んだ状態にする。
    /// ⚠️ `open` で開くのと違い、中身は開かない（大きいファイルを間違って開かないため）。
    static func reveal(_ path: String) {
        guard FileManager.default.fileExists(atPath: path) else {
            Toast.show("見つかりません: \(URL(fileURLWithPath: path).lastPathComponent)", isError: true)
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    static func openURL(_ string: String) {
        guard let url = URL(string: string), url.scheme != nil else {
            Toast.show("URLとして読めません", isError: true)
            return
        }
        NSWorkspace.shared.open(url)
    }

    /// スクリプトの実行。
    ///
    /// 実行ファイルのパスと引数の配列を別々に渡す。シェルに文字列を組み立てて渡さないので、
    /// {query} に何を入力されてもコマンド注入は成立しない（引数1個として届くだけ）。
    static func runScript(path: String, arguments: [String]) {
        let fm = FileManager.default
        guard fm.isExecutableFile(atPath: path) else {
            Toast.show("実行できません: \(URL(fileURLWithPath: path).lastPathComponent)", isError: true)
            return
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        do {
            try process.run()
        } catch {
            Toast.show("起動できません: \(error.localizedDescription)", isError: true)
            return
        }

        // 先に読み切ってから終了を待つ。逆にするとパイプが詰まって固まることがある。
        DispatchQueue.global(qos: .userInitiated).async {
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            let output = String(data: data, encoding: .utf8) ?? ""
            let firstLine = output
                .split(separator: "\n")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .first(where: { !$0.isEmpty }) ?? ""
            let status = process.terminationStatus
            DispatchQueue.main.async {
                if status == 0 {
                    Toast.show(firstLine.isEmpty ? "実行しました" : String(firstLine.prefix(120)))
                } else {
                    Toast.show("失敗（終了コード \(status)）\(firstLine.isEmpty ? "" : ": \(firstLine.prefix(80))")", isError: true)
                }
            }
        }
    }
}
