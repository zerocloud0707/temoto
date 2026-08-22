import Foundation

/// 文字が地に対して読めるかどうかを、目でなく数字で確かめるための道具。
///
/// なぜ要るのか（2026-07-29 作者「デザインすごく見づらくなった。改善して。」）。
/// すりガラスの窓に `.secondaryLabelColor` / `.tertiaryLabelColor` を並べたところ、
/// 下の帯の「実行」「移動」「閉じる」が読めなくなった。あの手の系統色は
/// **塗りつぶした地**の上で読める濃さに作られていて、半透明の地では地に負ける。
/// 目で見て決めた濃さは、次に誰かが少し薄くしたときに黙って壊れる。数字で縛る。
///
/// ⚠️ ここは AppKit を持ち込まない（TemotoCore は AppKit 非依存＝検証にかけられる）。
/// 実際の色は `Theme.Palette` が AppKit の NSColor に組み立てるが、
/// **濃さの数字はこのファイルが正**とし、Theme はここから読むだけにする。
public enum Contrast {

    // MARK: - 明るさの計算（WCAG 2.1 の定義そのまま）

    /// sRGB の値（0…1）を、人の目の感じ方に直した明るさに変換する。
    ///
    /// 灰色だけを扱う。テモトの文字は黒か白の重ねで、窓の地も色味のない曇りガラスなので、
    /// 赤緑青を別々に持つ必要がない。
    public static func luminance(gray: Double) -> Double {
        let c = min(max(gray, 0), 1)
        if c <= 0.04045 { return c / 12.92 }
        return pow((c + 0.055) / 1.055, 2.4)
    }

    /// 2つの明るさの比。1.0 が「見分けが付かない」、21.0 が「黒と白」。
    ///
    /// 読める目安（WCAG AA）:
    ///   - ふつうの大きさの文字 … 4.5 以上
    ///   - 大きい文字・枠線     … 3.0 以上
    public static func ratio(_ a: Double, _ b: Double) -> Double {
        let la = luminance(gray: a)
        let lb = luminance(gray: b)
        let hi = max(la, lb)
        let lo = min(la, lb)
        return (hi + 0.05) / (lo + 0.05)
    }

    /// 半透明の色を地に重ねたときの見た目の明るさ。
    ///
    /// - Parameters:
    ///   - overlay: 重ねる色（黒なら 0、白なら 1）
    ///   - alpha: どれだけ効かせるか（0…1）
    ///   - backdrop: 下にある地の明るさ
    public static func composite(overlay: Double, alpha: Double, on backdrop: Double) -> Double {
        let a = min(max(alpha, 0), 1)
        return overlay * a + backdrop * (1 - a)
    }

    // MARK: - 窓の地がどれくらいの明るさになりうるか

    /// すりガラス＋覆い（`BackdropView`）を通したあと、窓の地が取りうる明るさの幅。
    ///
    /// ⚠️ これは**測定値ではなく見積もり**。macOS の材質が背後をどう混ぜるかは公開されていないので、
    /// 「覆い（明=白0.55／暗=黒0.28）を通したあとに残る背後の影響」を安全側に見た値を置いている。
    /// 実機で明らかに違ったらここを直す。直したら、下の検証がそのまま新しい条件で回る。
    public enum Backdrop {
        /// 覆いの濃さ。`BackdropView` が実際に敷く値もここから読む
        /// （見積もりと実物が別々の数字になっていたら、検証は何も守っていない）。
        ///
        /// ⚠️ 薄くすると背後の模様が透けて文字が読めなくなり、
        /// 濃くすると窓が板になってすりガラスの意味が無くなる。動かすなら下の幅も直すこと
        /// ⚠️ 2026-07-30 作者「ほとんどデザイン変わってないよ」を受けて 0.55/0.28 → 0.45/0.20。
        /// macOS 26 らしさの正体は**ガラスの透け**で、覆いが濃いと板に見える。
        /// これ以上薄くすると背後の模様で文字が死ぬので、検証の下限ちょうどに置く
        public static let veilLightAlpha = 0.45
        public static let veilDarkAlpha = 0.20

        /// 明るい見た目のとき。いちばん暗くなるのは、真っ黒な画面の上に出したとき
        /// （覆いを薄くしたぶん、想定の幅も広げ直した。ここを直さず覆いだけ薄くすると検証が嘘になる）
        public static let lightDarkest = 0.61
        public static let lightBrightest = 1.00

        /// 暗い見た目のとき。いちばん明るくなるのは、真っ白な画面（表計算など）の上に出したとき
        public static let darkDarkest = 0.08
        public static let darkBrightest = 0.40
    }

    // MARK: - 文字の濃さ

    /// 明るいとき／暗いときで、黒または白をどれだけ効かせるか。
    ///
    /// 明るいときは黒を、暗いときは白を重ねる。数字はすべてここに集める
    /// （3か所に散らばった濃さは、必ずいつか食い違う）。
    public struct Tone: Sendable, Equatable {
        public let light: Double
        public let dark: Double

        public init(light: Double, dark: Double) {
            self.light = light
            self.dark = dark
        }

        /// この濃さで、地の明るさが `backdrop` のときの見た目の明るさ
        public func gray(on backdrop: Double, isDark: Bool) -> Double {
            Contrast.composite(overlay: isDark ? 1 : 0,
                               alpha: isDark ? dark : light,
                               on: backdrop)
        }

        /// 想定しうる地のすべての明るさのうち、いちばん読みにくいときの比。
        ///
        /// 端だけ見れば足りる（重ねた明るさも比も、地の明るさに対して単調に動くため）。
        public var worstRatio: Double {
            let candidates: [(Double, Bool)] = [
                (Backdrop.lightDarkest, false),
                (Backdrop.lightBrightest, false),
                (Backdrop.darkDarkest, true),
                (Backdrop.darkBrightest, true),
            ]
            return candidates.map { backdrop, isDark in
                Contrast.ratio(gray(on: backdrop, isDark: isDark), backdrop)
            }.min() ?? 0
        }
    }

    /// すりガラスの窓で使う濃さの一覧。`Theme.Palette` はここから読む。
    public enum Tones {
        /// 題名・入力した文字など、いちばん読ませたいもの。
        /// macOS の `.labelColor` と同じ濃さ（あれはこの用途なら半透明の地でも十分に足りる）
        public static let primary = Tone(light: 0.85, dark: 1.00)

        /// 副題・キーの説明・状態など、主役ではないが**読めないと困る**もの。
        ///
        /// ⚠️ `.secondaryLabelColor`（黒の約0.50）にすると 3.3 まで落ちて読めなくなる。
        /// ⚠️ `.tertiaryLabelColor`（黒の約0.26）だと 1.8。ほぼ消える。
        /// 実際に作者の画面で消えたのがこの2つ。
        ///
        /// 0.62 / 0.72 だと最悪 4.69 で、目安の 4.5 とほとんど差が無い。
        /// 一度「見づらい」と言われている以上、ぎりぎりを狙う場面ではないので一段濃くする
        public static let caption = Tone(light: 0.76, dark: 0.84)
        // ⚠️ 2026-07-30 覆いを薄くした（ガラスの透けを出した）ぶん、文字は濃くして読みを守る。
        // 透けと文字の濃さはトレードオフ＝片方を動かしたらもう片方も動かす

        /// 読ませるためではなく、間を持たせるためのもの（空の一覧に出す大きな記号など）。
        /// ここだけは 4.5 を求めない
        public static let faint = Tone(light: 0.34, dark: 0.40)

        /// 仕切り線。
        /// ⚠️ 文字ではないので 4.5 は求めないが、**線と分かる程度には見えていること**
        /// （`Threshold.visibleEdge = 1.5`）を要求する。
        /// 0.14/0.16 だと最悪 1.32 で届かない。0.22/0.20 で最悪 1.55（2026-08-23 実測）
        public static let separatorLine = Tone(light: 0.22, dark: 0.20)

        /// キーの札の枠。文字ではないので 4.5 は求めないが、
        /// **枠と分かる程度には見えていること**を要求する（見えない枠を描く意味はない）
        public static let keyCapEdge = Tone(light: 0.24, dark: 0.24)

        /// キーの札の地色。枠より薄くてよい（枠が輪郭を作るため）。
        /// ⚠️ 0.08 は Apple macOS 26 UI Kit の実測値（Fills/Secondary＝ボタンの標準の塗り。
        /// 2026-07-30 に .sketch を解剖して確認。明暗とも同じ濃さなのも Apple の流儀）。
        /// 枠 0.24 が輪郭を作るので、過去に「薄すぎて消えた」0.07+枠0.14 の事故とは条件が違う
        public static let keyCapFill = Tone(light: 0.08, dark: 0.08)

        /// アイコンの下に敷く四角。ボタン（0.08=Secondary）より一段濃い 0.10（=AppleのPrimary）。
        /// ⚠️ 2026-07-30 ガラスを透けさせたら「アイコンの視認性を上げて」（作者）。
        /// 押せるもの（ボタン）より、見分けるもの（アイコン）の方が地の強さが要る
        public static let iconTile = Tone(light: 0.10, dark: 0.10)

        /// アイコンの下敷きの立体感。iconTile を中心にわずかに振って「上から光が当たった札」にする。
        /// 平らな一色だと「灰色の四角」、わずかな勾配だと「磨いた札」に見える。
        /// ⚠️ 明暗で数字の向きが逆なのは、暗い見た目は白を・明るい見た目は黒を重ねるため。
        /// どちらも「上が明るい」を作っている（明るい見た目で黒を上に濃く塗ると、へこんで見える）。
        /// ⚠️ 振れ幅を大きくしない。0.1を超える勾配は2010年代の「テカり」になる
        public static let iconTileTop = Tone(light: 0.06, dark: 0.14)
        public static let iconTileBottom = Tone(light: 0.12, dark: 0.07)

        /// 窓の上端に敷く1本の光（ガラスの端が光を拾う表現）。
        /// 暗い見た目でだけ効かせる（明るい地では白い線は見えず、ただのゴミになる）
        public static let topGlint = Tone(light: 0.0, dark: 0.22)

        /// キーの札（⏎・⌘C・⌘1）の勾配。keyCapFill（0.08）を中心に振る。
        /// アイコンの下敷きと**同じ「磨いた札」の材質**をひとまわり控えめにしたもの。
        /// 押せるもの（0.08中心）と見分けるもの（0.10中心）の濃さの区別はそのまま保つ
        public static let keyCapTop = Tone(light: 0.05, dark: 0.11)
        public static let keyCapBottom = Tone(light: 0.11, dark: 0.05)

        /// 下の帯の沈み。⚠️ ここだけ「黒」をそのまま重ねる（他のToneと逆）。
        /// 道具の足元をわずかに沈ませて、操作の帯に「土台」の座りを作る。
        /// 明るい見た目では0＝沈ませない（説明文の読みやすさ4.5の余白が薄く、
        /// 黒を重ねる余裕が無い。明るいガラスでは区切り線だけで足りる）
        public static let footerShade = Tone(light: 0.0, dark: 0.16)
    }

    /// 読める目安。
    public enum Threshold {
        /// ふつうの大きさの文字（WCAG AA）
        public static let readableText = 4.5
        /// 枠として見分けが付く最低限。
        /// ⚠️ WCAG の 3.0 ではなく 1.5 にしているのは、キーの札の枠は
        /// **中の文字が主役で、枠は輪郭を添えるだけ**のため。
        /// それでも下限を置くのは、薄くしていって黙って消えた前科があるから
        public static let visibleEdge = 1.5
    }
}
