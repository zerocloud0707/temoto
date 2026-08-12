import Foundation

/// 棚のアプリを、検索窓が開いている間だけ数字で開くための決まり。
///
/// 2026-08-04 作者「この画面でアプリごとのショートカットも表示して欲しい。
/// 例えばこの画面が表示されているときはコントロールと数字を入力したらアプリが開くみたいな。」
///
/// ⚠️ 行き先が ⌘1〜⌘6 なので、棚は **⌃1〜⌃9** にする。
/// 同じ数字でも修飾キーが違えば別物＝「⌘は行き先・⌃は棚」と1度で覚えられる。
/// ⌥ は使わない（⌥Space が窓を開くキーなので、⌥は「窓そのもの」の担当にしておく）。
///
/// ⚠️ この番号は**窓が開いている間だけ**の話。世界中どこでも効く「アプリのキー」とは別物で、
/// あちらは設定で1つずつ選ぶ。ここは並び順で決まるので、棚の順番が変われば番号も変わる。
public enum ShelfKeys {

    /// 数字で開けるのは9個まで（0は「10番目」に見えないので使わない）
    public static let maxCount = 9

    /// 何番目に、どの札を出すか（画面に出す文字）
    public static func label(forIndex index: Int) -> String? {
        guard index >= 0, index < maxCount else { return nil }
        return "⌃\(index + 1)"
    }

    /// 押された文字が何番目を指すか。範囲の外なら nil
    public static func index(forCharacter character: String, count: Int) -> Int? {
        guard let number = Int(character), number >= 1, number <= maxCount else { return nil }
        let index = number - 1
        return index < count ? index : nil
    }
}
