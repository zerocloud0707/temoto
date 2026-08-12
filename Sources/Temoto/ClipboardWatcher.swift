import AppKit
import TemotoCore

/// 拾ったひとかたまり。絵のときだけ実体（PNG）が付く。
///
/// 絵を ClipItem に入れずここで分けて持つのは、履歴の一覧（clips.enc）が
/// 「全件を1つの封筒に入れて毎回まるごと書き直す」作りだから。
/// 絵を混ぜると、1回コピーするたびに過去の絵まで暗号化し直すことになる。
struct ClipCapture {
    var item: ClipItem
    var originalPNG: Data?
    var thumbnailPNG: Data?

    init(item: ClipItem, originalPNG: Data? = nil, thumbnailPNG: Data? = nil) {
        self.item = item
        self.originalPNG = originalPNG
        self.thumbnailPNG = thumbnailPNG
    }
}

/// クリップボードの見張り役。
///
/// NSPasteboard には「変わったら教えてくれる」通知が無いので changeCount を定期的に見る。
/// 拾った中身は必ず ClipboardGuard を通し、残してよいと判定されたものだけ渡す。
/// 捨てたものは中身を保持しない（理由の文字列にも中身は入らない）。
final class ClipboardWatcher {

    /// 判定結果の通知。保存するときだけ capture が入る。
    var onDecision: ((ClipDecision, ClipCapture?) -> Void)?

    /// ファイルがコピーされたと判断してよい型。
    ///
    /// ⚠️ readObjects(forClasses: [NSURL.self]) は、ただの文字列でも
    /// URL として読めれば URL に化ける（"/etc/hosts" をコピーしただけでファイル扱いになる）。
    /// なので「相手がファイルだと名乗っている」ときに限る。
    private static let fileURLTypes: Set<String> = [
        "public.file-url",
        "NSFilenamesPboardType",
    ]

    private let pasteboard = NSPasteboard.general
    private var timer: Timer?
    private var lastChangeCount: Int
    private var lastStored: ClipPayload?
    private var settings: ClipboardSettings
    private var guardian: ClipboardGuard

    init(settings: ClipboardSettings) {
        self.settings = settings
        self.guardian = settings.makeGuard()
        self.lastChangeCount = NSPasteboard.general.changeCount
    }

    func update(settings: ClipboardSettings) {
        self.settings = settings
        self.guardian = settings.makeGuard()
        if settings.enabled { start() } else { stop() }
    }

    /// 重複判定の起点。起動時に履歴の先頭を渡しておくと、
    /// 前回終了時と同じ内容が残っていても二重に積まない。
    func seed(with item: ClipItem?) {
        lastStored = ClipboardWatcher.payload(of: item)
    }

    private static func payload(of item: ClipItem?) -> ClipPayload? {
        guard let item else { return nil }
        switch item.kind {
        case .text:
            return .text(item.text)
        case .image:
            guard let info = item.image else { return nil }
            return .image(byteCount: info.byteCount, fingerprint: info.fingerprint)
        case .file:
            return .files(item.filePaths)
        }
    }

    /// 自分でペーストボードに書いたあとに呼ぶ。その変化は履歴に取り込まない。
    func ignoreCurrentChange() {
        lastChangeCount = pasteboard.changeCount
    }

    func start() {
        stop()
        guard settings.enabled else { return }
        let t = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in self?.poll() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func poll() {
        let count = pasteboard.changeCount
        guard count != lastChangeCount else { return }
        lastChangeCount = count

        let types = pasteboard.types?.map { $0.rawValue } ?? []
        let app = NSWorkspace.shared.frontmostApplication
        let name = app?.localizedName
        let bundle = app?.bundleIdentifier

        // 読む順番は ①ファイル ②文字 ③絵。
        //
        // 文字を絵より先にするのは、Word や Excel などが文字をコピーしたときに
        // 見た目を保つための TIFF を一緒に置くことがあるため。
        // 絵を先にすると、ふつうの文字のコピーが軒並み画像に化ける。
        // スクリーンショット・プレビュー・ブラウザの「画像をコピー」はいずれも
        // 文字を置かないので、この順でも取りこぼさない。

        if !types.filter({ ClipboardWatcher.fileURLTypes.contains($0) }).isEmpty {
            let paths = filePaths()
            let payload = ClipPayload.files(paths)
            let decision = guardian.decide(payload: payload, types: types,
                                           sourceBundleID: bundle, previous: lastStored)
            guard decision.isStored, !paths.isEmpty else {
                onDecision?(decision, nil)
                return
            }
            lastStored = payload
            onDecision?(decision, ClipCapture(
                item: .files(paths, sourceAppName: name, sourceBundleID: bundle)
            ))
            return
        }

        let text = pasteboard.string(forType: .string)
        if let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let payload = ClipPayload.text(text)
            let decision = guardian.decide(payload: payload, types: types,
                                           sourceBundleID: bundle, previous: lastStored)
            guard decision.isStored else {
                onDecision?(decision, nil)
                return
            }
            lastStored = payload
            onDecision?(decision, ClipCapture(
                item: ClipItem(text: text, sourceAppName: name, sourceBundleID: bundle)
            ))
            return
        }

        if let made = ClipImageMaker.make(from: pasteboard) {
            let fingerprint = ClipFingerprint.of(made.png)
            let payload = ClipPayload.image(byteCount: made.png.count, fingerprint: fingerprint)
            let decision = guardian.decide(payload: payload, types: types,
                                           sourceBundleID: bundle, previous: lastStored)
            guard decision.isStored else {
                onDecision?(decision, nil)
                return
            }
            lastStored = payload
            let info = ClipImageInfo(
                pixelWidth: made.pixelWidth,
                pixelHeight: made.pixelHeight,
                byteCount: made.png.count,
                fingerprint: fingerprint
            )
            onDecision?(decision, ClipCapture(
                item: .image(info, sourceAppName: name, sourceBundleID: bundle),
                originalPNG: made.png,
                thumbnailPNG: made.thumbnailPNG
            ))
            return
        }

        // 文字でも絵でもファイルでもない（PDFだけ、独自形式だけ、など）。
        // 中身を持たないまま「保存しない」とだけ伝える。
        onDecision?(guardian.decide(payload: .text(text ?? ""), types: types,
                                    sourceBundleID: bundle, previous: lastStored), nil)
    }

    /// ペーストボードに置かれたファイルの置き場所。中身は読まない。
    private func filePaths() -> [String] {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        guard let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [URL] else {
            return []
        }
        return urls.filter { $0.isFileURL }.map { $0.path }
    }
}
