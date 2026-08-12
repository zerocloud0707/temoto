import Foundation

/// 初めて使う人に、最初の1つだけを伝えるための決まりごと。
///
/// 2026-08-06 作者「掲載することができる構成、内容、質が高い内容にしたい。」
/// → 配る相手のことを考えると、いまの初回起動は成立していない。実測すると:
///   ① macOS のアクセシビリティ許可ダイアログが**何の説明もなく**出る
///   ② 「⌥Space で検索窓が開きます」のトーストが**数秒で消える**
/// これだけ。見逃したら、窓の出し方をもう知る機会が無い。
/// 常駐アプリなので、入れた人は「何も起きないアプリ」を見ることになる。
///
/// ⚠️ **新しい窓は作らない。**
/// 「窓は増やさない。増えるのは行き先だけ」がこの製品の芯（LauncherMode の冒頭）。
/// 案内窓を足すと、窓の数を数えている検証も、閉じ方の決まりも、全部書き換えることになる。
/// 代わりに**本物の検索窓の中に帯を1枚**出す。置き場所はアプリの棚と同じ場所で、
/// 棚は既定では空（appBindings が空）＝初回はその66ptが丸ごと空いている。
///
/// ⚠️ 伝えるのは**1つだけ**。「この窓を出すキー」。
/// 機能の一覧は窓の中に既に並んでいるので、帯で二度説明しない
/// （2026-08-05「色々と情報が多くなりすぎている気がする」）。
///
/// ⚠️ 時間で消さない。**実際にキーを押せたら**消す。
/// 時間で消すと「読み終える前に消えた人」が救われない。押せた人だけが卒業する。
public enum Welcome {

    /// 帯を出し続ける上限。これを超えたら諦めて出さない。
    /// ⚠️ 上限を切る理由。押さない人に永遠に出し続けるのは、案内ではなく小言になる。
    public static let maxShows = 5

    /// 帯を出すか。
    /// - Parameters:
    ///   - done: もうキーを押せた（卒業した）か
    ///   - shows: これまでに帯を出した回数
    public static func shouldShowBand(done: Bool, shows: Int, maxShows: Int = Welcome.maxShows) -> Bool {
        !done && shows < maxShows
    }

    /// 起動した直後に、こちらから窓を開けるか。
    ///
    /// ⚠️ **いちばん最初の1回だけ**。毎回勝手に窓が開くアプリは邪魔者になる。
    /// 2回目以降は、開いたときに帯が出る（自分で開いた人には邪魔にならない）。
    public static func shouldOpenOnLaunch(done: Bool, shows: Int) -> Bool {
        !done && shows == 0
    }

    /// 帯に何を出すか
    public enum BandContent: Equatable, Sendable {
        /// 窓を出すキーを教える（ふつう）
        case key(String)
        /// そのキーが他のアプリに取られていて登録できていない＝決め直してもらう
        case reassign
    }

    /// - Parameters:
    ///   - shortcutLabel: いま設定されているキーの見た目（`⌥Space` など）
    ///   - keyFailed: そのキーを登録できなかった（他のアプリが握っている）
    ///
    /// ⚠️ 押しても出ないキーを教えない。
    /// 「⌘Space で開きます」と書いてあるのに Spotlight が出る、が起きると、
    /// 人はアプリが壊れていると判断してそれきりになる。
    public static func bandContent(shortcutLabel: String, keyFailed: Bool) -> BandContent {
        if keyFailed || shortcutLabel.trimmingCharacters(in: .whitespaces).isEmpty {
            return .reassign
        }
        return .key(shortcutLabel)
    }

    /// 卒業のきっかけ
    public enum Trigger: Equatable, Sendable {
        /// 窓を出すキーを押した（開いたときも、閉じたときも。どちらも押せた証拠）
        case launcherHotkey
        /// 他の機能のキー（コピー履歴・定型文・メモ）を押した
        case otherHotkey
        /// メニューバーから開いた
        case menu
    }

    /// 卒業するか（＝もう帯を出さないか）。
    ///
    /// ⚠️ 「窓を出すキーを押せた」ときだけ。
    /// メニューバーから開けた人は、まだキーを知らない（そこがいちばん教えたいこと）。
    /// 他の機能のキーを押せた人も、入口のキーは別なので卒業させない。
    public static func graduates(on trigger: Trigger) -> Bool {
        trigger == .launcherHotkey
    }

    // MARK: - 画面に出す言葉
    //
    // ⚠️ キーの文字だけは、ここに書かない。
    // 既定は ⌥Space だが、作者は ⌘Space に変えている。
    // 直書きすると「画面の案内と実際のキーが違う」という、いちばんたちの悪い嘘になる。
    // 必ず settings.launcherShortcut.displayString を渡すこと。

    public static let keyTitle = "この窓を出すキー"
    public static let keySubtitle = "どのアプリを使っているときでも押せます"

    public static let reassignTitle = "窓を出すキーを決め直す"
    public static let reassignSubtitle = "いまのキーは他のアプリに取られています"

    /// 帯の右に小さく置く一文。
    /// ⚠️ 通信ゼロはこの製品のいちばんの取り柄なのに、どこにも書いていなかった。
    /// 履歴を預けてよいか迷っている人は、これが読めるかどうかで判断する。
    public static let privacyLine = "打った言葉も、コピーの中身も、どこにも送りません"

    /// 卒業したときに1回だけ出す言葉
    public static let graduatedToast = "それです。これでいつでも出せます。"

    /// もう一度読みたい人のための入口（メニューバー・検索・設定で共通の呼び名）
    public static let revisitTitle = "テモトの使い方"
    public static let revisitSubtitle = "この窓を出すキーを、もう一度出します"

    /// 検索で「使い方」を引くための言い換え
    public static let revisitAliases = [
        "tsukaikata", "つかいかた", "使い方", "はじめかた", "始め方",
        "ヘルプ", "help", "案内", "welcome", "guide", "説明",
    ]
}
