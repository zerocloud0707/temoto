import AppKit
import TemotoCore

/// うまくいかなかったことを手元のファイルに貯め、本人が読んでから渡せるようにする。
///
/// 2026-08-09 作者「今後他の人にも使ってもらい、エラー情報を収集したい。」→ A案。
///
/// ⚠️ **どこにも送らない。** 送る/送らないは、その人が毎回決める。
/// ここがやるのは「貯める・読める形にする・書き出す」まで。
///
/// ⚠️ 貯める入口を1つに絞る。
/// 失敗したときに出す赤いお知らせ（Toast.show(isError: true)）は、
/// **すでに「人に見える失敗」の全部**なので、そこを通せば書き漏らしが起きない。
/// 記録用の呼び出しを各所に散らすと、必ずどこかで忘れる。
enum ErrorReporter {

    /// 記録の置き場所（コピー履歴などと同じフォルダ）
    static var fileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Temoto", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("problems.json")
    }

    private static let queue = DispatchQueue(label: "jp.zerocloud.temoto.problems")

    /// 1件書く。
    /// ⚠️ 書けなくても**何も言わない**。記録が取れないことを知らせても人は何もできないし、
    /// 「失敗の記録に失敗しました」というお知らせほど無意味なものはない。
    static func record(area: String, what: String, detail: String = "") {
        let entry = ErrorLog.Entry(at: Date(), area: area, what: what, detail: detail)
        queue.async {
            var entries = load()
            entries.append(entry)
            save(ErrorLog.trim(entries))
        }
    }

    static func load() -> [ErrorLog.Entry] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        return (try? JSONDecoder().decode([ErrorLog.Entry].self, from: data)) ?? []
    }

    private static func save(_ entries: [ErrorLog.Entry]) {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    static func clear() {
        queue.async { save([]) }
    }

    /// 本人が読む形にする
    static func report() -> String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        let os = ProcessInfo.processInfo.operatingSystemVersionString
        var text = ErrorLog.report(entries: load(),
                                   appVersion: "\(version)（\(build)）",
                                   osVersion: os,
                                   now: Date())
        // ⚠️ 落ちた記録は macOS 側にある。ここに中身は取り込まない
        // （他のアプリの情報まで混ざるうえ、量も多い）。**在り処だけ**を伝える。
        let crashes = recentCrashReports()
        if !crashes.isEmpty {
            text += "\n\n──────────\n"
            text += "テモトが落ちた記録が macOS 側に \(crashes.count)件 あります（この文には含めていません）。\n"
            text += "必要なら「落ちた記録を表示」から Finder で開けます。\n"
            text += crashes.prefix(5).map { "  ・" + $0.lastPathComponent }.joined(separator: "\n")
        }
        return text
    }

    /// macOS が書いた「落ちた記録」。中身は読まず、在り処だけ数える
    static func recentCrashReports() -> [URL] {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/DiagnosticReports", isDirectory: true)
        let files = (try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        return files
            .filter { $0.lastPathComponent.hasPrefix("Temoto") }
            .sorted { a, b in
                let da = (try? a.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let db = (try? b.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return da > db
            }
    }

    // MARK: - 見せて、渡す

    /// 「問題を報告する」を押したとき。
    ///
    /// ⚠️ **中身を見せてから**渡す。読めない形で「送りますか？」と聞くのは聞いていないのと同じ。
    static func showReport() {
        let text = report()
        let alert = NSAlert()
        alert.messageText = "テモトの不具合の記録"
        alert.informativeText = "下の内容が、そのまま渡されます。中身を読んでから決めてください。"
                              + "\nどこにも自動では送りません。"

        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 520, height: 260))
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        let view = NSTextView(frame: scroll.bounds)
        view.isEditable = false
        view.isSelectable = true
        view.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        view.string = text
        scroll.documentView = view
        alert.accessoryView = scroll

        alert.addButton(withTitle: "コピーする")
        alert.addButton(withTitle: "ファイルに書き出す")
        alert.addButton(withTitle: "閉じる")
        if !ErrorReporter.load().isEmpty || !recentCrashReports().isEmpty {
            alert.addButton(withTitle: "記録を消す")
        }

        NSApp.activate()
        let response = alert.runModal()
        switch response {
        case .alertFirstButtonReturn:
            let board = NSPasteboard.general
            board.clearContents()
            board.setString(text, forType: .string)
            Toast.show("記録をコピーしました。メールやチャットに貼って送ってください")
        case .alertSecondButtonReturn:
            writeToFile(text)
        case .alertThirdButtonReturn:
            return
        default:
            // ⚠️ 消すのは取り返しがつかないので、一度だけ確かめる
            let confirm = NSAlert()
            confirm.messageText = "記録を消しますか？"
            confirm.informativeText = "手元の記録だけを消します（macOS 側の落ちた記録は消しません）。"
            confirm.alertStyle = .warning
            confirm.addButton(withTitle: "消す")
            confirm.addButton(withTitle: "やめる")
            if confirm.runModal() == .alertFirstButtonReturn {
                clear()
                Toast.show("記録を消しました")
            }
        }
    }

    private static func writeToFile(_ text: String) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "テモトの記録 \(ErrorLog.stamp(Date()).replacingOccurrences(of: ":", with: "-")).txt"
        panel.allowedContentTypes = [.plainText]
        NSApp.activate()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            Toast.show("書き出しました。このファイルを送ってください")
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } catch {
            Toast.show("書き出せませんでした: \(error.localizedDescription)", isError: true)
        }
    }
}
