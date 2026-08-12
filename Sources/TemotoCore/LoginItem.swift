import Foundation

/// Macを起動したときにテモトを開くかどうか、の「人に見せる側」。
///
/// なぜ要るのか（2026-07-29）。
/// テモトには**自動起動の仕組みが1行も無かった**。動いているのは手で起動したものだけで、
/// Macを再起動すれば消える。Raycast を消したあとにこれが起きると、
/// ⌥Space を押しても何も出てこない＝「壊れた」ようにしか見えない。
/// 乗り換えの前提として、まずここを塞ぐ。
///
/// ⚠️ 入/切の状態は `Settings`（settings.json）に持たない。
/// 本当のことを知っているのは macOS の「ログイン項目」の方で、
/// 作者はシステム設定から直接そこを外せる。設定ファイルにも同じ入/切を置くと、
/// **「入れたのに動かない」「切ったのに残る」**が必ず起きる。
/// このファイルが持つのは「OSに聞いた答えを人の言葉に直す」ところだけ。
///
/// ⚠️ AppKit も ServiceManagement も持ち込まない（TemotoCore は検証にかけられる層）。
/// 実際に OS を叩くのは `Temoto/LoginItemService.swift`。
public enum LoginItem {

    /// OSに聞いた「いまどうなっているか」。
    public enum State: Equatable, Sendable {
        /// 入っている。次にMacを起動したときテモトが立ち上がる
        case on
        /// 入っていない。＝**再起動したら消える**
        case off
        /// 登録はしたが、作者がシステム設定で「許可」を押すまで動かない
        case needsApproval
        /// そもそも登録できない場所にアプリがある（開発中に .build の中から動かしたときなど）
        case unavailable
    }

    /// チェックボックスに入れる印。
    ///
    /// ⚠️ `needsApproval` を「入」に見せる。登録そのものは済んでいるので、
    /// ここで「切」に見せると作者はもう一度押してしまい、
    /// 「押しても入らない」という一番わかりにくい状態になる。
    /// 代わりに下の `note` で「あと一手ある」ことを伝える。
    public static func isChecked(_ state: State) -> Bool {
        switch state {
        case .on, .needsApproval: return true
        case .off, .unavailable: return false
        }
    }

    /// チェックボックスを押せるか。
    /// 登録できない場所にあるときは押させない（押しても必ず失敗するので）。
    public static func isEnabled(_ state: State) -> Bool {
        state != .unavailable
    }

    /// チェックボックスの下に出す一言。
    ///
    /// 空文字を返すのは「言うことが無い」ときだけ。
    /// ⚠️ 「入っています」のような、押した結果を繰り返すだけの文は出さない。
    /// 印を見れば分かることを字で書くと、本当に読ませたい警告が埋もれる。
    public static func note(_ state: State) -> String {
        switch state {
        case .on:
            return ""
        case .off:
            return "いまは切です。このままだとMacを再起動したときテモトは立ち上がりません。"
        case .needsApproval:
            return "システム設定 →「一般」→「ログイン項目と機能拡張」で"
                + "テモトを許可してください。許可するまで自動では立ち上がりません。"
        case .unavailable:
            return "いまのテモトは登録できない場所から動いています。"
                + "~/Applications/Temoto.app から起動しなおしてください。"
        }
    }

    /// 押したときに失敗した場合に出す一言。
    ///
    /// ⚠️ OSが返すエラーをそのまま出さない。英語で、しかも
    /// 「Operation not permitted」のように何をすればいいか分からないものが返る。
    /// 何ができるかを書く。
    public static func failureMessage(turningOn: Bool) -> String {
        turningOn
            ? "Macの起動時に開く設定にできませんでした。"
                + "システム設定 →「一般」→「ログイン項目と機能拡張」から手で足せます。"
            : "設定を切れませんでした。"
                + "システム設定 →「一般」→「ログイン項目と機能拡張」から手で外せます。"
    }

    /// メニューバーの一覧に出す短い注意書き。
    ///
    /// ⚠️ 設定画面を開かない限り気づけない、では意味がない。
    /// 「再起動したら消える」は、消えてから気づいても手遅れなので、
    /// いつも見えるところに出す。
    public static func menuWarning(_ state: State) -> String? {
        switch state {
        case .on: return nil
        case .off: return "⚠️ 再起動すると立ち上がりません"
        case .needsApproval: return "⚠️ ログイン項目の許可が要ります"
        case .unavailable: return nil   // 場所の問題は設定画面で説明する
        }
    }

    /// アプリの置き場所として正しいか。
    ///
    /// ⚠️ テモトの置き場所は `~/Applications/Temoto.app` ただ1つと決めてある。
    /// `.build` の中や Downloads から動かしていると、
    /// 登録できてもビルドのたびに指す先が消えて、次の起動で黙って失敗する。
    ///
    /// - Parameter bundlePath: 動いている .app の場所
    /// - Parameter homePath: ホームフォルダ（検証で差し替えられるように引数にしてある）
    public static func isInstalledProperly(bundlePath: String, homePath: String) -> Bool {
        let normalized = bundlePath.hasSuffix("/") ? String(bundlePath.dropLast()) : bundlePath
        let expected = [
            "\(homePath)/Applications/Temoto.app",
            "/Applications/Temoto.app",
        ]
        return expected.contains(normalized)
    }
}
