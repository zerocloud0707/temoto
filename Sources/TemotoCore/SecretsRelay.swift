import Foundation

/// アプリを作り直すときに、定型文とメモを新旧のビルドの間で運ぶ。
///
/// なぜ要るか:
/// ad-hoc署名は作り直すたびに変わり、macOSは前のビルドが作ったキーチェーンの鍵を
/// 「他人のもの」と見なす。読もうとすると許可ダイアログが出るが、
/// これはキーチェーンのパスワードを求めてきて、作者の環境では答えられなかった。
///
/// 実測（2026-07-28）で分かったこと:
///   ・自分が作った鍵を読む   → 即座に成功。ダイアログは出ない
///   ・別署名が作った鍵を読む → ダイアログ（パスワード要求）で止まる
///   ・別署名が作った鍵を消す → 旧APIなら成功。ダイアログは出ない
///
/// つまり「読めない鍵は捨てて作り直す」ならパスワードは一度も要らない。
/// ただし素直にやると定型文とメモが毎回消えるので、
/// 捨てる前に旧ビルドで取り出し（export）、作り直した後に新ビルドで書き戻す（import）。
///
/// クリップボード履歴は運ばない。中身にパスワードやトークンが入りうるので、
/// 一瞬でも平文のファイルに置きたくない。履歴は作り直しのたびに空から始める。
///
/// AppKitに触らないので TemotoCore に置いてある（検証で中身を確かめられるようにするため）。
public enum SecretsRelay {

    public enum Mode: Equatable {
        case export(URL)
        case importFrom(URL)
    }

    public static func parse(_ arguments: [String]) -> Mode? {
        var it = arguments.dropFirst().makeIterator()
        while let arg = it.next() {
            switch arg {
            case "--export-secrets":
                guard let path = it.next() else { return nil }
                return .export(URL(fileURLWithPath: path))
            case "--import-secrets":
                guard let path = it.next() else { return nil }
                return .importFrom(URL(fileURLWithPath: path))
            default:
                continue
            }
        }
        return nil
    }

    /// 終了コード
    ///   0 … できた
    ///   2 … 鍵が使えないので運べなかった（呼び出し側は続行してよい）
    ///   3 … 鍵の取り出しが時間内に返らなかった（許可ダイアログで止まった）
    ///   4 … ファイルの読み書きに失敗
    public static func run(_ mode: Mode) -> Int32 {
        let store = Store()
        store.loadPlaintext()

        switch mode {
        case .export(let destination):
            guard let result = vaultWithDeadline(store) else {
                FileHandle.standardError.write(Data(
                    "鍵の取り出しが返ってきません（許可ダイアログで止まっています）。引き継ぎは諦めます。\n".utf8))
                return 3
            }
            store.adoptVault(result)
            guard let backup = store.exportSecrets() else {
                FileHandle.standardError.write(Data("鍵が使えないので引き継げません。\n".utf8))
                return 2
            }
            do {
                let data = try JSONEncoder.temoto.encode(backup)
                try data.write(to: destination, options: [.atomic])
                try? FileManager.default.setAttributes(
                    [.posixPermissions: 0o600], ofItemAtPath: destination.path)
                let noteCount = backup.notes.count + (backup.notes.isEmpty && !backup.note.text.isEmpty ? 1 : 0)
                print("引き継ぎ用に取り出しました: 定型文 \(backup.snippets.count)件・メモ \(noteCount)枚")
                return 0
            } catch {
                FileHandle.standardError.write(Data("書き出しに失敗: \(error.localizedDescription)\n".utf8))
                return 4
            }

        case .importFrom(let source):
            guard let data = try? Data(contentsOf: source),
                  let backup = try? JSONDecoder.temoto.decode(Store.SecretsBackup.self, from: data) else {
                FileHandle.standardError.write(Data("引き継ぎファイルを読めませんでした。\n".utf8))
                return 4
            }
            // ここは作り直した直後なので、鍵はまだ無いか、読めない古いものが残っている。
            // どちらでも recreateVault が捨てて作り直す（ダイアログは出ない）。
            guard store.recreateVault() else {
                FileHandle.standardError.write(Data(
                    "\(store.vaultProblem ?? "暗号鍵を作り直せませんでした")\n".utf8))
                return 2
            }
            store.importSecrets(backup)
            // ⚠️ 取り出し側と同じ項目を必ず並べる。
            // 「メモ 3枚」と出したのに書き戻しで黙っていると、
            // あとで中身が無かったとき「消えたのか、報告し忘れただけか」が分からない。
            let expected = backup.notes.count + (backup.notes.isEmpty && !backup.note.text.isEmpty ? 1 : 0)
            let noteState: String
            if expected == 0 {
                noteState = "0枚"
            } else if store.notes.count >= expected {
                noteState = "\(store.notes.count)枚"
            } else {
                noteState = "🔴 \(expected)枚のうち \(store.notes.count)枚しか引き継げず（前の .broken に残っています）"
            }
            print("引き継ぎました: 定型文 \(store.snippets.count)件・メモ \(noteState)")
            return 0
        }
    }

    /// 鍵の取り出しに制限時間を付ける。
    /// 許可ダイアログが出ると答えるまで返ってこないので、
    /// 待たずに諦めて終了する（プロセスが終わればダイアログも閉じる）。
    private static func vaultWithDeadline(_ store: Store, seconds: Double = 6) -> Result<Vault, Error>? {
        let box = ResultBox()
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            box.value = store.makeVault()
            done.signal()
        }
        guard done.wait(timeout: .now() + seconds) == .success else { return nil }
        return box.value
    }

    private final class ResultBox: @unchecked Sendable {
        var value: Result<Vault, Error>?
    }
}
