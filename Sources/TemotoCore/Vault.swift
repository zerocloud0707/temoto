import CryptoKit
import Foundation
import Security

/// 保存時の暗号化。鍵はmacOSキーチェーンに置き、ディスクには暗号文だけを書く。
///
/// なぜ必要か:
/// クリップボード履歴と定型文には、作者の場合ほぼ確実に freee の会社ID・振込先・
/// 報酬額・APIキーが混ざる。平文でファイルに置くと、
///   ①クラウド同期やバックアップに乗って外へ出る
///   ②フォルダをgrepしたスクリプトやAIがそのまま拾って別ファイルに書き写す
/// という事故が起きる。暗号化しておけばどちらも防げる。
///
/// 鍵が取り出せない場合は「ディスクに書かない（メモリ上だけで動く）」に倒す。
/// 弱い方式に自動で格下げして平文を書くようなことはしない。
public enum VaultError: Error, Equatable {
    case keychainUnavailable(OSStatus)
    case decryptionFailed
}

public struct Vault: Sendable {
    private let key: SymmetricKey

    public init(key: SymmetricKey) {
        self.key = key
    }

    public func seal(_ data: Data) throws -> Data {
        let box = try AES.GCM.seal(data, using: key)
        guard let combined = box.combined else { throw VaultError.decryptionFailed }
        return combined
    }

    public func open(_ data: Data) throws -> Data {
        do {
            let box = try AES.GCM.SealedBox(combined: data)
            return try AES.GCM.open(box, using: key)
        } catch {
            throw VaultError.decryptionFailed
        }
    }

    // MARK: - キーチェーン

    public static let keychainService = "jp.zerocloud.temoto"
    public static let keychainAccount = "store-encryption-key"

    /// 既存の鍵を読む。無ければ新規作成して保存する。
    public static func loadOrCreateKey(
        service: String = keychainService,
        account: String = keychainAccount
    ) throws -> SymmetricKey {
        if let existing = try readKey(service: service, account: account) {
            return existing
        }
        let newKey = SymmetricKey(size: .bits256)
        try writeKey(newKey, service: service, account: account)
        return newKey
    }

    static func readKey(service: String, account: String) throws -> SymmetricKey? {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var out: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &out)
        switch status {
        case errSecSuccess:
            guard let data = out as? Data, data.count == 32 else { return nil }
            return SymmetricKey(data: data)
        case errSecItemNotFound:
            return nil
        default:
            throw VaultError.keychainUnavailable(status)
        }
    }

    static func writeKey(_ key: SymmetricKey, service: String, account: String) throws {
        let data = key.withUnsafeBytes { Data($0) }
        let attributes: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            // 画面ロック解除中のみ・このMacの外へ出さない（バックアップにも乗せない）
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]
        SecItemDelete(attributes as CFDictionary)
        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw VaultError.keychainUnavailable(status)
        }
    }

    /// テストや初期化やり直し用
    public static func deleteKey(service: String = keychainService, account: String = keychainAccount) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        // 自分で作った鍵ならこれで消える。
        // 別のビルドが作った鍵は断られる（-25244）ので、その時だけ下の手を使う。
        if status != errSecSuccess && status != errSecItemNotFound {
            discardKey(service: service, account: account)
        }
    }

    /// 読めなくなった鍵を捨てる。
    ///
    /// なぜ専用の関数が要るか:
    /// アプリを作り直すと署名が変わり、macOSは前のビルドが作った鍵を「他人のもの」と見なす。
    /// 読もうとすると許可のダイアログが出るが、これはキーチェーンのパスワードを求めてくる。
    /// 作者の環境ではこれに答えられなかったため、鍵を取り出す道が塞がっていた。
    ///
    /// 新しい SecItemDelete は、この「他人のもの」を消そうとすると -25244 で断る。
    /// 一方、古い SecKeychainItem 系は持ち主の確認をしないので消せる。
    /// 実測（2026-07-28）: 別署名から 新API=-25244 / 旧API=0。どちらもダイアログは出ない。
    ///
    /// 消してよい理由: この鍵はテモトが自分で作った乱数で、他のアプリは使っていない。
    /// 消した後の .enc は読めなくなるが、Store 側が .broken に退避して残す（消さない）。
    @discardableResult
    public static func discardKey(
        service: String = keychainService,
        account: String = keychainAccount
    ) -> OSStatus {
        var item: SecKeychainItem?
        let found = SecKeychainFindGenericPassword(
            nil,
            UInt32(service.utf8.count), service,
            UInt32(account.utf8.count), account,
            nil, nil, &item)
        guard found == errSecSuccess, let item else { return found }
        return SecKeychainItemDelete(item)
    }

    /// 今動いているビルドの「持ち主」を表す文字列。
    ///
    /// 何に使うか:
    /// キーチェーンの鍵は「作ったビルドだけが読める」設定になっている。
    /// 作ったときにこの文字列を控えておけば、読みに行く前に自分のものか判断できる。
    /// 他人のものだと分かっていれば読みに行かないので、答えられない許可ダイアログが出ない。
    ///
    /// 中身は2通り（2026-07-30 Apple Developer 登録で変わった）:
    /// - **Developer ID で署名されている** → `team:チームID`。
    ///   チームIDは作り直しても変わらないので、**鍵も許可も作り直しをまたいで生き残る**
    /// - ad-hoc 署名（証明書なし） → 署名の cdhash。作り直すたびに変わるので、
    ///   そのたび鍵を捨てて作り直すことになる（2026-07-30 までの日常）
    ///
    /// この文字列は秘密ではない（配ったバイナリから誰でも計算できる）ので、平文で控えてよい。
    public static func currentCodeIdentity() -> String? {
        var code: SecCode?
        guard SecCodeCopySelf(SecCSFlags(), &code) == errSecSuccess, let code else { return nil }

        var stat: SecStaticCode?
        guard SecCodeCopyStaticCode(code, SecCSFlags(), &stat) == errSecSuccess, let stat else { return nil }

        var info: CFDictionary?
        let flags = SecCSFlags(rawValue: kSecCSSigningInformation)
        guard SecCodeCopySigningInformation(stat, flags, &info) == errSecSuccess,
              let dict = info as? [String: Any]
        else { return nil }

        // 証明書で署名されていればチームIDが入る（ad-hoc では入らない）
        if let team = dict[kSecCodeInfoTeamIdentifier as String] as? String, !team.isEmpty {
            return "team:\(team)"
        }
        guard let unique = dict[kSecCodeInfoUnique as String] as? Data else { return nil }
        return unique.map { String(format: "%02x", $0) }.joined()
    }

    /// 鍵を捨てて作り直す。作り直したビルドが自分の鍵を持てるようにするため。
    ///
    /// 新しい鍵は「作った本人だけが読める」設定のまま。
    /// 誰でも読める設定に緩めれば作り直さずに済むが、
    /// それだと作者として動く他のプログラム（スクリプトやAI）が鍵を取り出せてしまい、
    /// 履歴を暗号化している意味が無くなるので、そちらは選ばない。
    public static func recreateKey(
        service: String = keychainService,
        account: String = keychainAccount
    ) throws -> SymmetricKey {
        discardKey(service: service, account: account)
        let newKey = SymmetricKey(size: .bits256)
        try writeKey(newKey, service: service, account: account)
        return newKey
    }
}
