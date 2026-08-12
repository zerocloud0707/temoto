import Foundation

/// 棚のアプリを矢印で選ぶときの、選び位置の動かし方。
///
/// 2026-08-04 作者「アプリ選択時にコントロールを長押しして矢印で移動できる様にしたい！」
/// ＋「コントロールを押して数字を押すと、別のショートカットが設定されているものがあり、
/// うまく開かない時があります。」
///
/// ⚠️ **修飾キーを付けない**ことにした理由（実機で確認した事実）:
/// - `⌃←` `⌃→` は macOS の「左右のスペースへ移動」が既定で握っている（作者のMacでも**有効**）。
///   ⌃を長押しして矢印、はOSに先取りされるので、この案は成立しない
/// - `⌃↑`（Mission Control）`⌃↓`（App Exposé）も同様
/// - `⌥`＋矢印は文字入力で「単語単位の移動」に使う
/// → 窓が開いていて、検索欄が空のときだけ **← →** をそのまま使う。
///   修飾キーが無ければ誰とも取り合いにならない。
public enum ShelfFocus {

    /// 矢印を押したときの次の位置。
    /// - Parameters:
    ///   - current: いまの位置（まだ棚に入っていなければ nil）
    ///   - count: 棚に並んでいる数
    ///   - step: +1 が右、-1 が左
    /// - Returns: 次の位置。棚が空なら nil
    ///
    /// ⚠️ 端で止めずに回す（右端の次は左端）。数が少ないので、行き止まりを作るより回した方が速い。
    public static func move(from current: Int?, count: Int, step: Int) -> Int? {
        guard count > 0 else { return nil }
        guard let current else {
            // まだ棚に入っていない＝右なら先頭、左なら末尾から入る
            return step > 0 ? 0 : count - 1
        }
        let next = (current + step) % count
        return next < 0 ? next + count : next
    }

    /// いまの位置が棚の中に収まっているか（棚の中身が減ったときの取りこぼしを防ぐ）
    public static func valid(_ index: Int?, count: Int) -> Int? {
        guard let index, index >= 0, index < count else { return nil }
        return index
    }
}
