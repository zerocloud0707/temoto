import Foundation

/// 窓の閉じ方・開き方の決まりを、この1か所だけに書く。
///
/// ⚠️ なぜ表にまとめたか（経緯を消さないこと）
///   作者から
///     「メモやその他、アプリとは別の部分をクリックしても閉じなかったり、挙動をもっと上手く作って。」
///   と言われた。原因は、検索窓は外をクリックすると閉じるのに、
///   メモだけ「他のアプリを見ながら書き写すことがあるので、離れても消さない」という
///   別の決まりで作られていたこと。作った側の理屈としては筋が通っていたが、
///   使う側から見ると「窓によって閉じ方が違う」＝壊れて見える。
///
///   窓ごとにその場で書き分けると、また片方だけ直し忘れる。
///   だから決まりはここに集め、TemotoChecks から表として検証する。
///   AppKit に触れないのはそのため（触れると検証できない）。

/// テモトが出す窓。
public enum PanelKind: String, CaseIterable, Sendable {
    /// 検索窓。コピー履歴・定型文・リンク・ウィンドウ配置は、この窓の中身が変わるだけ。
    case launcher
    /// メモ
    case note
    /// 設定
    case settings

    public var title: String {
        switch self {
        case .launcher: return "検索窓"
        case .note: return "メモ"
        case .settings: return "設定"
        }
    }

    /// 枠（タイトルバーと閉じるボタン）があるか。
    /// 無い窓は、閉じる手段を自前で全部用意しないと画面に貼り付いたまま剥がせない。
    public var hasWindowFrame: Bool {
        switch self {
        case .launcher, .note: return false
        case .settings: return true
        }
    }
}

/// 窓が閉じるきっかけ。
public enum CloseReason: String, CaseIterable, Sendable {
    /// esc を押した
    case escape
    /// ⌘W を押した
    case commandW
    /// 開いたときと同じホットキーをもう一度押した
    case hotkey
    /// 外（テモト以外の場所）をクリックして焦点を失った
    case focusLost
    /// テモトの別の窓を開いたので、入れ替わりで閉じた
    case replacedByAnother
    /// 用が済んだ。開いた先が自分で前に出てくる（アプリを開いた・リンクを開いた・貼り付けた）
    case finished
    /// 前に使っていたアプリに仕事を渡した（ウィンドウ配置・コピーだけして戻る）。
    /// ⚠️ 先に前面へ戻さないと、その手前にある別の窓を掴んでしまう。
    case handOffToPreviousApp

    /// 使う人が「閉じよう」と思って閉じたか。
    /// そうでない（横から閉じられた）ものと分けたいときに使う。
    public var isDeliberate: Bool {
        switch self {
        case .escape, .commandW, .hotkey: return true
        case .focusLost, .replacedByAnother, .finished, .handOffToPreviousApp: return false
        }
    }
}

public enum PanelBehavior {

    /// 焦点を失ったとき、この窓は閉じるか。
    ///
    /// 枠の無い窓（検索窓・メモ）は閉じる。閉じるボタンが無いので、
    /// 外をクリックしても消えないと剥がし方が esc しか無くなる。
    /// 設定は枠がある普通の窓なので閉じない。
    /// 他のアプリを見ながら設定を変えたい場面があり、
    /// そこで勝手に消えると今度は逆向きに壊れて見える。
    public static func closesWhenFocusLost(_ kind: PanelKind) -> Bool {
        !kind.hasWindowFrame
    }

    /// esc で閉じられるか。
    /// どの窓でも閉じられるようにする（覚えることを増やさない）。
    public static func closesOnEscape(_ kind: PanelKind) -> Bool { true }

    /// ⌘W で閉じられるか。
    ///
    /// ⚠️ テモトはメニューバーだけのアプリ（.accessory）で、画面上部のメニューを持たない。
    /// つまり macOS が普通に用意する「ファイル > 閉じる ⌘W」が存在しない。
    /// 何もしなければ ⌘W はどの窓でも効かないので、窓ごとに自分で拾う。
    public static func closesOnCommandW(_ kind: PanelKind) -> Bool { true }

    /// 閉じたあと、開く前に使っていたアプリへ焦点を返すか。
    ///
    /// ⚠️ 外をクリックして閉じたときだけは返さない。
    /// クリックした先のアプリを使いたいはずで、そこから焦点を奪い返すと
    /// 「押したのに知らないアプリが前に出てくる」になる。
    ///
    /// 用が済んだとき（アプリを開いた・貼り付けた）も、こちらからは触らない。
    /// 開いたアプリや貼り付け先が自分で前に出てくるので、二重に動かすと取り合いになる。
    public static func restoresPreviousApp(_ kind: PanelKind, reason: CloseReason) -> Bool {
        // 設定は普通の窓。閉じたあとの焦点は macOS に任せる。
        guard kind != .settings else { return false }
        // 自分で閉じたときは元の場所へ戻す。
        // ウィンドウ配置のように、前のアプリが前面にいないと成立しない仕事も戻す。
        return reason.isDeliberate || reason == .handOffToPreviousApp
    }

    /// この窓を開くとき、先に閉じておく窓。
    ///
    /// 作者の「一つ一つが別アプリみたい」を避けるため、
    /// 検索窓とメモは同時に出さない（同じ場所・同じ大きさに出るので重なる）。
    ///
    /// ⚠️ 検索窓とメモは浮く窓（.floating）で、設定は普通の窓。
    /// 設定を開くとき浮く窓が残っていると、設定の手前に被って押せない。
    /// だから設定を開くときは両方どかす。
    /// 逆に検索窓・メモを開くときは設定を閉じない。
    /// 設定でショートカットを変えた直後、そのまま押して確かめられるようにするため。
    public static func panelsToClose(whenOpening kind: PanelKind) -> [PanelKind] {
        switch kind {
        case .launcher: return [.note]
        case .note: return [.launcher]
        case .settings: return [.launcher, .note]
        }
    }

    /// 閉じる前に、書きかけを保存しないといけない窓か。
    ///
    /// メモは打つたびに自動保存しているが、最後の一打から0.8秒は
    /// まだディスクに書いていない。外をクリックした瞬間に閉じるなら、
    /// その手前で必ず書き切る（1文字消えるだけで信用が無くなる）。
    public static func savesBeforeClose(_ kind: PanelKind) -> Bool {
        switch kind {
        case .note, .settings: return true
        case .launcher: return false
        }
    }

    /// 閉じる前に、文字入力を終わらせないといけない窓か。
    ///
    /// ⚠️ 日本語入力の変換中（「っっっd」のような未確定の状態）で窓を閉じると、
    /// 確定していない分が宙に浮く。閉じる前に入力欄から手を離させて
    /// 未確定の文字を確定させてから保存する。
    public static func commitsInputBeforeClose(_ kind: PanelKind) -> Bool {
        savesBeforeClose(kind)
    }
}
