import AppKit
import Foundation
import TemotoCore

/// Spotlight を回す係。
///
/// ⚠️ なぜ自前で索引を作らないのか。
/// 数十万件のファイルを自分で舐めて索引を作ると、初回に何分もかかるうえ、
/// 常駐して監視し続けることになる（電池も食う）。macOS はそれを既に持っている。
/// Raycast も同じで、Spotlight の索引に相乗りしている。
///
/// 気をつけていること:
/// - 打つたびに検索しない（0.2秒待つ）。1文字ごとに投げると Spotlight が詰まる
/// - 検索語も結果も**どこにも保存しない**。履歴にも残さない
/// - ライブラリやビルド生成物は結果から外す（node_modules が並ぶと使い物にならない）
final class FileSearcher: NSObject {

    /// 結果が届いたときに呼ばれる。必ずメインスレッドで呼ぶ。
    /// 第1引数は「どの検索語に対する答えか」。打ち間違えて打ち直した後に
    /// 古い答えが届くことがあるので、受け取る側で照合できるようにしている。
    var onResults: ((String, [FileHit]) -> Void)?
    /// 検索を始めた合図（画面に「探しています」を出すため）
    var onSearching: ((String) -> Void)?

    private let query = NSMetadataQuery()
    private var debounce: DispatchWorkItem?
    private var pendingRaw = ""
    private var limit = 100
    private var isRunning = false

    override init() {
        super.init()
        query.notificationBatchingInterval = 0.2
        NotificationCenter.default.addObserver(
            self, selector: #selector(gathered),
            name: .NSMetadataQueryDidFinishGathering, object: query)
        NotificationCenter.default.addObserver(
            self, selector: #selector(gathered),
            name: .NSMetadataQueryGatheringProgress, object: query)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        if isRunning { query.stop() }
    }

    // MARK: - 検索

    /// 検索欄が変わるたびに呼ぶ。0.2秒静かになってから実際に投げる。
    func search(_ raw: String, settings: FileSearchSettings) {
        debounce?.cancel()
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        let parsed = FileQuery.parse(trimmed)

        // 使う／使わないはここでは見ない（設定の「使う機能」1か所で決める）。
        // ここで見るのは「回すと全件が出てしまう検索かどうか」だけ。
        guard parsed.isRunnable else {
            stop()
            onResults?(raw, [])
            return
        }

        // 本文検索を切っているのに中身で探そうとしている（`中身:` や「中身だけ」）。
        // ⚠️ このまま回すと中身の条件だけが**静かに落ちて**、残りの絞り（今月など）だけで
        // 全然違う結果が正解のような顔で並ぶ。0件で止めて、理由は下の帯が言う。
        guard !parsed.isContentSearchBlocked(searchesContent: settings.searchesContent) else {
            stop()
            onResults?(raw, [])
            return
        }

        onSearching?(raw)
        let work = DispatchWorkItem { [weak self] in
            self?.run(raw: raw, parsed: parsed, settings: settings)
        }
        debounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: work)
    }

    /// 窓を閉じたときなど、もう結果が要らないとき。
    func stop() {
        debounce?.cancel()
        debounce = nil
        if isRunning {
            query.stop()
            isRunning = false
        }
    }

    private func run(raw: String, parsed: FileQuery, settings: FileSearchSettings) {
        guard let predicate = parsed.predicate(searchesContent: settings.searchesContent) else {
            onResults?(raw, [])
            return
        }
        // 🔴 渡す直前の最後の関所。Spotlight が飲み込めない形を渡すと
        // Objective-C の例外が飛んでアプリごと落ちる（Swiftでは受け止められない）。
        // 2026-07-31「中身だけを選択するとクラッシュする」＝部品1つの複合条件だった。
        guard FileQuery.isMetadataSafe(predicate) else {
            onResults?(raw, [])
            return
        }

        if isRunning { query.stop() }
        pendingRaw = raw
        limit = max(10, settings.maxResults)

        query.predicate = predicate
        query.sortDescriptors = [NSSortDescriptor(key: parsed.sort.key, ascending: parsed.sort.ascending)]
        query.searchScopes = scopes(for: parsed, settings: settings)
        isRunning = query.start()
        if !isRunning {
            // 起動に失敗したときに黙って0件を出すと「壊れている」と分からない。
            // 空配列を返しつつ、受け取る側が「探せませんでした」と言えるようにしておく。
            onResults?(raw, [])
        }
    }

    private func scopes(for parsed: FileQuery, settings: FileSearchSettings) -> [Any] {
        let home = NSHomeDirectory()
        if let folder = parsed.folder, let resolved = FileScope.resolve(folder, home: home) {
            return [resolved]
        }
        let configured = settings.folders
            .compactMap { FileScope.resolve($0, home: home) }
        if !configured.isEmpty { return configured }
        return [NSMetadataQueryUserHomeScope]
    }

    // MARK: - 結果

    @objc private func gathered(_ notification: Notification) {
        query.disableUpdates()
        defer { query.enableUpdates() }

        let home = NSHomeDirectory()
        var hits: [FileHit] = []
        // 除外で落ちる分を見込んで多めに見る。全件舐めると数万件で固まる。
        let scanLimit = min(query.resultCount, max(limit * 8, 800))

        for index in 0..<scanLimit {
            guard let item = query.result(at: index) as? NSMetadataItem else { continue }
            guard let path = item.value(forAttribute: NSMetadataItemPathKey) as? String else { continue }
            guard !FileNoise.isExcluded(path) else { continue }

            let contentType = item.value(forAttribute: NSMetadataItemContentTypeKey) as? String
            let name = (item.value(forAttribute: NSMetadataItemFSNameKey) as? String)
                ?? (path as NSString).lastPathComponent
            hits.append(FileHit(
                path: path,
                name: name,
                contentType: contentType,
                byteCount: (item.value(forAttribute: NSMetadataItemFSSizeKey) as? NSNumber)?.int64Value,
                modifiedAt: item.value(forAttribute: NSMetadataItemFSContentChangeDateKey) as? Date,
                isFolder: contentType == "public.folder"
            ))
            if hits.count >= limit { break }
        }

        _ = home
        let raw = pendingRaw
        if Thread.isMainThread {
            onResults?(raw, hits)
        } else {
            DispatchQueue.main.async { [weak self] in self?.onResults?(raw, hits) }
        }
    }
}
