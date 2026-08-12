import Foundation
import ServiceManagement
import TemotoCore

/// macOS の「ログイン項目」を読み書きする薄い層。
///
/// 判断や文言は `TemotoCore/LoginItem.swift` に置いてある（あちらは検証にかけられる）。
/// ここは OS を叩くだけにして、間違えようのない厚みに保つ。
enum LoginItemService {

    /// いま登録されているか。
    ///
    /// ⚠️ 覚えておかない（キャッシュしない）。
    /// 作者はシステム設定からいつでも外せるので、
    /// こちらが覚えた値は簡単に嘘になる。毎回OSに聞く。
    static var state: LoginItem.State {
        // 置き場所が違うと、登録できても次の起動で黙って失敗する。先に弾く
        guard LoginItem.isInstalledProperly(bundlePath: Bundle.main.bundlePath,
                                            homePath: NSHomeDirectory()) else {
            return .unavailable
        }
        switch SMAppService.mainApp.status {
        case .enabled:
            return .on
        case .requiresApproval:
            return .needsApproval
        case .notRegistered:
            return .off
        case .notFound:
            // 登録の記録はあるが実体が見つからない（前の .app を消したときなど）。
            // 入っていないのと同じ扱いにして、押し直せば直るようにする
            return .off
        @unknown default:
            return .off
        }
    }

    /// 入/切を変える。うまくいったら true。
    @discardableResult
    static func setEnabled(_ on: Bool) -> Bool {
        do {
            if on {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            return true
        } catch {
            // ⚠️ 既に切れているものを切ろうとしたときもここに来る。
            // 結果として望みの状態になっているなら、失敗として騒がない
            if !on, state == .off { return true }
            NSLog("[Temoto] ログイン項目の変更に失敗しました: \(error.localizedDescription)")
            return false
        }
    }

    /// システム設定の「ログイン項目と機能拡張」を開く。
    ///
    /// ⚠️ 許可を押すのは作者自身。こちらでできるのは画面を出すところまで。
    static func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
