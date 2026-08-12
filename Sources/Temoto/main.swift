import AppKit
import TemotoCore

// ここは3つの入口を兼ねている。
//   1) --export-secrets <path>  … 鍵を作り直す前に、定型文とメモを取り出す
//   2) --import-secrets <path>  … 作り直した後に、それを新しい鍵で書き戻す
//   3) 引数なし                  … 通常のメニューバーアプリとして起動
//
// 1と2は scripts/build-app.sh から呼ばれる。
// アプリを作り直すと署名が変わり、macOSは前のビルドが作った鍵を「他人のもの」と見なす。
// 読もうとすると出る許可ダイアログはキーチェーンのパスワードを求めてきて、
// 作者の環境ではこれに答えられなかった。
// なので「読めない鍵は捨てて作り直す」に倒し、その前後で中身を運ぶのがこの2つ。
if let mode = SecretsRelay.parse(CommandLine.arguments) {
    exit(SecretsRelay.run(mode))
}

// 見た目の確認用（--render-preview <出力先.png> [--light]）。
// 実物の部品で入口の画面を組み、絵にして終了する。窓もメニューバーも出さない。
if let iconDirectory = DesignIcon.parse(CommandLine.arguments) {
    exit(DesignIcon.run(outputDirectory: iconDirectory))
}
if let outputPath = DesignPreview.parse(CommandLine.arguments) {
    exit(DesignPreview.run(outputPath: outputPath,
                           dark: !CommandLine.arguments.contains("--light")))
}

// 入力欄で ⌘C/⌘V が効くかを実物で確かめる（--check-menu）。
// メニューバーに出ないアプリは、メニューを自分で作らないと編集のキーが届かない。
// 直したつもりで終わらせないための入口。
if CommandLine.arguments.contains("--check-menu") {
    exit(EditMenu.selfTest())
}

// 二重起動を止める。
//
// 作り直したアプリを起動したとき、前のものがメニューバーに残っていることがある。
// 2つ動いていると、どちらもコピー履歴をディスクに書くので、
// あとから書いた方の内容で上書きされ、もう片方が拾った分が消える。
// 見た目には気づけない消え方をするので、ここで止める。
let running = NSRunningApplication.runningApplications(
    withBundleIdentifier: Bundle.main.bundleIdentifier ?? "jp.zerocloud.temoto"
).filter { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }

if !running.isEmpty {
    NSLog("[Temoto] すでに起動しているので終了します（PID \(running.map { String($0.processIdentifier) }.joined(separator: ", ")))")
    exit(0)
}

// メニューバーだけに出るアプリにする（Dockには出さない）。
// .accessory にしておくと、検索窓を開いたときだけ前面に来て、閉じれば前のアプリに戻る。
let app = NSApplication.shared
app.setActivationPolicy(.accessory)

let delegate = AppDelegate()
app.delegate = delegate
app.run()
