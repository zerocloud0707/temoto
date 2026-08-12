import Foundation

/// メニューバーのメニューに「何を出すか」を決める係。
///
/// ⚠️ ここが存在する理由（2026-07-30 作者「このメニュー画面、構成が汚い」）。
/// 前は灰色の1行に「履歴 8件・定型文 4件・⚠️…・⚠️…」と詰め込んで右端で切れていた。
/// 警告は**読ませる文字ではなく、押して直せる行**にする。その出し分け（どの警告を・
/// どの順で・どんな文言で）はここで決める（AppKitに触れない＝検証できる）。
///
/// 決めごと（3案の設計審査で確定・2026-07-30）:
/// - 警告は最上部の「要対応」節に。**0件のときは節ごと出さない**（沈黙＝健康）
/// - 並びは深刻度の固定順: 保存できない → 次の起動で全損 → ウィンドウ機能死 → 一部のキー死
/// - 文言は「症状 — 押すと起きること」。末尾の「…」は画面が開く印、無ければその場で完結
/// - 機能を切っているなら、その機能の警告は出さない（既存ルールと同じ）
public enum MenuPlan {

    /// 警告の節の見出し
    public static let warningSectionTitle = "要対応"

    /// 判断に要る今の状態
    public struct State: Sendable {
        /// 鍵の確認が終わったか（起動直後だけ false）
        public var secretsReady: Bool
        /// 鍵が使えず保存できない状態か
        public var vaultBroken: Bool
        public var loginState: LoginItem.State
        public var accessibilityGranted: Bool
        /// 他のアプリに取られていて登録できなかったショートカットの数
        public var failedShortcutCount: Int
        /// 設定で出している機能
        public var clipboardVisible: Bool
        public var snippetsVisible: Bool
        public var noteVisible: Bool
        public var windowsVisible: Bool

        public init(
            secretsReady: Bool,
            vaultBroken: Bool,
            loginState: LoginItem.State,
            accessibilityGranted: Bool,
            failedShortcutCount: Int,
            clipboardVisible: Bool,
            snippetsVisible: Bool,
            noteVisible: Bool,
            windowsVisible: Bool
        ) {
            self.secretsReady = secretsReady
            self.vaultBroken = vaultBroken
            self.loginState = loginState
            self.accessibilityGranted = accessibilityGranted
            self.failedShortcutCount = failedShortcutCount
            self.clipboardVisible = clipboardVisible
            self.snippetsVisible = snippetsVisible
            self.noteVisible = noteVisible
            self.windowsVisible = windowsVisible
        }
    }

    /// 押して直せる警告1行
    public struct Warning: Equatable, Sendable {
        public enum Kind: Equatable, Sendable {
            /// 鍵が使えない → 暗号鍵を作り直す（確認ダイアログ）
            case vault
            /// 自動起動が切 → その場で入にする
            case loginOff
            /// ログイン項目がOSに止められている → システム設定を開く
            case loginNeedsApproval
            /// アクセシビリティ未許可 → システム設定を開く
            case accessibility
            /// 登録できないショートカットがある → テモトの設定を開く
            case shortcuts(Int)
        }
        public let kind: Kind
        public let title: String

        public init(kind: Kind, title: String) {
            self.kind = kind
            self.title = title
        }
    }

    /// いま出すべき警告を、深刻度の固定順で返す。
    public static func warnings(_ state: State) -> [Warning] {
        var out: [Warning] = []

        // ① 保存できない（今この瞬間のデータ喪失）。
        //    暗号化して保存する機能を全部切っているなら、保存できなくても困らないので出さない
        let usesVault = state.clipboardVisible || state.snippetsVisible || state.noteVisible
        if state.secretsReady && state.vaultBroken && usesVault {
            out.append(Warning(kind: .vault, title: "履歴を保存できません — 暗号鍵を作り直す…"))
        }

        // ② 次の起動で全損（Macを再起動するとテモトごと消える）
        switch state.loginState {
        case .off:
            out.append(Warning(kind: .loginOff, title: "再起動すると立ち上がりません — 自動起動を入にする"))
        case .needsApproval:
            out.append(Warning(kind: .loginNeedsApproval, title: "ログイン項目の許可が必要です — システム設定を開く…"))
        case .on, .unavailable:
            break   // unavailable（置き場所の問題）は設定画面が説明する
        }

        // ③ ウィンドウ機能死。機能を切っているなら困っていない
        if state.windowsVisible && !state.accessibilityGranted {
            out.append(Warning(kind: .accessibility, title: "ウィンドウ操作が動きません — アクセシビリティを許可する…"))
        }

        // ④ 一部のキー死
        if state.failedShortcutCount > 0 {
            out.append(Warning(
                kind: .shortcuts(state.failedShortcutCount),
                title: "ショートカット\(state.failedShortcutCount)件が使えません — 設定で確かめる…"))
        }

        return out
    }

    /// メニューバーに出すしるし。
    /// 警告がある間はしるし自体を変える（メニューを開かない限り警告が見えない穴を、色を増やさず塞ぐ）。
    public static func statusSymbol(warningCount: Int) -> String {
        warningCount > 0 ? "exclamationmark.square" : "square.grid.2x2"
    }
}
