import Foundation

/// 画面の下に出す「押せる操作」1つぶん。
///
/// ⚠️ なぜ文字列1本ではなく組にするのか。
///
/// 前は `"⏎ 貼り付け　⌘C コピー　esc 戻る"` という1本の文字列だった。
/// 一続きの薄い文字は、どこまでがキーでどこからが説明なのか目が切り分けられない。
/// 結果、その行はまるごと風景になって誰も読まない。
///
/// キーと説明を分けて持てば、画面側でキーだけを枠に入れて描ける。
/// 枠があると「これは押せる」と一目で分かる。Raycast が下の帯でやっているのもこれ。
public struct HintAction: Equatable, Sendable {
    /// 押すキー。`⏎` `⌘C` `esc` のように、実際にキーボードに見える形で書く
    public let keys: String
    /// そのキーで何が起きるか。**押せない操作は書かない**
    public let label: String
    /// 幅が足りないときでも最後まで残す操作。
    ///
    /// ⚠️ 残すのは「戻り方」だけ。
    /// 迷ったときの出口が画面から消えると、人は窓を閉じるのではなく
    /// アプリごと信用しなくなる（「どうやって抜けるのか分からない」）。
    public let isEssential: Bool

    public init(_ keys: String, _ label: String, isEssential: Bool = false) {
        self.keys = keys
        self.label = label
        self.isEssential = isEssential
    }

    /// 枠を描けない場所で使う1行表記
    public var inlineText: String { "\(keys) \(label)" }
}

extension Array where Element == HintAction {
    /// 幅に収まるところまで削る。
    ///
    /// ⚠️ 削る順は「後ろから」。前に置いた操作ほどよく使う並びにしてあるので、
    /// 端から消せば、狭い画面でも大事なものが残る。
    /// ただし `isEssential`（＝戻り方）は何件になっても落とさない。
    public func trimmed(to maximum: Int) -> [HintAction] {
        guard maximum > 0 else { return filter(\.isEssential) }
        guard count > maximum else { return self }

        let essential = filter(\.isEssential)
        // 出口だけで既に溢れるなら、出口を優先する（切るなら説明のほうを切る）
        guard essential.count < maximum else { return essential }

        var kept = filter { !$0.isEssential }.prefix(maximum - essential.count).map { $0 }
        kept.append(contentsOf: essential)
        return kept
    }
}
