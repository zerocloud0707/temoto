import CoreGraphics
import CryptoKit
import Foundation
import TemotoCore

// Xcodeが無い環境（Command Line Toolsのみ）ではXCTestが使えないため、
// 自前のテストランナーで検証する。CapsAwakeで実績のある方式。

var failures: [String] = []
var passed = 0

func section(_ title: String) {
    print("")
    print("── \(title)")
}

func expect(_ condition: Bool, _ what: String) {
    if condition {
        passed += 1
        print("  ok   \(what)")
    } else {
        failures.append(what)
        print("  NG   \(what)")
    }
}

func expectEqual<T: Equatable>(_ actual: T, _ expected: T, _ what: String) {
    if actual == expected {
        passed += 1
        print("  ok   \(what)")
    } else {
        failures.append(what)
        print("  NG   \(what)")
        print("       期待: \(expected)")
        print("       実際: \(actual)")
    }
}

func expectThrows(_ what: String, _ body: () throws -> Void) {
    do {
        try body()
        failures.append(what)
        print("  NG   \(what)（例外が出なかった）")
    } catch {
        passed += 1
        print("  ok   \(what)")
    }
}

// MARK: - 座標系の変換
//
// ここを間違えるとウィンドウが画面外へ飛ぶ。実機で採取した値をそのまま使って検証する。
//   NSScreen[0] frame=(0,0,1710,1112) visibleFrame=(0,0,1710,1073)  ← Cocoa座標
//   最大化したウィンドウの kAXPosition/kAXSize = (0,39) 1710x1073   ← AX座標

func checkCoordinates() {
    section("座標系の変換（Cocoa ⇄ Accessibility）")

    let primaryHeight: CGFloat = 1112
    let cocoaVisible = CGRect(x: 0, y: 0, width: 1710, height: 1073)
    let ax = Geometry.axRect(fromCocoa: cocoaVisible, primaryHeight: primaryHeight)

    expectEqual(ax, CGRect(x: 0, y: 39, width: 1710, height: 1073),
                "実機で採取したvisibleFrameがAX座標のウィンドウ枠と一致する")

    let back = Geometry.cocoaRect(fromAX: ax, primaryHeight: primaryHeight)
    expectEqual(back, cocoaVisible, "2回通すと元に戻る")

    // 主ディスプレイの上に置いた副ディスプレイ。AX座標では y が負になる。
    let above = CGRect(x: 0, y: 1112, width: 1920, height: 1080)
    expectEqual(Geometry.axRect(fromCocoa: above, primaryHeight: primaryHeight),
                CGRect(x: 0, y: -1080, width: 1920, height: 1080),
                "主ディスプレイより上の画面はAX座標でyが負になる")

    // 主ディスプレイの左に置いた副ディスプレイ。xは変換しない。
    let left = CGRect(x: -1920, y: 0, width: 1920, height: 1080)
    expectEqual(Geometry.axRect(fromCocoa: left, primaryHeight: primaryHeight).minX, -1920,
                "xは変換しない")
}

// MARK: - ウィンドウ分割の計算

func checkLayout() {
    section("ウィンドウ分割の計算")

    let visible = CGRect(x: 0, y: 39, width: 1710, height: 1073)

    func target(_ layout: WindowLayout) -> CGRect? {
        Geometry.targetFrame(for: layout, visible: visible)
    }

    guard let left = target(.leftHalf), let right = target(.rightHalf) else {
        failures.append("左右半分が計算できない")
        return
    }
    expectEqual(left, CGRect(x: 0, y: 39, width: 855, height: 1073), "左半分")
    expectEqual(right, CGRect(x: 855, y: 39, width: 855, height: 1073), "右半分")
    expectEqual(left.maxX, right.minX, "左半分と右半分の境界が一致する（隙間も重なりも無い）")
    expectEqual(left.width + right.width, visible.width, "左右を足すと画面幅ちょうど")

    // 奇数幅でも隙間ができないこと（丸め方の検証）
    let odd = CGRect(x: 0, y: 0, width: 1001, height: 600)
    guard let ol = Geometry.targetFrame(for: .leftHalf, visible: odd),
          let or = Geometry.targetFrame(for: .rightHalf, visible: odd) else {
        failures.append("奇数幅で計算できない")
        return
    }
    expectEqual(ol.maxX, or.minX, "奇数幅でも境界が一致する")
    expectEqual(ol.width + or.width, 1001, "奇数幅でも合計が画面幅と一致する")

    // 3分割（幅が3で割り切れない場合）
    let w1000 = CGRect(x: 0, y: 0, width: 1000, height: 600)
    guard let t1 = Geometry.targetFrame(for: .leftThird, visible: w1000),
          let t2 = Geometry.targetFrame(for: .centerThird, visible: w1000),
          let t3 = Geometry.targetFrame(for: .rightThird, visible: w1000) else {
        failures.append("3分割が計算できない")
        return
    }
    expectEqual(t1.maxX, t2.minX, "左1/3と中央1/3の境界が一致する")
    expectEqual(t2.maxX, t3.minX, "中央1/3と右1/3の境界が一致する")
    expectEqual(t1.width + t2.width + t3.width, 1000, "3分割の合計が画面幅と一致する")

    // 4分割
    guard let tl = target(.topLeft), let tr = target(.topRight),
          let bl = target(.bottomLeft), let br = target(.bottomRight) else {
        failures.append("4分割が計算できない")
        return
    }
    expectEqual(tl.maxX, tr.minX, "左上と右上の境界が一致する")
    expectEqual(tl.maxY, bl.minY, "左上と左下の境界が一致する")
    expectEqual(tl.height + bl.height, visible.height, "上下を足すと画面高さちょうど")
    expectEqual(br.maxX, visible.maxX, "右下の右端が画面の右端と一致する")
    expectEqual(br.maxY, visible.maxY, "右下の下端が画面の下端と一致する")

    expectEqual(target(.maximize), visible, "最大化は作業領域そのもの")

    // 中央寄せ
    let current = CGRect(x: 10, y: 10, width: 800, height: 600)
    expectEqual(Geometry.targetFrame(for: .center, visible: visible, current: current),
                CGRect(x: 455, y: 276, width: 800, height: 600),
                "中央寄せは大きさを変えずに真ん中へ")

    // 画面より大きいウィンドウを中央寄せしたら作業領域に収める
    let huge = CGRect(x: -500, y: -500, width: 3000, height: 2000)
    expectEqual(Geometry.targetFrame(for: .center, visible: visible, current: huge),
                visible,
                "画面より大きいウィンドウは作業領域まで縮める")

    // 元に戻す
    let previous = CGRect(x: 100, y: 200, width: 640, height: 480)
    expectEqual(Geometry.targetFrame(for: .restore, visible: visible, previous: previous),
                previous, "元のサイズに戻す")
    expect(Geometry.targetFrame(for: .restore, visible: visible) == nil,
           "戻す先が無ければ何もしない")
    expect(Geometry.targetFrame(for: .center, visible: visible) == nil,
           "現在の枠が分からなければ中央寄せしない")

    // どのレイアウトでも作業領域からはみ出さない
    var allInside = true
    for layout in WindowLayout.allCases where layout != .center && layout != .restore {
        guard let f = Geometry.targetFrame(for: layout, visible: visible) else {
            allInside = false
            continue
        }
        if f.minX < visible.minX || f.minY < visible.minY
            || f.maxX > visible.maxX || f.maxY > visible.maxY
            || f.width <= 0 || f.height <= 0 {
            print("       はみ出し: \(layout) → \(f)")
            allInside = false
        }
    }
    expect(allInside, "全レイアウトが作業領域の内側に収まる（\(WindowLayout.allCases.count - 2)種類）")

    expectEqual(WindowLayout.allCases.count, 17, "レイアウトは17種類")
    expect(WindowLayout.allCases.allSatisfy { !$0.title.isEmpty }, "全レイアウトに日本語の名前がある")
}

// MARK: - 画面の判定と画面間の移動

func checkScreens() {
    section("画面の判定と画面間の移動")

    let screen0 = CGRect(x: 0, y: 0, width: 1710, height: 1112)
    let screen1 = CGRect(x: 1710, y: 0, width: 1920, height: 1080)
    let screens = [screen0, screen1]

    // 境界をまたぐウィンドウは、より多く重なっている方
    let straddling = CGRect(x: 1650, y: 100, width: 100, height: 100)
    expectEqual(Geometry.bestScreenIndex(for: straddling, screens: screens), 0,
                "境界をまたぐウィンドウは重なりが大きい画面に属する")

    expectEqual(Geometry.bestScreenIndex(for: CGRect(x: 2000, y: 100, width: 400, height: 300),
                                         screens: screens), 1,
                "副ディスプレイ上のウィンドウ")

    // 画面構成が変わってどの画面にも乗っていない場合
    expectEqual(Geometry.bestScreenIndex(for: CGRect(x: 5000, y: 5000, width: 100, height: 100),
                                         screens: screens), 1,
                "どの画面にも乗っていなければ中心が近い画面へ")

    expect(Geometry.bestScreenIndex(for: straddling, screens: []) == nil,
           "画面が無ければ nil")

    // 相対位置を保った移動（screen0 のちょうど真ん中に置いた 400x300）
    let centered = CGRect(x: 655, y: 406, width: 400, height: 300)
    expectEqual(CGPoint(x: centered.midX, y: centered.midY),
                CGPoint(x: screen0.midX, y: screen0.midY),
                "検証用のウィンドウが元の画面の真ん中にある")
    let moved = Geometry.movedProportionally(centered, from: screen0, to: screen1)
    expect(moved.minX >= screen1.minX && moved.maxX <= screen1.maxX
            && moved.minY >= screen1.minY && moved.maxY <= screen1.maxY,
           "移動先の画面からはみ出さない")
    expect(abs(moved.midX - screen1.midX) <= 1 && abs(moved.midY - screen1.midY) <= 1,
           "元の画面の真ん中にあったものは移動先でも真ん中")

    // 隅にあるウィンドウ（丸めで1pxはみ出しやすい）
    let corner = Geometry.movedProportionally(
        CGRect(x: 1610, y: 1012, width: 100, height: 100), from: screen0, to: screen1)
    expect(corner.maxX <= screen1.maxX && corner.maxY <= screen1.maxY,
           "右下隅のウィンドウも移動先からはみ出さない")

    // 移動先が小さい場合
    let small = CGRect(x: 0, y: 0, width: 800, height: 600)
    let shrunk = Geometry.movedProportionally(screen0, from: screen0, to: small)
    expect(shrunk.width <= small.width && shrunk.height <= small.height,
           "解像度の低い画面へ移すと収まるまで縮む")

    expectEqual(Geometry.neighborScreenIndex(from: 0, count: 2, step: 1), 1, "次の画面")
    expectEqual(Geometry.neighborScreenIndex(from: 1, count: 2, step: 1), 0, "次の画面（一周する）")
    expectEqual(Geometry.neighborScreenIndex(from: 0, count: 2, step: -1), 1, "前の画面（一周する）")
    expectEqual(Geometry.neighborScreenIndex(from: 1, count: 3, step: 1), 2, "3画面での次")
    expect(Geometry.neighborScreenIndex(from: 0, count: 1, step: 1) == nil,
           "画面が1枚なら移動しない")
}

// MARK: - あいまい検索

func checkFuzzy() {
    section("あいまい検索")

    expect(FuzzyMatcher.match(query: "さふぁり", in: "サファリ") != nil,
           "ひらがなで打ってカタカナに当たる")
    expect(FuzzyMatcher.match(query: "ｇｉｔ", in: "GitHub") != nil,
           "全角で打っても半角に当たる")
    expect(FuzzyMatcher.match(query: "GIT", in: "github.com") != nil,
           "大文字小文字は区別しない")
    expect(FuzzyMatcher.match(query: "しはらい", in: "本日支払一覧") == nil,
           "読みがなでは漢字に当たらない（変換辞書は持たない）")
    expect(FuzzyMatcher.match(query: "支払", in: "本日支払一覧") != nil,
           "漢字そのままなら当たる")
    expect(FuzzyMatcher.match(query: "zzz", in: "GitHub") == nil, "無関係なら当たらない")
    expect(FuzzyMatcher.match(query: "githubb", in: "GitHub") == nil,
           "候補より長い入力は当たらない")

    // 強調表示用の添字が元の文字列とずれない
    if let r = FuzzyMatcher.match(query: "gh", in: "GitHub") {
        expectEqual(r.matchedIndices, [0, 3], "一致位置が元の文字列の添字と対応する")
    } else {
        failures.append("GitHub に gh が当たらない")
    }
    if let r = FuzzyMatcher.match(query: "さり", in: "サファリ") {
        expectEqual(r.matchedIndices, [0, 3], "カタカナでも一致位置がずれない")
    } else {
        failures.append("サファリ に さり が当たらない")
    }

    // 並び順
    func best(_ query: String, _ names: [String]) -> String? {
        FuzzyMatcher.rank(names, query: query, key: { $0 }).first?.item
    }
    expectEqual(best("no", ["Keynote", "Notion"]), "Notion", "先頭一致を優先する")
    expectEqual(best("abc", ["axbxcx", "abcdef"]), "abcdef", "連続一致を優先する")
    expectEqual(best("ログ", ["作業ログ ABC", "ダイアログ設定"]), "作業ログ ABC",
                "語の切れ目に近い方を優先する")
    expectEqual(FuzzyMatcher.rank(["zzz test", "aaa test"], query: "test", key: { $0 })
                    .first?.item,
                "aaa test",
                "同点なら名前順（起動のたびに並びが変わらない）")

    expectEqual(FuzzyMatcher.rank(["b", "a"], query: "  ", key: { $0 }).map { $0.item },
                ["b", "a"],
                "入力が空なら元の順番のまま全部返す")
    expectEqual(FuzzyMatcher.rank(["Safari", "Notion", "GitHub"], query: "zzz", key: { $0 }).count,
                0,
                "当たらない候補は除外する")

    // 畳み込みは必ず1文字→1文字（添字がずれないための前提）
    let samples = ["ＧitＨub", "サファリ", "abc DEF", "日本語テキスト", "１２３"]
    expect(samples.allSatisfy { FuzzyMatcher.fold($0).count == $0.count },
           "畳み込みで文字数が変わらない")
}

// MARK: - 日本語で探す（テモトを作った理由）

func checkJapaneseReading() {
    section("日本語で探す — IME を切り替えずに漢字の項目を引く")

    // 読みを作る対象の見極め＝「英字キーボードで打てない字を含むか」
    expect(JapaneseReading.needsReading("定型文"), "漢字を含むなら読みを作る")
    expect(JapaneseReading.needsReading("作業ログ"), "漢字が混じっていれば作る")
    expect(JapaneseReading.needsReading("々"), "々 も漢字として扱う")
    expect(JapaneseReading.needsReading("メモ"), "カタカナだけでも作る（memo と打ちたいので）")
    expect(JapaneseReading.needsReading("ですます"), "ひらがなだけでも作る")
    expect(!JapaneseReading.needsReading("Safari"), "英字だけなら作らない（費用の割に得が無い）")
    expect(!JapaneseReading.needsReading("Google Chrome 2"), "英数と空白だけなら作らない")
    expect(!JapaneseReading.needsReading(""), "空文字で作らない")

    // ローマ字化
    expectEqual(JapaneseReading.romaji(of: "定型文"), "teikeibun", "定型文 → teikeibun")
    expectEqual(JapaneseReading.romaji(of: "設定"), "settei", "設定 → settei")
    expect(JapaneseReading.romaji(of: "履歴").contains("rireki"), "履歴 → rireki")
    // ⚠️ ICU の Any-Latin だと漢字が中国語のピンインになる。ここが ding にならないこと
    expect(!JapaneseReading.romaji(of: "定型文").hasPrefix("ding"),
           "中国語読み（ピンイン）にならない")

    // 記号の混じった読みを素の英字にそろえる
    expectEqual(JapaneseReading.normalizeRomaji("kopīrireki"), "kopirireki",
                "伸ばし記号を落とす")
    expectEqual(JapaneseReading.normalizeRomaji("u~indou"), "uindou", "波を落とす")
    expectEqual(JapaneseReading.normalizeRomaji("Ｇit Hub"), "github", "全角と空白を落とす")
    expect(JapaneseReading.normalizeRomaji("あいう").isEmpty, "英字でないものは残さない")

    // ローマ字 → ひらがな
    expectEqual(JapaneseReading.hiragana(ofRomaji: "teikeibun"), "ていけいぶん",
                "teikeibun → ていけいぶん")
    expect(JapaneseReading.hiragana(ofRomaji: "").isEmpty, "空なら空を返す")

    // 別名（順番が揺れると同じ入力で結果が変わって見える）
    let keys = JapaneseReading.keys(for: "定型文")
    expectEqual(keys.count, 2, "別名はローマ字とひらがなの2つ")
    expectEqual(keys.first, "teikeibun", "1つ目はローマ字で固定")
    expectEqual(keys.last, "ていけいぶん", "2つ目はひらがなで固定")
    expect(JapaneseReading.keys(for: "Safari").isEmpty, "英字だけなら別名を作らない")
    expectEqual(JapaneseReading.keys(for: "メモ").first, "memo", "メモ の別名は memo")

    // ここが本題 — 作者「UIが英語しか対応していない」への答え
    func hit(_ query: String, _ name: String) -> Bool {
        FuzzyMatcher.match(query: query, in: name, aliases: JapaneseReading.keys(for: name)) != nil
    }
    expect(hit("teikei", "定型文"), "teikei で 定型文 に当たる（IME を切り替えなくてよい）")
    expect(hit("ていけい", "定型文"), "ていけい で 定型文 に当たる")
    expect(hit("テイケイ", "定型文"), "テイケイ で 定型文 に当たる")
    expect(hit("定型", "定型文"), "漢字そのままでも当たる")
    expect(hit("settei", "設定"), "settei で 設定 に当たる")
    expect(hit("rireki", "コピー履歴"), "rireki で コピー履歴 に当たる")
    expect(hit("りれき", "コピー履歴"), "りれき で コピー履歴 に当たる")
    expect(hit("こぴー", "コピー履歴"), "こぴー で コピー履歴 に当たる（伸ばし記号ごと）")
    expect(hit("めも", "メモ"), "めも で メモ に当たる")
    expect(hit("memo", "メモ"), "memo で メモ に当たる")
    expect(hit("gamen", "画面をまたぐ"), "gamen で 画面をまたぐ に当たる")
    expect(!hit("zzz", "定型文"), "無関係な入力では当たらない")
    expect(!hit("zzz", "メモ"), "別名があっても無関係な入力では当たらない")

    // 読みで当たったときは色を塗らない（添字が別の文字列を指しているため）
    if let r = FuzzyMatcher.match(query: "teikei", in: "定型文",
                                  aliases: JapaneseReading.keys(for: "定型文")) {
        expect(r.matchedIndices.isEmpty, "読みで当たったら色付け位置は返さない")
    } else {
        failures.append("teikei が 定型文 に当たらない")
    }

    // 表示名そのものに当たった方を必ず上に置く。
    // ⚠️ 比べるのは「同じ入力に対する2つの候補」であること。
    // 入力が違えば点も違って当たり前なので、入力をまたいで点を比べても何も分からない。
    if let direct = FuzzyMatcher.match(query: "せってい", in: "せってい候補"),
       let alias = FuzzyMatcher.match(query: "せってい", in: "設定",
                                      aliases: JapaneseReading.keys(for: "設定")) {
        expect(direct.score > alias.score, "同じ入力なら、表示名で当たった方が読みより上に来る")
        expectEqual(direct.matchedIndices, [0, 1, 2, 3], "表示名で当たった方は色付け位置が残る")
    } else {
        failures.append("せってい の直接一致と読み一致がそろわない")
    }
    expectEqual(FuzzyMatcher.rank(["設定", "せってい候補"], query: "せってい", key: { $0 },
                                  aliases: { JapaneseReading.keys(for: $0) }).first?.item,
                "せってい候補",
                "並べ替えでも表示名で当たった方が先")

    let ranked = FuzzyMatcher.rank(
        ["定型文", "設定"], query: "settei", key: { $0 },
        aliases: { JapaneseReading.keys(for: $0) })
    expectEqual(ranked.first?.item, "設定", "settei なら 設定 が1番目")

    // 読みを使わない呼び方（既定）は今までどおり
    expectEqual(FuzzyMatcher.rank(["定型文"], query: "teikei", key: { $0 }).count, 0,
                "読みを渡さなければ英字では当たらない（既定の動きを変えない）")

    // 作り置き
    let index = ReadingIndex()
    expectEqual(index.count, 0, "作り置きは空から始まる")
    let first = index.keys(for: "定型文")
    let second = index.keys(for: "定型文")
    expectEqual(first, second, "2回目も同じ読みを返す")
    expectEqual(index.count, 1, "同じ名前で2つ覚えない")
    _ = index.keys(for: "Safari")
    expectEqual(index.count, 2, "読みが空でも覚える（毎回作り直さないため）")
    expect(index.keys(for: "Safari").isEmpty, "英字だけの名前は空のまま返す")
    index.clear()
    expectEqual(index.count, 0, "消せる")

    let small = ReadingIndex(limit: 2)
    _ = small.keys(for: "設定")
    _ = small.keys(for: "定型文")
    _ = small.keys(for: "履歴")
    expect(small.count <= 2, "上限を超えて抱え込まない")
    expectEqual(small.keys(for: "設定").first, "settei", "捨てたあとも正しい読みを返す")
}

// MARK: - クリップボードの選別（最重要）

func checkClipboardGuard() {
    section("クリップボードの選別 — 残してよいものだけ残す")

    let guardian = ClipboardGuard()
    func decide(_ text: String,
                types: [String] = ["public.utf8-plain-text"],
                bundle: String? = "com.apple.Safari",
                previous: String? = nil) -> ClipDecision {
        guardian.decide(types: types, sourceBundleID: bundle, text: text,
                        byteCount: text.utf8.count, previousText: previous)
    }

    // ── 保存してよいもの
    expectEqual(decide("お世話になっております。"), .store, "普通の文章は保存する")
    expectEqual(decide("https://github.com/search?q=test"), .store, "URLは保存する")
    expectEqual(decide("03-1234-5678"), .store, "電話番号は保存する")
    expectEqual(decide("〒100-0001"), .store, "郵便番号は保存する")
    expectEqual(decide("2026-07-28 の売上は 1,301,750 円"), .store,
                "日付と金額が並んだ文章は保存する")
    expectEqual(decide("task-management"), .store,
                "sk- を含むだけの英単語で誤検知しない")

    // 自分が最初に作った実装のバグ。区切りをまたいで数字を繋げると
    // 取引先コードを並べただけの文字列が14桁になり、10回に1回Luhnを通ってしまった。
    expectEqual(decide("1000001 1000002 1000003"), .store,
                "取引先コードを並べただけなら保存する（区切りをまたいで数字を繋げない）")
    expectEqual(decide("ABC 1000001 / GHI 1000002"), .store,
                "IDの一覧を貼っても捨てられない")

    // ── 捨てるもの: 機密フラグと除外アプリ
    expectEqual(decide("なんでもよい", types: ["org.nspasteboard.ConcealedType"]),
                .skipConcealed("org.nspasteboard.ConcealedType"),
                "機密フラグ付きは中身を見ずに捨てる")
    expectEqual(decide("なんでもよい", bundle: "com.1password.1password"),
                .skipExcludedApp("com.1password.1password"),
                "1Passwordからのコピーは中身を見ずに捨てる")
    expectEqual(decide("なんでもよい", bundle: "com.apple.keychainaccess"),
                .skipExcludedApp("com.apple.keychainaccess"),
                "キーチェーンアクセスからのコピーも捨てる")

    // ── 捨てるもの: 秘密情報
    // 本物の鍵は絶対に書かないので、その場で組み立てた偽物で検証する。
    let fakeAnthropic = "sk-" + "ant-" + "api03-" + String(repeating: "x", count: 40)
    expectEqual(decide(fakeAnthropic), .skipSecret(.apiKey("Anthropic")),
                "Anthropic形式のAPIキーを捨てる")

    let fakeAWS = "AKIA" + "IOSFODNN7EXAMPLE"
    expectEqual(decide(fakeAWS), .skipSecret(.apiKey("AWS")), "AWSのアクセスキーIDを捨てる")

    let fakeGitHub = "ghp_" + String(repeating: "A", count: 36)
    expectEqual(decide(fakeGitHub), .skipSecret(.apiKey("GitHub")),
                "GitHubのパーソナルアクセストークンを捨てる")

    let fakeStripe = "sk_live_" + String(repeating: "9", count: 24)
    expectEqual(decide(fakeStripe), .skipSecret(.apiKey("Stripe")), "Stripeの本番キーを捨てる")

    expectEqual(decide("コード中に \(fakeGitHub) が混ざっている"),
                .skipSecret(.apiKey("GitHub")),
                "文章の途中に混ざっていても捨てる")

    let fakeJWT = "eyJhbGciOiJIUzI1NiJ9"
        + ".eyJzdWIiOiIxMjM0NTY3ODkwIn0"
        + ".dBjftJeZ4CVPmB92K27uhbUJU1p1r_wW1gFWFOEjXk"
    expectEqual(decide(fakeJWT), .skipSecret(.jwt), "JWTを捨てる")
    expectEqual(decide("Authorization: Bearer \(fakeJWT)"), .skipSecret(.jwt),
                "ヘッダごとコピーしても捨てる")

    expectEqual(decide("-----BEGIN OPENSSH PRIVATE KEY-----\nabc\n-----END OPENSSH PRIVATE KEY-----"),
                .skipSecret(.privateKey), "秘密鍵を捨てる")
    expectEqual(decide("-----BEGIN RSA PRIVATE KEY-----\nabc"),
                .skipSecret(.privateKey), "RSA秘密鍵を捨てる")

    // カード番号（Luhnを通る有名なテスト番号。実在の番号ではない）
    expectEqual(decide("4111111111111111"), .skipSecret(.creditCard),
                "カード番号（区切り無し）を捨てる")
    expectEqual(decide("4111-1111-1111-1111"), .skipSecret(.creditCard),
                "カード番号（ハイフン区切り）を捨てる")
    expectEqual(decide("4111 1111 1111 1111"), .skipSecret(.creditCard),
                "カード番号（空白区切り）を捨てる")
    expect(ClipboardGuard.luhnIsValid([4, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1]),
           "Luhnの検査が通る")
    expect(!ClipboardGuard.luhnIsValid([4, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 2]),
           "1桁違えばLuhnの検査は通らない")

    // マイナンバー（検査用数字を自分で計算して確かめる。実在の番号ではない）
    let myNumber = [1, 2, 3, 4, 5, 6, 7, 8, 9, 0, 1, 8]
    expect(ClipboardGuard.myNumberIsValid(myNumber), "検査用数字の計算が仕様どおり")
    expect(!ClipboardGuard.myNumberIsValid([1, 2, 3, 4, 5, 6, 7, 8, 9, 0, 1, 7]),
           "検査用数字が違えば通らない")
    expectEqual(decide("マイナンバーは123456789018です"), .skipSecret(.myNumber),
                "マイナンバーらしき12桁を捨てる")

    // ── 捨てるもの: 自分で足した除外語
    let withPattern = ClipboardGuard(userPatterns: ["振込先", "himitsu"])
    func decideWithPattern(_ text: String) -> ClipDecision {
        withPattern.decide(types: [], sourceBundleID: nil, text: text,
                           byteCount: text.utf8.count, previousText: nil)
    }
    expectEqual(decideWithPattern("振込先は〇〇銀行です"), .skipSecret(.userPattern("振込先")),
                "自分で指定した語を含むものを捨てる")
    expectEqual(decideWithPattern("HIMITSUのメモ"), .skipSecret(.userPattern("himitsu")),
                "除外語は大文字小文字を区別しない")
    expectEqual(decideWithPattern("普通のメモ"), .store, "除外語を含まなければ保存する")

    // ── その他の理由
    expectEqual(decide("   \n\t  "), .skipEmpty, "空白だけなら保存しない")
    expectEqual(decide("同じ文字列", previous: "同じ文字列"), .skipDuplicate,
                "直前と同じなら保存しない")
    let smallGuard = ClipboardGuard(maxBytes: 10)
    expectEqual(smallGuard.decide(types: [], sourceBundleID: nil, text: "0123456789ab",
                                  byteCount: 12, previousText: nil),
                .skipTooLarge(12), "大きすぎるものは保存しない")

    // ── 捨てた理由の文言に中身そのものを含めない（ログに秘密が漏れないこと）
    let reason = ClipDecision.skipSecret(.apiKey("Anthropic")).reason
    expect(!reason.contains("sk-") && !reason.contains(fakeAnthropic),
           "捨てた理由の文言に中身そのものを含めない")
    let allReasons = [
        ClipDecision.store, .skipEmpty, .skipConcealed("t"), .skipExcludedApp("b"),
        .skipSecret(.creditCard), .skipTooLarge(1), .skipDuplicate,
    ].map(\.reason)
    expect(allReasons.allSatisfy { !$0.isEmpty }, "全ての判定に説明の文言がある")
    expect(ClipDecision.store.isStored && !ClipDecision.skipEmpty.isStored,
           "保存するかどうかの判定")
}

// MARK: - 履歴の保持ルール

func checkRetention() {
    section("履歴の保持ルール")

    let now = Date()
    func item(_ text: String, hoursAgo: Double, pinned: Bool = false) -> ClipItem {
        ClipItem(text: text, copiedAt: now.addingTimeInterval(-hoursAgo * 3600), pinned: pinned)
    }

    let items = [
        item("新しい1", hoursAgo: 1),
        item("新しい2", hoursAgo: 2),
        item("新しい3", hoursAgo: 3),
        item("新しい4", hoursAgo: 4),
        item("古い", hoursAgo: 24 * 40),
        item("ピン留め・古い", hoursAgo: 24 * 100, pinned: true),
    ]
    let kept = ClipRetention.prune(items, maxCount: 3, maxAgeDays: 30, now: now)
    let texts = kept.map(\.text)

    expectEqual(kept.count, 4, "件数制限3件＋ピン留め1件が残る")
    expect(texts.contains("ピン留め・古い"), "ピン留めは日数制限を超えても残る")
    expect(!texts.contains("古い"), "古いものは消える")
    expect(!texts.contains("新しい4"), "件数を超えた分は古い方から消える")
    expectEqual(texts.first, "新しい1", "新しい順に並ぶ")
    expectEqual(ClipRetention.prune([], maxCount: 3, maxAgeDays: 30, now: now).count, 0,
                "空でも壊れない")

    let flat = ClipItem(text: "一行目\n二行目\t三行目")
    expectEqual(flat.previewLine, "一行目 二行目 三行目", "一覧表示は改行とタブを潰す")
    expectEqual(ClipItem(text: String(repeating: "あ", count: 500)).previewLine.count, 200,
                "一覧表示は200文字までにする")
}

// MARK: - 画像とファイルの履歴

func checkClipboardKinds() {
    section("画像とファイルの履歴 — 残す判定と見え方")

    let guardian = ClipboardGuard()
    let png = Data(repeating: 0x89, count: 4096)
    let fingerprint = ClipFingerprint.of(png)

    // ── 画像
    func decideImage(
        bytes: Int = 4096,
        fingerprint fp: String = fingerprint,
        types: [String] = ["public.png"],
        bundle: String? = "com.apple.screencapture",
        previous: ClipPayload? = nil,
        guardian g: ClipboardGuard = ClipboardGuard()
    ) -> ClipDecision {
        g.decide(payload: .image(byteCount: bytes, fingerprint: fp),
                 types: types, sourceBundleID: bundle, previous: previous)
    }

    expectEqual(decideImage(), .store, "ふつうの画像は残す")
    expectEqual(decideImage(bytes: 0), .skipEmpty, "中身の無い画像は残さない")
    expectEqual(decideImage(bytes: 20 * 1024 * 1024), .skipTooLarge(20 * 1024 * 1024),
                "大きすぎる画像は残さない")
    expectEqual(decideImage(previous: .image(byteCount: 4096, fingerprint: fingerprint)),
                .skipDuplicate, "直前と同じ絵（指紋が一致）なら残さない")
    expectEqual(decideImage(previous: .image(byteCount: 4096, fingerprint: "ちがう指紋")),
                .store, "指紋が違えば別の絵として残す")
    expectEqual(decideImage(guardian: ClipboardGuard(capturesImages: false)),
                .skipTypeDisabled("画像"), "設定で画像を切っていれば残さない")
    expectEqual(decideImage(types: ["org.nspasteboard.ConcealedType", "public.png"]),
                .skipConcealed("org.nspasteboard.ConcealedType"),
                "機密フラグ付きなら画像でも残さない")
    expectEqual(decideImage(bundle: "com.1password.1password"),
                .skipExcludedApp("com.1password.1password"),
                "除外アプリからの画像は残さない")

    // 同じ絵なら同じ指紋、1バイト違えば別の指紋（重複判定の土台）
    expectEqual(ClipFingerprint.of(png), fingerprint, "同じ中身なら同じ指紋")
    expect(ClipFingerprint.of(png + Data([0x00])) != fingerprint, "中身が違えば指紋も違う")
    expect(!fingerprint.contains("\u{89}"), "指紋に元の中身は現れない")

    // ── ファイル
    let paths = ["/Users/who/Downloads/収支報告.xlsx", "/Users/who/Downloads/請求書.pdf"]
    func decideFiles(
        _ p: [String] = paths,
        types: [String] = ["public.file-url"],
        bundle: String? = "com.apple.finder",
        previous: ClipPayload? = nil,
        guardian g: ClipboardGuard = ClipboardGuard()
    ) -> ClipDecision {
        g.decide(payload: .files(p), types: types, sourceBundleID: bundle, previous: previous)
    }

    expectEqual(decideFiles(), .store, "ふつうのファイルは残す")
    expectEqual(decideFiles([]), .skipEmpty, "1本も無ければ残さない")
    expectEqual(decideFiles(["  "]), .skipEmpty, "空白だけの行は数に入れない")
    expectEqual(decideFiles(previous: .files(paths)), .skipDuplicate,
                "直前と同じ並びなら残さない")
    let many = (0..<80).map { "/tmp/f\($0).txt" }
    expectEqual(decideFiles(many), .skipTooMany(80), "本数が多すぎるものは残さない")
    expectEqual(decideFiles(guardian: ClipboardGuard(capturesFiles: false)),
                .skipTypeDisabled("ファイル"), "設定でファイルを切っていれば残さない")
    expectEqual(decideFiles(["/Users/who/Desktop/振込先メモ.txt"],
                            guardian: ClipboardGuard(userPatterns: ["振込先"])),
                .skipSecret(.userPattern("振込先")), "置き場所に除外語が入っていれば残さない")

    // ── 文字は今までと同じ道を通る（判定の順番を変えていないこと）
    expectEqual(guardian.decide(payload: .text("ふつうのメモ"), types: [],
                                sourceBundleID: nil, previous: nil), .store,
                "文字はこれまで通り残る")
    expectEqual(guardian.decide(payload: .text("同じ"), types: [],
                                sourceBundleID: nil, previous: .text("同じ")), .skipDuplicate,
                "文字の重複判定もこれまで通り")
    expectEqual(guardian.decide(payload: .text("同じ"), types: [],
                                sourceBundleID: nil, previous: .files(["/tmp/同じ"])), .store,
                "種類が違えば重複扱いにしない")

    // ── 一覧の見え方
    let image = ClipItem.image(
        ClipImageInfo(pixelWidth: 1284, pixelHeight: 2778, byteCount: 101_376, fingerprint: fingerprint),
        sourceAppName: "スクリーンショット"
    )
    expectEqual(image.previewLine, "画像 1284×2778", "読む前の画像は大きさを出す")
    expectEqual(image.detailLine, "1284×2778・99 KB", "副題に大きさと容量を並べる")
    expectEqual(image.kindLabel, "画像", "画像の札")

    let files = ClipItem.files(paths, sourceAppName: "Finder")
    expectEqual(files.previewLine, "収支報告.xlsx ほか1件", "ファイルは名前と残りの件数を出す")
    expectEqual(ClipItem.files([paths[0]]).previewLine, "収支報告.xlsx", "1本なら名前だけ")
    expectEqual(files.kindLabel, "ファイル", "ファイルの札")
    expect(!files.detailLine.contains("収支報告.xlsx"),
           "一覧にファイル名までの絶対パスを出さない（画面を見せたときに漏れる）")
    expectEqual(ClipItem.files([NSHomeDirectory() + "/Downloads/x.pdf"]).detailLine, "~/Downloads",
                "ホーム以下は ~ に畳む")

    // ── 絵の題名（2026-07-30 作者「どんな画像かわかりにくい」への答え）
    //    大きさは絵を選ぶ手掛かりにならない。写っている文字を題名にする。
    func shot(text: String? = nil, secret: String? = nil, scanned: Bool = true) -> ClipImageInfo {
        ClipImageInfo(pixelWidth: 912, pixelHeight: 592, byteCount: 2048, fingerprint: "fp",
                      recognizedText: text, secretHint: secret, textScanned: scanned)
    }

    expectEqual(ImageCaption.title(for: shot(text: "七夕ランタン 収支報告書")), "七夕ランタン 収支報告書",
                "読めた文字をそのまま題名にする")
    expectEqual(ImageCaption.title(for: shot(text: nil)), "画像 912×592",
                "文字が無い絵（写真・図）は今までどおり大きさを出す")
    expectEqual(ImageCaption.title(for: shot(scanned: false)), "画像 912×592",
                "まだ読んでいない絵も大きさのまま")
    expectEqual(ImageCaption.title(for: shot(text: "4111 1111 1111 1111", secret: "カード番号")),
                "⚠️ 画像 912×592",
                "秘密が写っていたら題名に文字を出さない（一覧に並べた時点で漏れる）")
    expect(ImageCaption.detail(for: shot(text: "x", secret: "カード番号")).contains("カード番号"),
           "秘密の理由は副題で知らせる")
    expectEqual(ImageCaption.title(for: shot(text: String(repeating: "あ", count: 300))).count,
                ImageCaption.maxTitleCharacters, "題名は行に収まる長さで切る")
    expectEqual(ImageCaption.sizeLabel(shot()), "912×592", "大きさの表記")

    // 読み取りは行ごとに返る。改行をそのまま抱えると題名が縦に崩れる
    expectEqual(ImageCaption.trimForStorage("請求書\n株式会社\tサンプル\r\n合計"),
                "請求書 株式会社 サンプル 合計", "改行とタブは空白1つに畳む")
    expectEqual(ImageCaption.trimForStorage("  余白   だらけ  "), "余白 だらけ",
                "連続した空白は1つにまとめて前後を落とす")
    expectEqual(ImageCaption.trimForStorage(String(repeating: "文", count: 900)).count,
                ImageCaption.maxStoredCharacters,
                "書類を丸ごと抱えない（全件を毎回書き直す作りなので1件の重さが毎回効く）")
    expectEqual(ImageCaption.trimForStorage("   "), "", "空白だけなら文字なし扱い")

    expect(ImageCaption.needsScan(shot(scanned: false)), "読む前の絵は読み直しの対象")
    expect(!ImageCaption.needsScan(shot(text: nil, scanned: true)),
           "読んで文字が無かった絵は二度と読みに行かない（毎回の起動で読み直さない）")

    // ── 絵が検索に載る（題名は先頭だけなので、全文を別名で渡す）
    let captioned = ClipItem.image(shot(text: "七夕ランタン 収支報告書 2026年7月"))
    expectEqual(captioned.searchAliases, ["七夕ランタン 収支報告書 2026年7月"],
                "読めた文字の全文を検索の手掛かりに渡す")
    expectEqual(ClipItem.image(shot(text: nil)).searchAliases.count, 0, "文字が無ければ別名も無い")
    expectEqual(ClipItem(text: "ただの文字").searchAliases.count, 0, "文字の履歴に別名は要らない")

    // ── 古い clips.enc（文字を読む前の時代）が読めること。
    //    ここが壊れると画像履歴がまるごと消えたように見える
    let legacyImage = #"{"pixelWidth":800,"pixelHeight":600,"byteCount":1024,"fingerprint":"old"}"#
    if let decoded = try? JSONDecoder().decode(ClipImageInfo.self, from: Data(legacyImage.utf8)) {
        expectEqual(decoded.pixelWidth, 800, "昔の画像も読める")
        expect(decoded.recognizedText == nil, "昔の画像に文字は入っていない")
        expect(!decoded.textScanned, "昔の画像はこれから読みに行く")
    } else {
        expect(false, "昔の画像も読める")
    }

    // ── 画像から読んだ文字にも秘密の検知をかける
    let imageGuard = ClipboardGuard(excludedBundleIDs: [], userPatterns: ["社外秘"])
    // ⚠️ ここも完全な形をソースに書かない（実行時に組み立てる。理由は下の redact の検査と同じ）
    expect(imageGuard.detectSecretInImageText("sk-ant-api03-" + String(repeating: "x", count: 32)) != nil,
           "スクリーンショットに写ったAPIキーに気付く")
    expect(imageGuard.detectSecretInImageText("これは社外秘の資料です") != nil,
           "自分で足した言葉も画像に効く")
    expect(imageGuard.detectSecretInImageText("ふつうの会議メモ") == nil,
           "ふつうの画面を秘密扱いしない")

    // ── 右半分のプレビュー（2026-07-30 作者「画像の表示がやっぱりわかりにくい」への答え）
    //    一覧の行の中で頑張るのをやめて、見分ける仕事は右のプレビューが引き受ける。
    let previewNow = Date(timeIntervalSince1970: 1_000_000)
    let textClip = ClipItem(text: "1行目\n2行目", sourceAppName: "Claude",
                            copiedAt: previewNow.addingTimeInterval(-120))
    let textSpec = ItemPreview.spec(for: textClip, now: previewNow)
    expectEqual(textSpec.content, ItemPreview.Content.text("1行目\n2行目"),
                "文字は改行を潰さず全文を出す（一覧は1行に潰すが、下見は中身の確認が仕事）")
    expectEqual(textSpec.info.map(\.label), ["アプリ", "いつ", "文字数"], "文字の情報欄の並び")
    expectEqual(textSpec.info[0].value, "Claude", "どこからコピーしたか")
    expectEqual(textSpec.info[1].value, "2分前", "いつコピーしたか")
    expectEqual(textSpec.info[2].value, "7文字", "文字数も出す")

    let anonymous = ItemPreview.spec(for: ClipItem(text: "x", copiedAt: previewNow), now: previewNow)
    expect(!anonymous.info.contains { $0.label == "アプリ" },
           "アプリが分からないときは「不明」と書かずに行ごと消す")

    let previewImage = ClipItem.image(shot(text: "七夕ランタン"),
                                      sourceAppName: "プレビュー", copiedAt: previewNow)
    let imageSpec = ItemPreview.spec(for: previewImage, now: previewNow)
    expectEqual(imageSpec.content, ItemPreview.Content.image, "絵は絵として出す")
    expectEqual(imageSpec.info.map(\.label), ["アプリ", "いつ", "大きさ", "容量"], "絵の情報欄の並び")
    expectEqual(imageSpec.info[2].value, "912×592", "大きさは題名から情報欄へ移った")
    expectEqual(imageSpec.info[3].value, "2 KB", "容量も情報欄へ")
    expect(!imageSpec.info.contains { $0.isWarning }, "秘密が無ければ警告の行も無い")

    let secretSpec = ItemPreview.spec(
        for: ClipItem.image(shot(text: nil, secret: "カード番号らしき数字列"), copiedAt: previewNow),
        now: previewNow)
    expect(secretSpec.info.first?.isWarning == true, "秘密の警告は先頭に置く（下に沈めると読まれない）")
    expect(secretSpec.info.first?.value.contains("カード番号らしき数字列") == true,
           "何を見つけたのかまで言う")

    let fileSpec = ItemPreview.spec(for: ClipItem.files(paths, copiedAt: previewNow), now: previewNow)
    expectEqual(fileSpec.content, ItemPreview.Content.fileNames(["収支報告.xlsx", "請求書.pdf"]),
                "ファイルは名前だけ出す（絶対パスを大きく出すと画面を見せたときに漏れる）")
    expectEqual(fileSpec.info.first { $0.label == "場所" }?.value, "/Users/who/Downloads",
                "置き場所は情報欄に1つだけ")
    expectEqual(fileSpec.info.first { $0.label == "個数" }?.value, "2件", "複数あれば本数を出す")
    let oneFileSpec = ItemPreview.spec(for: ClipItem.files([paths[0]], copiedAt: previewNow), now: previewNow)
    expect(!oneFileSpec.info.contains { $0.label == "個数" }, "1本のときに「1件」とは言わない")

    let previewSnippet = Snippet(title: "請求メール", keyword: "seikyu", body: "いつもお世話になっております。\n{date}")
    let snippetSpec = ItemPreview.spec(for: previewSnippet)
    expectEqual(snippetSpec.content, ItemPreview.Content.text("いつもお世話になっております。\n{date}"),
                "定型文は差し込み前の生の本文を出す（何が書いてあるかを確かめる場所）")
    expectEqual(snippetSpec.info.map(\.label), ["キーワード", "文字数"], "定型文の情報欄")
    expectEqual(snippetSpec.info[0].value, "seikyu", "キーワードを出す")
    expect(!ItemPreview.spec(for: Snippet(title: "t", body: "b")).info.contains { $0.label == "キーワード" },
           "キーワードが無ければ行ごと消す")

    expectEqual(ByteSize.label(0), "0 B", "0バイトの表示")
    expectEqual(ByteSize.label(999), "999 B", "1KB未満はバイトで出す")
    expectEqual(ByteSize.label(101_376), "99 KB", "KBの表示")
    expectEqual(ByteSize.label(3 * 1024 * 1024), "3.0 MB", "MBの表示")
    expectEqual(ByteSize.label(-5), "0 B", "負の数でも壊れない")

    // ── 貼るときに実在するものだけ残す
    let alive = ClipItem.availablePaths(paths) { $0.hasSuffix(".pdf") }
    expectEqual(alive, [paths[1]], "元が消えたファイルは貼り付けの対象から外す")
    expectEqual(ClipItem.availablePaths(paths) { _ in false }.count, 0,
                "全部消えていれば1本も残らない")

    // ── 画像は文字と別枠で数える
    let now = Date()
    func img(_ n: Int) -> ClipItem {
        ClipItem.image(ClipImageInfo(pixelWidth: 10, pixelHeight: 10, byteCount: 100, fingerprint: "f\(n)"),
                       copiedAt: now.addingTimeInterval(-Double(n)))
    }
    var mixed: [ClipItem] = (0..<5).map { img($0) }
    mixed += (0..<5).map { ClipItem(text: "文字\($0)", copiedAt: now.addingTimeInterval(-Double(10 + $0))) }
    let pruned = ClipRetention.prune(mixed, maxCount: 100, maxAgeDays: 30, maxImageCount: 2, now: now)
    expectEqual(pruned.filter { $0.kind == .image }.count, 2, "画像は決めた枚数までしか残さない")
    expectEqual(pruned.filter { $0.kind == .text }.count, 5, "画像を絞っても文字は減らない")
    expectEqual(pruned.first?.image?.fingerprint, "f0", "新しい画像の方を残す")

    let pinnedOld = ClipItem.image(
        ClipImageInfo(pixelWidth: 10, pixelHeight: 10, byteCount: 100, fingerprint: "pin"),
        copiedAt: now.addingTimeInterval(-3600)
    )
    var withPin = mixed
    withPin.append({ var i = pinnedOld; i.pinned = true; return i }())
    let prunedPin = ClipRetention.prune(withPin, maxCount: 100, maxAgeDays: 30, maxImageCount: 2, now: now)
    expect(prunedPin.contains { $0.image?.fingerprint == "pin" },
           "ピン留めした画像は枚数の枠に数えない")

    // ── 古い履歴（kind が無い時代のもの）も読める
    let legacy = """
        {"id":"\(UUID().uuidString)","text":"むかしのコピー","copiedAt":760000000,"pinned":true}
        """.data(using: .utf8)!
    let decoder = JSONDecoder()
    if let old = try? decoder.decode(ClipItem.self, from: legacy) {
        expectEqual(old.kind, .text, "kind の無い古い履歴は文字として読む")
        expectEqual(old.text, "むかしのコピー", "古い履歴の本文が消えない")
        expect(old.pinned, "古い履歴のピン留めが消えない")
        expectEqual(old.filePaths.count, 0, "古い履歴のファイル欄は空で始まる")
    } else {
        expect(false, "kind の無い古い履歴が読めない")
    }

    // 書いて読み直しても崩れない
    let round = [image, files, ClipItem(text: "文字")]
    if let data = try? JSONEncoder().encode(round),
       let back = try? decoder.decode([ClipItem].self, from: data) {
        expectEqual(back.map(\.kind), [.image, .file, .text], "種類が保存して読み直しても変わらない")
        expectEqual(back[0].image?.pixelWidth, 1284, "画像の大きさが残る")
        expectEqual(back[1].filePaths, paths, "ファイルの置き場所が残る")
    } else {
        expect(false, "画像・ファイルの履歴を保存して読み直せない")
    }
}

// MARK: - 定型文の差し込み

func checkSnippets() {
    section("定型文の差し込み")

    var comps = DateComponents()
    comps.year = 2026
    comps.month = 7
    comps.day = 28
    comps.hour = 9
    comps.minute = 5
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone.current
    guard let fixed = cal.date(from: comps) else {
        failures.append("検証用の日付が作れない")
        return
    }

    let ctx = SnippetContext(now: fixed, clipboard: "貼り付けた中身", query: "入力した語")
    func expand(_ body: String) -> String { SnippetExpander.expand(body, context: ctx) }

    expectEqual(expand("{date}"), "2026-07-28", "今日の日付")
    expectEqual(expand("{time}"), "09:05", "今の時刻")
    expectEqual(expand("{date:yyyy/MM/dd}"), "2026/07/28", "書式を指定した日付")
    expectEqual(expand("{date:M月d日}"), "7月28日", "日本語の書式")
    expectEqual(expand("{clipboard}"), "貼り付けた中身", "クリップボードの中身")
    expectEqual(expand("{query}"), "入力した語", "ランチャーで入力した語")
    expectEqual(expand("{date} に {query} の件"), "2026-07-28 に 入力した語 の件", "混在")
    expectEqual(expand("{date}と{date}"), "2026-07-28と2026-07-28", "同じ記法を繰り返せる")
    expectEqual(expand("記法なし"), "記法なし", "記法が無ければそのまま")
    expectEqual(expand("{unknown}"), "{unknown}", "知らない記法はそのまま残す")
    expectEqual(expand("閉じ忘れ {date"), "閉じ忘れ {date", "閉じ括弧が無くても壊れない")
    expectEqual(expand(""), "", "空でも壊れない")
    expectEqual(expand("いつも大変お世話になっております。\n{date}"),
                "いつも大変お世話になっております。\n2026-07-28", "改行を含む定型文")
}

// MARK: - リンクと自作コマンド

func checkCommands() {
    section("リンクと自作コマンド")

    let google = Quicklink(title: "Google検索", url: "https://www.google.com/search?q={query}")
    expect(google.needsQuery, "{query}を含むリンクは入力を求める")
    expect(!Quicklink(title: "freee", url: "https://secure.freee.co.jp/").needsQuery,
           "{query}が無ければ入力を求めない")

    let resolved = google.resolvedURL(query: "山田 太郎")
    expect(resolved.hasPrefix("https://www.google.com/search?q="), "リンクの形が保たれる")
    expect(!resolved.contains(" "), "空白はエンコードされる")
    expect(!resolved.contains("純"), "日本語はエンコードされる")

    // & や = を通すとパラメータを1個増やされる（リンクの意味が変わる）
    let injected = google.resolvedURL(query: "test&hl=xx")
    expect(!injected.contains("&hl="), "検索語に混ぜた & でパラメータを増やせない")
    expectEqual(injected, "https://www.google.com/search?q=test%26hl%3Dxx",
                "予約文字を全部エンコードする")

    // ── コマンド注入が成立しないこと（最重要）
    let logCommand = CustomCommand(
        title: "作業ログ ABC",
        action: .runScript(path: "~/bin/worklog.sh", arguments: ["ABC", "{query}"])
    )
    let payload = "; rm -rf ~ && echo \"やられた\" `whoami` $(id)"
    guard case .runScript(let path, let args) = logCommand.action.resolved(query: payload) else {
        failures.append("スクリプトの解決に失敗")
        return
    }
    expectEqual(args.count, 2, "引数の数が増えない（シェルに解釈させない）")
    expectEqual(args[0], "ABC", "1つ目の引数はそのまま")
    expectEqual(args[1], payload, "入力は丸ごと1個の引数として渡る")
    expect(path.hasPrefix(NSHomeDirectory()), "~ が展開される")
    expect(!path.contains("~"), "展開後に ~ が残らない")

    // {today} の差し込み
    var comps = DateComponents()
    comps.year = 2026
    comps.month = 7
    comps.day = 28
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone.current
    guard let fixed = cal.date(from: comps) else {
        failures.append("検証用の日付が作れない")
        return
    }
    let diary = CommandAction.openPath("~/Documents/Claude/20_日記/{today}.md")
    guard case .openPath(let p) = diary.resolved(query: "", now: fixed) else {
        failures.append("パスの解決に失敗")
        return
    }
    expect(p.hasSuffix("/20_日記/2026-07-28.md"), "{today}が今日の日付になる")
    expect(p.hasPrefix(NSHomeDirectory()), "パスの ~ が展開される")

    expect(CommandAction.runScript(path: "/bin/echo", arguments: ["{query}"]).needsQuery,
           "引数に{query}があれば入力を求める")
    expect(!CommandAction.runScript(path: "/bin/echo", arguments: ["fixed"]).needsQuery,
           "{query}が無ければ入力を求めない")
    expect(CommandAction.openPath("/tmp/{query}").needsQuery, "パスの{query}も拾う")
    expect(!CommandAction.openPath("/tmp/{today}").needsQuery,
           "{today}は自動で決まるので入力を求めない")

    let kinds = [
        CommandAction.openPath("/tmp"),
        .openURL("https://example.com"),
        .runScript(path: "/bin/echo", arguments: []),
    ]
    expect(kinds.allSatisfy { !$0.kindLabel.isEmpty }, "全ての種類に日本語の名前がある")

    // JSONで往復できる（設定ファイルとして保存する前提）
    do {
        let data = try JSONEncoder.temotoTest.encode(logCommand)
        let back = try JSONDecoder.temotoTest.decode(CustomCommand.self, from: data)
        expectEqual(back, logCommand, "自作コマンドをJSONで往復できる")
    } catch {
        failures.append("自作コマンドのJSON往復に失敗: \(error)")
    }
}

extension JSONEncoder {
    static var temotoTest: JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }
}

extension JSONDecoder {
    static var temotoTest: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }
}

// MARK: - 暗号化

func checkVault() throws {
    section("暗号化")

    let key = SymmetricKey(size: .bits256)
    let other = SymmetricKey(size: .bits256)
    let vault = Vault(key: key)
    let wrongVault = Vault(key: other)

    let plain = Data("振込先は〇〇銀行 普通 1234567".utf8)
    let sealed = try vault.seal(plain)

    expect(sealed != plain, "暗号文は平文と違う")
    expect(sealed.range(of: plain) == nil, "暗号文の中に平文がそのまま入っていない")
    expectEqual(try vault.open(sealed), plain, "同じ鍵なら開ける")

    expectThrows("違う鍵では開けない") { _ = try wrongVault.open(sealed) }

    var tampered = sealed
    tampered[tampered.count - 1] ^= 0x01
    expectThrows("1バイトでも書き換えられていたら開けない") { _ = try vault.open(tampered) }

    expectThrows("暗号文でないデータは開けない") {
        _ = try vault.open(Data("これは暗号文ではない".utf8))
    }

    // 同じ平文でも毎回違う暗号文になる（nonceが使い回されていない）
    let again = try vault.seal(plain)
    expect(again != sealed, "同じ内容でも毎回違う暗号文になる")
    expectEqual(try vault.open(again), plain, "2回目も正しく開ける")
}

// MARK: - キーチェーン

func checkKeychain() throws {
    section("キーチェーン（鍵の保管）")
    // 前は「許可の画面が出たら許可してください」と書いていたが、それは嘘だった。
    // その画面はキーチェーンのパスワードを求めてくるもので、作者は答えられない。
    //
    // ここで画面は出ない。理由は、毎回その場で作った名前（check-<毎回違う値>）を使い、
    // 作った本人がそのまま読んで、終わったら消すから。
    // 「他人が作った鍵を読む」ことをしないので、許可を尋ねられる場面が無い。
    // もしここで画面が出たら、それは設計が壊れた合図なので、答えずに閉じて知らせてほしい。
    let service = "jp.zerocloud.temoto.checks"
    let account = "check-\(UUID().uuidString)"
    defer { Vault.deleteKey(service: service, account: account) }

    let first = try Vault.loadOrCreateKey(service: service, account: account)
    let second = try Vault.loadOrCreateKey(service: service, account: account)

    let firstBytes = first.withUnsafeBytes { Data($0) }
    let secondBytes = second.withUnsafeBytes { Data($0) }
    expectEqual(firstBytes.count, 32, "鍵は256ビット")
    expectEqual(firstBytes, secondBytes, "2回目は同じ鍵が返る（履歴が読めなくならない）")

    // 実際に往復できるか
    let sealed = try Vault(key: first).seal(Data("往復".utf8))
    expectEqual(try Vault(key: second).open(sealed), Data("往復".utf8),
                "保存した鍵で開ける")

    Vault.deleteKey(service: service, account: account)
    let recreated = try Vault.loadOrCreateKey(service: service, account: account)
    expect(recreated.withUnsafeBytes { Data($0) } != firstBytes,
           "消したあとは新しい鍵が作られる")
}

// MARK: - 保存層

func checkStore() throws {
    section("保存層")

    let base = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("temoto-checks-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: base) }

    let key = SymmetricKey(size: .bits256)
    let dir = base.appendingPathComponent("normal", isDirectory: true)

    let store = Store(directory: dir, vaultProvider: { Vault(key: key) })
    expect(store.load(), "最初の起動として扱われる")
    expect(store.canPersistSecrets, "鍵があれば暗号化して保存できる")
    expect(store.vaultProblem == nil, "問題は報告されない")
    expect(!store.quicklinks.isEmpty, "初回はよく使うリンクが入っている")
    expect(!store.commands.isEmpty, "初回は自作コマンドが入っている")
    expect(!store.snippets.isEmpty, "初回は定型文が入っている")
    expect(store.clips.isEmpty, "履歴は空から始まる")

    store.clips = [ClipItem(text: "テスト用の記録")]
    store.saveClips()

    let clipsURL = dir.appendingPathComponent("clips.enc")
    let raw = try Data(contentsOf: clipsURL)
    expect(raw.range(of: Data("テスト用の記録".utf8)) == nil,
           "履歴ファイルに平文が残っていない")

    let fileAttrs = try FileManager.default.attributesOfItem(atPath: clipsURL.path)
    expectEqual(fileAttrs[.posixPermissions] as? Int, 0o600, "ファイルは本人だけが読み書きできる")
    let dirAttrs = try FileManager.default.attributesOfItem(atPath: dir.path)
    expectEqual(dirAttrs[.posixPermissions] as? Int, 0o700, "フォルダは本人だけが開ける")

    // 設定は手で編集できるよう平文
    let settingsText = try String(contentsOf: dir.appendingPathComponent("settings.json"),
                                 encoding: .utf8)
    expect(settingsText.contains("launcherShortcut"), "設定は平文のJSONで手で編集できる")

    // 読み直し
    let reopened = Store(directory: dir, vaultProvider: { Vault(key: key) })
    expect(!reopened.load(), "2回目は初回起動ではない")
    expectEqual(reopened.clips.first?.text, "テスト用の記録", "履歴を読み直せる")
    expectEqual(reopened.quicklinks.count, store.quicklinks.count, "リンクを読み直せる")
    expectEqual(reopened.snippets.count, store.snippets.count, "定型文を読み直せる")

    // 鍵が変わったら、壊れずに空から始める
    let before = try Data(contentsOf: clipsURL)
    let rekeyed = Store(directory: dir, vaultProvider: { Vault(key: SymmetricKey(size: .bits256)) })
    _ = rekeyed.load()
    expect(rekeyed.clips.isEmpty, "鍵が変わったら履歴は空から始める（起動できなくならない）")
    expect(rekeyed.vaultProblem != nil, "その事実は報告する")
    expect(!rekeyed.quicklinks.isEmpty, "平文の設定は読めたまま")

    // ここが要。読めなかったからといって消してはいけない。
    // あとで正しい鍵が戻ってきたときに読めなくなるため（バックアップからの復元・Mac移行）。
    let quarantined = dir.appendingPathComponent("clips.enc.broken")
    expect(FileManager.default.fileExists(atPath: quarantined.path),
           "読めなかったファイルは消さずに .broken として残す")
    expectEqual(try? Data(contentsOf: quarantined), before,
                "退避したファイルの中身は1バイトも変わっていない")
    expect(rekeyed.vaultProblem?.contains(".broken") == true, "退避したことを利用者に伝える")
    expect(!FileManager.default.fileExists(atPath: clipsURL.path),
           "元の場所からは退いている（新しい鍵で作り直せる）")

    // 正しい鍵が戻ってきたら、退避したファイルを戻して読み直せる
    try FileManager.default.moveItem(at: quarantined, to: clipsURL)
    let recovered = Store(directory: dir, vaultProvider: { Vault(key: key) })
    _ = recovered.load()
    expectEqual(recovered.clips.first?.text, "テスト用の記録", "鍵が戻れば退避したファイルから復旧できる")

    // 2回続けて開けなかった場合、1回目の退避を上書きしない
    let twice = Store(directory: dir, vaultProvider: { Vault(key: SymmetricKey(size: .bits256)) })
    _ = twice.load()
    recovered.clips = [ClipItem(text: "2回目の記録")]
    recovered.saveClips()
    let twice2 = Store(directory: dir, vaultProvider: { Vault(key: SymmetricKey(size: .bits256)) })
    _ = twice2.load()
    expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("clips.enc.broken").path),
           "1回目の退避が残っている")
    expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("clips.enc.broken.2").path),
           "2回目は連番を足して別名で退避する")

    // 鍵が取り出せない場合はディスクに書かない（平文に格下げしない）
    let lockedDir = base.appendingPathComponent("nokey", isDirectory: true)
    let locked = Store(directory: lockedDir,
                       vaultProvider: { throw VaultError.keychainUnavailable(-25300) })
    _ = locked.load()
    expect(!locked.canPersistSecrets, "鍵が無ければ暗号化保存はできない")
    expect(locked.vaultProblem?.contains("-25300") == true, "OSStatusを添えて報告する")
    locked.snippets = [Snippet(title: "秘密", body: "振込先")]
    locked.saveSnippets()
    locked.clips = [ClipItem(text: "秘密")]
    locked.saveClips()
    expect(!FileManager.default.fileExists(atPath: lockedDir.appendingPathComponent("snippets.enc").path),
           "鍵が無ければ定型文をディスクに書かない")
    expect(!FileManager.default.fileExists(atPath: lockedDir.appendingPathComponent("clips.enc").path),
           "鍵が無ければ履歴をディスクに書かない")
    expect(FileManager.default.fileExists(atPath: lockedDir.appendingPathComponent("quicklinks.json").path),
           "秘密を含まない設定は保存できる")

    // 壊れたファイルがあっても起動できる
    let brokenDir = base.appendingPathComponent("broken", isDirectory: true)
    try FileManager.default.createDirectory(at: brokenDir, withIntermediateDirectories: true)
    try Data("これはJSONではない".utf8).write(to: brokenDir.appendingPathComponent("settings.json"))
    let broken = Store(directory: brokenDir, vaultProvider: { Vault(key: key) })
    _ = broken.load()
    expectEqual(broken.settings, Settings(), "壊れた設定ファイルは既定値で置き換える")
}

// MARK: - 起動の2段構え

/// 起動でキーチェーンの許可ダイアログが出ると、答えるまで鍵の取り出しが返ってこない。
/// 以前はそれを起動の先頭でやっていたので、答えるまでメニューバーのアイコンすら出なかった。
/// 鍵の要らないものだけ先に読めること（＝画面を先に立てられること）をここで担保する。
func checkStartupPhases() throws {
    section("起動の2段構え — 鍵を待たずに画面を立てる")

    let base = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("temoto-phases-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: base) }

    let key = SymmetricKey(size: .bits256)
    let dir = base.appendingPathComponent("phase", isDirectory: true)

    // 鍵を取りに行ったかどうかを数える。
    // ここが0のままなら、キーチェーンのダイアログで止まる余地がない。
    final class Counter: @unchecked Sendable { var count = 0 }
    let asked = Counter()

    let store = Store(directory: dir, vaultProvider: {
        asked.count += 1
        return Vault(key: key)
    })

    expect(store.loadPlaintext(), "最初の起動として扱われる")
    expectEqual(asked.count, 0, "鍵の要らない読み込みでは、キーチェーンに一度も触らない")
    expect(!store.quicklinks.isEmpty, "リンクは鍵なしで読める（検索窓をすぐ開ける）")
    expect(!store.commands.isEmpty, "自作コマンドも鍵なしで読める")
    expect(store.settings.launcherShortcut == Settings.defaultLauncher,
           "ショートカットも鍵なしで読める（この時点でホットキーを登録できる）")
    expect(store.snippets.isEmpty, "定型文はまだ入っていない（鍵が要るので後回し）")
    expect(store.clips.isEmpty, "履歴もまだ入っていない")
    expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("settings.json").path),
           "設定ファイルは初回に書き出される（手で直せるように）")
    expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("snippets.enc").path),
           "鍵を取る前に定型文ファイルを作ってしまわない")

    // 鍵を取り出す。ここは別スレッドで呼ぶ想定なので、Storeの中身を書き換えないこと。
    let snapshotBefore = store.quicklinks.count
    let result = store.makeVault()
    expectEqual(asked.count, 1, "鍵を取りに行くのはこの1回だけ")
    expect(!store.canPersistSecrets, "受け取るまでStoreはまだ鍵を持っていない（別スレッドから呼んで安全）")
    expectEqual(store.quicklinks.count, snapshotBefore, "鍵を取り出しても中身は書き換わらない")

    store.adoptVault(result)
    expect(store.canPersistSecrets, "受け取れば保存できるようになる")
    expect(store.vaultProblem == nil, "問題は報告されない")
    expect(!store.snippets.isEmpty, "鍵が開けてから定型文が入る")
    expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("snippets.enc").path),
           "定型文は暗号化して保存される")

    // 2段に分けても、まとめて読んだのと同じ結果になること
    let whole = Store(directory: base.appendingPathComponent("whole", isDirectory: true),
                      vaultProvider: { Vault(key: key) })
    _ = whole.load()
    expectEqual(whole.quicklinks.count, store.quicklinks.count, "分けて読んでもリンクの数は同じ")
    expectEqual(whole.commands.count, store.commands.count, "分けて読んでもコマンドの数は同じ")
    expectEqual(whole.snippets.count, store.snippets.count, "分けて読んでも定型文の数は同じ")

    // 鍵が取れなかったとき（許可しなかった・キーチェーンがロック）
    let deniedDir = base.appendingPathComponent("denied", isDirectory: true)
    let denied = Store(directory: deniedDir,
                       vaultProvider: { throw VaultError.keychainUnavailable(-128) })
    _ = denied.loadPlaintext()
    expect(!denied.quicklinks.isEmpty, "鍵が取れなくてもリンクは使える")
    denied.adoptVault(denied.makeVault())
    expect(!denied.canPersistSecrets, "鍵は持てない")
    expect(denied.vaultProblem?.contains("-128") == true, "OSStatusを添えて報告する")
    // 前は「許可ダイアログで“常に許可”を押してください」と案内していた。
    // だがそのダイアログはキーチェーンのパスワードを求めてきて、作者は答えられなかった。
    // 押せない選択肢を案内するのは案内していないのと同じなので、
    // パスワードの要らない道（作り直す）を書くように変えた。
    expect(denied.vaultProblem?.contains("作り直す") == true,
           "-128 のときは、パスワードの要らない直し方を書く")
    expect(denied.vaultProblem?.contains("常に許可") != true,
           "答えられないダイアログの操作を案内しない")
    expect(denied.snippets.isEmpty, "鍵が無いときに定型文を入れない（保存できず毎回消えるため）")
    expect(!FileManager.default.fileExists(atPath: deniedDir.appendingPathComponent("snippets.enc").path),
           "鍵が無いときに空のファイルを作らない")

    // 自分で全部消したものが、次の起動で勝手に戻ってこないこと
    let emptied = Store(directory: dir, vaultProvider: { Vault(key: key) })
    _ = emptied.load()
    emptied.quicklinks.removeAll()
    emptied.saveQuicklinks()
    emptied.snippets.removeAll()
    emptied.saveSnippets()
    let after = Store(directory: dir, vaultProvider: { Vault(key: key) })
    _ = after.load()
    expect(after.quicklinks.isEmpty, "自分で消したリンクは復活しない")
    expect(after.snippets.isEmpty, "自分で消した定型文は復活しない")
    expect(!after.commands.isEmpty, "消していないコマンドはそのまま残る")

    try checkVaultRetry(base: base, key: key)
}

/// 鍵を断ってしまったあと、メニューから取り直したときの挙動。
/// ここで普通に読み直すと、断っている間にコピーしたものが消える。
func checkVaultRetry(base: URL, key: SymmetricKey) throws {
    section("鍵の取り直し — 断っている間にコピーしたものを消さない")

    let dir = base.appendingPathComponent("retry", isDirectory: true)

    // 日付は「今から何分前」で作る。
    // 固定の日付（1970年など）を使うと保持ルールの期限切れに引っかかって全部消える。
    let now = Date()
    func minutesAgo(_ m: Double) -> Date { now.addingTimeInterval(-m * 60) }

    // まず鍵がある状態で1件貯めておく（これがディスク側になる）
    let first = Store(directory: dir, vaultProvider: { Vault(key: key) })
    _ = first.load()
    first.clips = [ClipItem(text: "鍵がある時の記録", copiedAt: minutesAgo(30))]
    first.saveClips()

    // 起動時に鍵を断った状態を作る
    final class Switchable: @unchecked Sendable { var allow = false }
    let gate = Switchable()
    let store = Store(directory: dir, vaultProvider: {
        guard gate.allow else { throw VaultError.keychainUnavailable(-128) }
        return Vault(key: key)
    })
    _ = store.loadPlaintext()
    store.adoptVault(store.makeVault())
    expect(!store.canPersistSecrets, "断ったので鍵は無い")
    expect(store.clips.isEmpty, "読めないので履歴は空に見える")

    // 鍵が無い間もコピーは拾える（保存できないだけ）
    let inMemory = ClipItem(text: "鍵が無い間の記録", copiedAt: minutesAgo(20))
    store.clips.insert(inMemory, at: 0)
    store.saveClips()
    expect(store.clips.count == 1, "メモリには載っている")

    // メニューから取り直す
    gate.allow = true
    store.adoptVaultKeepingMemory(store.makeVault())
    expect(store.canPersistSecrets, "取り直せば鍵が使えるようになる")
    expectEqual(store.clips.count, 2, "ディスクの1件とメモリの1件が両方残る")
    expect(store.clips.contains { $0.text == "鍵がある時の記録" }, "ディスクにあったものが戻る")
    expect(store.clips.contains { $0.text == "鍵が無い間の記録" }, "断っている間に拾ったものが消えない")
    expectEqual(store.clips.first?.text, "鍵が無い間の記録", "新しい順に並ぶ")

    let reloaded = Store(directory: dir, vaultProvider: { Vault(key: key) })
    _ = reloaded.load()
    expectEqual(reloaded.clips.count, 2, "取り直したあと、両方ディスクに保存されている")

    // 取り直しにも失敗したら、メモリの中身を捨てない
    gate.allow = false
    let stillPending = ClipItem(text: "さらに増えた記録", copiedAt: minutesAgo(10))
    store.clips.insert(stillPending, at: 0)
    store.adoptVaultKeepingMemory(store.makeVault())
    expect(!store.canPersistSecrets, "断れば鍵は使えないまま")
    expectEqual(store.clips.count, 3, "取り直しに失敗しても、メモリの中身は消えない")
    expect(store.clips.contains { $0.text == "さらに増えた記録" }, "直前に拾ったものも残っている")

    try checkVaultOwner(base: base, key: key)
    try checkVaultRecreate(base: base, key: key)
    try checkClipImageStorage(base: base, key: key)
    try checkClipImageRecreate(base: base, key: key)
    try checkSecretsHandover(base: base, key: key)
}

// MARK: - 鍵の持ち主の見分け

/// アプリを作り直すと署名が変わり、macOSは前のビルドが作った鍵を「他人のもの」と見なす。
/// 読もうとすると許可ダイアログが出るが、これはキーチェーンのパスワードを求めてきて、
/// 作者の環境では答えられなかった。しかも一度出ると答えるまで消えない。
///
/// つまり「出てから対処する」ことができない。出る前に避けるしかない。
/// ここで確かめるのは、キーチェーンに一度も触らずに持ち主を見分けられること。
func checkVaultOwner(base: URL, key: SymmetricKey) throws {
    section("鍵の持ち主 — 読みに行く前に自分のものか見分ける")

    let dir = base.appendingPathComponent("owner", isDirectory: true)

    // 控えが1つも無い初回起動
    let fresh = Store(directory: dir,
                      vaultProvider: { Vault(key: key) },
                      codeIdentity: { "aaaa1111" })
    expectEqual(fresh.planForVault(), .recreate,
                "控えが無いときは読みに行かない（読んで確かめること自体がダイアログを呼ぶため）")

    // 鍵を受け取ると、そのとき動いていたビルドを控える
    _ = fresh.load()
    expect(fresh.canPersistSecrets, "鍵は使える")
    expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("key-owner.txt").path),
           "鍵を受け取ったら持ち主を控える")

    // 同じビルドで起動し直したら、そのまま読んでよい
    let sameBuild = Store(directory: dir,
                          vaultProvider: { Vault(key: key) },
                          codeIdentity: { "aaaa1111" })
    expectEqual(sameBuild.planForVault(), .readOurs, "同じビルドなら読んでよい（ダイアログは出ない）")

    // 作り直したビルド（署名が変わった）で起動したら、読みに行かない
    let rebuilt = Store(directory: dir,
                        vaultProvider: { Vault(key: key) },
                        codeIdentity: { "bbbb2222" })
    expectEqual(rebuilt.planForVault(), .recreate, "別のビルドなら読みに行かず作り直す")

    // 署名が取れない場合（署名なしで動かしたとき等）も安全側に倒す
    let unsigned = Store(directory: dir,
                         vaultProvider: { Vault(key: key) },
                         codeIdentity: { nil })
    expectEqual(unsigned.planForVault(), .recreate, "自分の署名が分からないときも読みに行かない")

    // 控えの中身は cdhash だけ。秘密が混ざっていないこと
    let recorded = try String(contentsOf: dir.appendingPathComponent("key-owner.txt"), encoding: .utf8)
    expectEqual(recorded.trimmingCharacters(in: .whitespacesAndNewlines), "aaaa1111",
                "控えるのは署名の文字列だけ（鍵そのものは書かない）")
    let keyBytes = key.withUnsafeBytes { Data($0) }
    expect(!recorded.contains(keyBytes.map { String(format: "%02x", $0) }.joined()),
           "控えに鍵が混ざっていない")
}

// MARK: - 鍵の作り直し

/// 読めない鍵は捨てて作り直す。ここで一番怖いのは、
/// 「新しい鍵で保存し直す」ときに、前の鍵で書いたファイルを空の中身で上書きしてしまうこと。
/// 上書きすると前の中身は永久に戻らないので、必ず脇へよけてから保存する。
func checkVaultRecreate(base: URL, key: SymmetricKey) throws {
    section("鍵の作り直し — 前のファイルを消さない")

    let dir = base.appendingPathComponent("recreate", isDirectory: true)
    let now = Date()

    // 前のビルドが書いた状態を作る
    let old = Store(directory: dir,
                    vaultProvider: { Vault(key: key) },
                    codeIdentity: { "old-build" })
    _ = old.load()
    old.clips = [ClipItem(text: "前のビルドで拾った記録", copiedAt: now.addingTimeInterval(-600))]
    old.saveClips()
    let oldClipsBytes = try Data(contentsOf: dir.appendingPathComponent("clips.enc"))

    // 作り直したビルドで起動する。鍵は読めない（＝読みに行かない）
    let newKey = SymmetricKey(size: .bits256)
    let rebuilt = Store(directory: dir,
                        vaultProvider: { throw VaultError.keychainUnavailable(-128) },
                        vaultRecreator: { Vault(key: newKey) },
                        codeIdentity: { "new-build" })
    _ = rebuilt.loadPlaintext()
    expectEqual(rebuilt.planForVault(), .recreate, "作り直したビルドなので鍵は読みに行かない")
    expect(rebuilt.hasEncryptedFiles, "前のビルドが書いたファイルは残っている")

    // 作り直す前に、起動してから拾った分をメモリに載せておく
    rebuilt.clips = [ClipItem(text: "作り直す前に拾った記録", copiedAt: now.addingTimeInterval(-60))]

    expect(rebuilt.recreateVault(), "鍵を作り直せる")
    expect(rebuilt.canPersistSecrets, "作り直したら保存できる")
    expect(rebuilt.vaultProblem == nil, "作り直せたなら警告は出ない")

    // 前の中身は消えていない（.broken に残っている）
    let brokenClips = dir.appendingPathComponent("clips.enc.broken")
    expect(FileManager.default.fileExists(atPath: brokenClips.path),
           "読めなくなったファイルは消さずに .broken へ退避する")
    expectEqual(try Data(contentsOf: brokenClips), oldClipsBytes,
                "退避したファイルの中身は1バイトも変わっていない")

    // 新しい鍵で書き直せている
    let after = Store(directory: dir,
                      vaultProvider: { Vault(key: newKey) },
                      codeIdentity: { "new-build" })
    _ = after.load()
    expect(after.clips.contains { $0.text == "作り直す前に拾った記録" },
           "作り直す前に拾ったものは新しい鍵で保存される")
    expect(!after.clips.contains { $0.text == "前のビルドで拾った記録" },
           "前の鍵で書いたものは読めない（読めたら暗号化の意味が無い）")
    expect(!after.snippets.isEmpty, "定型文は初期値が入る")
    expectEqual(after.planForVault(), .readOurs, "作り直したあとは自分の鍵として読める")

    // 作り直しにも失敗したら、平文で保存しない
    let broken = Store(directory: base.appendingPathComponent("recreate-fail", isDirectory: true),
                       vaultProvider: { throw VaultError.keychainUnavailable(-25308) },
                       vaultRecreator: { throw VaultError.keychainUnavailable(-25308) },
                       codeIdentity: { "new-build" })
    _ = broken.loadPlaintext()
    broken.clips = [ClipItem(text: "保存できないはずの記録", copiedAt: now)]
    expect(!broken.recreateVault(), "作り直せなければ失敗を返す")
    expect(!broken.canPersistSecrets, "鍵は持てない")
    expect(broken.vaultProblem?.contains("-25308") == true, "なぜ駄目だったかを報告する")
    broken.saveClips()
    expect(!FileManager.default.fileExists(
        atPath: base.appendingPathComponent("recreate-fail/clips.enc").path),
           "鍵が無いときは何も書かない（平文に格下げしない）")
    expectEqual(broken.clips.count, 1, "保存できなくてもメモリの中身は消えない")
}

// MARK: - 画像の実体の置き場

/// 絵は履歴（clips.enc）とは別に1件1ファイルで置く。
/// ここで怖いのは「履歴から消したのに絵だけディスクに残る」＝消したつもりが消えていない状態。
func checkClipImageStorage(base: URL, key: SymmetricKey) throws {
    section("画像の実体 — 別ファイルに暗号化して置く")

    let fm = FileManager.default
    let dir = base.appendingPathComponent("clip-images", isDirectory: true)
    let store = Store(directory: dir, vaultProvider: { Vault(key: key) })
    _ = store.load()

    let original = Data("これは絵の中身のつもり".utf8)
    let thumbnail = Data("これは小さい方".utf8)
    let item = ClipItem.image(
        ClipImageInfo(pixelWidth: 100, pixelHeight: 50, byteCount: original.count,
                      fingerprint: ClipFingerprint.of(original))
    )

    expect(store.saveClipImage(id: item.id, original: original, thumbnail: thumbnail),
           "鍵があれば絵をディスクに置ける")
    store.clips = [item]
    store.saveClips()

    let imageFile = store.clipImageDirectory.appendingPathComponent("\(item.id.uuidString).enc")
    let thumbFile = store.clipImageDirectory.appendingPathComponent("\(item.id.uuidString).thumb.enc")
    expect(fm.fileExists(atPath: imageFile.path), "元の絵のファイルができる")
    expect(fm.fileExists(atPath: thumbFile.path), "小さい絵のファイルができる")

    let raw = try Data(contentsOf: imageFile)
    expect(raw.range(of: original) == nil, "絵のファイルに平文が残っていない")
    expectEqual(try fm.attributesOfItem(atPath: imageFile.path)[.posixPermissions] as? Int, 0o600,
                "絵のファイルは本人だけが読み書きできる")
    expectEqual(try fm.attributesOfItem(atPath: store.clipImageDirectory.path)[.posixPermissions] as? Int,
                0o700, "絵のフォルダは本人だけが開ける")

    expectEqual(store.loadClipImage(id: item.id), original, "元の絵を取り出せる")
    expectEqual(store.loadClipThumbnail(id: item.id), thumbnail, "小さい絵を取り出せる")
    expect(store.loadClipImage(id: UUID()) == nil, "知らない番号なら何も返さない")

    // 開き直しても読める
    let reopened = Store(directory: dir, vaultProvider: { Vault(key: key) })
    _ = reopened.load()
    expectEqual(reopened.loadClipImage(id: item.id), original, "開き直しても絵を取り出せる")

    // 鍵が違えば開けない（読めてしまったら暗号化の意味が無い）
    let stranger = Store(directory: dir, vaultProvider: { Vault(key: SymmetricKey(size: .bits256)) })
    _ = stranger.load()
    expect(stranger.loadClipImage(id: item.id) == nil, "鍵が違えば絵は開けない")

    // 履歴から消えた絵は片付ける
    let orphan = UUID()
    store.saveClipImage(id: orphan, original: Data("迷子".utf8), thumbnail: Data("迷子小".utf8))
    store.pruneClipImages()
    expect(!fm.fileExists(atPath: store.clipImageDirectory.appendingPathComponent("\(orphan.uuidString).enc").path),
           "履歴に無い絵はディスクから片付ける")
    expect(fm.fileExists(atPath: imageFile.path), "履歴に残っている絵は片付けない")

    // 1件だけ消す
    store.deleteClipImage(id: item.id)
    expect(!fm.fileExists(atPath: imageFile.path), "1件消すと元の絵も消える")
    expect(!fm.fileExists(atPath: thumbFile.path), "1件消すと小さい絵も消える")

    // 全部消す
    store.saveClipImage(id: item.id, original: original, thumbnail: thumbnail)
    store.deleteAllClipImages()
    expect(!fm.fileExists(atPath: store.clipImageDirectory.path), "全部消すとフォルダごと無くなる")

    // 鍵が無いときはディスクに書かない（起動中だけメモリに持つ）
    let lockedDir = base.appendingPathComponent("clip-images-nokey", isDirectory: true)
    let locked = Store(directory: lockedDir,
                       vaultProvider: { throw VaultError.keychainUnavailable(-25300) })
    _ = locked.load()
    expect(!locked.saveClipImage(id: item.id, original: original, thumbnail: thumbnail),
           "鍵が無ければディスクには置けないと返す")
    expect(!fm.fileExists(atPath: locked.clipImageDirectory.path),
           "鍵が無ければ絵をディスクに書かない（平文に格下げしない）")
    expectEqual(locked.loadClipImage(id: item.id), original,
                "鍵が無くても起動中は貼り付けられる（メモリに持つ）")
    locked.clips = []
    locked.pruneClipImages()
    expect(locked.loadClipImage(id: item.id) == nil, "履歴から消せばメモリの分も手放す")
}

/// 鍵を作り直したら、絵は開けない＝押しても何も出てこない行になる。
/// 行は落とし、ファイルは消さずに脇へよける。
func checkClipImageRecreate(base: URL, key: SymmetricKey) throws {
    section("鍵の作り直しと画像 — 開けない行は残さない・ファイルは消さない")

    let fm = FileManager.default
    let dir = base.appendingPathComponent("clip-images-recreate", isDirectory: true)

    let old = Store(directory: dir, vaultProvider: { Vault(key: key) }, codeIdentity: { "old-build" })
    _ = old.load()
    let picture = ClipItem.image(
        ClipImageInfo(pixelWidth: 8, pixelHeight: 8, byteCount: 4, fingerprint: "f")
    )
    old.saveClipImage(id: picture.id, original: Data("絵".utf8), thumbnail: Data("小".utf8))
    old.clips = [picture, ClipItem(text: "文字のコピー")]
    old.saveClips()
    let oldImageBytes = try Data(contentsOf: dir.appendingPathComponent(
        "clip-images/\(picture.id.uuidString).enc"))

    let newKey = SymmetricKey(size: .bits256)
    let rebuilt = Store(directory: dir,
                        vaultProvider: { throw VaultError.keychainUnavailable(-128) },
                        vaultRecreator: { Vault(key: newKey) },
                        codeIdentity: { "new-build" })
    _ = rebuilt.loadPlaintext()
    // 作り直す前に拾っていた分（メモリ）に画像が混ざっている状態を作る
    rebuilt.clips = [picture, ClipItem(text: "作り直す前に拾った文字")]
    expect(rebuilt.recreateVault(), "鍵を作り直せる")

    expect(!rebuilt.clips.contains { $0.kind == .image },
           "開けない絵の行は落とす（押しても何も出てこない行を残さない）")
    expect(rebuilt.clips.contains { $0.text == "作り直す前に拾った文字" },
           "文字の行は残す")

    expect(!fm.fileExists(atPath: dir.appendingPathComponent("clip-images").path),
           "前の鍵で書いた絵のフォルダは元の場所から退いている")
    let moved = dir.appendingPathComponent("clip-images.broken/\(picture.id.uuidString).enc")
    expect(fm.fileExists(atPath: moved.path), "絵は消さずに .broken へ退避する")
    expectEqual(try Data(contentsOf: moved), oldImageBytes,
                "退避した絵の中身は1バイトも変わっていない")

    // 2回作り直しても、1回目の退避を上書きしない
    rebuilt.saveClipImage(id: picture.id, original: Data("新しい絵".utf8), thumbnail: Data("新小".utf8))
    let again = Store(directory: dir,
                      vaultProvider: { throw VaultError.keychainUnavailable(-128) },
                      vaultRecreator: { Vault(key: SymmetricKey(size: .bits256)) },
                      codeIdentity: { "third-build" })
    _ = again.loadPlaintext()
    expect(again.recreateVault(), "もう一度作り直せる")
    expect(fm.fileExists(atPath: dir.appendingPathComponent("clip-images.broken").path),
           "1回目の退避が残っている")
    expect(fm.fileExists(atPath: dir.appendingPathComponent("clip-images.broken.2").path),
           "2回目は連番を足して別名で退避する")
}

// MARK: - 作り直しのときの引き継ぎ

/// 鍵を捨てると定型文とメモも読めなくなる。作者が自分で書いたものなので、
/// 捨てる前に取り出して、作り直した後に書き戻す。
/// クリップボード履歴は運ばない（パスワードやトークンが入りうるので平文に置きたくない）。
func checkSecretsHandover(base: URL, key: SymmetricKey) throws {
    section("作り直しの引き継ぎ — 定型文とメモだけ運ぶ")

    let dir = base.appendingPathComponent("handover", isDirectory: true)
    let now = Date()

    let old = Store(directory: dir,
                    vaultProvider: { Vault(key: key) },
                    codeIdentity: { "old-build" })
    _ = old.load()
    old.snippets = [
        Snippet(title: "振込先", keyword: "furikomi", body: "〇〇銀行 △△支店"),
        Snippet(title: "あいさつ", keyword: "aisatsu", body: "お世話になっております。"),
    ]
    old.saveSnippets()
    old.note = FloatingNote(text: "書きかけのメモ", updatedAt: now)
    old.saveNote()
    old.clips = [ClipItem(text: "パスワードかもしれない文字列", copiedAt: now)]
    old.saveClips()

    guard let backup = old.exportSecrets() else {
        expect(false, "鍵が使えるなら取り出せる")
        return
    }
    expectEqual(backup.snippets.count, 2, "定型文は運ぶ")
    expectEqual(backup.note.text, "書きかけのメモ", "メモも運ぶ")

    // 運ぶ中身をファイルにしたとき、履歴が混ざっていないこと
    let encoded = try JSONEncoder.temoto.encode(backup)
    let asText = String(decoding: encoded, as: UTF8.self)
    expect(!asText.contains("パスワードかもしれない文字列"),
           "クリップボード履歴は運ばない（一瞬でも平文のファイルに置かない）")
    expect(asText.contains("振込先"), "定型文は運ぶ中身に入っている")

    // 鍵が使えなければ取り出しようがない
    let noKey = Store(directory: base.appendingPathComponent("handover-nokey", isDirectory: true),
                      vaultProvider: { throw VaultError.keychainUnavailable(-128) },
                      codeIdentity: { "old-build" })
    _ = noKey.loadPlaintext()
    noKey.adoptVault(noKey.makeVault())
    expect(noKey.exportSecrets() == nil, "鍵が使えないときは取り出せない（nilを返す）")

    // 作り直した先へ書き戻す
    let newKey = SymmetricKey(size: .bits256)
    let fresh = Store(directory: base.appendingPathComponent("handover-new", isDirectory: true),
                      vaultProvider: { throw VaultError.keychainUnavailable(-128) },
                      vaultRecreator: { Vault(key: newKey) },
                      codeIdentity: { "new-build" })
    _ = fresh.loadPlaintext()
    expect(fresh.recreateVault(), "作り直せる")
    let seeded = fresh.snippets.count
    expect(seeded > 0, "作り直した直後は初期の定型文が入っている")

    let decoded = try JSONDecoder.temoto.decode(Store.SecretsBackup.self, from: encoded)
    fresh.importSecrets(decoded)
    expectEqual(fresh.snippets.count, seeded + 2,
                "引き継いだ分は足し算で入る（初期の定型文を上書きで消さない）")
    expect(fresh.snippets.contains { $0.title == "振込先" }, "引き継いだ定型文がある")
    expectEqual(fresh.note.text, "書きかけのメモ", "引き継いだメモが入る")
    expect(fresh.clips.isEmpty, "履歴は引き継がない（空から始める）")

    // 書き戻した分がディスクに残っていること
    let reloaded = Store(directory: base.appendingPathComponent("handover-new", isDirectory: true),
                         vaultProvider: { Vault(key: newKey) },
                         codeIdentity: { "new-build" })
    _ = reloaded.load()
    expect(reloaded.snippets.contains { $0.title == "振込先" }, "引き継ぎは新しい鍵で保存されている")
    expectEqual(reloaded.note.text, "書きかけのメモ", "メモも保存されている")

    // 二重に書き戻しても増えない
    fresh.importSecrets(decoded)
    expectEqual(fresh.snippets.count, seeded + 2, "同じものを2回書き戻しても増えない")

    // 新しい側でメモを書いた後に、古いメモで上書きしない
    fresh.note = FloatingNote(text: "作り直した後に書いたメモ", updatedAt: now.addingTimeInterval(60))
    fresh.saveNote()
    fresh.importSecrets(decoded)
    expectEqual(fresh.note.text, "作り直した後に書いたメモ", "古いメモで新しいメモを潰さない")

    // 鍵が使えないところへ書き戻そうとしても、平文で保存しない
    let cannot = Store(directory: base.appendingPathComponent("handover-locked", isDirectory: true),
                       vaultProvider: { throw VaultError.keychainUnavailable(-25308) },
                       codeIdentity: { "new-build" })
    _ = cannot.loadPlaintext()
    cannot.adoptVault(cannot.makeVault())
    cannot.importSecrets(decoded)
    expect(cannot.snippets.isEmpty, "鍵が無いところへは書き戻さない")
    expect(!FileManager.default.fileExists(
        atPath: base.appendingPathComponent("handover-locked/snippets.enc").path),
           "鍵が無いのにファイルを作らない")

    // 実際の作り直しと同じ順番でやったとき、初期の定型文が二重にならないこと。
    //
    // 作り直すと初期の定型文が新しい id で入る。引き継ぎ側にも同じ文面が古い id で入っている。
    // id だけで比べると別物に見えるので、何もしないと作り直すたびに倍に増えていく。
    let seedDir = base.appendingPathComponent("handover-seed", isDirectory: true)
    let seedKey = SymmetricKey(size: .bits256)
    let before = Store(directory: seedDir,
                       vaultProvider: { Vault(key: seedKey) },
                       codeIdentity: { "build-1" })
    _ = before.load()
    let seedCount = before.snippets.count
    expect(seedCount > 0, "初期の定型文が入っている")
    before.snippets.append(Snippet(title: "自分で足した定型文", keyword: "mine", body: "本文"))
    before.saveSnippets()

    guard let seedBackup = before.exportSecrets() else {
        expect(false, "取り出せる")
        return
    }
    let key2 = SymmetricKey(size: .bits256)
    let after2 = Store(directory: seedDir,
                       vaultProvider: { throw VaultError.keychainUnavailable(-128) },
                       vaultRecreator: { Vault(key: key2) },
                       codeIdentity: { "build-2" })
    _ = after2.loadPlaintext()
    expect(after2.recreateVault(), "作り直せる")
    after2.importSecrets(seedBackup)
    expectEqual(after2.snippets.count, seedCount + 1,
                "作り直して書き戻しても、初期の定型文は二重にならない")
    expectEqual(after2.snippets.filter { $0.title == "自分で足した定型文" }.count, 1,
                "自分で足した定型文は1つだけ残る")

    // もう一度作り直しても増えない（作り直すたびに倍に増えないこと）
    guard let backup2 = after2.exportSecrets() else {
        expect(false, "もう一度取り出せる")
        return
    }
    let key3 = SymmetricKey(size: .bits256)
    let after3 = Store(directory: seedDir,
                       vaultProvider: { throw VaultError.keychainUnavailable(-128) },
                       vaultRecreator: { Vault(key: key3) },
                       codeIdentity: { "build-3" })
    _ = after3.loadPlaintext()
    expect(after3.recreateVault(), "3回目も作り直せる")
    after3.importSecrets(backup2)
    expectEqual(after3.snippets.count, seedCount + 1, "何回作り直しても増えない")

    // 引き継ぎの入口（コマンドライン引数）の読み取り
    expect(SecretsRelay.parse(["temoto"]) == nil, "引数なしなら通常起動")
    expect(SecretsRelay.parse(["temoto", "--export-secrets"]) == nil,
           "行き先を書き忘れていたら受け付けない")
    expectEqual(SecretsRelay.parse(["temoto", "--export-secrets", "/tmp/a.json"]),
                .export(URL(fileURLWithPath: "/tmp/a.json")), "取り出し先を読み取れる")
    expectEqual(SecretsRelay.parse(["temoto", "--import-secrets", "/tmp/a.json"]),
                .importFrom(URL(fileURLWithPath: "/tmp/a.json")), "書き戻し元を読み取れる")
}

// MARK: - ショートカット

func checkShortcuts() {
    section("ショートカット")

    expectEqual(Settings.defaultLauncher.displayString, "⌥Space", "ランチャーは⌥Space")
    expectEqual(Settings.defaultClipboard.displayString, "⌃⌥V", "クリップボード履歴は⌃⌥V")

    // ── メニューの右寄せ表示（2026-07-30 作者「メニュー画面、構成が汚い」への答えの部品）
    expectEqual(Settings.defaultLauncher.menuKeyEquivalent, " ", "Space はメニューでは空白1文字")
    expectEqual(Settings.defaultClipboard.menuKeyEquivalent, "v",
                "文字キーは小文字で渡す（大文字だと⇧が勝手に付いて見える）")
    expectEqual(Shortcut(keyCode: KeyCode.left, carbonModifiers: Shortcut.cmdBit, keyLabel: "←").menuKeyEquivalent,
                "\u{F702}", "矢印はメニュー用の特殊文字になる")
    expectEqual(Shortcut(keyCode: 999, carbonModifiers: Shortcut.cmdBit, keyLabel: "キー999").menuKeyEquivalent,
                nil, "出せないキーは nil（呼ぶ側は表示を諦めるだけ）")
    expectEqual(Settings.defaultClipboard.cocoaModifierRawFlags, UInt(0x40000 | 0x80000),
                "⌃⌥ が Cocoa の旗に変わる（右寄せ表示に使う）")
    expectEqual(
        Shortcut(keyCode: KeyCode.a,
                 carbonModifiers: Shortcut.controlBit | Shortcut.optionBit
                     | Shortcut.shiftBit | Shortcut.cmdBit,
                 keyLabel: "A").displayString,
        "⌃⌥⇧⌘A",
        "修飾キーはmacOS標準の並び順")

    expect(Settings.defaultLauncher.hasModifier, "既定のショートカットには修飾キーがある")
    expect(!Shortcut(keyCode: KeyCode.a, carbonModifiers: 0, keyLabel: "A").hasModifier,
           "修飾キー無しは受け付けない判定になる")

    expectEqual(Shortcut.carbonModifiers(fromCocoaRawFlags: 0x80000 | 0x100000),
                Shortcut.optionBit | Shortcut.cmdBit,
                "Cocoaの修飾キーをCarbonの値に変換できる")

    // 既定のショートカットどうしがぶつかっていないこと
    let settings = Settings()
    var all: [Shortcut] = [
        settings.launcherShortcut, settings.clipboardShortcut,
        settings.snippetShortcut, settings.noteShortcut,
    ]
    all += settings.windowBindings.map(\.shortcut)
    all += settings.displayBindings.map(\.shortcut)

    expectEqual(Set(all).count, all.count, "既定のショートカットが重複していない（\(all.count)個）")
    expect(all.allSatisfy(\.hasModifier), "既定のショートカットは全て修飾キー付き")

    // Raycastの既定（⌘Space・⌃⌥＋矢印）とぶつからないこと
    let cmdSpace = Shortcut(keyCode: KeyCode.space, carbonModifiers: Shortcut.cmdBit, keyLabel: "Space")
    let ctrlOptLeft = Shortcut(keyCode: KeyCode.left,
                               carbonModifiers: Shortcut.controlBit | Shortcut.optionBit,
                               keyLabel: "←")
    expect(!all.contains(cmdSpace), "⌘Space（Raycastの既定）を奪わない")
    expect(!all.contains(ctrlOptLeft), "⌃⌥←（Raycastの既定）を奪わない")

    // 設定をJSONで往復できる
    do {
        let data = try JSONEncoder.temotoTest.encode(settings)
        let back = try JSONDecoder.temotoTest.decode(Settings.self, from: data)
        expectEqual(back, settings, "設定をJSONで往復できる")
    } catch {
        failures.append("設定のJSON往復に失敗: \(error)")
    }

    // 押したキーを設定画面に出す文字にできる
    expectEqual(Shortcut.label(keyCode: KeyCode.left, characters: "\u{F702}"), "←", "矢印キーは矢印の文字で出る")
    expectEqual(Shortcut.label(keyCode: KeyCode.space, characters: " "), "Space", "スペースは Space と出る")
    expectEqual(Shortcut.label(keyCode: KeyCode.ret, characters: "\r"), "Return", "Returnは改行文字にならない")
    expectEqual(Shortcut.label(keyCode: KeyCode.del, characters: "\u{7F}"), "⌫", "⌫は制御文字にならない")
    expectEqual(Shortcut.label(keyCode: KeyCode.a, characters: "a"), "A", "文字キーは大文字で出る")
    expectEqual(Shortcut.label(keyCode: 999, characters: nil), "キー999", "名前も文字も無いキーでも空の札にしない")
    // 制御文字がそのまま札になると「⌃⌥⇧」の後ろが空白に見えて、何を押したのか分からなくなる
    expect(!Shortcut.label(keyCode: 200, characters: "\u{1}").isEmpty, "制御文字だけのときも札が空にならない")

    // 同じキーを2つに割り当てたら、その場で気づけること
    expect(settings.conflicts().isEmpty, "既定の設定にショートカットの重複は無い")
    var doubled = Settings()
    doubled.snippetShortcut = doubled.clipboardShortcut
    let conflicts = doubled.conflicts()
    expectEqual(conflicts.count, 1, "重複を1件見つける")
    expectEqual(Set(conflicts.first?.names ?? []), Set(["コピー履歴", "定型文"]), "重なっている両方の名前を出す")
    expectEqual(settings.allShortcuts.count, 16, "割り当て一覧は16件（開くもの4＋ウィンドウ10＋画面2）")
}

// MARK: - 使う機能のオン/オフ
//
// テモトを作った理由そのもの（「使わない機能が多い」）なので、
// 切ったものが本当にどこにも出てこないかを機械で確かめる。

func checkFeatureVisibility() {
    section("使う機能のオン/オフ")

    var settings = Settings()
    // ⚠️ 2026-08-12 から**新規の**既定は最小構成（links/windows/calculator は隠れて始まる）。
    // 「シンプル」が売りなのに初期状態で全機能が並ぶと多機能ランチャーに見える（公開監査の指摘）。
    // 読み込み（古いファイル）は空＝全部出す。新規と持ち越しで既定が違うことをここで縛る
    expectEqual(Settings().visibleModes, [.all, .clipboard, .files, .snippets],
                "新規の既定は最小構成（検索・履歴・ファイル・定型文）")
    expect(Settings().isNoteVisible, "メモは既定で出る")
    expect(Settings().isCaptureTextVisible, "文字読み取りも既定で出る")
    expect(!Settings().isVisible(.links), "リンクは既定で隠れている（設定で足せる）")
    settings.hiddenFeatures = []
    expectEqual(settings.visibleModes, LauncherMode.allCases, "全部出すこともできる")
    expect(settings.isNoteVisible, "はじめはメモも出る")

    settings.setVisible(LauncherMode.windows.rawValue, false)
    expect(!settings.isVisible(.windows), "切った行き先は出ない")
    expect(!settings.visibleModes.contains(.windows), "切った行き先は一覧にも入らない")
    expect(settings.isVisible(.clipboard), "切っていない行き先はそのまま出る")

    // Tab の巡回に混ざらない＝「使わない機能に着地しない」
    var visited: Set<LauncherMode> = []
    var walk = LauncherMode.all
    for _ in 0..<10 {
        walk = walk.next(within: settings.visibleModes)
        visited.insert(walk)
    }
    expect(!visited.contains(.windows), "切った行き先にはTabで着地しない")

    settings.setVisible(LauncherMode.windows.rawValue, false)
    expectEqual(settings.hiddenFeatures.filter { $0 == "windows" }.count, 1, "2回切っても重複して覚えない")

    settings.setVisible(LauncherMode.windows.rawValue, true)
    expect(settings.isVisible(.windows), "戻せば出る")
    expect(settings.hiddenFeatures.isEmpty, "戻したら記録も消える")

    // 入口は隠せない。隠せるとどこにも行けなくなる。
    settings.setVisible(LauncherMode.all.rawValue, false)
    expect(settings.isVisible(.all), "入口（すべて）は切れない")
    expect(settings.visibleModes.contains(.all), "入口は必ず一覧に残る")

    settings.setVisible(Settings.noteFeature, false)
    expect(!settings.isNoteVisible, "メモも切れる")

    // 全部切っても入口だけは残る（迷子にならない）
    // ⚠️ 行き先を1つずつ名指しで切ると、新しい行き先が増えたとき切り忘れる。
    // しかも visibleModes はモードしか見ないので、切り忘れても**この検査は落ちない**
    // （＝「全部切っても」という名前だけが嘘になる）。allCases で回して取りこぼしを無くす
    var minimal = Settings()
    for mode in LauncherMode.allCases { minimal.setVisible(mode.rawValue, false) }
    for entry in LauncherEntry.allCases { minimal.setVisible(entry.key, false) }
    expectEqual(minimal.visibleModes, [.all], "全部切っても入口だけは残る")
    expect(minimal.visibleEntries.isEmpty, "全部切ったら行き先の一覧は空になる")
    expect(!minimal.isNoteVisible, "メモも切れている")
    expect(!minimal.isCaptureTextVisible, "画面の文字読み取りも切れている")

    // JSONで往復しても切った状態が残る
    do {
        let data = try JSONEncoder.temotoTest.encode(settings)
        let back = try JSONDecoder.temotoTest.decode(Settings.self, from: data)
        expectEqual(back.hiddenFeatures.sorted(), settings.hiddenFeatures.sorted(), "切った機能はJSONで往復できる")
    } catch {
        failures.append("使う機能のJSON往復に失敗: \(error)")
    }

    // ⭐ここが本題。
    // 機能を1つ足すたびに設定ファイルへ項目が増える。
    // 「項目が欠けたら丸ごと既定に戻す」読み方だと、
    // 更新した瞬間に利用者が決めたショートカットが黙って全部消える。
    let oldFile = """
        {
          "launcherShortcut": { "keyCode": 49, "carbonModifiers": 256, "keyLabel": "Space" }
        }
        """
    do {
        let back = try JSONDecoder.temotoTest.decode(Settings.self, from: Data(oldFile.utf8))
        expectEqual(back.launcherShortcut.displayString, "⌘Space", "古い設定ファイルでも自分で決めたキーが残る")
        expectEqual(back.clipboardShortcut, Settings.defaultClipboard, "書いていない項目だけ既定で埋まる")
        // ⚠️ 古いファイルに hiddenFeatures が無いとき、新規の既定（最小構成）を当てると
        // **上書き導入した日に機能が消える**。持ち越しは空＝全部出す、で受ける
        expect(back.hiddenFeatures.isEmpty, "古いファイルの人から機能を消さない（空で受ける）")
        expectEqual(back.windowBindings.count, Settings.defaultWindowBindings.count, "ウィンドウの割り当ても既定で埋まる")
        expectEqual(back.clipboard.maxCount, 300, "履歴の設定も既定で埋まる")
    } catch {
        failures.append("古い設定ファイルの読み込みに失敗: \(error)")
    }

    // 履歴の設定だけ古い形（件数しか書いていない）でも読めること
    let partialClipboard = #"{ "clipboard": { "maxCount": 50 } }"#
    do {
        let back = try JSONDecoder.temotoTest.decode(Settings.self, from: Data(partialClipboard.utf8))
        expectEqual(back.clipboard.maxCount, 50, "書いてある件数はそのまま読む")
        expectEqual(back.clipboard.maxAgeDays, 30, "書いていない日数は既定で埋まる")
        expect(!back.clipboard.excludedBundleIDs.isEmpty, "書いていない除外アプリは既定の一覧で埋まる")
    } catch {
        failures.append("古い履歴設定の読み込みに失敗: \(error)")
    }

    // 設定画面のテキスト欄（1行1件）の読み取り
    expectEqual(SettingsLines.split("a\n\n  b  \nc"), ["a", "b", "c"], "空行と前後の空白を落として1行1件にする")
    expectEqual(SettingsLines.split(""), [], "空欄は0件")
    expectEqual(SettingsLines.split("   \n  "), [], "空白だけの行は捨てる")
    expectEqual(SettingsLines.split(nil), [], "何も書かなければ0件")
}

// MARK: - 出すアプリの絞り込み
//
// ⚠️ 作った理由（2026-07-28 作者）。
//   「このアプリに表示されるアプリを選択したい。不要なアプリは表示されない様にしたい。」
//
// 実機で数えたら211件出ていて、そのうち117件が /System/Library/CoreServices の裏方だった。
// 判断の中身（AppVisibility）は AppKit に触らないので、ここで機械にかけられる。

func checkAppVisibility() {
    section("出すアプリの絞り込み")

    // --- Info.plist の真偽値の読み方 ---
    //
    // ⚠️ ここが今回いちばん危ない所。素直に `as? Bool` で読むと取りこぼす。
    // 実機の Info.plist を見たら、同じ意味の値が true / YES / 1 の3通りで書かれていた。
    expect(AppVisibility.isTrue(true), "true を真と読む")
    expect(AppVisibility.isTrue("YES"), "YES（文字）を真と読む")
    expect(AppVisibility.isTrue("yes"), "小文字の yes も真と読む")
    expect(AppVisibility.isTrue("true"), "true（文字）を真と読む")
    expect(AppVisibility.isTrue("1"), "1（文字）を真と読む")
    expect(AppVisibility.isTrue(1), "1（数）を真と読む")
    expect(!AppVisibility.isTrue(false), "false は偽")
    expect(!AppVisibility.isTrue("NO"), "NO は偽")
    expect(!AppVisibility.isTrue("0"), "0（文字）は偽")
    expect(!AppVisibility.isTrue(0), "0（数）は偽")
    expect(!AppVisibility.isTrue(nil), "書いていなければ偽")
    expect(!AppVisibility.isTrue(""), "空文字は偽")
    expect(!AppVisibility.isTrue(["a"]), "読めない形は偽（落とさない）")

    // --- 裏方かどうか ---
    expect(AppVisibility.isHelper(infoPlist: ["LSUIElement": "1"]), "LSUIElement があれば裏方")
    expect(AppVisibility.isHelper(infoPlist: ["LSBackgroundOnly": true]), "LSBackgroundOnly があれば裏方")
    expect(AppVisibility.isHelper(infoPlist: ["LSUIElement": "YES", "LSBackgroundOnly": "1"]), "両方あっても裏方")
    expect(!AppVisibility.isHelper(infoPlist: ["CFBundleName": "Safari"]), "どちらも無ければ裏方ではない")
    expect(!AppVisibility.isHelper(infoPlist: [:]), "空の Info.plist は裏方ではない")
    expect(!AppVisibility.isHelper(infoPlist: ["LSUIElement": "0"]), "0 と書いてあれば裏方ではない")

    // --- 既定で出す/出さない ---
    expect(AppVisibility.isVisibleByDefault(path: "/Applications/Safari.app", isHelper: false),
           "自分で入れたアプリは出す")
    expect(!AppVisibility.isVisibleByDefault(path: "/Applications/Nanika.app", isHelper: true),
           "どこにいても裏方は出さない")
    expect(AppVisibility.isVisibleByDefault(path: "/System/Applications/メモ.app", isHelper: false),
           "標準アプリは出す")

    // ⭐ここが本題。CoreServices 直下（117件）は許可したものだけ。
    expect(!AppVisibility.isVisibleByDefault(path: "/System/Library/CoreServices/AOSUIPrefPaneLauncher.app", isHelper: false),
           "CoreServices 直下は裏方の印が無くても出さない")
    expect(!AppVisibility.isVisibleByDefault(path: "/System/Library/CoreServices/AirPlayUIAgent.app", isHelper: true),
           "スクショに写っていた AirPlayUIAgent は出さない")
    expect(AppVisibility.isVisibleByDefault(path: "/System/Library/CoreServices/Finder.app", isHelper: false),
           "Finder だけは CoreServices 直下でも出す")

    // ⚠️ CoreServices/Applications は別のフォルダ。ここは人が開く道具（キーチェーンアクセス等）。
    expect(AppVisibility.isVisibleByDefault(path: "/System/Library/CoreServices/Applications/キーチェーンアクセス.app", isHelper: false),
           "CoreServices/Applications は出す（許可リストの対象外）")

    // --- 探すフォルダ ---
    let dirs = AppVisibility.searchDirectories(home: "/Users/test")
    expect(dirs.contains("/Applications"), "アプリケーションフォルダを見る")
    expect(dirs.contains("/Users/test/Applications"), "ホームのアプリケーションも見る")
    expect(dirs.contains("/System/Library/CoreServices/Applications"),
           "キーチェーンアクセス等の入っているフォルダも見る")
    expectEqual(dirs.count, Set(dirs).count, "同じフォルダを2回読まない")

    // --- 作者が1つずつ決めたもの ---
    let safari = AppRecord(path: "/Applications/Safari.app", name: "Safari", isHelper: false)
    let agent = AppRecord(path: "/System/Library/CoreServices/AirPlayUIAgent.app", name: "AirPlayUIAgent", isHelper: true)

    var settings = Settings()
    expect(settings.isAppVisible(safari), "はじめは自動の判断どおり（Safariは出る）")
    expect(!settings.isAppVisible(agent), "はじめは自動の判断どおり（裏方は出ない）")
    expectEqual(settings.appChoiceCount, 0, "何も決めていなければ0件")

    settings.setAppVisible(safari, false)
    expect(!settings.isAppVisible(safari), "外したものは出ない")
    expectEqual(settings.hiddenApps, ["/Applications/Safari.app"], "外したものだけ覚える")

    settings.setAppVisible(agent, true)
    expect(settings.isAppVisible(agent), "裏方でも自分で入れれば出る")
    expectEqual(settings.shownApps, ["/System/Library/CoreServices/AirPlayUIAgent.app"], "入れたものだけ覚える")
    expectEqual(settings.appChoiceCount, 2, "自分で決めた数を数えられる")

    // ⭐ 自動の判断と同じ状態に戻したら、どちらの一覧からも消す。
    // 残したままだと「自分で決めたもの」が実際より多く見えて、
    // 何を触ったのか分からなくなる。
    settings.setAppVisible(safari, true)
    expect(settings.hiddenApps.isEmpty, "元に戻したら記録も消える（出さない側）")
    expect(!settings.shownApps.contains(safari.path), "戻したものを逆側へ入れ替えない")
    settings.setAppVisible(agent, false)
    expect(settings.shownApps.isEmpty, "元に戻したら記録も消える（出す側）")
    expectEqual(settings.appChoiceCount, 0, "全部戻せば0件")

    // 同じものを2回外しても重複しない
    settings.setAppVisible(safari, false)
    settings.setAppVisible(safari, false)
    expectEqual(settings.hiddenApps.count, 1, "2回外しても重複して覚えない")

    // 外す → 出す → 外す と往復しても、両方の一覧に同時に載らない
    settings.setAppVisible(safari, true)
    settings.setAppVisible(safari, false)
    expect(!(settings.hiddenApps.contains(safari.path) && settings.shownApps.contains(safari.path)),
           "同じアプリが出す側と出さない側の両方に載らない")

    settings.resetAppChoices()
    expectEqual(settings.appChoiceCount, 0, "おすすめの状態に戻すと決めた記録が消える")
    expect(settings.isAppVisible(safari), "戻したあとは自動の判断に従う")

    // ⭐⭐ 設計の核心。
    // 「出すものの一覧」を持つ作りにすると、新しく入れたアプリが一覧に無いので黙って消える。
    // 「既定からの差」だけを持つので、知らないアプリは自動の判断に従って出る。
    var decided = Settings()
    decided.setAppVisible(safari, false)
    let newlyInstalled = AppRecord(path: "/Applications/新しく入れたアプリ.app", name: "新しく入れたアプリ", isHelper: false)
    expect(decided.isAppVisible(newlyInstalled), "あとから入れたアプリは何もしなくても出る")

    // --- JSONで往復しても決めたことが残る ---
    do {
        var s = Settings()
        s.setAppVisible(safari, false)
        s.setAppVisible(agent, true)
        let data = try JSONEncoder.temotoTest.encode(s)
        let back = try JSONDecoder.temotoTest.decode(Settings.self, from: data)
        expectEqual(back.hiddenApps, s.hiddenApps, "外したアプリはJSONで往復できる")
        expectEqual(back.shownApps, s.shownApps, "出したアプリはJSONで往復できる")
        expect(!back.isAppVisible(safari), "読み直しても外れたまま")
        expect(back.isAppVisible(agent), "読み直しても出たまま")
    } catch {
        failures.append("出すアプリのJSON往復に失敗: \(error)")
    }

    // 前の版の設定ファイル（この項目が無い）でも読める
    let oldFile = #"{ "launcherShortcut": { "keyCode": 49, "carbonModifiers": 256, "keyLabel": "Space" } }"#
    do {
        let back = try JSONDecoder.temotoTest.decode(Settings.self, from: Data(oldFile.utf8))
        expect(back.hiddenApps.isEmpty, "前の版の設定ファイルでも読める（出さないアプリ）")
        expect(back.shownApps.isEmpty, "前の版の設定ファイルでも読める（出すアプリ）")
        expect(back.isAppVisible(safari), "前の版から上げても自動の判断で出る")
    } catch {
        failures.append("前の版の設定ファイルの読み込みに失敗: \(error)")
    }

    // --- 一覧に出す場所の呼び名（英語を出さない） ---
    expectEqual(AppRecord(path: "/Applications/Safari.app", name: "Safari", isHelper: false).placeLabel,
                "アプリケーション", "場所の呼び名が日本語")
    expectEqual(AppRecord(path: "/System/Applications/メモ.app", name: "メモ", isHelper: false).placeLabel,
                "標準アプリ", "標準アプリの呼び名")
    expectEqual(AppRecord(path: "/System/Library/CoreServices/Finder.app", name: "Finder", isHelper: false).placeLabel,
                "システム内部", "CoreServices 直下の呼び名")
    expectEqual(AppRecord(path: "/Users/test/Applications/なにか.app", name: "なにか", isHelper: false).placeLabel,
                "自分で入れたもの", "ホームに入れたものの呼び名")
}

// MARK: - 窓の閉じ方
//
// ⚠️ 作った理由（2026-07-28 作者）。
//   「メモやその他、アプリとは別の部分をクリックしても閉じなかったり、挙動をもっと上手く作って。」
//
// 原因は、検索窓は外をクリックすると閉じるのに、メモだけ
// 「他のアプリを見ながら書き写すことがあるので、離れても消さない」という
// 別の決まりで作られていたこと。作った側の理屈は通っていたが、
// 使う側から見ると「窓によって閉じ方が違う」＝壊れている。
//
// 窓ごとにその場で書き分けると、また片方だけ直し忘れる。
// だから決まりを PanelBehavior の表にして、ここで全部の組み合わせを機械にかける。

func checkPanelBehavior() {
    section("窓の閉じ方")

    let kinds = PanelKind.allCases
    let reasons = CloseReason.allCases

    expectEqual(kinds.count, 3, "窓は3つ（検索窓・メモ・設定）")

    // --- 呼び名は日本語（英語のラベルを1つも出さない） ---
    expectEqual(PanelKind.launcher.title, "検索窓", "検索窓の呼び名")
    expectEqual(PanelKind.note.title, "メモ", "メモの呼び名")
    expectEqual(PanelKind.settings.title, "設定", "設定の呼び名")

    // --- ⭐ここが本題。外をクリックしたら閉じるか ---
    expect(PanelBehavior.closesWhenFocusLost(.note),
           "メモは外をクリックしたら閉じる（作者の指摘そのもの）")
    expect(PanelBehavior.closesWhenFocusLost(.launcher),
           "検索窓も外をクリックしたら閉じる")
    expect(!PanelBehavior.closesWhenFocusLost(.settings),
           "設定は閉じない（枠と閉じるボタンがあり、他のアプリを見ながら変えることがある）")

    // 枠の無い窓は全部閉じる、が決まり。窓を足したときに書き忘れないよう、
    // 個別ではなく総当たりでも押さえる。
    for kind in kinds {
        expectEqual(PanelBehavior.closesWhenFocusLost(kind), !kind.hasWindowFrame,
                    "\(kind.title): 枠が無い窓だけ外クリックで閉じる")
    }

    // --- 閉じ方は全部の窓で同じ ---
    for kind in kinds {
        expect(PanelBehavior.closesOnEscape(kind), "\(kind.title): esc で閉じられる")
        // ⚠️ テモトは画面上部のメニューを持たないので、macOS の ⌘W が効かない。
        // 窓ごとに自分で拾わないと、設定は閉じるボタンを探すしかなくなる。
        expect(PanelBehavior.closesOnCommandW(kind), "\(kind.title): ⌘W で閉じられる")
    }

    // --- 焦点を元のアプリへ返すか ---
    //
    // ⚠️ 外をクリックして閉じたときだけは返さない。
    // クリックした先を使いたいはずで、そこから奪い返すと
    // 「押したのに知らないアプリが前に出てくる」になる。
    expect(!PanelBehavior.restoresPreviousApp(.note, reason: .focusLost),
           "外をクリックして閉じたら、焦点は奪い返さない（メモ）")
    expect(!PanelBehavior.restoresPreviousApp(.launcher, reason: .focusLost),
           "外をクリックして閉じたら、焦点は奪い返さない（検索窓）")

    expect(PanelBehavior.restoresPreviousApp(.note, reason: .escape),
           "esc で閉じたら元のアプリへ戻す（メモ）")
    expect(PanelBehavior.restoresPreviousApp(.note, reason: .commandW),
           "⌘W で閉じたら元のアプリへ戻す（メモ）")
    expect(PanelBehavior.restoresPreviousApp(.launcher, reason: .hotkey),
           "同じホットキーをもう一度押して閉じたら元のアプリへ戻す")

    // 入れ替わりで閉じたときに戻すと、次に開く窓の手前に別のアプリが割り込む
    expect(!PanelBehavior.restoresPreviousApp(.launcher, reason: .replacedByAnother),
           "別の窓と入れ替わるときは焦点を動かさない")

    // アプリやリンクを開いたときは、開いた先が自分で前に出る。二重に動かすと取り合いになる
    expect(!PanelBehavior.restoresPreviousApp(.launcher, reason: .finished),
           "アプリ・リンクを開いたときは焦点を動かさない")

    // ⚠️ ウィンドウ配置だけは例外。前のアプリが前面にいないと手前の別の窓を掴む
    expect(PanelBehavior.restoresPreviousApp(.launcher, reason: .handOffToPreviousApp),
           "ウィンドウ配置は先に元のアプリを前面へ戻す")

    // 設定は普通の窓。閉じたあとの焦点は macOS に任せる
    for reason in reasons {
        expect(!PanelBehavior.restoresPreviousApp(.settings, reason: reason),
               "設定は焦点をこちらから動かさない（\(reason.rawValue)）")
    }

    // --- 使う人が閉じたのか、横から閉じられたのか ---
    expect(CloseReason.escape.isDeliberate, "esc は自分で閉じた")
    expect(CloseReason.commandW.isDeliberate, "⌘W は自分で閉じた")
    expect(CloseReason.hotkey.isDeliberate, "ホットキーの押し直しは自分で閉じた")
    expect(!CloseReason.focusLost.isDeliberate, "外クリックは自分で閉じたのではない")
    expect(!CloseReason.replacedByAnother.isDeliberate, "入れ替わりは自分で閉じたのではない")
    expect(!CloseReason.finished.isDeliberate, "用が済んだのは自分で閉じたのではない")
    expect(!CloseReason.handOffToPreviousApp.isDeliberate, "受け渡しは自分で閉じたのではない")

    // --- 同時に出す窓 ---
    //
    // ⚠️ 検索窓とメモは同じ場所・同じ大きさに出るので、重なると
    // 作者の「一つ一つが別アプリみたい」に逆戻りする。
    expectEqual(PanelBehavior.panelsToClose(whenOpening: .launcher), [.note],
                "検索窓を開くとメモを閉じる")
    expectEqual(PanelBehavior.panelsToClose(whenOpening: .note), [.launcher],
                "メモを開くと検索窓を閉じる")

    // ⚠️ 検索窓とメモは浮く窓で、設定は普通の窓。
    // 残っていると設定の手前に被って押せない。
    expectEqual(PanelBehavior.panelsToClose(whenOpening: .settings), [.launcher, .note],
                "設定を開くと浮く窓は両方どかす")

    // 逆は閉じない。設定でショートカットを変えた直後、そのまま押して試せるように
    expect(!PanelBehavior.panelsToClose(whenOpening: .launcher).contains(.settings),
           "検索窓を開いても設定は閉じない（変えた直後に試せる）")
    expect(!PanelBehavior.panelsToClose(whenOpening: .note).contains(.settings),
           "メモを開いても設定は閉じない")

    // 自分自身を閉じにいくと、開こうとした窓がその場で消える
    for kind in kinds {
        expect(!PanelBehavior.panelsToClose(whenOpening: kind).contains(kind),
               "\(kind.title): 自分自身は閉じない")
        expectEqual(Set(PanelBehavior.panelsToClose(whenOpening: kind)).count,
                    PanelBehavior.panelsToClose(whenOpening: kind).count,
                    "\(kind.title): どかす窓に重複が無い")
    }

    // --- 閉じる前の後始末 ---
    //
    // ⚠️ メモは打つたびに自動保存しているが、最後の一打から0.8秒はまだ書いていない。
    // 外をクリックした瞬間に閉じるなら、その手前で必ず書き切る。
    expect(PanelBehavior.savesBeforeClose(.note), "メモは閉じる前に保存する")
    expect(PanelBehavior.savesBeforeClose(.settings), "設定は閉じる前に保存する")
    expect(!PanelBehavior.savesBeforeClose(.launcher), "検索窓に保存するものは無い")

    // ⚠️ 日本語入力の変換中（未確定の文字）で窓が消えると、確定していない分の行き場が無くなる。
    // 作者のスクショはまさに「っっっd」の変換中だった。
    for kind in kinds {
        expectEqual(PanelBehavior.commitsInputBeforeClose(kind), PanelBehavior.savesBeforeClose(kind),
                    "\(kind.title): 保存する窓は、閉じる前に変換中の文字を確定させる")
    }
}

// MARK: - 窓の中の行き先（LauncherMode）
//
// ⚠️ テモトの作りの核心。
// 「一つ一つが別アプリみたいやし」への答えが、この行き来。
// ここが壊れると窓が増える作りに逆戻りするので、機械で押さえておく。

func checkLauncherMode() {
    section("窓の中の行き先")

    let modes = LauncherMode.allCases

    // esc の戻り先。階層は浅いまま（すべて ←→ 行き先）
    expect(LauncherMode.all.parent == nil, "入口から esc は窓を閉じる（戻り先が無い）")
    for mode in modes where mode != .all {
        expect(mode.parent == .all, "\(mode.title) から esc は入口へ戻る")
    }

    // ⌘1〜⌘9 の番号は Settings が並び順から出す（checkEntryOrder で確かめる）

    // Tab の巡回。全部たどると元に戻る
    var current = LauncherMode.all
    for _ in modes { current = current.next(within: modes) }
    expectEqual(current, .all, "Tabを行き先の数だけ押すと元に戻る")

    current = LauncherMode.all
    for _ in modes { current = current.previous(within: modes) }
    expectEqual(current, .all, "⇧Tabも同じだけ押すと元に戻る")

    // 行きと戻りが対称
    for mode in modes {
        expectEqual(mode.next(within: modes).previous(within: modes), mode, "\(mode.title) は Tab→⇧Tab で戻る")
    }

    // 使う機能を絞ったときの巡回
    let two: [LauncherMode] = [.all, .clipboard]
    expectEqual(LauncherMode.all.next(within: two), .clipboard, "2つだけなら次はコピー履歴")
    expectEqual(LauncherMode.clipboard.next(within: two), .all, "その次は入口に戻る")

    // ⚠️ 全部切られたときに無限に回らないこと（入口に着地する）
    expectEqual(LauncherMode.all.next(within: [.all]), .all, "入口だけでも次は入口（回り続けない）")
    expectEqual(LauncherMode.all.next(within: []), .all, "全部切っても入口へ着地する")
    expectEqual(LauncherMode.clipboard.next(within: []), .all, "切られた行き先からも入口へ戻れる")

    // 今いる行き先が巡回に含まれていなくても、必ずどこかへ行ける（固まらない）
    let withoutClipboard: [LauncherMode] = [.all, .snippets, .links]
    expect(withoutClipboard.contains(LauncherMode.clipboard.next(within: withoutClipboard)),
           "切られた行き先にいても、出る先は生きている行き先")

    // 画面に出す文字が空でないこと（空だと何の行き先か分からない）
    for mode in modes {
        expect(!mode.title.isEmpty, "\(mode.rawValue) に名前がある")
        expect(!mode.summary.isEmpty, "\(mode.rawValue) に説明がある")
        expect(!mode.placeholder.isEmpty, "\(mode.rawValue) に検索欄の案内がある")
        expect(!mode.symbolName.isEmpty, "\(mode.rawValue) にアイコンがある")
        expect(mode.hint.contains("esc"), "\(mode.rawValue) の説明に esc の行き先が書いてある")
    }

    // 入口だけ札を出さない（入口に「すべて」の札が出ると、どこかへ入ったように見える）
    expect(LauncherMode.all.chip == nil, "入口には札を出さない")
    for mode in modes where mode != .all {
        expectEqual(mode.chip, mode.title, "\(mode.title) は札に名前が出る")
    }

    // ⭐ 決めごと: 押せない操作は案内しない。
    // 「許可してください」と書いたのに作者が許可できなかった件の反省。
    for mode in modes {
        expect(!mode.hint.contains("許可"), "\(mode.rawValue) の説明に押せない案内を書かない")
    }

    // MARK: 下の帯に並べる操作

    for mode in modes {
        let actions = mode.actions
        expect(!actions.isEmpty, "\(mode.rawValue) に押せる操作がある")

        for action in actions {
            expect(!action.keys.isEmpty, "\(mode.rawValue) の操作にキーが書いてある")
            expect(!action.label.isEmpty, "\(mode.rawValue) の「\(action.keys)」に説明がある")
            // ⚠️ キーの枠は狭い。長い文字を入れると枠からはみ出して汚れる。
            expect(action.keys.count <= 4, "\(mode.rawValue) の「\(action.keys)」は枠に収まる長さ")
            // 説明のほうも長いと隣とぶつかる。日本語で6文字を超えるなら言い換える
            expect(action.label.count <= 12, "\(mode.rawValue) の「\(action.label)」は帯に収まる長さ")
        }

        // ⚠️ 出口はちょうど1つ。0個だと狭い画面で戻り方が消え、
        // 2つ以上あると「幅が足りないとき何を残すか」が決まらなくなる。
        let essential = actions.filter(\.isEssential)
        expectEqual(essential.count, 1, "\(mode.rawValue) の落とさない操作はちょうど1つ")
        expectEqual(essential.first?.keys, "esc", "\(mode.rawValue) で最後まで残るのは esc")

        // 同じキーを2度出さない（同じキーに違う説明が並ぶと、どちらが本当か分からない）
        let keys = actions.map(\.keys)
        expectEqual(Set(keys).count, keys.count, "\(mode.rawValue) に同じキーが二重に出ない")

        // 1行表記は、組から機械的に作る（＝両方を手で書いてズレることがない）
        for action in actions {
            expect(mode.hint.contains(action.keys), "\(mode.rawValue) の1行表記に「\(action.keys)」が入る")
            expect(mode.hint.contains(action.label), "\(mode.rawValue) の1行表記に「\(action.label)」が入る")
        }
    }

    // ⚠️ Quick Look に Space を割り当てない。
    // ここは検索欄に文字を打ち続ける画面なので、Space は「空白を打つ」以外にできない。
    expect(!LauncherMode.files.actions.contains { $0.keys == "Space" },
           "ファイル検索で Space を操作に使わない（検索欄に空白が入るため）")

    // 定型文はその場で作れる（2026-07-31「新規作成できない。この画面からできるようにしたい」）
    for key in ["⌘N", "⌘E", "⌘⌫"] {
        expect(LauncherMode.snippets.actions.contains { $0.keys == key },
               "定型文の帯に \(key) がある（作る・直す・消すの入口）")
    }

    // MARK: 幅が足りないときの削り方

    let files = LauncherMode.files.actions
    expect(files.count > 3, "ファイル検索は操作が多い（削る対象になる）")

    let trimmed = files.trimmed(to: 3)
    expectEqual(trimmed.count, 3, "3つまでなら3つに削る")
    expect(trimmed.contains { $0.isEssential }, "削っても戻り方（esc）は残る")
    expectEqual(trimmed.first?.keys, files.first?.keys, "削るのは後ろから（先頭のよく使う操作は残る）")
    expectEqual(trimmed.last?.keys, "esc", "esc は末尾に置く")

    expectEqual(files.trimmed(to: 99).count, files.count, "幅が足りていれば1つも削らない")
    // ⚠️ 幅ゼロでも戻り方だけは消さない。出口が消えると窓から抜けられなくなる。
    expectEqual(files.trimmed(to: 1).map(\.keys), ["esc"], "1つしか入らないなら esc を残す")
    expectEqual(files.trimmed(to: 0).map(\.keys), ["esc"], "幅が無くても esc は消さない")
    for mode in modes {
        expect(mode.actions.trimmed(to: 2).contains { $0.isEssential },
               "\(mode.rawValue) は狭い画面でも戻り方が残る")
    }

    checkEmptyState()
}

// MARK: - 何も出ないときの言い方

/// ⚠️ 空っぽの画面は「アプリが壊れた」と受け取られやすい一番の場所なのに、
/// 目で確かめるのが一番むずかしい（空にする条件をまず作らないといけない）。
/// だから文言は全部の場合を機械で通す。
func checkEmptyState() {
    section("何も出ないときの言い方")

    let modes = LauncherMode.allCases

    // どの場合でも、必ず何か言う（無言の空白を作らない）
    for mode in modes {
        for query in ["", "みつからない語"] {
            for hasSource in [true, false] {
                for isSearching in [true, false] {
                    let message = EmptyState.message(mode: mode, query: query,
                                                     isSearching: isSearching, hasSource: hasSource)
                    expect(!message.title.isEmpty,
                           "\(mode.rawValue)/「\(query)」/元\(hasSource)/探索中\(isSearching) に言葉がある")
                    expect(!message.symbol.isEmpty,
                           "\(mode.rawValue)/「\(query)」/元\(hasSource)/探索中\(isSearching) に記号がある")
                    // ⭐ 決めごと: 押せない操作は案内しない
                    expect(!message.detail.contains("許可"),
                           "\(mode.rawValue)/「\(query)」 の案内に押せないことを書かない")
                }
            }
        }
    }

    // 探している最中は、行き先に関わらず「探しています」
    for mode in modes {
        let searching = EmptyState.message(mode: mode, query: "請求書", isSearching: true, hasSource: true)
        expectEqual(searching.title, "探しています…", "\(mode.rawValue) は探索中だとそう言う")
        // ⚠️ 探している最中に「見つかりません」と出してはいけない。
        // まだ探しているのに諦めさせることになる。
        expect(!searching.title.contains("ありません"), "\(mode.rawValue) は探索中に0件と言わない")
    }

    // ファイル検索は、打つまでは0件ではなく「打ってください」
    let filesEmpty = EmptyState.message(mode: .files, query: "", isSearching: false, hasSource: true)
    expect(filesEmpty.title.contains("打って"), "ファイル検索は空欄なら打つよう促す")
    expect(filesEmpty.detail.contains("例"), "打ち方の例を添える")
    expect(!filesEmpty.title.contains("ありません"), "打つ前に「ありません」と言わない")

    // ⭐ ここが本題: 「絞って0件」と「そもそも0件」を混同しない
    let neverCopied = EmptyState.message(mode: .clipboard, query: "", isSearching: false, hasSource: false)
    expect(neverCopied.title.contains("まだ"), "履歴が1件も無いときは「まだ」と言う")
    expect(neverCopied.detail.contains("コピー"), "どうすれば増えるかを言う")

    let copiedButNoMatch = EmptyState.message(mode: .clipboard, query: "見積", isSearching: false, hasSource: true)
    expect(copiedButNoMatch.title.contains("見積"), "絞って0件なら、打った言葉をそのまま見せる")
    expect(!copiedButNoMatch.title.contains("まだ"), "持っているのに「まだありません」と言わない")

    // 打った言葉は前後の空白を落として見せる（「  pdf  」がそのまま出ると汚い）
    let padded = EmptyState.message(mode: .snippets, query: "  見積  ", isSearching: false, hasSource: true)
    expect(padded.title.contains("「見積」"), "打った言葉の前後の空白は落とす")

    // 登録がまだ0件のとき、どこで登録するかを必ず言う
    for mode in [LauncherMode.snippets, .links] {
        let message = EmptyState.message(mode: mode, query: "", isSearching: false, hasSource: false)
        expect(message.detail.contains("⌘,"), "\(mode.rawValue) は登録の入口（⌘,）を案内する")
    }

    // 0件のときの逃げ道は、必ず**減らす方向**（絞りすぎを疑わせる）
    let noFiles = EmptyState.message(mode: .files, query: "請求書 pdf 今月", isSearching: false, hasSource: true)
    expect(noFiles.detail.contains("減らし"), "ファイル検索の0件は言葉を減らすよう促す")
}

// MARK: - ファイル検索（打った言葉をどう読むか）

/// ⚠️ ここが一番静かに壊れる。
/// 検索は「間違った結果」を正解の顔で出すので、目で見ても気づけない。
/// だから条件式は文字を見るだけでなく、**実際に当ててみて**確かめる。
func checkFileQuery() {
    section("ファイル検索（打った言葉の読み取り）")

    let calendar = FileDateFilter.japaneseCalendar
    var components = DateComponents()
    components.year = 2026; components.month = 7; components.day = 29   // 水曜
    components.hour = 12; components.minute = 34
    guard let now = calendar.date(from: components) else {
        failures.append("検証用の日付が作れなかった")
        return
    }

    // ── 日本語をそのまま絞り込みに使えること
    let invoice = FileQuery.parse("請求書 pdf 今月")
    expectEqual(invoice.terms, ["請求書"], "「請求書 pdf 今月」で探す語は請求書だけ")
    expectEqual(invoice.kinds, [.pdf], "pdf は種類の絞り込みになる")
    expectEqual(invoice.date, .thisMonth, "今月 は日付の絞り込みになる")
    expectEqual(FileQuery.parse("エクセル").kinds, [.spreadsheet], "エクセルは表計算")
    expectEqual(FileQuery.parse("パワポ").kinds, [.presentation], "パワポはスライド")
    expectEqual(FileQuery.parse("PDF").kinds, [.pdf], "大文字で打っても種類の絞り込みになる")
    expectEqual(FileQuery.parse("請求書　pdf").kinds, [.pdf], "全角の空白でも区切りになる（日本語入力のまま打てる）")

    // ⚠️ 一番の落とし穴。「pdfの作り方.txt」を探す人を PDF に絞ってはいけない
    let howto = FileQuery.parse("pdfの作り方")
    expect(howto.kinds.isEmpty, "トークン丸ごと一致でなければ種類の絞り込みにしない")
    expectEqual(howto.terms, ["pdfの作り方"], "修飾子でない語はそのまま探す語になる")

    // 逃げ道。これが無いと「pdf という名前のファイル」が永久に引けない
    let byName = FileQuery.parse("名前:pdf")
    expectEqual(byName.nameTerms, ["pdf"], "名前: で名前だけに当てられる")
    expect(byName.kinds.isEmpty, "名前: を付ければ種類の絞り込みにならない")
    expect(byName.terms.isEmpty, "名前: の語は自由語に混ざらない")
    expectEqual(FileQuery.parse("名前：pdf").nameTerms, ["pdf"], "全角コロンでも受ける")
    expectEqual(FileQuery.parse("name:invoice").nameTerms, ["invoice"], "英語の name: も受ける")
    expectEqual(FileQuery.parse("中身:見積").contentTerms, ["見積"], "中身: で本文だけに当てられる")
    expectEqual(FileQuery.parse("本文:見積").contentTerms, ["見積"], "本文: も同じ意味")
    expectEqual(FileQuery.parse("場所:デスクトップ").folder, "デスクトップ", "場所: で探す場所を決められる")
    expect(FileQuery.parse("名前:").nameTerms.isEmpty, "名前: だけ打っても空の条件を作らない")

    // ── プルダウンで選んだ条件を検索欄の文字へ流し込む（正は常に検索欄の文字）
    //    2026-07-30 作者「プルダウンで選択したり、検索条件を保存したり」への答え。
    expectEqual(FileQueryEdit.replacingKind("請求書 今月", with: .pdf), "請求書 今月 pdf",
                "種類を選ぶと言葉として足される")
    expectEqual(FileQueryEdit.replacingKind("請求書 pdf 今月", with: .spreadsheet), "請求書 今月 表計算",
                "種類を選び直すと前の種類の言葉は消える")
    expectEqual(FileQueryEdit.replacingKind("請求書 エクセル", with: nil), "請求書",
                "「すべて」に戻すと種類の言葉だけ消える")
    expectEqual(FileQueryEdit.replacingKind("pdfの作り方", with: .pdf), "pdfの作り方 pdf",
                "語の一部（pdfの作り方）は種類の言葉と見なさず残す")
    expectEqual(FileQueryEdit.replacingDate("請求書 今月", with: .thisWeek), "請求書 今週",
                "期間を選び直すと入れ替わる")
    expectEqual(FileQueryEdit.replacingDate("請求書 今月", with: nil), "請求書",
                "「いつでも」で期間の言葉が消える")
    expectEqual(FileQueryEdit.replacingSort("請求書", with: .size), "請求書 大きさ順",
                "並べ替えも言葉として足される")
    expectEqual(FileQueryEdit.replacingSort("請求書 大きさ順", with: .recent), "請求書",
                "既定（更新順）に戻すと言葉ごと消える（黙って付いたままにしない）")
    expectEqual(FileQueryEdit.replacingPlace("請求書", with: "デスクトップ"), "請求書 場所:デスクトップ",
                "場所は 場所: の形で入る")
    expectEqual(FileQueryEdit.replacingPlace("請求書 場所:デスクトップ", with: "downloads"),
                "請求書 場所:downloads", "場所を選び直すと入れ替わる")
    expectEqual(FileQueryEdit.replacingPlace("請求書 フォルダ:書類", with: nil), "請求書",
                "フォルダ: 表記の場所も一緒に消せる")
    expectEqual(FileQueryEdit.replacingKind("請求書　今月", with: .pdf), "請求書 今月 pdf",
                "全角の空白で打っていても壊れない")

    // 選んだ結果をもう一度読めば同じ条件になる（行って戻れる＝プルダウンが鏡になれる）
    let roundTrip = FileQuery.parse(FileQueryEdit.replacingKind("請求書 今月", with: .pdf))
    expectEqual(roundTrip.kinds, [.pdf], "選んだ種類が読み直しても残る")
    expectEqual(roundTrip.date, .thisMonth, "元の期間も残る")
    expectEqual(roundTrip.terms, ["請求書"], "探す語も残る")

    // ── 探す対象（2026-07-30 作者「本文検索とファイル名検索を選択できる様にして欲しい」）
    //    「DEF」で中身にDEFと書いてあるだけの extension.js まで並ぶのを、名前だけに絞れるように。
    let nameOnly = FileQuery.parse("DEF 名前だけ 今月")
    expectEqual(nameOnly.scope, .nameOnly, "「名前だけ」で対象が切り替わる")
    expectEqual(nameOnly.terms, ["DEF"], "対象の言葉は探す語に混ざらない")
    expectEqual(nameOnly.date, .thisMonth, "他の絞りは一緒に使える")
    expectEqual(FileQuery.parse("予算 本文だけ").scope, .contentOnly, "「本文だけ」でも切り替わる")
    // ⚠️ 既定は「名前だけ」（2026-07-30 作者「デフォルトは名前検索で」）。
    // 中身まで見ると、本文にその語があるだけのファイルが山ほど並んで本命が埋もれる
    expectEqual(FileQuery.parse("DEF").scope, .nameOnly, "何も言わなければ名前だけ")
    expectEqual(FileQuery.parse("DEF 中身も").scope, .both, "「中身も」で本文まで広がる")
    expect(FileQuery.parse("DEF 中身も").summary(searchesContent: true).contains("名前と中身に「DEF」"),
           "広げたときは説明も「名前と中身に」と言う")

    expectEqual(nameOnly.summary(searchesContent: true), "今月／名前に「DEF」 で絞り込み",
                "名前だけのときは説明も「名前に」と言う")
    expect(FileQuery.parse("DEF 中身だけ").summary(searchesContent: true).contains("中身に「DEF」"),
           "中身だけのときは「中身に」と言う")

    expect(!nameOnly.wantsContentSearch, "名前だけなら本文を見にいかない（速くもなる）")
    expect(!FileQuery.parse("DEF").wantsContentSearch, "既定（名前だけ）は本文を見にいかない")
    expect(FileQuery.parse("DEF 中身も").wantsContentSearch, "「中身も」と頼んだときだけ本文を見にいく")

    // 本文検索を切っているのに「中身だけ」→ 黙って回すと違う結果が正解の顔で並ぶ。止める
    expect(FileQuery.parse("DEF 中身だけ 今月").isContentSearchBlocked(searchesContent: false),
           "本文検索オフ×中身だけ は止める")
    expect(!FileQuery.parse("DEF 名前だけ").isContentSearchBlocked(searchesContent: false),
           "名前だけなら本文検索オフでも探せる")

    // Spotlight に渡す条件にも効いていること（説明だけ変わって中身が変わらない、を防ぐ）
    if let format = FileQuery.parse("DEF 名前だけ").predicate(searchesContent: true)?.predicateFormat {
        expect(!format.contains("kMDItemTextContent"), "名前だけの条件式は本文を見にいかない")
        expect(format.contains("kMDItemFSName"), "名前だけの条件式は名前を見る")
    } else {
        expect(false, "名前だけの条件式が組める")
    }
    if let format = FileQuery.parse("DEF").predicate(searchesContent: true)?.predicateFormat {
        expect(!format.contains("kMDItemTextContent"), "既定の条件式も本文を見にいかない（説明と中身を一致させる）")
    } else {
        expect(false, "既定の条件式が組める")
    }
    if let format = FileQuery.parse("DEF 中身だけ").predicate(searchesContent: true)?.predicateFormat {
        expect(format.contains("kMDItemTextContent"), "中身だけの条件式は本文を見る")
        expect(!format.contains("kMDItemFSName"), "中身だけの条件式は名前を見にいかない")
    } else {
        expect(false, "中身だけの条件式が組める")
    }

    expectEqual(FileQueryEdit.replacingScope("DEF 今月", with: .both), "DEF 今月 中身も",
                "プルダウンで選ぶと言葉として足される")
    expectEqual(FileQueryEdit.replacingScope("DEF 中身も", with: .contentOnly), "DEF 中身だけ",
                "選び直すと入れ替わる")
    expectEqual(FileQueryEdit.replacingScope("DEF 中身も", with: .nameOnly), "DEF",
                "既定（名前だけ）に戻すと言葉ごと消える")
    expectEqual(FileQuery.parse(FileQueryEdit.replacingScope("DEF", with: .both)).scope, .both,
                "選んだ対象が読み直しても残る（プルダウンが鏡になれる）")

    // ── 保存した検索（settings.json に入る。古い設定ファイルでも壊れない）
    let savedJSON = #"{"searchesContent":false}"#
    if let decoded = try? JSONDecoder().decode(FileSearchSettings.self, from: Data(savedJSON.utf8)) {
        expect(decoded.saved.isEmpty, "保存の項目が無い古い settings.json も読める")
        expect(!decoded.searchesContent, "元からある項目は元のまま")
    } else {
        expect(false, "保存の項目が無い古い settings.json も読める")
    }
    let savedFull = #"{"saved":[{"name":"今月の請求書","query":"請求書 pdf 今月"}]}"#
    if let decoded = try? JSONDecoder().decode(FileSearchSettings.self, from: Data(savedFull.utf8)) {
        expectEqual(decoded.saved.first?.name, "今月の請求書", "保存した名前が読める")
        expectEqual(decoded.saved.first?.query, "請求書 pdf 今月", "条件は検索欄の文字そのまま")
    } else {
        expect(false, "保存した検索が読める")
    }

    // ── 保存した検索の直し方（2026-07-30 作者「削除や編集できる様にして」）
    //    並びが動く・改名で別の条件が黙って消える、は画面では気づけない壊れ方なので機械で押さえる
    let savedList = [
        SavedFileSearch(name: "今月の請求書", query: "請求書 pdf 今月"),
        SavedFileSearch(name: "DEFの資料", query: "DEF 名前だけ"),
        SavedFileSearch(name: "大きい動画", query: "動画 100MB以上"),
    ]
    let overwritten = SavedSearchList.upserting(savedList, name: "DEFの資料", query: "DEF 名前だけ 今月")
    expectEqual(overwritten.map(\.name), ["今月の請求書", "DEFの資料", "大きい動画"],
                "同じ名前で保存し直しても並びは動かない（消して足すで作らない）")
    expectEqual(overwritten[1].query, "DEF 名前だけ 今月", "中身は入れ替わる")
    expectEqual(SavedSearchList.upserting(savedList, name: "新しい条件", query: "x").count, 4,
                "知らない名前なら末尾に足す")

    let edited = SavedSearchList.updating(savedList, originalName: "DEFの資料",
                                          newName: "DEF関連", newQuery: "DEF 名前だけ 1ヶ月以内")
    expectEqual(edited?.map(\.name), ["今月の請求書", "DEF関連", "大きい動画"],
                "編集は元の場所のまま（改名しても並びは動かない）")
    expectEqual(edited?[1].query, "DEF 名前だけ 1ヶ月以内", "条件も書き換わる")
    expect(SavedSearchList.updating(savedList, originalName: "DEFの資料",
                                    newName: "今月の請求書", newQuery: "x") == nil,
           "別の条件と同じ名前への改名は断る（黙って片方を消さない）")
    expect(SavedSearchList.updating(savedList, originalName: "DEFの資料",
                                    newName: "DEFの資料", newQuery: "y") != nil,
           "名前を変えずに条件だけ直すのは通る")
    expect(SavedSearchList.updating(savedList, originalName: "存在しない", newName: "a", newQuery: "b") == nil,
           "元が無ければ直せない")

    expectEqual(SavedSearchList.removing(savedList, name: "DEFの資料").map(\.name),
                ["今月の請求書", "大きい動画"], "削除は名前で消す")
    expectEqual(SavedSearchList.removing(savedList, name: "無い名前").count, 3,
                "無い名前を消しても何も起きない")

    // ── 言葉が重なっていないこと
    // 重なると parse の書いた順（種類→日付→並べ替え）で片方が黙って勝つ
    var vocabulary: [String: String] = [:]
    var collisions: [String] = []
    func register(_ words: [String], _ owner: String) {
        for word in words {
            let key = word.lowercased()
            if let existing = vocabulary[key] {
                collisions.append("「\(word)」が \(existing) と \(owner) で重なっている")
            } else {
                vocabulary[key] = owner
            }
        }
    }
    for kind in FileKind.allCases { register(kind.words, "種類:\(kind.title)") }
    for date in FileDateFilter.allCases { register(date.words, "日付:\(date.title)") }
    for sort in FileSort.allCases { register(sort.words, "並べ替え:\(sort.title)") }
    for scope in FileSearchScope.allCases { register(scope.words, "対象:\(scope.title)") }
    expect(collisions.isEmpty, "絞り込みの言葉が重なっていない\(collisions.isEmpty ? "" : "：\(collisions.joined(separator: " / "))")")

    for kind in FileKind.allCases {
        expect(!kind.contentTypes.isEmpty, "\(kind.title) に当てる UTI がある")
        expect(!kind.words.isEmpty, "\(kind.title) を呼び出す言葉がある")
    }
    expectEqual(FileKind.image.contentTypes, ["public.image"],
                "画像は親の UTI ひとつで PNG も JPEG も HEIC も入る")
    for sort in FileSort.allCases { expect(!sort.key.isEmpty, "\(sort.title) の並べ替えキーがある") }
    expectEqual(FileQuery.parse("請求書").sort, .recent, "何も言わなければ更新が新しい順")
    expectEqual(FileQuery.parse("請求書 名前順").sort, .name, "名前順 と打てば名前で並ぶ")
    expect(FileSort.name.ascending, "名前順は あ→ん の向き")
    expect(!FileSort.recent.ascending, "更新順は新しいものが上")

    // ── 大きさ
    if let big = FileSizeToken.parse("10MB以上") {
        expectEqual(big.bytes, 10 * 1_048_576, "10MB以上 は10MBと読む")
        expect(big.isMinimum, "「以上」は下限")
    } else { failures.append("10MB以上 が読めなかった") }
    if let small = FileSizeToken.parse("500KB以下") {
        expectEqual(small.bytes, 500 * 1024, "500KB以下 は500KBと読む")
        expect(!small.isMinimum, "「以下」は上限")
    } else { failures.append("500KB以下 が読めなかった") }
    if let giga = FileSizeToken.parse("1ギガ超") {
        expectEqual(giga.bytes, 1_073_741_824, "1ギガ超 も読む（日本語の単位）")
    } else { failures.append("1ギガ超 が読めなかった") }
    expect(FileSizeToken.parse("abc") == nil, "大きさに見えない語は大きさとして読まない")
    expect(FileSizeToken.parse("10mb") == nil, "以上/以下が無ければ大きさの条件にしない")
    expectEqual(FileQuery.parse("10mb").terms, ["10mb"], "大きさとして読めない語はそのまま探す語にする")
    expectEqual(FileQuery.parse("2026-").terms, ["2026-"], "末尾が - でも大きさと誤解しない")

    // ── 日付の境目（ここを間違えると「今日」に昨日の分が出る）
    let startOfToday = calendar.startOfDay(for: now)
    let today = FileDateFilter.today.range(now: now, calendar: calendar)
    expectEqual(today.start, startOfToday, "今日 は当日の0時から")
    expectEqual(today.end, calendar.date(byAdding: .day, value: 1, to: startOfToday), "今日 は翌日の0時まで")
    let yesterdayRange = FileDateFilter.yesterday.range(now: now, calendar: calendar)
    expectEqual(yesterdayRange.end, startOfToday, "昨日 は当日の0時で終わる")
    expectEqual(yesterdayRange.start, calendar.date(byAdding: .day, value: -1, to: startOfToday), "昨日 は前日の0時から")
    if let weekStart = FileDateFilter.thisWeek.range(now: now, calendar: calendar).start {
        expectEqual(calendar.component(.weekday, from: weekStart), 2, "今週 は月曜から始まる（日曜始まりだと月曜の朝に先週が出る）")
        expectEqual(calendar.component(.day, from: weekStart), 27, "2026-07-29(水) の週の始まりは 7/27")
    } else { failures.append("今週 の範囲が出せなかった") }
    if let monthStart = FileDateFilter.thisMonth.range(now: now, calendar: calendar).start {
        expectEqual(calendar.component(.day, from: monthStart), 1, "今月 は1日から")
        expectEqual(calendar.component(.month, from: monthStart), 7, "今月 は7月")
    } else { failures.append("今月 の範囲が出せなかった") }
    let lastMonth = FileDateFilter.lastMonth.range(now: now, calendar: calendar)
    if let start = lastMonth.start, let end = lastMonth.end {
        expectEqual(calendar.component(.month, from: start), 6, "先月 は6月から")
        expectEqual(calendar.component(.month, from: end), 7, "先月 は7月に入る前まで")
    } else { failures.append("先月 の範囲が出せなかった") }
    if let lastYearStart = FileDateFilter.lastYear.range(now: now, calendar: calendar).start {
        expectEqual(calendar.component(.year, from: lastYearStart), 2025, "去年 は2025年から")
    } else { failures.append("去年 の範囲が出せなかった") }

    // ── 何も打っていないときは回さない（全件が出てしまう）
    expect(!FileQuery().isRunnable, "何も無ければ検索しない")
    expect(!FileQuery.parse("").isRunnable, "空文字では検索しない")
    expect(!FileQuery.parse("   ").isRunnable, "空白だけでは検索しない")
    expect(FileQuery.parse("pdf").isRunnable, "絞り込みだけでも検索してよい")
    expect(FileQuery.parse("請求書").isRunnable, "語だけでも検索する")

    // ── 条件式に実際に当ててみる
    //
    // ⚠️ Spotlight の kMDItemContentTypeTree は本来「配列」で、== は「含む」の意味になる。
    // ここでは1つの文字列を当てて、条件の形が正しいことだけを見る。
    func matches(
        _ raw: String,
        name: String,
        content: String = "",
        type: String = "public.data",
        size: Int64 = 1024,
        modified: Date? = nil,
        searchesContent: Bool = true
    ) -> Bool {
        let query = FileQuery.parse(raw)
        guard let predicate = query.predicate(searchesContent: searchesContent, now: now, calendar: calendar) else {
            return false
        }
        let item: [String: Any] = [
            "kMDItemFSName": name,
            "kMDItemDisplayName": name,
            "kMDItemTextContent": content,
            "kMDItemContentTypeTree": type,
            "kMDItemFSSize": NSNumber(value: size),
            "kMDItemContentModificationDate": (modified ?? now) as NSDate
        ]
        return predicate.evaluate(with: item as NSDictionary)
    }

    expect(matches("請求書", name: "2026年 請求書.pdf"), "名前の一部で当たる")
    expect(matches("請求書 中身も", name: "memo.txt", content: "請求書の控えです"),
           "「中身も」と頼めば名前になくても中身で当たる")
    expect(!matches("請求書", name: "memo.txt", content: "請求書の控えです", searchesContent: false),
           "中身の検索を切ったら中身だけでは当たらない")
    expect(matches("請求書", name: "請求書.pdf", searchesContent: false), "中身の検索を切っても名前では当たる")
    expect(!matches("請求書 領収書", name: "請求書.pdf"), "語を2つ打ったら両方に当たるものだけ")
    expect(matches("請求書 領収書", name: "請求書と領収書.pdf"), "両方あれば当たる")
    expect(matches("INVOICE", name: "invoice_2026.pdf"), "大文字で打っても小文字の名前に当たる")

    expect(matches("pdf", name: "a.txt", type: "com.adobe.pdf"), "pdf は種類で当てる（名前ではない）")
    expect(!matches("pdf", name: "pdf.txt", type: "public.plain-text"), "pdf という名前でも種類が違えば出ない")
    expect(matches("名前:pdf", name: "pdf.txt", type: "public.plain-text"), "名前:pdf なら名前で当たる（逃げ道が効く）")

    // ワイルドカードを打ち消していること（通すと `*.pdf` で全然違うものが出る）
    expect(!matches("名前:*.pdf", name: "請求書.pdf"), "* をワイルドカードとして通さない")
    expect(matches("名前:*.pdf", name: "図*.pdf"), "* は文字そのものとして探す")

    let yesterday = calendar.date(byAdding: .day, value: -1, to: now) ?? now
    expect(matches("請求書 今日", name: "請求書.pdf", modified: now), "今日 の指定に今日のファイルは当たる")
    expect(!matches("請求書 今日", name: "請求書.pdf", modified: yesterday), "今日 の指定に昨日のファイルは当たらない")
    expect(matches("請求書 1mb以上", name: "請求書.pdf", size: 2_000_000), "1mb以上 に大きいファイルは当たる")
    expect(!matches("請求書 1mb以上", name: "請求書.pdf", size: 1000), "1mb以上 に小さいファイルは当たらない")
    expect(matches("請求書 500kb以下", name: "請求書.pdf", size: 1000), "500kb以下 に小さいファイルは当たる")

    // ── 「中身:」を切っているときに黙って化けさせない
    expect(FileQuery.parse("中身:見積").predicate(searchesContent: false, now: now, calendar: calendar) == nil,
           "中身の検索を切っていたら「中身:」を名前検索に化けさせない")
    expect(FileQuery.parse("中身:見積").isContentSearchBlocked(searchesContent: false),
           "切ったまま 中身: で探そうとしたら、それと分かる")
    expect(!FileQuery.parse("中身:見積").isContentSearchBlocked(searchesContent: true), "切っていなければ普通に探す")
    expect(!FileQuery.parse("請求書").isContentSearchBlocked(searchesContent: false), "自由語は名前で探せるので止めない")

    // ── どう受け取ったかを画面に出す（黙って絞ると「出ない」と誤解される）
    expectEqual(FileQuery.parse("請求書 pdf 今月").summary(searchesContent: true),
                "PDF／今月／名前に「請求書」 で絞り込み", "受け取った内容を日本語で言える（既定は名前だけ）")
    expectEqual(FileQuery.parse("請求書 pdf 今月 中身も").summary(searchesContent: true),
                "PDF／今月／名前と中身に「請求書」 で絞り込み", "「中身も」なら名前と中身と言う")
    expectEqual(FileQuery.parse("請求書").summary(searchesContent: false),
                "名前に「請求書」 で絞り込み", "中身の検索を切っているときは「名前に」と言う")
    expect(FileQuery().summary(searchesContent: true).isEmpty, "何も無ければ何も言わない")

    // ── 探す場所
    let home = "/Users/test"
    expectEqual(FileScope.resolve("デスクトップ", home: home), "/Users/test/Desktop", "デスクトップ→Desktop")
    expectEqual(FileScope.resolve("書類", home: home), "/Users/test/Documents", "書類→Documents")
    expectEqual(FileScope.resolve("ダウンロード", home: home), "/Users/test/Downloads", "ダウンロード→Downloads")
    expectEqual(FileScope.resolve("Downloads", home: home), "/Users/test/Downloads", "英語でも受ける")
    expectEqual(FileScope.resolve("ホーム", home: home), "/Users/test", "ホームはホームそのもの")
    expectEqual(FileScope.resolve("~", home: home), "/Users/test", "~ だけならホーム")
    expectEqual(FileScope.resolve("~/仕事", home: home), "/Users/test/仕事", "~ はホームに直す")
    expectEqual(FileScope.resolve("/tmp", home: home), "/tmp", "/ 始まりはそのまま")
    expectEqual(FileScope.resolve("/tmp/", home: home), "/tmp", "末尾の / は落とす")
    expectEqual(FileScope.resolve("しごと", home: home), "/Users/test/しごと", "知らない言葉はホームの下として扱う（変な所は探さない）")
    expect(FileScope.resolve("  ", home: home) == nil, "空白だけなら場所として使わない")
    for place in FileScope.places { expect(!place.words.isEmpty, "\(place.title) を呼び出す言葉がある") }

    // ── 出さない場所（ここが抜けると node_modules で本命が沈む）
    expect(FileNoise.isExcluded("/Users/test/app/node_modules/index.js"), "node_modules は出さない")
    expect(FileNoise.isExcluded("/Users/test/app/.build/x.o"), "ビルド生成物は出さない")
    expect(FileNoise.isExcluded("/Users/test/.config/settings.json"), "ドットで始まるフォルダは出さない")
    expect(FileNoise.isExcluded("/Users/test/Library/Caches/x.db"), "キャッシュは出さない")
    expect(FileNoise.isExcluded("/Users/test/Library/Containers/x/y.txt"), "アプリの内部フォルダは出さない")
    expect(FileNoise.isExcluded("/System/Library/x"), "システムの中は出さない")
    expect(FileNoise.isExcluded("/private/var/folders/x"), "一時領域は出さない")
    expect(!FileNoise.isExcluded("/Users/test/Documents/請求書.pdf"), "普通の書類は出す")
    expect(!FileNoise.isExcluded("/Users/test/Documents/node_modules_memo.md"), "名前が似ているだけのファイルは落とさない")
    expect(!FileNoise.isExcluded("/Users/test/Documents/Claude/01_ABC/資料.xlsx"), "仕事のフォルダは落とさない")

    // ── 一覧に出す文字（人に画面を見せたときに漏れないこと）
    expectEqual(FileHit.foldedParent("/Users/test/Documents/請求書.pdf", home: home), "~/Documents", "置き場所はホームを ~ に畳む")
    expectEqual(FileHit.foldedParent("/Users/test/a.txt", home: home), "~", "ホーム直下は ~ だけ")
    expectEqual(FileHit.foldedParent("/tmp/a.txt", home: home), "/tmp", "ホームの外はそのまま出す")
    let hit = FileHit(path: "/Users/test/Documents/請求書.pdf", name: "請求書.pdf",
                      contentType: "com.adobe.pdf", byteCount: 204_800,
                      modifiedAt: now.addingTimeInterval(-3600))
    let subtitle = hit.subtitle(home: home, now: now)
    expect(!subtitle.contains("/Users/"), "副題に絶対パスを出さない（画面を人に見せたときに漏れる）")
    expect(subtitle.contains("200 KB"), "副題に大きさを出す")
    expect(subtitle.contains("1時間前"), "副題にいつ更新したかを出す")
    let folderHit = FileHit(path: "/Users/test/Documents/請求書", name: "請求書",
                            contentType: "public.folder", byteCount: 4096, isFolder: true)
    expect(!folderHit.subtitle(home: home).contains("KB"), "フォルダに大きさは出さない（中身の合計ではないので嘘になる）")

    expectEqual(FileTypeLabel.of("com.adobe.pdf"), "PDF", "PDF の札")
    expectEqual(FileTypeLabel.of("public.folder"), "フォルダ", "フォルダの札")
    expectEqual(FileTypeLabel.of("public.image"), "画像", "画像の札")
    expectEqual(FileTypeLabel.of("public.plain-text"), "テキスト", "テキストの札")
    expectEqual(FileTypeLabel.of("public.png"), "PNG", "知らない種類は拡張子っぽく出す")
    expectEqual(FileTypeLabel.of(nil), "ファイル", "種類が分からなければ「ファイル」")
    expectEqual(FileTypeLabel.of(""), "ファイル", "空でも「ファイル」")

    // ── 設定の既定値
    let defaults = FileSearchSettings()
    expect(defaults.searchesContent, "中身も探すのが既定（名前だけなら Finder でできる）")
    expect(defaults.maxResults > 0, "出す件数に上限がある")
    expect(defaults.folders.isEmpty, "既定では場所を限らない（ホーム全体）")
    // 使う／使わないは「使う機能」1か所で決める。2か所あると必ず食い違う
    var visibility = Settings()
    expect(visibility.isVisible(.files), "ファイル検索は最初から使える")
    visibility.setVisible(LauncherMode.files.rawValue, false)
    expect(!visibility.isVisible(.files), "「使う機能」で外せる")
    expect(!visibility.visibleModes.contains(.files), "外したら Tab の順番にも出てこない")
    // 古い設定ファイル（ファイル検索の項目が無い頃のもの）を読んでも既定に落ちること
    if let data = "{}".data(using: .utf8),
       let decoded = try? JSONDecoder().decode(FileSearchSettings.self, from: data) {
        expectEqual(decoded, defaults, "古い設定ファイルを読んでも既定値になる")
    } else {
        failures.append("空のJSONから FileSearchSettings を読めなかった")
    }
}

// MARK: - 画面表示用の文字づくり

// MARK: - メニューの出し分け

/// メニューバーのメニュー（2026-07-30 作者「このメニュー画面、構成が汚い」への答え）
func checkMenuPlan() {
    print("▼ メニューの出し分け")

    func state(
        vaultBroken: Bool = false,
        login: LoginItem.State = .on,
        ax: Bool = true,
        failed: Int = 0,
        clipboard: Bool = true,
        snippets: Bool = true,
        note: Bool = true,
        windows: Bool = true
    ) -> MenuPlan.State {
        MenuPlan.State(
            secretsReady: true, vaultBroken: vaultBroken, loginState: login,
            accessibilityGranted: ax, failedShortcutCount: failed,
            clipboardVisible: clipboard, snippetsVisible: snippets,
            noteVisible: note, windowsVisible: windows)
    }

    expect(MenuPlan.warnings(state()).isEmpty, "全部うまくいっていれば警告は0（沈黙＝健康）")

    // 深刻度の固定順: 保存できない → 次の起動で全損 → ウィンドウ死 → 一部のキー死
    let all = MenuPlan.warnings(state(vaultBroken: true, login: .off, ax: false, failed: 2))
    expectEqual(all.map(\.kind),
                [.vault, .loginOff, .accessibility, .shortcuts(2)],
                "警告は深刻度の固定順で並ぶ（開くたびに順序が変わらない）")
    expect(all[0].title.contains("暗号鍵を作り直す"), "壊れている事実と直す手段を1行で言う")
    expect(all[1].title.contains("再起動すると立ち上がりません"), "症状から言い始める")
    expectEqual(all[3].title, "ショートカット2件が使えません — 設定で確かめる…", "件数は文の中に入れる")

    // 「…」の決まり: 画面が開くものに付け、その場で完結するものには付けない
    expect(all[0].title.hasSuffix("…"), "確認ダイアログが開くものは … で終わる")
    expect(!all[1].title.hasSuffix("…"), "その場で直るものに … を付けない")

    // 機能を切っていれば、その機能の警告は出さない
    expect(!MenuPlan.warnings(state(ax: false, windows: false)).contains { $0.kind == .accessibility },
           "ウィンドウ操作を切っていればアクセシビリティの警告は出さない")
    expect(!MenuPlan.warnings(state(vaultBroken: true, clipboard: false, snippets: false, note: false))
        .contains { $0.kind == .vault },
           "暗号化して保存する機能を全部切っていれば鍵の警告は出さない")
    expect(MenuPlan.warnings(state(vaultBroken: true, clipboard: false, snippets: true, note: false))
        .contains { $0.kind == .vault },
           "定型文だけでも使っていれば鍵の警告は出す")

    // ログイン項目の2つの状態は違う行になる（押したときの動きが違うため）
    expect(MenuPlan.warnings(state(login: .needsApproval)).first?.kind == .loginNeedsApproval,
           "OSに止められているときは「許可が必要」の行になる")
    expect(MenuPlan.warnings(state(login: .needsApproval)).first?.title.hasSuffix("…") == true,
           "システム設定が開くので … で終わる")
    expect(MenuPlan.warnings(state(login: .unavailable)).isEmpty,
           "置き場所の問題（unavailable）はメニューでは言わない（設定画面が説明する）")

    // メニューバーのしるし: 警告がある間だけ変わる
    expectEqual(MenuPlan.statusSymbol(warningCount: 0), "square.grid.2x2", "平常のしるし")
    expectEqual(MenuPlan.statusSymbol(warningCount: 1), "exclamationmark.square",
                "警告がある間はしるし自体が変わる（開かない限り見えない穴を塞ぐ）")
}

// MARK: - コマンドの畳み方

/// 入口の「フォルダを開く: X」×9連発を1行に畳む決まり
/// （2026-07-30 作者「複数表示されすぎていて、リスト表示されている項目が汚い」への答え）
func checkCommandGrouping() {
    print("▼ コマンドの畳み方")

    func command(_ title: String) -> CustomCommand {
        CustomCommand(title: title, action: .openPath("/tmp"))
    }

    expectEqual(CommandGrouping.prefix(of: "フォルダを開く: ABC（サンプル商事）"),
                "フォルダを開く", "コロンの前が書き出しになる")
    expectEqual(CommandGrouping.prefix(of: "作業ログ ABC"), "作業ログ", "空白区切りでも書き出しになる")
    expectEqual(CommandGrouping.prefix(of: "今日の日記を開く"), nil, "区切りが無ければ畳みようがない")
    expectEqual(CommandGrouping.prefix(of: "整理：受信箱"), "整理", "全角コロンも受ける")

    expectEqual(CommandGrouping.shortTitle("フォルダを開く: ABC（サンプル商事）"),
                "ABC（サンプル商事）", "畳んだ中では書き出しを取り除いた名前で出す")
    expectEqual(CommandGrouping.shortTitle("作業ログ ABC"), "ABC", "空白区切りも同じ")
    expectEqual(CommandGrouping.shortTitle("今日の日記を開く"), "今日の日記を開く", "畳めないものはそのまま")

    expectEqual(CommandGrouping.abbreviated("フォルダを開く: ABC（サンプル商事）"), "ABC",
                "副題に並べる呼び名は（）の前まで（正式名称を9件並べたら新しい壁になる）")

    // 実データと同じ形: フォルダを開く×3 ＋ 作業ログ×3 ＋ 単独2つ
    let commands = [
        command("フォルダを開く: ABC（サンプル商事）"),
        command("フォルダを開く: DEF（サンプル物産）"),
        command("フォルダを開く: TRR（チームロロ）"),
        command("今日の日次作業ログを開く"),
        command("作業ログ ABC"),
        command("作業ログ DEF"),
        command("作業ログ TRR"),
        command("今日の日記を開く"),
    ]
    let organized = CommandGrouping.organize(commands)
    expectEqual(organized.count, 4, "8件が「畳み2＋単独2」の4行になる")
    if case .group(let title, let members) = organized[0] {
        expectEqual(title, "フォルダを開く", "最初の畳みは最初に現れた場所に置く")
        expectEqual(members.count, 3, "仲間が全員入る")
    } else {
        expect(false, "1行目は畳みになる")
    }
    if case .single(let single) = organized[1] {
        expectEqual(single.title, "今日の日次作業ログを開く", "畳めないものは元の順のまま単独で残る")
    } else {
        expect(false, "2行目は単独になる")
    }
    if case .group(let title, _) = organized[2] {
        expectEqual(title, "作業ログ", "2つ目の畳み")
    } else {
        expect(false, "3行目は畳みになる")
    }

    // 2つしか仲間がいなければ畳まない（たまたま似ただけかもしれない）
    let two = CommandGrouping.organize([command("メモ: 一つ"), command("メモ: 二つ")])
    expectEqual(two.count, 2, "2つでは畳まない")
    if case .single = two[0] {} else { expect(false, "2つのときは単独のまま") }

    expectEqual(CommandGrouping.memberSummary([
        command("フォルダを開く: ABC（サンプル商事）"),
        command("フォルダを開く: DEF（サンプル物産）"),
    ]), "ABC・DEF", "畳んだ行の副題は呼び名を・で並べる")
}

// MARK: - メモ

/// 複数枚のメモ（2026-07-30 作者「保存ボタン・検索・一覧・保存先の選択」への答え）
func checkNotes() {
    print("▼ メモ")

    // ── 題名は最初の空でない行
    expectEqual(NoteText.title(for: "会議メモ\n本文です"), "会議メモ", "最初の行が題名になる")
    expectEqual(NoteText.title(for: "\n\n  2行目から始まる"), "2行目から始まる", "空の行は飛ばす")
    expectEqual(NoteText.title(for: "# 見出し記法"), "見出し記法", "Markdownの # は題名から外す")
    expectEqual(NoteText.title(for: ""), "無題のメモ", "何も無ければ無題")
    expectEqual(NoteText.title(for: String(repeating: "あ", count: 100)).count, 60, "題名は60字で切る")

    // ── 検索は語の全部が（題名か本文の）どこかに入っていれば当たり
    expect(NoteText.matches(title: "会議メモ", body: "見積の本数を確認", query: "見積"),
           "本文の言葉で当たる")
    expect(NoteText.matches(title: "会議メモ", body: "x", query: "会議"), "題名の言葉でも当たる")
    expect(NoteText.matches(title: "会議メモ", body: "見積の本数", query: "会議　本数"),
           "全角空白区切りで両方入っていれば当たる")
    expect(!NoteText.matches(title: "会議メモ", body: "見積", query: "会議 予算"),
           "1語でも欠ければ外れる（OR にしない）")
    expect(NoteText.matches(title: "Memo", body: "x", query: "memo"), "大文字小文字は区別しない")
    expect(NoteText.matches(title: "a", body: "b", query: ""), "空の検索は全部に当たる")

    // ── .md のファイル名
    expectEqual(NoteText.fileName(for: "会議メモ\n本文", existing: [], fallback: "メモ 2026-07-30 1030"),
                "会議メモ.md", "題名がそのままファイル名になる")
    expectEqual(NoteText.fileName(for: "会議メモ", existing: ["会議メモ.md"], fallback: "f"),
                "会議メモ 2.md", "同じ名前があれば番号を足す（先にある .md を黙って潰さない）")
    expectEqual(NoteText.fileName(for: "会議メモ", existing: ["会議メモ.md", "会議メモ 2.md"], fallback: "f"),
                "会議メモ 3.md", "番号は空きが出るまで進む")
    expectEqual(NoteText.fileName(for: "経費/交際費: 7月", existing: [], fallback: "f"),
                "経費 交際費 7月.md", "ファイル名に使えない文字は空白にする")
    expectEqual(NoteText.fileName(for: "", existing: [], fallback: "メモ 2026-07-30 1030"),
                "メモ 2026-07-30 1030.md", "題名が無ければ時刻の名前にする")
    expectEqual(NoteText.fileName(for: ".gitignore の話", existing: [], fallback: "f"),
                "gitignore の話.md", "ドット始まりは不可視ファイルになるので外す")

    // ── 1枚時代からの引っ越し
    let old = Date(timeIntervalSince1970: 1_000_000)
    let moved = NoteMigration.migrated(notes: [], legacyText: "昔のメモ", legacyDate: old)
    expectEqual(moved.count, 1, "1枚時代の中身が最初の1枚になる")
    expectEqual(moved.first?.body, "昔のメモ", "中身はそのまま")
    expectEqual(moved.first?.updatedAt, old, "日付もそのまま")
    let existing = [Note(body: "既にある")]
    expectEqual(NoteMigration.migrated(notes: existing, legacyText: "昔のメモ", legacyDate: old),
                existing, "既に複数枚があれば二重に増やさない")
    expect(NoteMigration.migrated(notes: [], legacyText: "  \n ", legacyDate: old).isEmpty,
           "空の1枚時代からは何も作らない")

    // ── 古い notes.enc・引き継ぎファイルでも壊れない
    if let decoded = try? JSONDecoder().decode(Note.self, from: Data(#"{"body":"中身だけ"}"#.utf8)) {
        expectEqual(decoded.body, "中身だけ", "項目が欠けたメモも読める")
    } else {
        expect(false, "項目が欠けたメモも読める")
    }
    if let decoded = try? JSONDecoder.temoto.decode(
        Store.SecretsBackup.self,
        from: Data(#"{"snippets":[],"note":{"text":"旧メモ","updatedAt":"2026-07-01T00:00:00Z"}}"#.utf8)) {
        expect(decoded.notes.isEmpty, "notes の無い古い引き継ぎファイルも読める")
        expectEqual(decoded.note.text, "旧メモ", "1枚時代のメモは残る")
    } else {
        expect(false, "notes の無い古い引き継ぎファイルも読める")
    }

    // ── フォルダの読み書き（本物の一時フォルダで確かめる）
    let folder = FileManager.default.temporaryDirectory
        .appendingPathComponent("temoto-note-check-\(UUID().uuidString)").path
    try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(atPath: folder) }

    expect(NoteFolder.write("一枚目の中身", fileName: "一枚目.md", folderPath: folder), "md を書ける")
    expect(NoteFolder.write("二枚目", fileName: "二枚目.md", folderPath: folder), "2枚目も書ける")
    FileManager.default.createFile(atPath: folder + "/メモではない.txt", contents: Data("x".utf8))
    let scanned = NoteFolder.scan(folder)
    expectEqual(scanned.count, 2, ".md だけを読む（.txt は混ぜない）")
    expect(scanned.contains { $0.title == "一枚目" && $0.body == "一枚目の中身" },
           "書いた中身がそのまま読める")
    expectEqual(Set(NoteFolder.existingNames(folder)), ["一枚目.md", "二枚目.md"], "名前の一覧が取れる")
    expect(NoteFolder.scan("").isEmpty, "置き場が未設定なら空")
    expect(!NoteFolder.write("x", fileName: "x.md", folderPath: ""), "置き場が無ければ書かない")

    // ── フォルダを読む許可の確かめ方（2026-07-30「裁判_チケット規約 が見つかりません」の再発防止）
    //    許可の無いアプリには Spotlight が「書類」の中身を黙って間引く。読めるかは実際に読んで確かめる
    let okFolder = FileManager.default.temporaryDirectory
        .appendingPathComponent("temoto-access-check-\(UUID().uuidString)").path
    try? FileManager.default.createDirectory(atPath: okFolder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(atPath: okFolder) }
    expectEqual(FolderAccess.probe(okFolder), .allowed, "読めるフォルダは allowed")

    let lockedFolder = okFolder + "/locked"
    try? FileManager.default.createDirectory(atPath: lockedFolder, withIntermediateDirectories: true)
    try? FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: lockedFolder)
    expectEqual(FolderAccess.probe(lockedFolder), .denied, "読めないフォルダは denied（黙って0件にしない）")
    try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: lockedFolder)

    expectEqual(FolderAccess.probe(okFolder + "/存在しない"), .denied, "無いフォルダも denied 扱い")
    expectEqual(FolderAccess.protectedPlaces.map(\.title), ["書類", "デスクトップ", "ダウンロード"],
                "守られている3つのフォルダを確かめる")

    // ── メモの設定（古い settings.json でも壊れない）
    if let decoded = try? JSONDecoder().decode(NoteSettings.self, from: Data("{}".utf8)) {
        expectEqual(decoded.folderPath, "", "置き場の項目が無い古い設定も読める")
    } else {
        expect(false, "置き場の項目が無い古い設定も読める")
    }
}

func checkPresentation() {
    section("画面表示用の文字づくり")

    let now = Date(timeIntervalSince1970: 1_800_000_000)
    expectEqual(ClipFormatter.relative(now, now: now), "たった今", "同時刻はたった今")
    expectEqual(ClipFormatter.relative(now.addingTimeInterval(-59), now: now), "たった今", "59秒前はたった今")
    expectEqual(ClipFormatter.relative(now.addingTimeInterval(-60), now: now), "1分前", "60秒前は1分前")
    expectEqual(ClipFormatter.relative(now.addingTimeInterval(-3599), now: now), "59分前", "3599秒前は59分前")
    expectEqual(ClipFormatter.relative(now.addingTimeInterval(-3600), now: now), "1時間前", "3600秒前は1時間前")
    expectEqual(ClipFormatter.relative(now.addingTimeInterval(-86_400), now: now), "1日前", "86400秒前は1日前")
    // 時計が巻き戻ったとき（NTP同期など）に「-1分前」と出さない
    expectEqual(ClipFormatter.relative(now.addingTimeInterval(300), now: now), "たった今", "未来の日付でも変な表示にならない")

    // ここが本題。あいまい検索は Character 単位の位置を返すので、
    // UTF-16 の位置に直さないと色付けがずれる（絵文字を含む題名で実際にずれる）。
    let ascii = "ABC"
    expectEqual(TextRanges.utf16Ranges(in: ascii, characterIndices: [0, 2]).map(\.location), [0, 2],
                "ASCIIならCharacterの位置とUTF-16の位置は同じ")
    expect(TextRanges.utf16Ranges(in: ascii, characterIndices: [0, 2]).allSatisfy { $0.length == 1 },
           "ASCIIの1文字はUTF-16で1つ分")

    // 🗂 はサロゲートペア（UTF-16で2つ分）
    let withEmoji = "🗂作業ログ"
    expectEqual(withEmoji.count, 5, "Character単位では5文字")
    expectEqual(withEmoji.utf16.count, 6, "UTF-16では6つ分")
    let emojiRanges = TextRanges.utf16Ranges(in: withEmoji, characterIndices: [0, 1, 4])
    expectEqual(emojiRanges.map(\.location), [0, 2, 5], "絵文字の後ろの位置が1つずれる")
    expectEqual(emojiRanges.map(\.length), [2, 1, 1], "絵文字の長さは2つ分")

    // 換算した範囲が文字列からはみ出さないこと（はみ出すとNSAttributedStringで即クラッシュする）
    let limit = withEmoji.utf16.count
    let all = TextRanges.utf16Ranges(in: withEmoji, characterIndices: Array(0..<withEmoji.count))
    expect(all.allSatisfy { $0.location >= 0 && $0.location + $0.length <= limit },
           "換算した範囲が文字列の外に出ない")
    expectEqual(all.map(\.length).reduce(0, +), limit, "全文字の長さの合計がUTF-16の長さと一致する")

    // 範囲外の位置を渡されても落ちない
    expectEqual(TextRanges.utf16Ranges(in: "abc", characterIndices: [-1, 5, 1]).map(\.location), [1],
                "範囲外の位置は捨てる")
    expect(TextRanges.utf16Ranges(in: "abc", characterIndices: []).isEmpty, "位置が空なら空を返す")
    expect(TextRanges.utf16Ranges(in: "", characterIndices: [0]).isEmpty, "空文字なら空を返す")

    // あいまい検索の結果をそのまま流し込めること（実際の使われ方）
    if let hit = FuzzyMatcher.match(query: "ログ", in: "🗂作業ログ") {
        let ranges = TextRanges.utf16Ranges(in: "🗂作業ログ", characterIndices: hit.matchedIndices)
        expectEqual(ranges.count, 2, "「ログ」の2文字が色付け対象になる")
        expect(ranges.allSatisfy { $0.location + $0.length <= limit }, "検索結果から作った範囲もはみ出さない")
    } else {
        failures.append("絵文字入りの題名で「ログ」が一致しなかった")
    }
}

// MARK: - 実データの診断（読み取りのみ・中身は出さない）

/// 実際に保存されているファイルを開いて、壊れていないかだけを見る。
///
/// 中身は絶対に表示しない（履歴には振込先や下書きが入りうるため）。
/// 出すのは件数・文字数・コピー元アプリ名・日時だけ。
/// 実行: swift run TemotoChecks --diagnose
func runDiagnosis() {
    print("テモト 保存データの診断（中身は表示しません）")

    let store = Store()
    let directory = store.directory
    print("")
    print("保存先: \(directory.path)")

    guard FileManager.default.fileExists(atPath: directory.path) else {
        print("  まだ保存先がありません（アプリを一度起動してください）")
        exit(0)
    }

    for name in ["settings.json", "quicklinks.json", "commands.json", "snippets.enc", "clips.enc", "note.enc"] {
        let url = directory.appendingPathComponent(name)
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? nil
        let perm = (try? FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int) ?? nil
        if let size {
            let permText = perm.map { String(format: "%03o", $0) } ?? "?"
            let warn = (perm == 0o600) ? "" : "  ⚠️ 本人以外も読める権限です"
            print("  \(name.padding(toLength: 16, withPad: " ", startingAt: 0)) \(size)バイト  権限\(permText)\(warn)")
        } else {
            print("  \(name.padding(toLength: 16, withPad: " ", startingAt: 0)) （まだ無い）")
        }
    }

    print("")
    store.load()

    if let problem = store.vaultProblem {
        print("⚠️ 暗号鍵: \(problem)")
    } else {
        print("暗号鍵: キーチェーンから取り出せました")
    }

    print("")
    print("読めた件数:")
    print("  リンク    \(store.quicklinks.count)件")
    print("  コマンド  \(store.commands.count)件")
    print("  定型文    \(store.snippets.count)件")
    print("  履歴      \(store.clips.count)件")
    print("  メモ      \(store.note.text.count)文字")

    if !store.clips.isEmpty {
        print("")
        print("履歴の新しい順（中身は出さず、文字数とコピー元だけ）:")
        let formatter = DateFormatter()
        formatter.dateFormat = "MM/dd HH:mm:ss"
        for clip in store.clips.prefix(10) {
            let pin = clip.pinned ? "📌" : "  "
            let from = clip.sourceAppName ?? "不明"
            print("  \(pin) \(formatter.string(from: clip.copiedAt))  \(clip.text.count)文字  ← \(from)")
        }
        if store.clips.count > 10 { print("  …ほか \(store.clips.count - 10)件") }

        // 保持ルールが守られているか
        let settings = store.settings.clipboard
        let overCount = store.clips.count > settings.maxCount
        let oldest = store.clips.map(\.copiedAt).min()
        let overAge = oldest.map { Date().timeIntervalSince($0) > Double(settings.maxAgeDays) * 86_400 } ?? false
        print("")
        print(overCount ? "  ⚠️ 上限\(settings.maxCount)件を超えています" : "  ok  上限\(settings.maxCount)件以内")
        print(overAge ? "  ⚠️ \(settings.maxAgeDays)日より古いものが残っています" : "  ok  \(settings.maxAgeDays)日以内")
    }

    // 暗号化ファイルに平文が混ざっていないことを機械で確かめる
    print("")
    let encrypted = ["snippets.enc", "clips.enc", "note.enc"]
    for name in encrypted {
        let url = directory.appendingPathComponent(name)
        guard let data = try? Data(contentsOf: url), !data.isEmpty else { continue }
        // JSONそのままなら先頭が '[' か '{'（0x5B / 0x7B）になる
        let head = data.first ?? 0
        if head == 0x5B || head == 0x7B {
            print("  ⚠️ \(name) が平文のJSONに見えます")
        } else {
            print("  ok  \(name) は平文ではない（先頭 0x\(String(format: "%02x", head))）")
        }
    }

    print("")
    print("診断おわり。中身は一切表示していません。")
    exit(0)
}

// MARK: - 文字が読めるか（すりガラスの上での明暗差）
//
// 2026-07-29、作者に「デザインすごく見づらくなった」と言われた。
// 下の帯の「実行」「移動」「閉じる」と、行き先のアイコンが消えていた。
// 原因は、塗りつぶした地の上で読めるように作られた系統色
// （.secondaryLabelColor / .tertiaryLabelColor）を、半透明の窓に使ったこと。
//
// 目で見て決めた濃さは、次に誰かが少し薄くしたときに黙って壊れる。
// ここでは「どんな画面の上に出しても、この濃さなら読める」を数字で縛る。

func checkContrast() {
    section("文字が読めるか（すりガラスの上での明暗差）")

    // 計算そのものが正しいか。両端を手で確かめる
    expect(abs(Contrast.ratio(0, 1) - 21) < 0.01, "黒と白の差は21倍")
    expect(abs(Contrast.ratio(0.5, 0.5) - 1) < 0.001, "同じ明るさ同士の差は1倍")
    expect(Contrast.ratio(0.2, 0.9) == Contrast.ratio(0.9, 0.2), "どちらを先に置いても同じ")

    // 重ねの計算
    expect(abs(Contrast.composite(overlay: 0, alpha: 1, on: 1) - 0) < 0.001,
           "真っ黒を全部効かせたら黒になる")
    expect(abs(Contrast.composite(overlay: 0, alpha: 0, on: 0.8) - 0.8) < 0.001,
           "まったく効かせなければ地のまま")
    expect(abs(Contrast.composite(overlay: 1, alpha: 0.5, on: 0.0) - 0.5) < 0.001,
           "白を半分だけ効かせたら真ん中")

    // ここが本題。実際に使っている濃さが、想定しうるどの地の上でも読めること
    let caption = Contrast.Tones.caption
    expect(caption.worstRatio >= Contrast.Threshold.readableText,
           "副題・キーの説明は、いちばん条件が悪いときでも読める（"
           + String(format: "%.2f", caption.worstRatio) + " ≧ 4.5）")

    let primary = Contrast.Tones.primary
    expect(primary.worstRatio >= Contrast.Threshold.readableText,
           "題名・入力した文字は、いちばん条件が悪いときでも読める（"
           + String(format: "%.2f", primary.worstRatio) + " ≧ 4.5）")
    expect(primary.worstRatio > caption.worstRatio,
           "主役の文字は、脇の文字よりはっきり見える")

    // 枠は文字ほど求めないが、消えてはいけない
    let edge = Contrast.Tones.keyCapEdge
    expect(edge.worstRatio >= Contrast.Threshold.visibleEdge,
           "キーの札の枠は、消えずに見分けが付く（"
           + String(format: "%.2f", edge.worstRatio) + " ≧ 1.5）")
    expect(Contrast.Tones.keyCapFill.light < edge.light,
           "札の地色は枠より薄い（枠が輪郭を作る）")

    // 実際に消えた2つを、同じものさしで測って落ちることを確かめる。
    // これが落ちないなら、このものさしは何も守っていない
    let systemSecondary = Contrast.Tone(light: 0.50, dark: 0.55)
    expect(systemSecondary.worstRatio < Contrast.Threshold.readableText,
           ".secondaryLabelColor 相当（0.50）は、すりガラスの上だと足りない（"
           + String(format: "%.2f", systemSecondary.worstRatio) + " < 4.5）")

    let systemTertiary = Contrast.Tone(light: 0.26, dark: 0.28)
    expect(systemTertiary.worstRatio < 2.5,
           ".tertiaryLabelColor 相当（0.26）は、ほぼ消える（"
           + String(format: "%.2f", systemTertiary.worstRatio) + " < 2.5）")

    // 以前の枠の濃さ（0.14）も落ちること。作者の画面で枠が見えなかった値
    let oldEdge = Contrast.Tone(light: 0.14, dark: 0.14)
    expect(oldEdge.worstRatio < Contrast.Threshold.visibleEdge,
           "以前の枠の濃さ（0.14）は見えない（"
           + String(format: "%.2f", oldEdge.worstRatio) + " < 1.5）")

    // 覆いが薄くなりすぎていないか。背後の模様を殺すのがこれの仕事
    expect(Contrast.Backdrop.veilLightAlpha >= 0.45,
           "明るいときの覆いは、背後の色を消せる濃さがある")
    expect(Contrast.Backdrop.veilDarkAlpha >= 0.20,
           "暗いときの覆いは、背後の色を消せる濃さがある")
    expect(Contrast.Backdrop.lightDarkest > Contrast.Backdrop.darkBrightest,
           "明るいときの地は、暗いときの地より必ず明るい（見積もりが入れ違っていない）")
}

// MARK: - 行き先の並べ替え

func checkEntryOrder() {
    section("行き先の並べ替え")

    // 既定は宣言順そのまま。入口（すべて）は一覧に入らない
    var s = Settings(hiddenFeatures: [])
    expectEqual(s.orderedEntries.map(\.key),
                ["clipboard", "files", "snippets", "links", "windows", "note", "capture.text", "calculator"],
                "何も決めていなければ既定の順で並ぶ")
    expect(!s.orderedEntries.contains(.mode(.all)),
           "入口は一覧に入らない（自分自身への入口を押す意味がない）")
    expect(!s.hasCustomEntryOrder, "動かしていなければ「元に戻す」は出さない")

    // 番号は上から順。並べ替えると番号も付いて回る
    expectEqual(s.directNumber(for: .mode(.clipboard)), 1, "1番目は ⌘1")
    expectEqual(s.directNumber(for: .note), 6, "6番目のメモは ⌘6")
    expectEqual(s.directNumber(for: .captureText), 7, "7番目の文字読み取りは ⌘7")
    expectEqual(s.entry(forDirectNumber: 1), .mode(.clipboard), "⌘1 で1番目へ行ける")
    expectEqual(s.entry(forDirectNumber: 6), .note, "⌘6 でメモへ行ける")
    expectEqual(s.entry(forDirectNumber: 7), .captureText, "⌘7 で文字読み取りへ行ける")
    expect(s.entry(forDirectNumber: 0) == nil, "⌘0 はどこにも行かない")
    expectEqual(s.entry(forDirectNumber: 8), .mode(.calculator), "⌘8 で計算へ行ける")
    expect(s.entry(forDirectNumber: 9) == nil, "無い番号はどこにも行かない")

    // ▲で1つ上へ
    s.moveEntry("note", by: -1)
    expectEqual(s.orderedEntries.map(\.key),
                ["clipboard", "files", "snippets", "links", "note", "windows", "capture.text", "calculator"],
                "メモが1つ上がる")
    expect(s.hasCustomEntryOrder, "動かしたら「元に戻す」を出す")
    // ⚠️ ここが今回の肝。番号が見た目の順に付いて回らないと
    // 「1番上に置いたのに札は ⌘3」という読めない画面になる
    expectEqual(s.directNumber(for: .note), 5, "上げたら番号も繰り上がる")
    expectEqual(s.directNumber(for: .mode(.windows)), 6, "下がった方は番号も下がる")
    expectEqual(s.entry(forDirectNumber: 5), .note, "⌘5 の行き先も入れ替わる")

    // 端では動かない（押しても何も起きない、を作らないため設定画面では押させない）
    var top = Settings(hiddenFeatures: [])
    top.moveEntry("clipboard", by: -1)
    expectEqual(top.orderedEntries.map(\.key).first, "clipboard", "1番上はそれ以上あがらない")
    var bottom = Settings(hiddenFeatures: [])
    bottom.moveEntry("calculator", by: 1)
    expectEqual(bottom.orderedEntries.map(\.key).last, "calculator", "1番下はそれ以上さがらない")

    // 知らない名前を動かそうとしても壊れない
    var unknown = Settings(hiddenFeatures: [])
    unknown.moveEntry("そんなものはない", by: 1)
    expectEqual(unknown.orderedEntries.map(\.key), Settings().orderedEntries.map(\.key),
                "知らない名前を動かしても並びは変わらない")

    // 隠したら番号は繰り上がる。
    // ⚠️ 隠した行に番号が残っていると、押しても何も起きない番号ができる
    var hidden = Settings(hiddenFeatures: [])
    hidden.setVisible("clipboard", false)
    expectEqual(hidden.visibleEntries.map(\.key),
                ["files", "snippets", "links", "windows", "note", "capture.text", "calculator"],
                "隠したものは一覧から消える")
    expectEqual(hidden.orderedEntries.count, 8, "隠しても並べ替えの一覧には残る（戻せないと困る）")
    expectEqual(hidden.directNumber(for: .mode(.files)), 1, "隠したぶん番号が繰り上がる")
    expect(hidden.directNumber(for: .mode(.clipboard)) == nil, "隠したものに番号は振らない")
    expect(hidden.entry(forDirectNumber: 8) == nil, "隠して7つになったら ⌘8 はどこにも行かない")

    // 行き先の並びは Tab の巡回にも効く
    var reordered = Settings(hiddenFeatures: [])
    reordered.moveEntry("windows", by: -4)
    expectEqual(reordered.visibleModes,
                [.all, .windows, .clipboard, .files, .snippets, .links, .calculator],
                "並べ替えは Tab の順番にも効く（入口は必ず先頭）")

    // 古い settings.json との行き来。
    // ⚠️ ここが崩れると、機能を1つ足しただけで誰の画面にも出てこなくなる
    let partial = Settings(hiddenFeatures: [], entryOrder: ["note", "links"])
    expectEqual(partial.orderedEntries.map(\.key),
                ["note", "links", "clipboard", "files", "snippets", "windows", "capture.text", "calculator"],
                "書いていない名前は既定の順のまま後ろに足す（新しい機能が消えない）")
    let stale = Settings(hiddenFeatures: [], entryOrder: ["もう無い機能", "note"])
    expectEqual(stale.orderedEntries.map(\.key),
                ["note", "clipboard", "files", "snippets", "links", "windows", "capture.text", "calculator"],
                "もう無い名前は黙って捨てる（機能を消しても壊れない）")
    let duplicated = Settings(hiddenFeatures: [], entryOrder: ["note", "note", "links"])
    expectEqual(duplicated.orderedEntries.count, 8, "同じ名前が2回書いてあっても二重に出ない")
    expectEqual(duplicated.orderedEntries.map(\.key).filter { $0 == "note" }.count, 1,
                "同じ名前は1つだけ")

    // 名前の対応
    expectEqual(LauncherEntry.from(key: "clipboard"), .mode(.clipboard), "名前から行き先に戻せる")
    expectEqual(LauncherEntry.from(key: "note"), .note, "名前からメモに戻せる")
    expect(LauncherEntry.from(key: "all") == nil, "入口は並べ替えの対象にならない")
    expect(LauncherEntry.from(key: "でたらめ") == nil, "知らない名前は行き先にならない")
    for entry in LauncherEntry.allCases {
        expectEqual(LauncherEntry.from(key: entry.key), entry, "\(entry.title) は名前と行き来できる")
        expect(!entry.title.isEmpty, "\(entry.key) に表示名がある")
        expect(!entry.summary.isEmpty, "\(entry.key) に説明がある")
    }

    // 隠す名前と並べる名前が同じものであること。
    // ⚠️ ここがずれると「隠したのに並びに残る」「並べたのに隠れる」が起きる
    var everythingHidden = Settings()
    for entry in LauncherEntry.allCases { everythingHidden.setVisible(entry.key, false) }
    expect(everythingHidden.visibleEntries.isEmpty, "全部隠せば一覧は空になる")
    expectEqual(everythingHidden.visibleModes, [.all],
                "全部隠しても入口だけは残る（どこにも行けなくならない）")
}

// MARK: - アプリのキー

func checkAppShortcuts() {
    section("アプリのキー")

    let slack = "/Applications/Slack.app"
    let mail = "/System/Applications/Mail.app"

    // 何も割り当てていない状態から
    var s = Settings()
    expect(s.appBindings.isEmpty, "はじめは1つも割り当てていない")
    expect(s.appShortcut(for: slack) == nil, "割り当てていないアプリのキーは無い")

    // 自動で振るキー。⌃⌥⌘1 から順に、空いているもの
    let first = s.suggestedAppShortcut()
    expectEqual(first?.displayString, "⌃⌥⌘1", "1つめは ⌃⌥⌘1")
    s.setAppShortcut(path: slack, name: "Slack", shortcut: first!)
    expectEqual(s.appBindings.count, 1, "選んだら1件になる")
    expectEqual(s.appShortcut(for: slack)?.displayString, "⌃⌥⌘1", "選んだそばから押せる状態になる")
    expectEqual(s.suggestedAppShortcut()?.displayString, "⌃⌥⌘2", "2つめは次の空き番号")

    // ⚠️ 同じアプリを2行にしない。2行あると画面では両方効きそうに見えるのに、
    // 実際は先に登録した方だけが効く（どちらが先かは画面から読めない）
    s.setAppShortcut(path: slack, name: "Slack", shortcut: Shortcut(
        keyCode: KeyCode.digits[4].code,
        carbonModifiers: Shortcut.controlBit | Shortcut.optionBit | Shortcut.cmdBit,
        keyLabel: KeyCode.digits[4].label))
    expectEqual(s.appBindings.count, 1, "同じアプリを選び直しても行は増えない")
    expectEqual(s.appShortcut(for: slack)?.displayString, "⌃⌥⌘5", "選び直したら新しいキーに差し替わる")

    // ⚠️ ここが一番大事。アプリのキーが重複チェックの輪に入っていること。
    // 入れ忘れると、⌃⌥S を定型文とアプリの両方に割り当てても設定画面は何も言わず、
    // 後から登録した方だけが黙って効かない
    var clash = Settings()
    clash.setAppShortcut(path: slack, name: "Slack", shortcut: Settings.defaultSnippet)
    let names = clash.conflicts().first?.names ?? []
    expectEqual(clash.conflicts().count, 1, "定型文と同じキーを割り当てたら重なりとして出る")
    expect(names.contains("定型文") && names.contains("Slack"),
           "重なったときは両方の名前を出す（片方だけだと直しようがない）")
    expect(Settings().conflicts().isEmpty, "既定の設定に重なりは無い")

    // 空いていない番号は飛ばす
    var packed = Settings()
    for (index, digit) in KeyCode.digits.enumerated() {
        packed.setAppShortcut(path: "/Applications/App\(index).app", name: "App\(index)",
                              shortcut: Shortcut(keyCode: digit.code,
                                                 carbonModifiers: Shortcut.controlBit | Shortcut.optionBit | Shortcut.cmdBit,
                                                 keyLabel: digit.label))
    }
    expectEqual(packed.appBindings.count, 10, "数字キーは10個ぶん割り当てられる")
    expect(packed.suggestedAppShortcut() == nil,
           "全部ふさがったら適当に埋めずに nil を返す（黙って重ねない）")
    expect(!Settings.appShortcutFullMessage.isEmpty, "ふさがったときに言うことが用意してある")

    // 外す
    var removing = Settings()
    removing.setAppShortcut(path: slack, name: "Slack", shortcut: Settings.defaultLauncher)
    removing.setAppShortcut(path: mail, name: "メール", shortcut: Settings.defaultNote)
    removing.removeAppShortcut(path: slack)
    expectEqual(removing.appBindings.count, 1, "外した1件だけが消える")
    expectEqual(removing.appBindings.first?.path, mail, "残る方は触らない")
    removing.removeAppShortcut(path: "/Applications/無い.app")
    expectEqual(removing.appBindings.count, 1, "無いものを外しても何も起きない")

    // 押したときにどうするか
    expectEqual(AppHotKey.outcome(exists: true, isFrontmost: false), .activate, "前にいなければ前に出す")
    expectEqual(AppHotKey.outcome(exists: true, isFrontmost: true), .hide, "すでに前にいればしまう")
    expectEqual(AppHotKey.outcome(exists: false, isFrontmost: false), .missing, "アプリが無ければ知らせる")
    // ⚠️ 見つからないのに「前にいる」ことはあり得ないが、
    // 万一そう来ても「しまう」に倒れない（何も起きない状態が一番わかりにくい）
    expectEqual(AppHotKey.outcome(exists: false, isFrontmost: true), .missing, "見つからない方が優先される")
    expect(AppHotKey.missingMessage(name: "Slack").contains("Slack"),
           "見つからないときは、どのアプリのことか名前で言う")
    expect(AppHotKey.missingMessage(name: "Slack").contains("設定"),
           "どこを直せばいいかまで書く")

    // パスしか無いときの呼び名
    expectEqual(AppBinding.displayName(path: "/Applications/Slack.app"), "Slack", "末尾の .app を落とす")
    expectEqual(AppBinding.displayName(path: "/Applications/Google Chrome.app"), "Google Chrome",
                "名前に空白が入っていても落とすのは .app だけ")
    expectEqual(AppBinding.displayName(path: "/Applications/appstore"), "appstore",
                ".app で終わっていなければそのまま")

    // 古い settings.json との行き来
    let json = """
    {"path":"/Applications/Slack.app","shortcut":{"keyCode":18,"carbonModifiers":6912,"keyLabel":"1"}}
    """
    if let data = json.data(using: .utf8),
       let decoded = try? JSONDecoder().decode(AppBinding.self, from: data) {
        expectEqual(decoded.name, "Slack", "名前が書いていない古い形でも、パスから呼び名を作る")
    } else {
        expect(false, "名前が書いていない古い形でも読める")
    }

    // 設定ファイルを書いて読み直しても消えない
    var saved = Settings()
    saved.setAppShortcut(path: slack, name: "Slack", shortcut: Settings.defaultLauncher)
    if let data = try? JSONEncoder().encode(saved),
       let back = try? JSONDecoder().decode(Settings.self, from: data) {
        expectEqual(back.appBindings.count, 1, "保存して読み直しても割り当ては残る")
        expectEqual(back.appBindings.first?.name, "Slack", "呼び名も残る")
    } else {
        expect(false, "設定を保存して読み直せる")
    }

    // ⚠️ アプリのキーを1つも知らない古い settings.json を読んでも、
    // 他の設定（作者が変えたショートカット）が既定に戻らないこと
    let old = """
    {"launcherShortcut":{"keyCode":49,"carbonModifiers":2048,"keyLabel":"Space"}}
    """
    if let data = old.data(using: .utf8),
       let back = try? JSONDecoder().decode(Settings.self, from: data) {
        expect(back.appBindings.isEmpty, "アプリのキーが無い古い設定でも読める")
        expectEqual(back.windowBindings.count, Settings.defaultWindowBindings.count,
                    "書いていないものは既定で埋まる")
    } else {
        expect(false, "アプリのキーが無い古い設定でも読める")
    }

    // 数字キーの番号。⚠️ 5 と 6 は並んでいない（5=23 / 6=22）
    expectEqual(KeyCode.digits.count, 10, "数字キーは10個")
    expectEqual(KeyCode.digits[4].code, 23, "5 のキー番号は 23")
    expectEqual(KeyCode.digits[5].code, 22, "6 のキー番号は 22（5より小さい）")
    expectEqual(KeyCode.digits.map(\.label), ["1", "2", "3", "4", "5", "6", "7", "8", "9", "0"],
                "打つ順に並んでいる")
    expectEqual(Set(KeyCode.digits.map(\.code)).count, 10, "同じキー番号が2つ入っていない")
}

// MARK: - Macの起動時に開く

func checkLoginItem() {
    section("Macの起動時に開く")

    // 印の付け方。
    // ⚠️ 「許可待ち」を切に見せると、作者はもう一度押してしまい、
    // 押しても入らない＝一番わかりにくい状態になる。登録は済んでいるので入に見せる
    expect(LoginItem.isChecked(.on), "入っていれば印が付く")
    expect(LoginItem.isChecked(.needsApproval), "許可待ちも印は付く（登録そのものは済んでいる）")
    expect(!LoginItem.isChecked(.off), "切なら印は付かない")
    expect(!LoginItem.isChecked(.unavailable), "登録できない場所にあるときは印を付けない")

    // 押せるか
    expect(LoginItem.isEnabled(.on), "入のときは押して切れる")
    expect(LoginItem.isEnabled(.off), "切のときは押して入れられる")
    expect(LoginItem.isEnabled(.needsApproval), "許可待ちでも押して取り消せる")
    expect(!LoginItem.isEnabled(.unavailable),
           "登録できない場所にあるときは押させない（押せば必ず失敗するため）")

    // 下に出す一言。
    // ⚠️ 入っているときに「入っています」と書かない。印を見れば分かることを字で書くと、
    // 本当に読ませたい警告が埋もれる
    expect(LoginItem.note(.on).isEmpty, "入っているときは何も言わない")
    expect(!LoginItem.note(.off).isEmpty, "切のときは、再起動で消えることを伝える")
    expect(LoginItem.note(.off).contains("再起動"),
           "切のときの一言には「再起動」が入っている（何が起きるか書く）")
    expect(LoginItem.note(.needsApproval).contains("システム設定"),
           "許可待ちのときは、どこを開けばいいか書いてある")
    expect(LoginItem.note(.unavailable).contains("~/Applications/Temoto.app"),
           "置き場所が違うときは、正しい置き場所を書いてある")

    // メニューバーに出す警告。
    // ⚠️ 設定画面を開かないと気づけない、では意味がない
    expect(LoginItem.menuWarning(.on) == nil, "入っているときはメニューに何も出さない")
    expect(LoginItem.menuWarning(.off) != nil, "切のときはメニューに警告を出す")
    expect(LoginItem.menuWarning(.needsApproval) != nil, "許可待ちのときもメニューに出す")
    expect(LoginItem.menuWarning(.unavailable) == nil,
           "置き場所の話はメニューに出さない（短く書けないので設定画面で説明する）")

    // 失敗したときの文言。OSの英語エラーをそのまま出さないための道
    expect(!LoginItem.failureMessage(turningOn: true).isEmpty, "入れ損ねたときに言うことがある")
    expect(!LoginItem.failureMessage(turningOn: false).isEmpty, "切り損ねたときに言うことがある")
    expect(LoginItem.failureMessage(turningOn: true) != LoginItem.failureMessage(turningOn: false),
           "入れ損ねと切り損ねで文言が違う")
    expect(LoginItem.failureMessage(turningOn: true).contains("システム設定"),
           "失敗しても手で足せる道を書いてある")

    // 置き場所。
    // ⚠️ テモトの置き場所は ~/Applications/Temoto.app ただ1つと決めてある。
    // .build の中から動かしていると、登録できてもビルドのたびに指す先が消える
    let home = "/Users/tester"
    expect(LoginItem.isInstalledProperly(bundlePath: "\(home)/Applications/Temoto.app", homePath: home),
           "ホームの Applications にあれば正しい")
    expect(LoginItem.isInstalledProperly(bundlePath: "/Applications/Temoto.app", homePath: home),
           "全体の Applications にあっても正しい")
    expect(LoginItem.isInstalledProperly(bundlePath: "\(home)/Applications/Temoto.app/", homePath: home),
           "末尾の / が付いていても同じものとして扱う")
    expect(!LoginItem.isInstalledProperly(bundlePath: "\(home)/dev/.build/release/Temoto.app", homePath: home),
           "組み立ての途中の場所は正しくない")
    expect(!LoginItem.isInstalledProperly(bundlePath: "\(home)/Downloads/Temoto.app", homePath: home),
           "ダウンロードの中は正しくない")
    expect(!LoginItem.isInstalledProperly(bundlePath: "\(home)/Applications/Temoto2.app", homePath: home),
           "名前が違えば別のもの")
    expect(!LoginItem.isInstalledProperly(bundlePath: "/Users/someone/Applications/Temoto.app", homePath: home),
           "他の人のホームは自分の置き場所ではない")
}

// MARK: - その場で答える（計算・和暦・桁）

func checkQuickAnswer() {
    section("その場で答える")

    // 2026-07-29（水）を「きょう」として全部見る
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "Asia/Tokyo") ?? .current
    var todayParts = DateComponents()
    todayParts.year = 2026; todayParts.month = 7; todayParts.day = 29; todayParts.hour = 15
    guard let today = calendar.date(from: todayParts) else {
        failures.append("検証用の日付を作れなかった")
        return
    }
    func ask(_ text: String) -> QuickAnswer.Answer? {
        QuickAnswer.answer(for: text, today: today, calendar: calendar)
    }

    // ── 探しものの邪魔をしないこと（ここが一番大事）
    //
    // 答えは一覧の先頭に割り込む。割り込みすぎると Enter が
    // 探していたものではなく答えをコピーして「壊れた」としか見えない。
    expect(ask("ABC") == nil, "ふつうの言葉には答えない")
    expect(ask("請求書") == nil, "日本語の探しものには答えない")
    expect(ask("1Password") == nil, "数字で始まるアプリ名に答えない")
    expect(ask("2階") == nil, "数字＋知らない字には答えない")
    expect(ask("pdf 今月") == nil, "ファイル検索の言葉には答えない")
    expect(ask("") == nil, "空なら答えない")
    expect(ask("   ") == nil, "空白だけなら答えない")
    expect(ask("2026") == nil, "4桁の数字だけなら答えない（フォルダ名かもしれない）")
    expect(ask("100") == nil, "短い数字だけなら答えない")
    expect(ask("12345") != nil, "5桁からは桁を数えたくなるので答える")
    expect(ask("100+1") != nil, "式なら短くても答える")
    expect(ask("3万") != nil, "単位が付いていれば短くても答える")
    expect(ask("1000円") != nil, "円が付いていれば短くても答える")

    // ── 桁を数えなくてよくする（請求書の額を読む場面）
    let big = ask("1234567")
    expectEqual(big?.value, "1234567", "貼り付ける値に桁区切りは入れない")
    expectEqual(big?.display, "1,234,567", "画面には3桁区切りで出す")
    expect(big?.detail.contains("123万4567") == true, "日本語の桁でも言い直す")
    expect(big?.detail.contains("税込 1,358,023") == true, "税込を出す（円未満切り捨て）")
    expect(big?.detail.contains("税抜 1,122,333") == true, "税抜を出す（円未満切り捨て）")

    // ── 会話に出てくる「万」を数字に直す
    expectEqual(ask("3万")?.value, "30000", "3万は30000")
    expectEqual(ask("3万")?.display, "30,000", "3万の見た目")
    expect(ask("3万")?.detail.contains("税込 33,000") == true, "3万の税込")
    expectEqual(ask("1億2345万")?.value, "123450000", "億と万を混ぜても読む（掛けずに足す）")
    expectEqual(ask("1億2345万6789")?.value, "123456789", "端数まで並べても読む")
    expectEqual(ask("1兆")?.value, "1000000000000", "兆も読む")
    expectEqual(ask("1兆2000億")?.value, "1200000000000", "兆と億")
    // ⚠️ 並びが逆なら「読めなかった」ことにする。打ち間違いをそれらしい数にして返さない
    expect(ask("1万2億") == nil, "小さい単位が先に来る並びは受けない")
    expect(ask("1万万") == nil, "同じ単位を重ねた並びも受けない")
    // ⚠️ 万は掛け算より先。ここを間違えると 3万*2 が 3*20000 になる
    expectEqual(ask("3万*2")?.value, "60000", "3万*2は60000")
    expectEqual(ask("3万+5000")?.value, "35000", "3万+5000は35000")

    // ── 計算
    expectEqual(ask("1000+2000")?.value, "3000", "足し算")
    expectEqual(ask("1000-300")?.value, "700", "引き算")
    expectEqual(ask("12*12")?.value, "144", "掛け算")
    expectEqual(ask("100/4")?.value, "25", "割り算")
    expectEqual(ask("(1+2)*3")?.value, "9", "かっこが先")
    expectEqual(ask("1+2*3")?.value, "7", "掛け算が足し算より先")
    expectEqual(ask("1000*10%")?.value, "100", "％は割合として読む")
    expectEqual(ask("-5+10")?.value, "5", "先頭のマイナス")
    expect(ask("100/0") == nil, "0で割った答えは出さない")
    expect(ask("1+") == nil, "途中で切れた式には答えない")
    expect(ask("(1+2") == nil, "かっこが閉じていなければ答えない")
    expect(ask("1+2)") == nil, "余ったかっこがあれば答えない")
    expect(ask("1..2") == nil, "点が2つなら答えない")
    expect(Arithmetic.evaluate("++") == nil, "記号だけなら式ではない")

    // ── 打ちやすさ（全角のまま打っても通る）
    expectEqual(ask("１２３４５")?.value, "12345", "全角の数字を読む")
    expectEqual(ask("１０００＋２０００")?.value, "3000", "全角の式を読む")
    expectEqual(ask("1,234,567")?.value, "1234567", "桁区切りを打っても読む")
    expectEqual(ask("1234567円")?.value, "1234567", "円を打っても読む")
    expectEqual(ask("¥1234567")?.value, "1234567", "¥を打っても読む")
    expectEqual(ask("100×3")?.value, "300", "全角の×")
    expectEqual(ask("100÷4")?.value, "25", "÷")

    // ── 端数（小数は2桁までにまるめて見せる）
    expectEqual(ask("1234567*1.1")?.value, "1358023.7", "小数は2桁まで")
    expectEqual(ask("10/3")?.value, "3.33", "割り切れないときも2桁")

    // ── 日付と和暦
    expectEqual(ask("きょう")?.value, "2026-07-29", "きょう")
    expectEqual(ask("今日")?.value, "2026-07-29", "漢字でも同じ")
    expectEqual(ask("あした")?.value, "2026-07-30", "あした")
    expectEqual(ask("きのう")?.value, "2026-07-28", "きのう")
    expect(ask("きょう")?.detail.contains("令和8年7月29日") == true, "和暦も出す")
    expect(ask("きょう")?.detail.contains("（水）") == true, "曜日も出す")
    expect(ask("きょう")?.detail.contains("20260729") == true, "区切り無しの形も出す（振込データ用）")
    expectEqual(ask("令和8年7月29日")?.value, "2026-07-29", "和暦から西暦へ")
    expectEqual(ask("令和元年5月1日")?.value, "2019-05-01", "元年は1年")
    expectEqual(ask("平成31年4月30日")?.value, "2019-04-30", "改元の前日")
    expectEqual(ask("2026-07-29")?.value, "2026-07-29", "ハイフン区切り")
    expectEqual(ask("2026/7/29")?.value, "2026-07-29", "スラッシュ区切り")
    expectEqual(ask("2026年7月29日")?.value, "2026-07-29", "年月日でも読む")
    expectEqual(ask("20260729")?.value, "2026-07-29", "8桁でも読む")
    // ⚠️ 日付を先に見る。8桁の数字は日付として読めるならそちらを優先する
    expect(ask("20260729")?.detail.contains("令和8年") == true, "8桁は数字ではなく日付として扱う")
    expect(ask("12345678") != nil, "日付として読めない8桁は数字として扱う")
    expect(ask("12345678")?.detail.contains("1234万5678") == true, "その場合は桁の言い直しが出る")
    // 化ける日付は「読めなかった」ことにする（2月31日を3月3日にしない）
    expect(ask("2026-02-31")?.value != "2026-03-03", "無い日を勝手に別の日にしない")
    // ⚠️ 「7/29/26」は割り算として答える（それ自体は正しい）。
    // 見張りたいのは**日付として読まないこと**。アメリカ式の月/日/年を勝手に
    // 当てはめると、7月29日のつもりが29月として黙って化ける。
    expect(ask("7/29/26")?.value != "2026-07-29", "年が4桁でない並びを日付として読まない")
    expect(JapaneseDate.parse("7/29/26", today: today, calendar: calendar) == nil, "月/日/年の並びは受けない")

    // ⚠️ 万・億・兆は Unicode 上「数字」扱い。数を読む輪で isNumber を使うと
    // 「3万」の万まで数として飲み込んで答えが消える（実際に一度消えた）
    expect(!Arithmetic.isDigit("万"), "万は数字として数えない")
    expect(!Arithmetic.isDigit("①"), "丸数字も数えない")
    expect(!Arithmetic.isDigit("１"), "全角は先にそろえてから数える")
    expect(Arithmetic.isDigit("0") && Arithmetic.isDigit("9"), "0〜9だけを数字として数える")

    // ── 和暦の境目（ここを間違えると書類の年号がずれる）
    expectEqual(JapaneseDate.wareki(year: 2019, month: 4, day: 30), "平成31年4月30日", "改元の前日は平成")
    expectEqual(JapaneseDate.wareki(year: 2019, month: 5, day: 1), "令和元年5月1日", "改元の日は令和元年")
    expectEqual(JapaneseDate.wareki(year: 1989, month: 1, day: 7), "昭和64年1月7日", "昭和の最後の日")
    expectEqual(JapaneseDate.wareki(year: 1989, month: 1, day: 8), "平成元年1月8日", "平成の最初の日")
    expect(JapaneseDate.wareki(year: 1867, month: 1, day: 1) == nil, "明治より前は答えない")

    // ── 日本語の桁
    expectEqual(JapaneseNumber.spell(10_000), "1万", "1万")
    expectEqual(JapaneseNumber.spell(12_340_000), "1234万", "1234万")
    expectEqual(JapaneseNumber.spell(100_000_000), "1億", "1億")
    expectEqual(JapaneseNumber.spell(123_456_789), "1億2345万6789", "億・万・端数を並べる")
    expectEqual(JapaneseNumber.spell(1_000_000_000_000), "1兆", "1兆")
    expectEqual(JapaneseNumber.spell(-12_340_000), "-1234万", "マイナスも言い直す")
    expect(JapaneseNumber.spell(9_999) == nil, "万より小さければ言い直さない")
    expect(JapaneseNumber.spell(1.5) == nil, "小数は言い直さない")

    // ── 3桁区切り
    expectEqual(QuickAnswer.grouped(1_234_567), "1,234,567", "3桁区切り")
    expectEqual(QuickAnswer.grouped(1_000), "1,000", "1000")
    expectEqual(QuickAnswer.grouped(100), "100", "3桁以下はそのまま")
    expectEqual(QuickAnswer.grouped(-1_234_567), "-1,234,567", "マイナスの位置")
    expectEqual(QuickAnswer.grouped(1_234.5), "1,234.5", "小数点の右は区切らない")
    expectEqual(QuickAnswer.grouped(0), "0", "0")

    // ── マイナスに税は付けない（切り捨ての向きが決まっていないので黙る）
    let minus = ask("0-1234567")
    expect(minus != nil, "マイナスの計算自体はできる")
    expect(minus?.detail.contains("税込") == false, "マイナスに税込は出さない")
}

// MARK: - 実行

if CommandLine.arguments.contains("--diagnose") {
    runDiagnosis()
}

print("テモト 動作確認")

checkCoordinates()
checkLayout()
checkScreens()
checkFuzzy()
checkJapaneseReading()
checkClipboardGuard()
checkRetention()
checkClipboardKinds()
checkSnippets()
checkCommands()

do {
    try checkVault()
    try checkKeychain()
    try checkStore()
try checkStartupPhases()
} catch {
    print("  NG   検証中に例外: \(error)")
    failures.append("検証中の例外: \(error)")
}

checkShortcuts()
checkFeatureVisibility()
checkAppVisibility()
checkPanelBehavior()
checkLauncherMode()
checkFileQuery()
checkCommandGrouping()
checkMenuPlan()
checkNotes()
checkPresentation()
checkContrast()
checkLoginItem()
checkEntryOrder()
checkAppShortcuts()
checkQuickAnswer()
checkTextTransform()
checkSnippetDraft()
checkSnippetDictionary()
checkSnippetSearch()
checkAppFolderScan()
checkShelfKeys()
checkShelfFocus()
checkSettingsPanes()
checkSettingsSurface()
checkQuickOpen()
checkShortcutInventory()
checkCaptureShot()
checkQuicklinkTags()
checkErrorLog()
checkClipJoin()
checkCalcLine()
checkAutoExpand()
checkWelcome()
checkScrollStitcher()
checkEntryAliases()
checkCaptureTextEntry()
checkSystemPlace()
checkCalculatorUpgrade()
checkPastePlain()
checkSeedsAreGeneric()
checkModeTints()
checkQuicklinkDraft()
checkPredicateSafety()
checkSpotlightHandover()
checkTileGradient()

func checkTextTransform() {
    section("文字の変換 — F6〜F10 と同じ5種類")

    // ひらがなへ
    expectEqual(TextTransform.hiragana.apply("カタカナ"), "かたかな", "カタカナ → ひらがな")
    expectEqual(TextTransform.hiragana.apply("ﾊﾝｶｸｶﾅ"), "はんかくかな", "半角カナ → ひらがな")
    expectEqual(TextTransform.hiragana.apply("ﾊﾞｲｸとバイク"), "ばいくとばいく", "濁点つき半角カナもひらがなへ")
    expectEqual(TextTransform.hiragana.apply("漢字とABCは変わらない"), "漢字とABCは変わらない", "漢字と英字はひらがな変換で動かない")

    // 全角カタカナへ
    expectEqual(TextTransform.katakana.apply("ひらがな"), "ヒラガナ", "ひらがな → カタカナ")
    expectEqual(TextTransform.katakana.apply("ﾊﾝｶｸ"), "ハンカク", "半角カナ → 全角カタカナ")
    expectEqual(TextTransform.katakana.apply("ｶﾞｷﾞｸﾞ"), "ガギグ", "濁点2文字が1文字のガに合わさる")
    expectEqual(TextTransform.katakana.apply("漢字TEA123"), "漢字TEA123", "漢字と英数はカタカナ変換で動かない")

    // 半角カタカナへ
    expectEqual(TextTransform.halfKatakana.apply("カタカナ"), "ｶﾀｶﾅ", "カタカナ → 半角カナ")
    expectEqual(TextTransform.halfKatakana.apply("がんばる"), "ｶﾞﾝﾊﾞﾙ", "ひらがな → 半角カナ（濁点は2文字に分かれる）")
    expectEqual(TextTransform.halfKatakana.apply("ハローABC123"), "ﾊﾛｰABC123", "英数は半角カナ変換で動かない")
    expectEqual(TextTransform.halfKatakana.apply("、。「」！"), "、。「」！", "句読点とカッコは変換しない")

    // 全角英数へ
    expectEqual(TextTransform.fullAscii.apply("ABC123"), "ＡＢＣ１２３", "半角英数 → 全角英数")
    expectEqual(TextTransform.fullAscii.apply("a-1_?"), "ａ－１＿？", "記号も全角へ")
    expectEqual(TextTransform.fullAscii.apply("かなとカナ"), "かなとカナ", "かなは全角英数変換で動かない")
    expectEqual(TextTransform.fullAscii.apply("A B"), "Ａ Ｂ", "空白は全角にしない（文の区切りを保つ）")

    // 半角英数へ
    expectEqual(TextTransform.halfAscii.apply("ＡＢＣ１２３"), "ABC123", "全角英数 → 半角英数")
    expectEqual(TextTransform.halfAscii.apply("Ａ　Ｂ"), "A B", "全角空白は半角空白へ")
    expectEqual(TextTransform.halfAscii.apply("ｱｲｳとアイウ"), "ｱｲｳとアイウ", "かなは半角英数変換で動かない")

    // 端の形
    expectEqual(TextTransform.katakana.apply(""), "", "空文字は空のまま")
    expectEqual(TextTransform.hiragana.apply("ミックスabcカナ123かな"), "みっくすabcかな123かな", "混在文は対象だけ変わる")

    // 設定の読み書き（古い settings.json に convertBindings が無くても壊れない）
    let empty = try? JSONDecoder().decode(Settings.self, from: Data("{}".utf8))
    expect(empty?.convertBindings.isEmpty == true, "変換キーの無い古い設定は空で読める")
    var s = Settings()
    s.convertBindings = [ConvertBinding(transform: .halfKatakana,
                                        shortcut: Shortcut(keyCode: 3, carbonModifiers: 4096, keyLabel: "F"))]
    if let data = try? JSONEncoder().encode(s),
       let back = try? JSONDecoder().decode(Settings.self, from: data) {
        expectEqual(back.convertBindings, s.convertBindings, "変換キーは保存して読み戻せる")
    } else {
        expect(false, "変換キーは保存して読み戻せる")
    }
}


func checkSnippetDraft() {
    section("定型文の入力 — 打ったものを捨てない")

    // 本文が空かどうか
    expect(SnippetDraft.isEmptyBody(""), "空文字は空")
    expect(SnippetDraft.isEmptyBody("   "), "空白だけは空")
    expect(SnippetDraft.isEmptyBody("\n\n"), "改行だけは空")
    expect(!SnippetDraft.isEmptyBody("あ"), "1文字でも本文があれば空ではない")
    expect(!SnippetDraft.isEmptyBody("  文字  "), "前後に空白があっても中身があれば空ではない")

    // 名前が空でも突き返さない（本文の1行目から付ける）
    expectEqual(SnippetDraft.resolvedTitle(title: "会社の住所", body: "東京都…"), "会社の住所",
                "名前があればそのまま")
    expectEqual(SnippetDraft.resolvedTitle(title: "  会社の住所  ", body: "x"), "会社の住所",
                "名前の前後の空白は落とす")
    expectEqual(SnippetDraft.resolvedTitle(title: "", body: "お世話になっております。\n株式会社…"),
                "お世話になっております。", "名前が空なら本文の1行目から付ける")
    expectEqual(SnippetDraft.resolvedTitle(title: "", body: "\n\n二行目が最初の中身"),
                "二行目が最初の中身", "空の行は飛ばして最初の中身を使う")
    expectEqual(SnippetDraft.resolvedTitle(title: "", body: ""), "名前のない定型文",
                "本文も空なら決まった呼び名にする（無題で消えない）")
    expectEqual(SnippetDraft.resolvedTitle(title: "", body: "   \n  "), "名前のない定型文",
                "空白だけの本文でも名前は作る")

    // 長い1行目は切る（一覧の行に収まる長さ）
    let long = String(repeating: "あ", count: 40)
    let cut = SnippetDraft.resolvedTitle(title: "", body: long, maxLength: 24)
    expectEqual(cut.count, 25, "長い1行目は24字＋…に切る")
    expect(cut.hasSuffix("…"), "切ったことが分かる印を付ける")
    expectEqual(SnippetDraft.resolvedTitle(title: "", body: String(repeating: "い", count: 24), maxLength: 24),
                String(repeating: "い", count: 24), "ちょうどの長さは切らない")
}


func checkQuicklinkDraft() {
    section("リンクの入力 — 打ったものを捨てない")

    // https:// を省いても開ける形にする
    expectEqual(QuicklinkDraft.normalizedURL("github.com"), "https://github.com",
                "むき出しのドメインには https:// を付ける")
    expectEqual(QuicklinkDraft.normalizedURL("  freee.co.jp  "), "https://freee.co.jp",
                "前後の空白は落としてから付ける")
    expectEqual(QuicklinkDraft.normalizedURL("https://example.com"), "https://example.com",
                "すでに https があれば触らない")
    expectEqual(QuicklinkDraft.normalizedURL("http://example.com"), "http://example.com",
                "http も触らない")
    expectEqual(QuicklinkDraft.normalizedURL("mailto:a@example.com"), "mailto:a@example.com",
                "メールの行き先に https を付けない")
    expectEqual(QuicklinkDraft.normalizedURL("raycast://extensions"), "raycast://extensions",
                "アプリ独自の行き先にも https を付けない")
    expectEqual(QuicklinkDraft.normalizedURL(""), "", "空は空のまま（呼ぶ側が止める）")

    // 開ける形かどうか
    expect(QuicklinkDraft.isOpenable("https://example.com"), "ふつうのURLは開ける")
    expect(QuicklinkDraft.isOpenable("https://www.google.com/search?q={query}"),
           "{query} が入っていても開ける形と見なす")
    expect(QuicklinkDraft.isOpenable("mailto:a@example.com"), "メールも開ける")
    expect(!QuicklinkDraft.isOpenable(""), "空は開けない")
    expect(!QuicklinkDraft.isOpenable("https://"), "行き先が無い https は開けない")
    expect(!QuicklinkDraft.isOpenable("ただの文字"), "URLでない文字は開けない")

    // 名前が空でも突き返さない
    expectEqual(QuicklinkDraft.resolvedTitle(title: "freee会計", url: "https://freee.co.jp"), "freee会計",
                "名前があればそのまま")
    expectEqual(QuicklinkDraft.resolvedTitle(title: "  freee会計 ", url: "x"), "freee会計",
                "前後の空白は落とす")
    expectEqual(QuicklinkDraft.resolvedTitle(title: "", url: "https://www.google.com/search?q={query}"),
                "google.com", "名前が空ならURLの行き先から付ける（www. は落とす）")
    expectEqual(QuicklinkDraft.resolvedTitle(title: "", url: "https://github.com"), "github.com",
                "サブドメインが無くても付けられる")
    expectEqual(QuicklinkDraft.resolvedTitle(title: "", url: ""), "名前のないリンク",
                "URLも空なら決まった呼び名（無題で消えない）")

    // 帯に作る・直す・消すの入口がある
    for key in ["⌘N", "⌘E", "⌘⌫"] {
        expect(LauncherMode.links.actions.contains { $0.keys == key },
               "リンクの帯に \(key) がある（作る・直す・消すの入口）")
    }
}


func checkPredicateSafety() {
    section("検索条件 — Spotlightに渡して落ちない形か")

    // 🔴 2026-07-31 作者「ファイル検索で中身だけを選択するとクラッシュする。」
    // 原因は「部品を1つだけ入れた複合条件」。NSMetadataQuery に渡すと例外が飛び、
    // Swift では受け止められないのでアプリごと落ちる（実測で再現・別プロセスで特定）。
    // ここでは条件の木を全部歩いて、その形が1つも無いことを確かめる。
    func hasThinCompound(_ predicate: NSPredicate) -> Bool {
        guard let compound = predicate as? NSCompoundPredicate else { return false }
        if compound.subpredicates.count < 2 { return true }
        return compound.subpredicates.compactMap { $0 as? NSPredicate }.contains(where: hasThinCompound)
    }

    var queries: [String] = []
    // 探し方3つ × 語のある/なし
    for scope in ["名前だけ", "名前と中身", "中身だけ"] {
        queries.append("請求書 \(scope)")
        queries.append("請求書 契約書 \(scope)")
        queries.append(scope)
    }
    // 種類は1つしかUTIを持たないもの（PDF・画像・動画・音声・コード）が落ちる形を作っていた
    for kind in FileKind.allCases {
        queries.append("請求書 \(kind.title)")
        queries.append("\(kind.title) 中身だけ")
        queries.append(kind.title)
    }
    for date in FileDateFilter.allCases {
        queries.append("請求書 \(date.title)")
        queries.append("\(date.title) 中身だけ")
    }
    queries += ["名前:裁判_", "中身:見積", "名前:裁判_ 中身だけ", "名前:A 中身:B pdf 今月",
                "請求書 1MB以上", "請求書 10MB以下", "デスクトップ", ""]

    var checked = 0
    for raw in queries {
        let parsed = FileQuery.parse(raw)
        for searchesContent in [true, false] {
            guard let predicate = parsed.predicate(searchesContent: searchesContent) else { continue }
            checked += 1
            if hasThinCompound(predicate) {
                expect(false, "「\(raw)」（中身\(searchesContent ? "入" : "切")）が部品1つの複合条件を作らない")
            }
            expect(FileQuery.isMetadataSafe(predicate),
                   "「\(raw)」の条件は Spotlight に渡せる形")
        }
    }
    expect(checked > 40, "確かめた条件が\(checked)通りある（十分な数を回した）")

    // 落ちる形そのものを、見張り役が見抜けること
    let one = NSPredicate(format: "kMDItemTextContent CONTAINS[cd] %@", "あ")
    expect(!FileQuery.isMetadataSafe(NSCompoundPredicate(orPredicateWithSubpredicates: [one])),
           "部品1つのORは「渡せない」と判定する")
    expect(!FileQuery.isMetadataSafe(NSCompoundPredicate(andPredicateWithSubpredicates: [one])),
           "部品1つのANDも「渡せない」と判定する")
    expect(FileQuery.isMetadataSafe(one), "ふつうの条件1つはそのまま渡せる")
    let two = NSCompoundPredicate(orPredicateWithSubpredicates: [one, one])
    expect(FileQuery.isMetadataSafe(two), "部品2つのORは渡せる")
    expect(!FileQuery.isMetadataSafe(NSCompoundPredicate(andPredicateWithSubpredicates: [
        two, NSCompoundPredicate(orPredicateWithSubpredicates: [one])])),
        "奥に隠れた部品1つも見つける")

    // 「中身だけ」で語が1つ＝当てる先が1つ。ここが今回落ちていた道
    if let p = FileQuery.parse("見積 中身だけ").predicate(searchesContent: true) {
        expect(!(p is NSCompoundPredicate), "「中身だけ」で語1つなら、包まずそのまま渡す")
    } else {
        expect(false, "「中身だけ」で語1つなら条件ができる")
    }
    // PDFひとつ＝UTIひとつ。ここも落ちていた
    if let p = FileQuery.parse("pdf").predicate(searchesContent: true) {
        expect(!(p is NSCompoundPredicate), "「種類: PDF」だけなら、包まずそのまま渡す")
    } else {
        expect(false, "「種類: PDF」だけで条件ができる")
    }
}


func checkSpotlightHandover() {
    section("本物の Spotlight に渡してみる（落ちないことの確認）")

    // 🔴 ここだけは「本物」に渡す。
    // 2026-07-31 のクラッシュは Objective-C の例外で、Swift 側では受け止められない＝
    // 形を検算するだけでは「本当に渡せるか」を確かめきれない。
    // 実際に NSMetadataQuery へ渡し、落ちなければ通過とする。
    // ⚠️ ここで落ちたら検証そのものが止まる。それでよい（黙って壊れたまま出すより百倍まし）。
    var raws: [String] = []
    for scope in ["名前だけ", "名前と中身", "中身だけ"] {
        raws += ["請求書 \(scope)", "請求書 契約書 \(scope)", scope,
                 "名前:裁判_ \(scope)", "中身:見積 \(scope)"]
        for kind in FileKind.allCases {
            raws += ["\(kind.title) \(scope)", "請求書 \(kind.title) \(scope)"]
        }
        for date in FileDateFilter.allCases {
            raws += ["\(date.title) \(scope)", "請求書 \(date.title) \(scope)"]
        }
    }
    // 打ち間違い・記号・長い語でも落ちないか
    raws += ["*", "?", "\\", "**請求書**", "a*b?c", "\"引用\"", "'単引用'", "%@", "$x",
             "請求書 1MB以上", "請求書 10MB以下", "1KB以上 100MB以下",
             String(repeating: "あ", count: 300), "🈵🍣", "  　 ", "名前: 中身:",
             "デスクトップ 書類 pdf 今月 中身だけ"]

    var handed = 0
    for raw in raws {
        let parsed = FileQuery.parse(raw)
        for searchesContent in [true, false] {
            guard let predicate = parsed.predicate(searchesContent: searchesContent) else { continue }
            guard FileQuery.isMetadataSafe(predicate) else {
                expect(false, "「\(raw)」が関所で止まった（Spotlightに渡せない形を作っている）")
                continue
            }
            let query = NSMetadataQuery()
            query.searchScopes = [NSMetadataQueryUserHomeScope]
            query.predicate = predicate      // ← 落ちるとしたらここ
            handed += 1
        }
    }
    expect(handed > 200, "\(handed)通りの条件を本物のSpotlightに渡して落ちなかった")
}


func checkTileGradient() {
    section("アイコンの下敷きの立体感 — 上が明るい札になっているか")

    // ⚠️ 明暗で数字の向きが逆なのは、暗い見た目は白を・明るい見た目は黒を重ねるため。
    // どちらも「上から光が当たった札」を作る。向きを間違えると、へこんで見える。
    let top = Contrast.Tones.iconTileTop
    let bottom = Contrast.Tones.iconTileBottom
    expect(top.dark > bottom.dark, "暗い見た目: 上の白が下より濃い（上が光る）")
    expect(top.light < bottom.light, "明るい見た目: 上の黒が下より薄い（上が明るい）")

    // 勾配は控えめに（0.1を超えると2010年代のテカりになる）
    expect(abs(top.dark - bottom.dark) <= 0.1, "暗い見た目の振れ幅は0.1以下")
    expect(abs(top.light - bottom.light) <= 0.1, "明るい見た目の振れ幅は0.1以下")

    // 中心は iconTile（0.10）から大きく離れない＝アイコンの読みやすさの前提を崩さない
    let darkMid = (top.dark + bottom.dark) / 2
    let lightMid = (top.light + bottom.light) / 2
    expect(abs(darkMid - Contrast.Tones.iconTile.dark) <= 0.02, "暗い見た目の平均は下敷きの濃さのまま")
    expect(abs(lightMid - Contrast.Tones.iconTile.light) <= 0.02, "明るい見た目の平均は下敷きの濃さのまま")

    // 上端の光の筋は「暗いときだけ」（明るい地の白い線はゴミにしか見えない）
    expect(Contrast.Tones.topGlint.light == 0, "明るい見た目に光の筋は出さない")
    expect(Contrast.Tones.topGlint.dark > 0, "暗い見た目には光の筋がある")
    expect(Contrast.Tones.topGlint.dark <= 0.3, "光の筋は控えめ（白線が主役にならない）")

    // キーの札も同じ「磨いた札」の材質（⌘バッジ・下の帯のキー・アイコンの下敷きで共有）
    let capTop = Contrast.Tones.keyCapTop
    let capBottom = Contrast.Tones.keyCapBottom
    expect(capTop.dark > capBottom.dark, "キーの札・暗い見た目: 上が光る")
    expect(capTop.light < capBottom.light, "キーの札・明るい見た目: 上が明るい")
    expect(abs(capTop.dark - capBottom.dark) <= 0.1, "キーの札の振れ幅は0.1以下")
    expect(abs(capTop.light - capBottom.light) <= 0.1, "キーの札の振れ幅は0.1以下（明）")
    expect(abs((capTop.dark + capBottom.dark) / 2 - Contrast.Tones.keyCapFill.dark) <= 0.02,
           "キーの札の平均は押せる札の濃さ（0.08）のまま＝押せる/見分けるの区別を保つ")
    expect(abs((capTop.light + capBottom.light) / 2 - Contrast.Tones.keyCapFill.light) <= 0.02,
           "キーの札の平均は押せる札の濃さのまま（明）")

    // 下の帯の沈みは「暗いときだけ」（明るい見た目は説明文の4.5の余白が薄く、黒を重ねる余裕が無い）
    expect(Contrast.Tones.footerShade.light == 0, "明るい見た目では帯を沈ませない")
    expect(Contrast.Tones.footerShade.dark >= 0.10, "暗い見た目の沈みは見える濃さ")
    expect(Contrast.Tones.footerShade.dark <= 0.25, "沈みは控えめ（黒帯が主役にならない）")
}


func checkSnippetDictionary() {
    section("合言葉（辞書引き） — 打った文字にぴったり一致したときだけ答える")

    let mails = Snippet(title: "メールアドレス", keyword: "mails", body: "junichiro@example.com")
    let address = Snippet(title: "会社の住所", keyword: "じゅうしょ", body: "東京都○○区1-2-3")
    let noKeyword = Snippet(title: "読みがな無し", keyword: "", body: "本文だけ")
    let all = [mails, address, noKeyword]

    // ぴったり一致だけ
    expectEqual(SnippetDictionary.hits(for: "mails", in: all).map(\.title), ["メールアドレス"],
                "mails で引ける")
    expectEqual(SnippetDictionary.hits(for: "mail", in: all).count, 0, "途中まで（mail）では出ない")
    expectEqual(SnippetDictionary.hits(for: "mails extra", in: all).count, 0, "余計な語が付くと出ない")
    expectEqual(SnippetDictionary.hits(for: "", in: all).count, 0, "空では引かない")

    // 🔴 日本語入力（IME）が入ったまま打った形でも引ける（2026-08-02 作者
    // 「mailzと入力してもtaro@example.comが表示されない」＝IMEの変換中文字列が来ていた）。
    // ローマ字IMEで m,a,i,l,z と打つと検索欄には「まいｌｚ」が入る
    let mailz = Snippet(title: "mail_ゼロクラウド", keyword: "mailz", body: "j_ueda@example.jp")
    let withMailz = all + [mailz]
    expectEqual(SnippetDictionary.hits(for: "まいｌｚ", in: withMailz).map(\.title),
                ["mail_ゼロクラウド"], "IME変換中の「まいｌｚ」で mailz が引ける")
    expectEqual(SnippetDictionary.hits(for: "まいら", in: withMailz).count, 0,
                "違う読み（まいら=maira）では引けない")
    expectEqual(SnippetDictionary.hits(for: "めーるず", in: withMailz).count, 0,
                "めーるず（me-ruzu）は mailz とは別（音の類推まではしない）")
    // かなの合言葉をローマ字で打っても引ける（逆向き）
    expectEqual(SnippetDictionary.hits(for: "jyuusho", in: withMailz).count
                + SnippetDictionary.hits(for: "juusho", in: withMailz).count, 1,
                "かなの合言葉（じゅうしょ）をローマ字で打っても引ける")

    // 畳み込み（あいまい検索と同じ）: 大小・全半角・かな
    expectEqual(SnippetDictionary.hits(for: "MAILS", in: all).count, 1, "大文字でも引ける")
    expectEqual(SnippetDictionary.hits(for: "ｍａｉｌｓ", in: all).count, 1, "全角英字でも引ける")
    expectEqual(SnippetDictionary.hits(for: "ジュウショ", in: all).count, 1, "カタカナで打ってひらがなの合言葉に当たる")
    expectEqual(SnippetDictionary.hits(for: "  mails  ", in: all).count, 1, "前後の空白は無視")

    // 読みがなが空の定型文は、何を打っても出ない（空同士で当たる事故を防ぐ）
    expectEqual(SnippetDictionary.hits(for: "本文だけ", in: all).count, 0, "読みがな無しは合言葉にならない")

    // 同じ合言葉が2つあれば両方（定型文の並び順のまま）
    let twin = [mails, Snippet(title: "別のメール", keyword: "mails", body: "info@example.com")]
    expectEqual(SnippetDictionary.hits(for: "mails", in: twin).map(\.title),
                ["メールアドレス", "別のメール"], "同じ合言葉は両方・並び順のまま")

    // 出す1行は「実際に貼られるもの」
    let context = SnippetContext(now: Date(timeIntervalSince1970: 0), clipboard: "貼", query: "")
    expectEqual(SnippetDictionary.displayLine(for: mails, context: context),
                "junichiro@example.com", "1行ならそのまま")
    let multi = Snippet(title: "署名", keyword: "sig", body: "山田\n株式会社…")
    expectEqual(SnippetDictionary.displayLine(for: multi, context: context),
                "山田 …", "複数行は1行目＋続きの印")
    let clip = Snippet(title: "差し込み", keyword: "c", body: "{clipboard}のまわり")
    expectEqual(SnippetDictionary.displayLine(for: clip, context: context),
                "貼のまわり", "差し込みは展開してから見せる（記号のままにしない）")
    let empty = Snippet(title: "空", keyword: "e", body: "\n\n")
    expectEqual(SnippetDictionary.displayLine(for: empty, context: context), "", "中身が無ければ空")
}


func checkCalculatorUpgrade() {
    section("電卓の強化 — 実務で打つ形の穴を塞ぐ")

    // +%/-% は「割合」（電卓の常識。1980.1 を答えの顔で出さない）
    expectEqual(Arithmetic.evaluate("1980+10%"), 2178, "+10% は1割増し")
    expectEqual(Arithmetic.evaluate("1980-10%"), 1782, "-10% は1割引き")
    expectEqual(Arithmetic.evaluate("100+5%+5%"), 110.25, "割合は左から順に効く")
    expectEqual(Arithmetic.evaluate("200+(100+10)%"), 420, "カッコ全体の%も割合")
    expectEqual(Arithmetic.evaluate("10%"), 0.1, "%単独は今までどおり割る100")
    expectEqual(Arithmetic.evaluate("10%*2"), 0.2, "掛け算が混ざったら普通の数（割合にしない）")
    expectEqual(Arithmetic.evaluate("100+10%*2"), 100.2, "右側が単独の%のときだけ割合")
    expectEqual(Arithmetic.evaluate("1000+100"), 1100, "%の無い足し算は変わらない")

    // 全角の％（日本語入力で打つとこれになる）
    expectEqual(Arithmetic.evaluate("１９８０＋１０％"), 2178, "全角の％も読める")

    // の（%入りの式でだけ「掛ける」）
    expectEqual(Arithmetic.evaluate("3万の10%"), 3000, "3万の10% ＝ 3000")
    expectEqual(Arithmetic.evaluate("128000の15%"), 19200, "128000の15%")
    expect(Arithmetic.evaluate("2026の7") == nil, "%が無い「の」は式にしない（探しものを奪わない）")
    expect(Arithmetic.evaluate("10の倍数") == nil, "式でない言葉はこれまでどおり無視")

    // 千
    expectEqual(Arithmetic.evaluate("3千"), 3000, "3千")
    expectEqual(Arithmetic.evaluate("1万3千"), 13000, "1万3千（大きい順の並び）")
    expectEqual(Arithmetic.evaluate("3千500"), 3500, "3千500")
    expect(Arithmetic.evaluate("3千2万") == nil, "小さい単位→大きい単位の並びは読まない（打ち間違い）")

    // 「電卓」を探しに来た人への案内
    expect(QuickAnswer.isCalculatorLookup("電卓"), "「電卓」で案内が出る")
    expect(QuickAnswer.isCalculatorLookup("でんたく"), "ひらがなでも出る")
    expect(QuickAnswer.isCalculatorLookup("DENTAKU"), "ローマ字大文字でも出る")
    expect(QuickAnswer.isCalculatorLookup("計算"), "「計算」でも出る")
    expect(QuickAnswer.isCalculatorLookup("calc"), "calc でも出る")
    expect(!QuickAnswer.isCalculatorLookup("電卓アプリ"), "余計な語が付いたら出ない（探しものを邪魔しない）")
    expect(!QuickAnswer.isCalculatorLookup(""), "空では出ない")
    expect(!QuickAnswer.calculatorGuide.isEmpty, "案内の文がある")

    // 従来の答えの形も崩れていない（値と説明）
    if let a = QuickAnswer.answer(for: "1980+10%") {
        expectEqual(a.value, "2178", "答えの値は貼ってそのまま使える形")
        expect(a.detail.contains("税込"), "整数の答えには税込も出る")
    } else {
        expect(false, "1980+10% に答えが出る")
    }
}


func checkPastePlain() {
    section("書式なし貼り付け — 設定の読み書き")

    // 古い settings.json に項目が無くても壊れない（既定は未割り当て）
    let empty = try? JSONDecoder().decode(Settings.self, from: Data("{}".utf8))
    expect(empty?.pastePlainShortcut == nil, "古い設定は未割り当てで読める")

    var s = Settings()
    s.pastePlainShortcut = Shortcut(keyCode: 9, carbonModifiers: 4864, keyLabel: "V")  // ⌘⇧V
    if let data = try? JSONEncoder().encode(s),
       let back = try? JSONDecoder().decode(Settings.self, from: data) {
        expectEqual(back.pastePlainShortcut, s.pastePlainShortcut, "割り当ては保存して読み戻せる")
    } else {
        expect(false, "割り当ては保存して読み戻せる")
    }
    s.pastePlainShortcut = nil
    if let data = try? JSONEncoder().encode(s),
       let back = try? JSONDecoder().decode(Settings.self, from: data) {
        expect(back.pastePlainShortcut == nil, "外した状態も保存できる")
    } else {
        expect(false, "外した状態も保存できる")
    }
}


func checkSeedsAreGeneric() {
    section("初期データ — 配って困るものが入っていないか")

    // 🔴 2026-08-02 リリース準備。初期データに顧問先の実名・個人名・個人のURLが
    // 入っていたことがある（配布すると全員に配られる＝守秘義務の問題）。
    // 初期データを将来足すときも、この検査が門番になる。
    let store = Store(directory: FileManager.default.temporaryDirectory
        .appendingPathComponent("temoto-seed-check-\(UUID().uuidString)"))
    _ = store.loadPlaintext()

    var seeded: [String] = []
    for link in store.quicklinks {
        seeded.append(link.title)
        seeded.append(link.url)
    }
    for command in store.commands {
        seeded.append(command.title)
        seeded.append(command.subtitle ?? "")
        seeded.append(String(describing: command.action))
    }
    // ⚠️ 以前はここに「入っていてはいけない名前」を直書きしていたが、
    // 公開リポジトリでは**一覧そのものが名前の逆引き**になる（2026-08-12 の公開監査で指摘）。
    // 名前ではなく「形」で見張る（下）。固有名は中立な道具の名前だけ残す
    let forbidden = ["freee", "claude", "worklog"]
    // ⚠️ ホームのパス（/Users/junichiro/…）は焼き込みではない。
    // NSHomeDirectory() 由来で、配布先ではその人の名前になる。~ に置き換えてから見る
    let cleaned = seeded.map { $0.replacingOccurrences(of: NSHomeDirectory(), with: "~") }
    for word in forbidden {
        expect(!cleaned.contains { $0.localizedCaseInsensitiveContains(word) },
               "初期データに「\(word)」が入っていない")
    }
    // 形の見張り: メールらしきもの・7桁以上の数字・家の実パスが1つでもあれば落とす
    for text in cleaned {
        expect(!(text.contains("@") && text.contains(".")),
               "初期データにメールアドレスらしきものが無い（\(text.prefix(24))…）")
        expect(!text.contains("/Users/"), "初期データに家の実パスが無い")
        var run = 0, worst = 0
        for ch in text { if ch.isNumber { run += 1; worst = max(worst, run) } else { run = 0 } }
        expect(worst < 7, "初期データに7桁以上の数字（IDや電話）が無い（\(text.prefix(24))…）")
    }
    expect(!store.quicklinks.isEmpty, "初期リンクはある（空っぽで始まらない）")
    expect(!store.commands.isEmpty, "初期コマンドはある")
    expect(store.commands.allSatisfy { command in
        if case .runScript = command.action { return false }
        return true
    }, "初期コマンドにスクリプト実行が無い（配布先で勝手に何かを実行しない）")
}


func checkModeTints() {
    section("行き先の持ち色 — しつけられた色（システム設定式）")

    // 白い記号が読める明るさに収まっている（明るすぎると白が消え、暗すぎると地に沈む）
    for tint in ModeTint.all {
        expect(tint.luminance >= 0.25 && tint.luminance <= 0.62,
               "輝度\(String(format: "%.2f", tint.luminance))が白い記号の読める帯（0.25〜0.62）にある")
    }

    // 行き先どうしで色がかぶらない（色でも見分けが付く）
    let tints = ModeTint.all
    for i in 0..<tints.count {
        for j in (i + 1)..<tints.count {
            expect(tints[i].distance(to: tints[j]) > 0.25,
                   "持ち色\(i)と\(j)は離れている（かぶらない）")
        }
    }

    // 「すべて」は行き先の行にならないので持ち色を持たない
    expect(ModeTint.tint(for: .all) == nil, "「すべて」に持ち色は無い")
    // 行き先の5つは全部持っている＋メモ
    for mode in [LauncherMode.clipboard, .files, .snippets, .links, .windows] {
        expect(ModeTint.tint(for: mode) != nil, "\(mode.rawValue) に持ち色がある")
    }
    // ⚠️ 7色目（画面の文字読み取り＝青灰）を足した。彩度を落としてあるのは、
    // 既存6色で色相が埋まっていて、鮮やかな7色目はどれかと必ず0.25未満に近づくため。
    // 意味の上でも他の6つは「場所」でこれは「道具」なので、色で種類が違って見えるのは正しい。
    // ⚠️ 8色目＝計算の藍。最初に置いた値は道具の青灰と距離0.222でこの検査の隣（かぶり検査）に落ちた
    expectEqual(ModeTint.all.count, 8,
                "持ち色は行き先6つ＋メモ＋道具の8色だけ（色を増やすときはここを直して理由を書く）")
}


func checkSnippetSearch() {
    section("定型文の中の検索 — 読みがなと本文でも見つかる")

    // 🔴 2026-08-02 作者「スニペット機能がうまく機能していない。」
    // 定型文の画面で読みがなを打つと、その定型文が**消えていた**。
    // 検索の当て先が題名だけで、読みがな（検索で当てるために作った欄）も本文も見ていなかった。
    let mail = Snippet(title: "mail_ゼロクラウド", keyword: "mailz", body: "j_ueda@example.jp")
    let sign = Snippet(title: "メール結び", keyword: "むすび", body: "よろしくお願いいたします。")
    let all = [mail, sign]

    func found(_ query: String) -> [String] {
        FuzzyMatcher.rank(all, query: query,
                          key: { $0.title },
                          aliases: { SnippetSearch.aliases(for: $0) })
            .map { $0.item.title }
    }

    expectEqual(found("mailz"), ["mail_ゼロクラウド"], "読みがな（mailz）で見つかる")
    expectEqual(found("むすび"), ["メール結び"], "かなの読みがなで見つかる")
    expectEqual(found("j_ueda"), ["mail_ゼロクラウド"], "本文の中身でも見つかる")
    expectEqual(found("ゼロクラウド"), ["mail_ゼロクラウド"], "題名でも今までどおり見つかる")
    expect(found("存在しない語").isEmpty, "関係ない語では出ない")

    // 当て先の中身そのもの
    let aliases = SnippetSearch.aliases(for: mail)
    expect(aliases.contains("mailz"), "読みがなが当て先に入る")
    expect(aliases.contains { $0.contains("j_ueda") }, "本文が当て先に入る")
    expect(SnippetSearch.aliases(for: Snippet(title: "空", keyword: "", body: "")).isEmpty,
           "読みがなも本文も無ければ当て先は空")

    // 日本語入力のまま打った形（まいｌｚ）でも、言い換えで見つかる
    expectEqual(SearchQuery.romajiAlternative(for: "まいｌｚ"), "mailz", "まいｌｚ → mailz に言い換える")
    expect(SearchQuery.romajiAlternative(for: "mailz") == nil, "英字だけなら言い換えない")
    expect(SearchQuery.romajiAlternative(for: "") == nil, "空は言い換えない")
    expect(SearchQuery.romajiAlternative(for: "請求書") == nil, "漢字だけ（かな無し）は言い換えない")
    if let alternative = SearchQuery.romajiAlternative(for: "まいｌｚ") {
        expectEqual(found(alternative), ["mail_ゼロクラウド"], "言い換えた形で定型文が見つかる")
    } else {
        expect(false, "言い換えた形で定型文が見つかる")
    }

    // ⚠️ 長い本文をまるごと当て先にしない（打った1文字が全部の定型文に当たると一覧が意味を失う）
    let long = Snippet(title: "長い", keyword: "", body: String(repeating: "あ", count: 500))
    expect((SnippetSearch.aliases(for: long).first?.count ?? 0) <= 200, "本文の当て先は200字まで")
}


func checkAppFolderScan() {
    section("自分のアプリの置き場所 — 歩き方の規則")

    // 🔴 2026-08-04 作者「シワケ、シオリ、finderのアプリなど、テモトから簡単に
    // アクセスできる様にしたい。」＝シワケ.app は開発フォルダの中にいて、
    // /Applications しか見ていないテモトからは永久に見つからなかった。

    // .app の中には絶対に入らない（中は「◯◯ Helper.app」だらけ）
    expect(!AppFolderScan.shouldDescend(name: "シワケ.app", depth: 0), ".appの中へは入らない")
    expect(!AppFolderScan.shouldDescend(name: "node_modules", depth: 0),
           "node_modules へは入らない（Electronの裏方アプリが大量に入っている）")
    expect(!AppFolderScan.shouldDescend(name: ".git", depth: 0), "隠しフォルダへは入らない")
    expect(!AppFolderScan.shouldDescend(name: "DerivedData", depth: 0), "ビルドの置き場へは入らない")
    expect(AppFolderScan.shouldDescend(name: "release", depth: 0), "ふつうのフォルダへは入る")
    expect(AppFolderScan.shouldDescend(name: "mac-arm64", depth: 3), "深さ3ならまだ入る")
    expect(!AppFolderScan.shouldDescend(name: "mac-arm64", depth: AppFolderScan.maxDepth),
           "決めた深さで止まる（開発フォルダを丸ごと歩いて固まらない）")

    // シワケ.app の実際の並び（10_アプリ開発 → PDF編集 → release → mac-arm64 → シワケ.app）に届く
    let path = ["PDF編集", "release", "mac-arm64"]
    var depth = 0
    var reachable = true
    for name in path {
        if !AppFolderScan.shouldDescend(name: name, depth: depth) { reachable = false; break }
        depth += 1
    }
    expect(reachable, "開発フォルダの4段下にあるアプリまで届く")

    expect(AppFolderScan.isApp(name: "シワケ.app"), ".app は数に入れる")
    expect(!AppFolderScan.isApp(name: "release"), "ふつうのフォルダは数に入れない")
    expect(AppFolderScan.maxApps >= 100, "1フォルダあたりの上限がある（暴走よけ）")

    // 設定の読み書き（古い settings.json でも壊れない）
    let empty = try? JSONDecoder().decode(Settings.self, from: Data("{}".utf8))
    expect(empty?.appFolders.isEmpty == true, "置き場所を足していない古い設定も読める")
    var s = Settings()
    s.appFolders = ["/Users/test/Documents/アプリ"]
    if let data = try? JSONEncoder().encode(s),
       let back = try? JSONDecoder().decode(Settings.self, from: data) {
        expectEqual(back.appFolders, s.appFolders, "足した置き場所は保存して読み戻せる")
    } else {
        expect(false, "足した置き場所は保存して読み戻せる")
    }
}


/// 行き先の「別の呼び方」。
///
/// 2026-08-05 作者「定型分ではなく、スニペットの方がいいかな？？そもそもスニペットって何？？」
/// → 表示は日本語のまま。呼び方だけ人に合わせる。
func checkEntryAliases() {
    section("行き先の別の呼び方")

    // 肝心のところ: スニペットで定型文に当たる
    let snippets = LauncherMode.snippets.aliases
    expect(snippets.contains("snippet"), "英語の snippet で定型文に当たる")
    expect(snippets.contains("スニペット"), "カタカナのスニペットで当たる")
    expect(snippets.contains("すにぺっと"), "ひらがなでも当たる")
    expect(snippets.contains("テンプレート"), "テンプレートでも当たる")

    // 他の行き先も、海外のアプリで慣れた呼び方で引ける
    expect(LauncherMode.clipboard.aliases.contains("clipboard"), "clipboard でコピー履歴に当たる")
    expect(LauncherMode.clipboard.aliases.contains("コピペ"), "コピペでも当たる")
    expect(LauncherMode.links.aliases.contains("bookmark"), "bookmark でリンクに当たる")
    expect(LauncherMode.windows.aliases.contains("tile"), "tile でウィンドウ操作に当たる")
    expect(LauncherMode.files.aliases.contains("spotlight"), "spotlight でファイル検索に当たる")
    expect(LauncherEntry.note.aliases.contains("memo"), "memo でメモに当たる")

    // 入口は行き先の行にならないので呼び方を持たない
    expect(LauncherMode.all.aliases.isEmpty, "入口に呼び方は要らない")

    // ⚠️ 呼び方が別の行き先とかぶると、打った人がどちらに行くか読めなくなる
    var owner: [String: String] = [:]
    for entry in LauncherEntry.allCases {
        for alias in entry.aliases {
            let key = alias.lowercased()
            if let already = owner[key] {
                expect(false, "「\(alias)」が \(already) と \(entry.title) で重なっている")
            }
            owner[key] = entry.title
        }
    }
    expect(!owner.isEmpty, "呼び方がどこかに登録されている")

    // ⚠️ 表示名は日本語のまま（カタカナの専門語に置き換えない）。
    // 作者が「スニペットって何？」と聞いた事実がそのまま理由
    expectEqual(LauncherMode.snippets.title, "定型文", "表示名は日本語のまま")
}

/// 画面の文字読み取りを「行き先」として並べたときの筋。
func checkCaptureTextEntry() {
    section("画面の文字読み取りを行き先に並べる")

    let entry = LauncherEntry.captureText
    expectEqual(entry.key, Settings.captureTextFeature, "名前は隠すときの名前と同じ")
    expectEqual(LauncherEntry.from(key: Settings.captureTextFeature), entry, "名前から戻せる")
    expect(!entry.title.isEmpty, "題名がある")
    expect(!entry.summary.isEmpty, "説明がある")
    expect(entry.mode == nil, "これは行き先（モード）ではない")

    // ⚠️ 名前が行き先の名前とぶつからないこと。
    // ぶつかると隠す・並べ替えが別の機能に効く
    for mode in LauncherMode.allCases {
        expect(mode.rawValue != Settings.captureTextFeature,
               "\(mode.title) の名前とぶつかっていない")
    }
    expect(Settings.captureTextFeature != Settings.noteFeature, "メモの名前ともぶつかっていない")

    // 隠す・出すが効く
    var s = Settings()
    expect(s.isCaptureTextVisible, "既定では出す")
    expect(s.visibleEntries.contains(entry), "既定で一覧に並ぶ")
    s.setVisible(Settings.captureTextFeature, false)
    expect(!s.isCaptureTextVisible, "隠せる")
    expect(!s.visibleEntries.contains(entry), "隠したら一覧から消える")
    expect(s.orderedEntries.contains(entry), "隠しても並べ替えの一覧には残る（戻せる）")
    expect(s.directNumber(for: entry) == nil, "隠したら番号は振らない")

    // 色: 7色目が他とぶつかっていない（かぶり検査は別途あるが、ここでも名指しで見る）
    for other in [ModeTint.clipboard, .files, .snippets, .links, .windows, .note] {
        expect(ModeTint.captureText.distance(to: other) > 0.25,
               "道具の色が他の持ち色と見分けられる")
    }
    expectEqual(ModeTint.tint(for: LauncherEntry.captureText), ModeTint.captureText,
                "行き先から持ち色を引ける")
    expectEqual(ModeTint.tint(for: LauncherEntry.note), ModeTint.note, "メモの持ち色も引ける")
    expectEqual(ModeTint.tint(for: LauncherEntry.mode(.clipboard)), ModeTint.clipboard,
                "モードの持ち色も同じ入口から引ける")
}

/// 初めての人への案内（帯）。
///
/// 2026-08-06〜09 の設計（3案＋3審査）。実測した現状は
/// 「説明なしの許可ダイアログ」＋「数秒で消えるトースト」だけだった。
func checkWelcome() {
    section("初めての人への案内")

    // ⚠️ 勝手に窓を開けるのは**いちばん最初の1回だけ**。
    // 毎回勝手に開くアプリは邪魔者になる
    expect(Welcome.shouldOpenOnLaunch(done: false, shows: 0), "初回だけ自分で窓を開く")
    expect(!Welcome.shouldOpenOnLaunch(done: false, shows: 1), "2回目からは勝手に開かない")
    expect(!Welcome.shouldOpenOnLaunch(done: true, shows: 0), "卒業した人には開かない")

    // 帯は数回まで出す（自分で開いた人には邪魔にならない）
    expect(Welcome.shouldShowBand(done: false, shows: 0), "まだ押せていない人には出す")
    expect(Welcome.shouldShowBand(done: false, shows: 4), "4回目までは出す")
    expect(!Welcome.shouldShowBand(done: false, shows: 5), "5回出しても押されなければ諦める（小言にしない）")
    expect(!Welcome.shouldShowBand(done: true, shows: 0), "押せた人にはもう出さない")

    // ⚠️ 卒業するのは「窓を出すキーを押せた」ときだけ。
    // メニューから開けた人はまだキーを知らない（そこがいちばん教えたいこと）
    expect(Welcome.graduates(on: .launcherHotkey), "窓を出すキーで卒業")
    expect(!Welcome.graduates(on: .otherHotkey), "他の機能のキーでは卒業しない")
    expect(!Welcome.graduates(on: .menu), "メニューから開けても卒業しない")

    // ⚠️ 押しても出ないキーを教えない
    expectEqual(Welcome.bandContent(shortcutLabel: "⌥Space", keyFailed: false), .key("⌥Space"),
                "登録できていればキーを教える")
    expectEqual(Welcome.bandContent(shortcutLabel: "⌘Space", keyFailed: true), .reassign,
                "取られていたら決め直す案内に変える")
    expectEqual(Welcome.bandContent(shortcutLabel: "", keyFailed: false), .reassign,
                "キーが空でも決め直す案内")

    // ⚠️ 文言にキーを直書きしていないこと。
    // 既定は ⌥Space だが作者は ⌘Space に変えている。直書きは画面と実物が食い違う嘘になる
    for text in [Welcome.keyTitle, Welcome.keySubtitle, Welcome.reassignTitle,
                 Welcome.reassignSubtitle, Welcome.graduatedToast] {
        expect(!text.contains("Space"), "文言にキーを直書きしていない（\(text)）")
        expect(!text.contains("⌘") && !text.contains("⌥"), "記号でも直書きしていない（\(text)）")
    }

    // 通信ゼロを伝える一文がある（この製品の一番の取り柄で、どこにも書いていなかった）
    expect(Welcome.privacyLine.contains("送りません"), "どこにも送らないことを伝える")

    // もう一度読む道の言い換え
    expect(Welcome.revisitAliases.contains("つかいかた"), "かなで引ける")
    expect(Welcome.revisitAliases.contains("help"), "英語でも引ける")
    expect(!Welcome.revisitTitle.isEmpty, "呼び名がある")
}

/// 合言葉の自動展開（どのアプリでも）の照合の決まり。
///
/// 2026-08-10 作者「設定した単語を入力したら登録した文字が表示される機能。
/// この機能が実装されていないので、実装して。」
///
/// ⚠️ 決まりを1つ間違えると「打った文字が勝手に消える」最悪の壊れ方をする。
/// だから照合は Core に置いて、ここで機械に縛らせる。
func checkAutoExpand() {
    section("合言葉の自動展開")

    let snippets = [(keyword: "mailz", body: "j@example.com"),
                    (keyword: "sig", body: "署名"),
                    (keyword: "sign", body: "長い方"),
                    (keyword: "a", body: "1文字"),
                    (keyword: "二 つ", body: "空白入り")]

    // 末尾一致で当たる
    expectEqual(AutoExpand.match(typed: "mailz", snippets: snippets)?.body, "j@example.com", "合言葉で当たる")
    expectEqual(AutoExpand.match(typed: "mailz", snippets: snippets)?.deleteCount, 5, "消すのは打った5文字")
    expect(AutoExpand.match(typed: "mail", snippets: snippets) == nil, "打ちかけでは反応しない")

    // ⚠️ 単語の途中で暴発しない（design の中の sig）
    expect(AutoExpand.match(typed: "design", snippets: [(keyword: "sig", body: "x")]) == nil,
           "英単語の途中では反応しない")
    expectEqual(AutoExpand.match(typed: " sig", snippets: snippets)?.body, "署名", "空白の後なら反応する")
    // 日本語の直後は許す（「請求書はmailz」の打ち方が普通にある）
    expectEqual(AutoExpand.match(typed: "請求書はmailz", snippets: snippets)?.body, "j@example.com",
                "日本語の直後は反応する")

    // 長い合言葉が勝つ
    expectEqual(AutoExpand.match(typed: "sign", snippets: snippets)?.body, "長い方", "長い合言葉が勝つ")

    // 大文字小文字は区別しない。消す数は打った長さ
    expectEqual(AutoExpand.match(typed: "MAILZ", snippets: snippets)?.body, "j@example.com", "大文字でも当たる")
    expectEqual(AutoExpand.match(typed: "MAILZ", snippets: snippets)?.deleteCount, 5, "消す数は打った長さ")

    // ⚠️ 危ない合言葉は登録されていても効かせない（最後の網はここ）
    expect(AutoExpand.match(typed: "a", snippets: snippets) == nil, "1文字の合言葉は効かない")
    expect(AutoExpand.match(typed: "二 つ", snippets: snippets) == nil, "空白入りの合言葉は効かない")

    // 打鍵の覚え方
    expectEqual(AutoExpand.buffer("abc", appending: "d"), "abcd", "打った分が足される")
    expectEqual(AutoExpand.bufferAfterBackspace("abcd"), "abc", "⌫で1つ戻る")
    expectEqual(AutoExpand.bufferAfterBackspace(""), "", "空で⌫しても落ちない")
    let long = AutoExpand.buffer(String(repeating: "x", count: 40), appending: "y")
    expectEqual(long.count, AutoExpand.bufferLimit, "覚えるのは末尾だけ（持たないのが一番安全）")
    expect(long.hasSuffix("y"), "新しい方を残す")
}

/// 計算の行き先。
///
/// 2026-08-10 作者「計算機能無くなった？？計算ようのメニューが欲しい。計算機能強めて。」
/// ＝入口で式を打てば前から動いていたが、**一覧に名前が無いので気づけなかった**。
func checkCalcLine() {
    section("計算の行き先")

    // 基本
    // ⚠️ 端数を勝手に丸めない（1234567×1.1 = 1358023.7）。会計の数字を黙って切ると事故になる
    expectEqual(CalcLine.line(for: "1234567*1.1")?.display, "1,358,023.7", "掛け算（端数もそのまま）")
    expectEqual(CalcLine.line(for: "(1200+800)*3")?.display, "6,000", "かっこ")
    expectEqual(CalcLine.line(for: "3万+5000")?.display, "35,000", "万も打てる")
    expect(CalcLine.line(for: "")  == nil, "空なら答えない")
    expect(CalcLine.line(for: "あいうえお") == nil, "式でなければ答えない")

    // ⚠️ 会計の仕事で毎回いるのは「漢数字の読み」と「税込・税抜」。ここが出ること
    let detail = CalcLine.line(for: "1234567")?.detail ?? ""
    expect(detail.contains("万"), "漢数字の読みが出る（\(detail)）")
    expect(detail.contains("税込"), "税込が出る")
    expect(detail.contains("税抜"), "税抜が出る")

    // ⚠️ マイナスには税込を出さない（切り捨ての向きが実務で決まっていない＝勝手に決めない）
    let minus = CalcLine.line(for: "0-500")?.detail ?? ""
    expect(!minus.contains("税込"), "マイナスに税込は出さない（\(minus)）")
    // 小数にも出さない（3.14 の税込に意味は無い）
    expect(!(CalcLine.line(for: "3.14")?.detail ?? "").contains("税込"), "小数に税込は出さない")

    // 前の答えを続けて使う
    expectEqual(CalcLine.line(for: "ans*2", previous: 100)?.display, "200", "ans が使える")
    expectEqual(CalcLine.line(for: "前/4", previous: 100)?.display, "25", "日本語でも使える")
    expectEqual(CalcLine.line(for: "答え+1", previous: 100)?.display, "101", "「答え」でも使える")
    // ⚠️ 前の答えが無いときは触らない（「前」を含む言葉を壊さない）
    expectEqual(CalcLine.substitutePrevious("前の資料", previous: nil), "前の資料", "前の答えが無ければ何もしない")

    // 貼るのは生の数（桁区切りは読むための飾り。表計算に入れると文字になる）
    expectEqual(CalcLine.trimZeros(1_358_023), "1358023", "貼るのは区切り無しの数")

    // 使い方の見本がある（何が書けるか分からないのが使われない一番の理由）
    expect(CalcLine.examples.count >= 4, "見本が並んでいる")
    for example in CalcLine.examples where !example.input.contains("ans") {
        expect(CalcLine.line(for: example.input) != nil, "見本は実際に計算できる（\(example.input)）")
    }

    // 行き先として一覧に在る（「無くなった？」の再発防止）
    expect(LauncherEntry.allCases.contains(.mode(.calculator)), "行き先の一覧に計算がある")
    expect(LauncherMode.calculator.aliases.contains("電卓"), "電卓でも引ける")
    expect(LauncherMode.calculator.aliases.contains("keisan"), "ローマ字でも引ける")
    expectEqual(LauncherEntry.allCases.last, .mode(.calculator),
                "新しい行き先は末尾（既存の⌘番号をずらさない）")
}

/// コピー履歴を複数まとめて貼るときの決まり。
///
/// 2026-08-09 作者「コピーする際に複数選択したい。」
func checkClipJoin() {
    section("複数まとめて貼る")

    // ⚠️ 順番は画面に見えているとおり。呼ぶ側が並べ替えて渡す約束で、ここは受けた順に繋ぐ
    let three = ClipJoin.join(["1行目", "2行目", "3行目"])
    expectEqual(three.text, "1行目\n2行目\n3行目", "受けた順に改行で繋ぐ")
    expectEqual(three.joined, 3, "3件つないだ")
    expectEqual(three.skipped, 0, "落としたものは無い")

    // ⚠️ 区切りは改行1つ。空行を入れると短い断片を集めたとき貼り先が間延びする
    expectEqual(ClipJoin.separator, "\n", "区切りは改行1つ")

    // 絵やファイル（文字でないもの）は繋げないので落とす。**必ず件数を伝える**
    let mixed = ClipJoin.join(["文字", nil, "もう1つ", nil])
    expectEqual(mixed.text, "文字\nもう1つ", "文字だけが繋がる")
    expectEqual(mixed.joined, 2, "繋いだのは2件")
    expectEqual(mixed.skipped, 2, "落としたのは2件")
    expect(ClipJoin.message(for: mixed).contains("2件"), "落とした件数を伝える")
    expect(ClipJoin.message(for: mixed).contains("外しました"), "黙って落とさない")

    // 空の行も「文字でないもの」と同じ扱い（空行だけが増えるのを防ぐ）
    let empty = ClipJoin.join(["文字", "", "もう1つ"])
    expectEqual(empty.text, "文字\nもう1つ", "空の行は繋がない")
    expectEqual(empty.skipped, 1, "空も落とした数に入る")

    // 1件も貼れないとき
    let none = ClipJoin.join([nil, nil])
    expect(none.isEmpty, "貼れるものが無い")
    expect(ClipJoin.message(for: none).contains("ありませんでした"), "貼れないことを伝える")

    // 1件だけなら繋ぎ目は出ない
    let single = ClipJoin.join(["1つだけ"])
    expectEqual(single.text, "1つだけ", "1件はそのまま")
    expect(!single.text.contains("\n"), "余計な改行が付かない")

    // 何も選んでいない・1件だけのときは、下の帯に何も出さない（うるさくしない）
    expectEqual(ClipJoin.status(count: 0), "", "0件なら黙る")
    expectEqual(ClipJoin.status(count: 1), "", "1件でも黙る")
    expect(ClipJoin.status(count: 3).contains("3件"), "2件以上で件数を出す")
    expect(ClipJoin.status(count: 3).contains("⏎"), "次に何を押すかも書く")

    // ── 絵やファイルが混ざるとき（2026-08-09 作者「画像は一気に選べないですね！」）
    func text(_ s: String) -> ClipJoin.Picked { ClipJoin.Picked(text: s, isImage: false, isFile: false) }
    let image = ClipJoin.Picked(text: nil, isImage: true, isFile: false)
    let file = ClipJoin.Picked(text: nil, isImage: false, isFile: true)

    // 文字だけ＝そのまま貼る（.txt にしない。ふつうに貼りたい人に .txt は的外れ）
    let onlyText = ClipJoin.plan([text("あ"), text("い")])
    expectEqual(onlyText.way, .text, "文字だけなら文字として貼る")
    expectEqual(onlyText.text, "あ\nい", "改行で繋ぐ")

    // ⚠️ 絵が1つでも入ったら**全部ファイル**にする（決まりを1文で言えるようにする）
    let withImage = ClipJoin.plan([text("あ"), image, image])
    expectEqual(withImage.way, .files, "絵が混ざったらファイルとして渡す")
    expectEqual(withImage.imageCount, 2, "絵は2件")
    expectEqual(withImage.textCount, 1, "文字も数える（捨てない）")
    expectEqual(withImage.text, "あ", ".txt の中身になる")

    // 絵だけでも渡せる（ここが「一気に選べない」と言われた本体）
    let onlyImages = ClipJoin.plan([image, image, image])
    expectEqual(onlyImages.way, .files, "絵だけでも渡せる")
    expectEqual(onlyImages.imageCount, 3, "3件とも渡す")
    expect(ClipJoin.message(for: onlyImages).contains("画像3件"), "何件渡したかを言う")

    // ファイルも同じ扱い
    let onlyFiles = ClipJoin.plan([file, file])
    expectEqual(onlyFiles.way, .files, "ファイルもまとめて渡せる")
    expectEqual(onlyFiles.fileCount, 2, "2件")

    // 全部入りのとき、3種類とも件数を言う
    let all = ClipJoin.plan([text("あ"), image, file])
    let allMessage = ClipJoin.message(for: all)
    expect(allMessage.contains("画像1件"), "絵の件数")
    expect(allMessage.contains("ファイル1件"), "ファイルの件数")
    expect(allMessage.contains("文字1件"), "文字の件数")
    expect(allMessage.contains(".txt"), "文字が .txt になることを伝える")

    // 何も無いとき
    expectEqual(ClipJoin.plan([]).way, .nothing, "空なら渡すものが無い")
    expectEqual(ClipJoin.plan([ClipJoin.Picked(text: "", isImage: false, isFile: false)]).way, .nothing,
                "空の文字だけでも渡すものが無い")

    // 下の帯の案内に「複数選ぶ」が出ている（書かなければ誰も気付かない）
    expect(LauncherMode.clipboard.actions.contains { $0.keys == "⇧↑↓" },
           "コピー履歴の案内に ⇧↑↓ がある")
}

/// うまくいかなかったことの記録と、伏せ字。
///
/// 2026-08-09 作者「今後他の人にも使ってもらい、エラー情報を収集したい。」→ A案（手元に貯めて本人が送る）
///
/// ⚠️ ここは**攻めるつもりで**確かめる。記録は最終的に人の手を離れて届く。
/// 1回でも中身が漏れたら「安全だから使っている」という前提そのものが崩れる。
func checkErrorLog() {
    section("不具合の記録と伏せ字")

    // ── 出してはいけないものが本当に消えるか
    let home = NSHomeDirectory()
    let masked = ErrorLog.redact("書けません: \(home)/Documents/請求書.pdf")
    expect(!masked.contains(home), "家のフォルダの本当の場所が残らない")
    expect(masked.contains("~"), "~ に置き換わる")

    // 他の人の家も形で潰す（自分の家と一致しなくても消す）
    let other = ErrorLog.redact("/Users/tanaka/Desktop/x.txt が開けません")
    expect(!other.contains("tanaka"), "他人の名前も消える（\(other)）")

    expect(!ErrorLog.redact("taro@example.com に送れません").contains("example.com"),
           "メールアドレスが消える")
    expect(ErrorLog.redact("taro@example.com に送れません").contains("***@***"), "伏せた印が残る")

    // ⚠️ ここが最初の版で抜けていた穴（2026-08-09 実測で発覚）。
    // 家の場所を ~ にしても、**フォルダ名とファイル名に仕事の相手の名前が残る**。
    // 記録は人の手を離れて届くので、誰の仕事をしているかが漏れるのは致命的
    let clientPath = ErrorLog.redact("~/Documents/01_ABC/請求書_サンプル物産.pdf が開けません")
    expect(!clientPath.contains("サンプル物産"), "取引先の名前が残らない（\(clientPath)）")
    expect(!clientPath.contains("ABC"), "顧問先の略号も残らない")
    expect(clientPath.contains("pdf"), "種類は残す（何のファイルで起きたかは追いたい）")
    expect(clientPath.contains("~"), "家の下だったことは残す")
    expect(clientPath.contains("開けません"), "何が起きたかの文は壊さない")

    // 点入りの名前を拡張子と間違えて残さない
    let dotted = ErrorLog.redact("/tmp/請求書.サンプル物産様 が開けません")
    expect(!dotted.contains("サンプル物産"), "点入りの名前も残らない（\(dotted)）")

    // 場所でない文はそのまま（文章まで壊さない）
    expectEqual(ErrorLog.redact("3件 失敗しました"), "3件 失敗しました", "普通の文は変えない")

    // 鍵・合言葉らしき長い塊（最後の網）
    // ⚠️ 偽トークンでも**ソースに完全な形を書かない**（実行時に組み立てる）。
    // 本物の形をした文字列がソースに在ると、GitHub の秘密押し込み保護が
    // 公開リポジトリへの push を拒否する（2026-08-13 に実際に拒否された）
    let token = ErrorLog.redact("token=sk_live_" + String(repeating: "Q", count: 24))
    expect(!token.contains("sk_live"), "鍵らしき塊が消える（\(token)）")

    // URL は行き先だけ残して、中身は落とす
    let url = ErrorLog.redact("開けません: https://docs.google.com/spreadsheets/d/1P-3OCO8hQRq9nbKe/edit?gid=123")
    expect(url.contains("docs.google.com"), "どこで起きたかは分かる")
    expect(!url.contains("spreadsheets/d"), "書類の場所は残らない（\(url)）")
    expect(!url.contains("gid=123"), "問い合わせの中身も残らない")

    // 長い数字（電話・口座・番号）
    expect(!ErrorLog.redact("口座 1234567890123").contains("1234567890123"), "長い数字が消える")
    // ⚠️ 短い数字は消さない（件数やコード番号まで消すと、何が起きたか分からなくなる）
    expect(ErrorLog.redact("3件 失敗（コード 42）").contains("42"), "短い数字は残す")

    // ⚠️ 作る時点で伏せる（あとで伏せ忘れる道を作らない）
    let entry = ErrorLog.Entry(at: Date(timeIntervalSince1970: 0), area: "コピー履歴",
                               what: "書き込みに失敗", detail: "\(home)/x.enc")
    expect(!entry.detail.contains(home), "Entry を作った時点で伏せてある")

    // ── 貯めすぎない
    let many = (0..<400).map {
        ErrorLog.Entry(at: Date(timeIntervalSince1970: Double($0)), area: "a", what: "b")
    }
    let trimmed = ErrorLog.trim(many)
    expectEqual(trimmed.count, ErrorLog.maxEntries, "上限まで減らす")
    expectEqual(trimmed.last?.at, many.last?.at, "**新しい方**を残す（いま起きている失敗が知りたい）")
    expectEqual(ErrorLog.trim([]).count, 0, "空でも落ちない")

    // ── 送る前に本人が読める形になっているか
    let report = ErrorLog.report(
        entries: [ErrorLog.Entry(at: Date(timeIntervalSince1970: 1_780_000_000),
                                 area: "画面を撮る", what: "許可がありません")],
        appVersion: "0.1.0", osVersion: "26.5", now: Date(timeIntervalSince1970: 1_780_000_100))
    expect(report.contains("画面を撮る"), "どこで起きたかが読める")
    expect(report.contains("許可がありません"), "何が起きたかが読める")
    expect(report.contains("0.1.0"), "版が分かる")
    expect(report.contains("伏せてあります"), "何を伏せたかを本人に伝えている")
    expect(report.contains("記録していません"), "はじめから記録していないものを伝えている")

    // 1件も無いときに「空の報告」を送らせない案内が出る
    let empty = ErrorLog.report(entries: [], appVersion: "0.1.0", osVersion: "26.5", now: Date())
    expect(empty.contains("記録はありません"), "空なら空と分かる")

    // ── 何が一番起きているか
    let mixed = [
        ErrorLog.Entry(at: Date(), area: "画面を撮る", what: "許可がありません"),
        ErrorLog.Entry(at: Date(), area: "画面を撮る", what: "許可がありません"),
        ErrorLog.Entry(at: Date(), area: "コピー履歴", what: "書き込みに失敗"),
    ]
    let summary = ErrorLog.summary(entries: mixed)
    expectEqual(summary.first?.count, 2, "多い順に並ぶ")
    expect(summary.first?.what.contains("画面を撮る") == true, "一番多いものが先頭")

    // 時刻は分まで（秒までは出さない）
    let stamp = ErrorLog.stamp(Date(timeIntervalSince1970: 1_780_000_000))
    expectEqual(stamp.count, 16, "「2026-08-09 14:03」の形（\(stamp)）")
}

/// リンクのタグ。
///
/// 2026-08-09 作者「リンクにタグつけれる様にしたい。」
func checkQuicklinkTags() {
    section("リンクのタグ")

    // ⚠️ 最優先: 古い quicklinks.json が読めること。
    // ここが壊れると、登録したリンクが全部消えたように見える
    // （2026-07-30 に ClipImageInfo で実際に踏んだ地雷と同じ形）
    let old = """
    [{"id":"11111111-1111-1111-1111-111111111111","title":"freee会計","url":"https://secure.freee.co.jp/"}]
    """
    do {
        let links = try JSONDecoder().decode([Quicklink].self, from: Data(old.utf8))
        expectEqual(links.count, 1, "タグが無い古いファイルも読める")
        expectEqual(links[0].title, "freee会計", "題名がそのまま読める")
        expectEqual(links[0].tags, [], "タグ欄が無ければ空として読む")
    } catch {
        expect(false, "古いファイルが読めない: \(error)")
    }

    // 書いて読み直しても変わらない
    let link = Quicklink(title: "落とし物台帳", url: "https://example.com/sheet", tags: ["ABC", "台帳"])
    do {
        let data = try JSONEncoder().encode([link])
        let back = try JSONDecoder().decode([Quicklink].self, from: data)
        expectEqual(back[0].tags, ["ABC", "台帳"], "書いて読み直してもタグが残る")
    } catch {
        expect(false, "書き戻せない: \(error)")
    }

    // 打った1行をタグにほどく
    expectEqual(Quicklink.parseTags("ABC 台帳 共有"), ["ABC", "台帳", "共有"], "空白で区切れる")
    expectEqual(Quicklink.parseTags("ABC, 台帳"), ["ABC", "台帳"], "カンマでも区切れる")
    expectEqual(Quicklink.parseTags("ABC、台帳"), ["ABC", "台帳"], "全角の読点でも区切れる")
    expectEqual(Quicklink.parseTags("ABC　台帳"), ["ABC", "台帳"], "全角の空白でも区切れる")
    expectEqual(Quicklink.parseTags(""), [], "空なら空")
    expectEqual(Quicklink.parseTags("   "), [], "空白だけなら空")

    // ⚠️ 同じ札を2枚にしない。ただし**打った形は変えない**
    expectEqual(Quicklink.parseTags("ABC abc ABC"), ["ABC"], "同じ札は1枚だけ（大小を無視して見分ける）")
    expectEqual(Quicklink.parseTags("Abc"), ["Abc"], "打った大文字小文字はそのまま残す")
    expectEqual(Quicklink.parseTags("台帳 ABC"), ["台帳", "ABC"], "並べ替えない（書いた順＝大事な順）")

    // 画面に出す形と、設定に書き戻す形が一致する（往復して崩れない）
    let line = Quicklink(title: "x", url: "https://x", tags: ["ABC", "台帳"]).tagLine
    expectEqual(line, "ABC 台帳", "画面に出す形")
    expectEqual(Quicklink.parseTags(line), ["ABC", "台帳"], "その形をもう一度ほどいても同じ")

    // ⚠️ 行の右端の札は伸ばさない（伸びると題名を押しのける）
    expectEqual(Quicklink(title: "x", url: "u", tags: []).badgeLabel, "リンク", "タグが無ければ今までどおり")
    expectEqual(Quicklink(title: "x", url: "u", tags: ["ABC"]).badgeLabel, "ABC", "1枚ならそのまま")
    expectEqual(Quicklink(title: "x", url: "u", tags: ["ABC", "台帳"]).badgeLabel, "ABC +1", "2枚目からは数で出す")
    expectEqual(Quicklink(title: "x", url: "u", tags: ["ABC", "台帳", "共有"]).badgeLabel, "ABC +2", "3枚でも札は伸びない")
    expectEqual(Quicklink(title: "x", url: "u", tags: ["とてもながいたぐのなまえ"]).badgeLabel,
                "とてもながいたぐ…", "長い札は縮める（8文字＋…）")
    let longBadge = Quicklink(title: "x", url: "u", tags: ["とてもながいたぐのなまえ", "台帳"]).badgeLabel
    expect(longBadge.count <= 14, "縮めたうえで数を足しても短いまま（\(longBadge)）")

    // 前後の空白は落とす（打ち間違いで札が増えない）
    expectEqual(Quicklink.parseTags(" ABC ,  台帳 "), ["ABC", "台帳"], "前後の空白を落とす")
}

/// 画面を撮る道具の決まり。
///
/// 2026-08-06 作者「キャプチャー機能つけれますか？？
/// 選択範囲や画面全部、画面スクロールでページ全体など。」
func checkCaptureShot() {
    section("画面を撮る")

    expect(CaptureShot.all.count >= 3, "範囲・全体・ウィンドウがある")
    expectEqual(Set(CaptureShot.all.map(\.id)).count, CaptureShot.all.count, "IDが重なっていない")
    expectEqual(Set(CaptureShot.all.map(\.title)).count, CaptureShot.all.count, "題名が重なっていない")

    for shot in CaptureShot.all {
        expect(!shot.aliases.isEmpty, "別の呼び方がある（\(shot.title)）")
        expect(!shot.symbol.isEmpty, "しるしがある（\(shot.title)）")
        // ⚠️ ページ全体だけは screencapture を1回で終わらせない（何枚も撮って繋ぐ）ので、
        // 引数の決まりの対象外。撮る側が組み立てる
        guard shot.target != .scrollingPage else {
            expect(shot.arguments.isEmpty, "ページ全体の引数は撮る側が組む")
            continue
        }
        // ⚠️ クリップボードへ載せることが全部の前提。
        // -c を落とすと、撮れているのに何も起きないアプリになる（履歴にも載らない）
        expect(shot.arguments.contains("-c"), "必ずクリップボードへ載せる（\(shot.title)）")
        // ⚠️ シェルに渡さないので、引数に空白や記号が混ざっていないこと
        for argument in shot.arguments {
            expect(argument.hasPrefix("-"), "引数は指定だけ（\(shot.title): \(argument)）")
        }
    }

    // ページ全体は「許可が2つ要る」唯一のもの。取り違えると原因不明の失敗になる
    let page = CaptureShot.all.first { $0.target == .scrollingPage }
    expect(page != nil, "ページ全体を撮る道具がある")
    expect(page?.needsScreenRecording == true, "ページ全体は画面収録の許可が要る")
    expect(page?.needsAccessibility == true, "ページ全体はスクロールを送る許可も要る")
    expect(CaptureShot.all.first { $0.target == .region }?.needsAccessibility == false,
           "範囲を撮るのにアクセシビリティは要らない")

    // 範囲とウィンドウは macOS の選択画面が撮るので、画面収録の許可が要らない。
    // 画面まるごとだけは要る。この違いが分からないと「全体だけ真っ黒」の原因を追えない
    let region = CaptureShot.all.first { $0.target == .region }
    let screen = CaptureShot.all.first { $0.target == .screen }
    let window = CaptureShot.all.first { $0.target == .window }
    expect(region?.needsScreenRecording == false, "範囲選択は画面収録の許可が要らない")
    expect(window?.needsScreenRecording == false, "ウィンドウ選択も要らない")
    expect(screen?.needsScreenRecording == true, "画面まるごとは許可が要る")

    // 撮り方が引数に正しく出ているか
    expect(region?.arguments.contains("-i") == true, "範囲は自分で選ぶ")
    expect(window?.arguments.contains("-w") == true, "ウィンドウ指定がある")
    expect(screen?.arguments.contains("-i") == false, "画面まるごとは選ばせない")

    // ⚠️ シャッター音を消さない。撮れた合図がこれしか無い
    for shot in CaptureShot.all where shot.target != .scrollingPage {
        expect(!shot.arguments.contains("-x"), "シャッター音を消さない（\(shot.title)）")
    }

    // 呼び方が他の道具・行き先とぶつかっていないか（打った人がどこへ行くか読めなくなる）
    var owner: [String: String] = [:]
    for entry in LauncherEntry.allCases {
        for alias in entry.aliases { owner[alias.lowercased()] = entry.title }
    }
    for shot in CaptureShot.all {
        for alias in shot.aliases {
            if let already = owner[alias.lowercased()] {
                expect(false, "「\(alias)」が \(already) と \(shot.title) で重なっている")
            }
            owner[alias.lowercased()] = shot.title
        }
    }
    // ⚠️ 撮る系と読む系で言葉を分ける。「スクショ」は撮る、「もじ」は読む。
    // 目的が近いからこそ、同じ言葉を両方に持たせると打った人がどちらへ行くか読めない
    expect(LauncherEntry.captureText.aliases.contains("もじ"), "文字が欲しい人は もじ で読み取りへ")
    expect(!LauncherEntry.captureText.aliases.contains("スクショ"), "読み取りは撮る系の言葉を持たない")
    let shotAliases = Set(CaptureShot.all.flatMap(\.aliases))
    expect(shotAliases.contains("スクショ"), "撮りたい人は スクショ で撮る側へ")
}

/// スクロールして撮った絵をつなぐ計算。
///
/// 2026-08-06 作者「画面スクロールでページ全体など。」
///
/// ⚠️ ここは「実物で試す」が一番効かない場所（人が画面をスクロールしないと再現できない）。
/// なので**作り物のページ**を用意して、素朴な実装が必ず落ちる3つの罠を機械で踏ませる。
func checkScrollStitcher() {
    section("スクロールした絵をつなぐ")

    // 作り物のページ: 1行＝16マスの明るさ。行番号がそのまま見た目になるようにして、
    // どの行がどこへ行ったかを人間にも追えるようにする
    // ⚠️ 行の作り方に周期があると、離れた行どうしが**たまたま同じ見た目**になる。
    // 最初に書いた `(n*7 + i*31) % 251` は 251行ごとに同じ行が現れ、
    // 「見出しが1回しか出ない」の検査が、本物の見出しではなく偶然の一致を数えていた
    // （2026-08-06・検証側の欠陥。落ちて初めて分かった）。
    // 行番号そのものを絵に埋めて、扱う範囲では絶対にかぶらないようにする。
    func row(_ n: Int) -> ScrollStitcher.RowSignature {
        // ⚠️ かけ算と余りで作ると、**離れた行どうしの数値が近くなる**。
        // 実際それで偽の一致を作ってしまった（正解95のところ73を「合っている」と答えた）。
        // 本物の画面写真は行ごとに中身がばらばらなので、混ぜて散らした値にする。
        (0..<16).map { i in
            var x = UInt64(bitPattern: Int64(n &* 2_654_435_761 &+ i &* 40_503))
            x ^= x >> 13
            x = x &* 0x9E37_79B9_7F4A_7C15
            x ^= x >> 27
            return UInt8(x & 0xFF)
        }
    }
    /// 動かない帯の行。中身の行とは絶対にかぶらない値にする
    func fixedRow(_ i: Int) -> ScrollStitcher.RowSignature {
        (0..<16).map { _ in UInt8(200 + (i % 40)) }
    }
    /// ページの `from` 行目から `height` 行ぶんを切り出した「画面」
    func window(from: Int, height: Int) -> [ScrollStitcher.RowSignature] {
        (0..<height).map { row(from + $0) }
    }

    // ── 行の見分け
    expectEqual(ScrollStitcher.distance(row(5), row(5)), 0, "同じ行は差0")
    expect(ScrollStitcher.distance(row(5), row(6)) > ScrollStitcher.sameRowTolerance,
           "違う行はちゃんと違うと分かる")

    // ── ずれ量を絵から割り出す（送った量を信じない、の根拠）
    let a = window(from: 0, height: 100)
    let b = window(from: 30, height: 100)
    expectEqual(ScrollStitcher.offset(previous: a, current: b,
                                      contentTop: 0, contentBottom: 100, minOverlap: 25),
                30, "30行進んだことを絵から言い当てる")

    // ── 一番下に着いた（もう動かない）
    expectEqual(ScrollStitcher.offset(previous: a, current: a,
                                      contentTop: 0, contentBottom: 100, minOverlap: 25),
                0, "動いていなければ0（＝終わり）")

    // ── 重なりが足りない答えは採らない
    let tooFar = ScrollStitcher.offset(previous: a, current: window(from: 95, height: 100),
                                       contentTop: 0, contentBottom: 100, minOverlap: 25)
    expect(tooFar == nil,
           "重なりが足りなければ「分からない」と言う（二度貼りを防ぐ・実際: \(String(describing: tooFar))）")

    // ── 罠①: 上に居座る見出し
    // 上20行は動かない。その下だけがスクロールする、というページを作る
    func stickyHeaderPage(from: Int, height: Int, header: Int) -> [ScrollStitcher.RowSignature] {
        (0..<height).map { $0 < header ? fixedRow($0) : row(from + $0 - header) }
    }
    let h1 = stickyHeaderPage(from: 0, height: 100, header: 20)
    let h2 = stickyHeaderPage(from: 40, height: 100, header: 20)
    expectEqual(ScrollStitcher.stickyTop(h1, h2, limit: 40), 20, "居座る見出しの高さを見つける")
    expectEqual(ScrollStitcher.offset(previous: h1, current: h2,
                                      contentTop: 20, contentBottom: 100, minOverlap: 20),
                40, "見出しを除いた中身のずれ量を出す")

    // ⚠️ 見出しを除かずに測ると答えを間違える＝これが「同じ帯が何本も入る」の正体
    let wrong = ScrollStitcher.offset(previous: h1, current: h2,
                                      contentTop: 0, contentBottom: 100, minOverlap: 20)
    expect(wrong != 40, "見出しを含めたまま測ると正しい答えにならない（除く必要がある証拠）")

    // ── 罠②: 下に貼り付く操作欄
    func stickyFooterPage(from: Int, height: Int, footer: Int) -> [ScrollStitcher.RowSignature] {
        (0..<height).map { $0 >= height - footer ? fixedRow($0) : row(from + $0) }
    }
    let f1 = stickyFooterPage(from: 0, height: 100, footer: 15)
    let f2 = stickyFooterPage(from: 30, height: 100, footer: 15)
    expectEqual(ScrollStitcher.stickyBottom(f1, f2, limit: 40), 15, "貼り付く操作欄の高さを見つける")

    // ── 全体の設計図: 3枚を繋いで、重なりが二度貼りされないこと
    let frames = [window(from: 0, height: 100),
                  window(from: 60, height: 100),
                  window(from: 120, height: 100)]
    let plan = ScrollStitcher.plan(frames: frames)
    expectEqual(plan.stickyTop, 0, "居座る帯は無い")
    expectEqual(plan.totalHeight, 220, "0〜219行ぶんの高さになる（100 + 60 + 60）")
    expectEqual(plan.pieces.count, 3, "3枚から切り出す")
    expectEqual(plan.pieces[0], ScrollStitcher.Piece(frame: 0, from: 0, to: 100), "1枚目はまるごと")
    expectEqual(plan.pieces[1], ScrollStitcher.Piece(frame: 1, from: 40, to: 100), "2枚目は新しい60行だけ")
    expectEqual(plan.pieces[2], ScrollStitcher.Piece(frame: 2, from: 40, to: 100), "3枚目も新しい60行だけ")

    // ⚠️ 繋いだ結果が、元のページと1行ずつ一致すること。
    // 継ぎ目のズレ・二度貼り・抜けは、ここが合わなければ必ず落ちる
    var built: [ScrollStitcher.RowSignature] = []
    for piece in plan.pieces {
        built += frames[piece.frame][piece.from..<piece.to]
    }
    expectEqual(built.count, 220, "組み立てた高さが設計図どおり")
    var mismatch = 0
    for index in 0..<220 where ScrollStitcher.distance(built[index], row(index)) != 0 {
        mismatch += 1
    }
    expectEqual(mismatch, 0, "繋いだ絵が元のページと1行ずつ一致する（ズレも二度貼りも抜けも無い）")

    // ── 罠③: 途中で一番下に着いたら、そこで止める
    let short = [window(from: 0, height: 100),
                 window(from: 50, height: 100),
                 window(from: 50, height: 100)]   // 3枚目は進んでいない
    let shortPlan = ScrollStitcher.plan(frames: short)
    expect(shortPlan.reachedBottom, "進まなくなったら「終わり」と分かる")
    expectEqual(shortPlan.totalHeight, 150, "進んでいない絵を足さない")

    // ── 居座る見出しつきで通しの設計図
    let hFrames = [stickyHeaderPage(from: 0, height: 100, header: 20),
                   stickyHeaderPage(from: 40, height: 100, header: 20),
                   stickyHeaderPage(from: 80, height: 100, header: 20)]
    let hPlan = ScrollStitcher.plan(frames: hFrames)
    expectEqual(hPlan.stickyTop, 20, "設計図でも見出しを見つける")
    // 見出し20 + 中身80 + 40 + 40 = 180
    expectEqual(hPlan.totalHeight, 180, "見出しは1回だけ入る")
    var hBuilt: [ScrollStitcher.RowSignature] = []
    for piece in hPlan.pieces { hBuilt += hFrames[piece.frame][piece.from..<piece.to] }
    var headerCount = 0
    for line in hBuilt where ScrollStitcher.distance(line, fixedRow(0)) == 0 { headerCount += 1 }
    expectEqual(headerCount, 1, "見出しの1行目が繋いだ絵に1回しか出てこない")

    // ── 何も撮れなかったとき・1枚だけのときに落ちない
    let empty = ScrollStitcher.plan(frames: [])
    expectEqual(empty.totalHeight, 0, "0枚でも落ちない")
    let single = ScrollStitcher.plan(frames: [window(from: 0, height: 50)])
    expectEqual(single.totalHeight, 50, "1枚だけならそのまま")
}

/// キーの重なり検査に、全部のキーが入っているか。
///
/// ⚠️ 2026-08-05 に実際に漏れていた（書式なし貼り付け・文字の変換・画面の文字読み取り）。
/// 漏れると、同じキーを2つの機能に割り当てても設定画面は何も言わず、
/// 後から登録した方だけが黙って効かない＝原因の分からない「効かないキー」になる。
/// 新しいキーを足したら、ここが落ちて気付ける。
func checkShortcutInventory() {
    section("キーの重なり検査に全部入っているか")

    let key = Shortcut(keyCode: 40, carbonModifiers: Shortcut.controlBit, keyLabel: "K")
    var settings = Settings()
    settings.pastePlainShortcut = key
    settings.captureTextShortcut = key
    settings.convertBindings = [ConvertBinding(transform: .katakana, shortcut: key)]

    let names = settings.allShortcuts.map(\.name)
    expect(names.contains("書式なしで貼り付け"), "書式なし貼り付けが一覧に入る")
    expect(names.contains("画面の文字を読み取る"), "画面の文字読み取りが一覧に入る")
    expect(names.contains { $0.contains("カタカナ") }, "文字の変換が一覧に入る")

    // 同じキーを重ねたら、同じキーが複数出てくる＝設定画面が気付ける状態
    let same = settings.allShortcuts.filter { $0.shortcut == key }
    expect(same.count >= 3, "重ねたキーが全部見えている（\(same.count)件）")

    // 未割り当てなら一覧に出さない（空の行が「重なっている」と誤判定されないように）
    var empty = Settings()
    empty.pastePlainShortcut = nil
    empty.captureTextShortcut = nil
    empty.convertBindings = []
    let emptyNames = empty.allShortcuts.map(\.name)
    expect(!emptyNames.contains("書式なしで貼り付け"), "未割り当ては一覧に出さない")
    expect(!emptyNames.contains("画面の文字を読み取る"), "未割り当ては一覧に出さない（読み取り）")
}

/// 打った文字がそのまま行き先になるか（URL・場所の直打ち）。
///
/// 2026-08-05 作者「全ての入り口としてテモトを利用したい。」
func checkQuickOpen() {
    section("打った文字をそのまま開く")

    let home = "/Users/tester"
    // 実在するのはこの2つだけ、という前提で試す
    let exists: (String) -> Bool = { ["/Users/tester/Documents", "/tmp"].contains($0) }

    // URL: そのまま
    expectEqual(QuickOpen.detect("https://example.com", home: home, exists: exists),
                .url("https://example.com"), "https はそのまま開く")
    expectEqual(QuickOpen.detect("www.example.com", home: home, exists: exists),
                .url("https://www.example.com"), "www. は https を補う")
    expectEqual(QuickOpen.detect("github.com/example", home: home, exists: exists),
                .url("https://github.com/example"), "ドメインに見えれば https を補う")

    // ⚠️ ここが肝心。普通の言葉を行き先にしない
    expect(QuickOpen.detect("teikei", home: home, exists: exists) == nil, "普通の言葉は行き先にしない")
    expect(QuickOpen.detect("請求書 pdf", home: home, exists: exists) == nil, "空白入りは検索語であって行き先ではない")
    expect(QuickOpen.detect("会議メモ.md", home: home, exists: exists) == nil, "ファイル名をURLにしない")
    expect(QuickOpen.detect("Slack.app", home: home, exists: exists) == nil, ".app をURLにしない")
    expect(QuickOpen.detect("1.5", home: home, exists: exists) == nil, "数字はURLにしない")
    expect(QuickOpen.detect(".foo", home: home, exists: exists) == nil, "点で始まるものは行き先にしない")
    expect(QuickOpen.detect("a..b", home: home, exists: exists) == nil, "点が続くものは行き先にしない")

    // 場所: 実在するときだけ
    expectEqual(QuickOpen.detect("~/Documents", home: home, exists: exists),
                .path("/Users/tester/Documents"), "~ は家の場所に開く")
    expectEqual(QuickOpen.detect("/tmp", home: home, exists: exists), .path("/tmp"), "実在する場所は開く")
    expect(QuickOpen.detect("~/Documents/ない", home: home, exists: exists) == nil,
           "実在しない場所は出さない（打ちかけを毎回行き先にしない）")

    // Webへ逃げるときのURL
    let url = QuickOpen.webSearchURL(for: "請求書 テンプレート")
    expect(url.hasPrefix("https://www.google.com/search?q="), "Web検索のURLの形")
    expect(!url.contains(" "), "空白はそのまま渡さない（包んでから渡す）")
    expect(!url.contains("請求書"), "日本語はそのまま渡さない（包んでから渡す）")
}

/// Mac そのものの操作・システム設定への行き先。
func checkSystemPlace() {
    section("Mac の操作")

    expect(SystemPlace.all.count >= 8, "よく行く先が一通りある")

    // ⚠️ 消す操作は絶対に置かない（入口は打ち間違いが起きる場所で、⏎ が近い）
    let dangerous = ["ゴミ箱", "削除", "消去", "初期化", "再起動", "終了", "シャットダウン"]
    for place in SystemPlace.all {
        for word in dangerous {
            expect(!place.title.contains(word), "取り返しのつかない操作を入口に置かない（\(place.title)）")
        }
    }

    // 名前が重ならない・IDが重ならない
    expectEqual(Set(SystemPlace.all.map(\.id)).count, SystemPlace.all.count, "IDが重なっていない")
    expectEqual(Set(SystemPlace.all.map(\.title)).count, SystemPlace.all.count, "題名が重なっていない")

    // 設定画面はURLの形になる。ロックとスリープはURLを持たない
    for place in SystemPlace.all {
        switch place.action {
        case .settingsPane(let identifier):
            let url = place.settingsURL ?? ""
            expect(url.hasPrefix("x-apple.systempreferences:"), "設定画面はURLで開く（\(place.title)）")
            if !identifier.isEmpty {
                expect(url.hasSuffix(identifier), "画面のIDがURLの末尾に入る（\(place.title)）")
            }
        case .lockScreen, .sleep:
            expect(place.settingsURL == nil, "設定画面ではないものはURLを持たない（\(place.title)）")
        }
        expect(!place.aliases.isEmpty, "別の呼び方がある（\(place.title)）")
        expect(!place.symbol.isEmpty, "しるしがある（\(place.title)）")
    }

    // 呼び方は日本語・かな・ローマ字・英語のどれでも当たる
    let sound = SystemPlace.all.first { $0.id == "sys.sound" }
    expect(sound?.aliases.contains("oto") == true, "ローマ字でも当たる")
    expect(sound?.aliases.contains("音量") == true, "日本語でも当たる")
    let network = SystemPlace.all.first { $0.id == "sys.network" }
    expect(network?.aliases.contains("wifi") == true, "wifi で当たる")
}

/// 棚を矢印で選ぶときの動き。
///
/// 2026-08-04 作者「アプリ選択時にコントロールを長押しして矢印で移動できる様にしたい！」
/// ＋「コントロールを押して数字を押すと、別のショートカットが設定されているものがあり、
/// うまく開かない時があります。」
/// → ⌃＋矢印は macOS の「スペース移動」が握っているので、**修飾キー無しの矢印**にした。
func checkShelfFocus() {
    section("棚を矢印で選ぶ")

    // 入り方: まだ棚に入っていないとき、右は先頭・左は末尾から入る
    expectEqual(ShelfFocus.move(from: nil, count: 4, step: 1), 0, "→ で入ると先頭")
    expectEqual(ShelfFocus.move(from: nil, count: 4, step: -1), 3, "← で入ると末尾")

    // 進み方
    expectEqual(ShelfFocus.move(from: 0, count: 4, step: 1), 1, "→ で次へ")
    expectEqual(ShelfFocus.move(from: 2, count: 4, step: -1), 1, "← で前へ")

    // 端は回る（行き止まりを作らない）
    expectEqual(ShelfFocus.move(from: 3, count: 4, step: 1), 0, "右端の次は先頭へ回る")
    expectEqual(ShelfFocus.move(from: 0, count: 4, step: -1), 3, "左端の前は末尾へ回る")

    // 棚が空なら、どちらを押しても何も選ばない（落ちない）
    expect(ShelfFocus.move(from: nil, count: 0, step: 1) == nil, "棚が空なら選ばない")
    expect(ShelfFocus.move(from: 0, count: 0, step: -1) == nil, "棚が空になったら選びを捨てる")

    // 1つだけなら、押しても同じ場所（回っても自分に戻る）
    expectEqual(ShelfFocus.move(from: 0, count: 1, step: 1), 0, "1つだけなら動かない")

    // 棚が減ったときに、範囲の外を指したままにしない
    expect(ShelfFocus.valid(3, count: 2) == nil, "棚が減ったら、はみ出した選びは捨てる")
    expect(ShelfFocus.valid(-1, count: 2) == nil, "負の位置は選びとして扱わない")
    expectEqual(ShelfFocus.valid(1, count: 2), 1, "範囲の中はそのまま残す")
    expect(ShelfFocus.valid(nil, count: 2) == nil, "選んでいないときは、選んでいないまま")

    // 9個を超えても矢印なら全部たどれる（札は9個までだが、矢印に上限は無い）
    expectEqual(ShelfFocus.move(from: 8, count: 12, step: 1), 9, "10個目以降も矢印なら届く")

    // ⚠️ 下の帯の「←→ アプリ」は「↑↓」の隣に差し込んでいる。
    // 「↑↓」の書き方が変わると、案内が黙って列の最後へ飛ぶ（気付けないので、ここで見張る）
    expect(LauncherMode.all.actions.contains { $0.keys == "↑↓" },
           "入口の帯に「↑↓」がある（←→ の差し込み先）")
}

func checkShelfKeys() {
    section("棚の番号キー — 窓が開いている間だけ効く ⌃1〜⌃9")

    // 2026-08-04 作者「この画面が表示されているときはコントロールと数字を入力したら
    // アプリが開くみたいな。」＝行き先の ⌘1〜⌘6 と対になる並び。
    expectEqual(ShelfKeys.label(forIndex: 0), "⌃1", "1番目の札は ⌃1")
    expectEqual(ShelfKeys.label(forIndex: 8), "⌃9", "9番目の札は ⌃9")
    expect(ShelfKeys.label(forIndex: 9) == nil, "10番目に札は出さない（0は10番目に見えない）")
    expect(ShelfKeys.label(forIndex: -1) == nil, "範囲の外は札を出さない")

    // 押された文字 → 何番目
    expectEqual(ShelfKeys.index(forCharacter: "1", count: 4), 0, "1 は1番目")
    expectEqual(ShelfKeys.index(forCharacter: "4", count: 4), 3, "4 は4番目")
    expect(ShelfKeys.index(forCharacter: "5", count: 4) == nil, "棚に無い番号は何もしない")
    expect(ShelfKeys.index(forCharacter: "0", count: 4) == nil, "0 は使わない")
    expect(ShelfKeys.index(forCharacter: "a", count: 4) == nil, "数字でなければ何もしない")
    expect(ShelfKeys.index(forCharacter: "", count: 4) == nil, "空なら何もしない")
    expect(ShelfKeys.index(forCharacter: "1", count: 0) == nil, "棚が空なら何もしない")

    // 行き先（⌘1〜⌘7）と番号がぶつかっても、修飾キーで分かれる。
    // ⚠️ 数を直に書かない。行き先が増えても maxCount は 9 のまま通ってしまい、
    // 落ちないまま説明だけが古くなる（2026-08-05 に実際そうなりかけた）
    expect(ShelfKeys.maxCount >= LauncherEntry.allCases.count,
           "棚には行き先の数（\(LauncherEntry.allCases.count)）より多く置ける")
}


print("")
print(String(repeating: "─", count: 50))
if failures.isEmpty {
    print("全て通過: \(passed)件")
    exit(0)
} else {
    print("通過 \(passed)件 / 失敗 \(failures.count)件")
    for f in failures {
        print("  - \(f)")
    }
    exit(1)
}


// MARK: - 設定画面の横メニュー

func checkSettingsPanes() {
    section("設定の横メニュー")

    // ── 画面そのもの
    expect(SettingsPane.allCases.count == 7, "画面は7つ")
    let titles = SettingsPane.allCases.map(\.title)
    expect(Set(titles).count == titles.count, "画面の名前がかぶらない")
    expect(titles.allSatisfy { !$0.isEmpty }, "名前の無い画面が無い")
    let symbols = SettingsPane.allCases.map(\.symbolName)
    expect(Set(symbols).count == symbols.count, "記号がかぶらない（見分けが付く）")
    expect(symbols.allSatisfy { !$0.isEmpty }, "記号の無い画面が無い")

    // ── 探せること
    // ⚠️ 数を直に書かない。画面を足したら自動で対象になる
    for pane in SettingsPane.allCases {
        expect(SettingsSearch.items.contains { $0.pane == pane },
               "「\(pane.title)」に探せる設定がある（探しても出てこない画面を作らない）")
    }
    expect(SettingsSearch.find("").isEmpty, "空欄なら何も絞らない")
    expect(SettingsSearch.find("   ").isEmpty, "空白だけでも何も絞らない")

    // 作者が実際に探しそうな言葉で当たるか
    expect(SettingsSearch.find("スニペット").contains { $0.pane == .features },
           "「スニペット」で使う機能に当たる")
    expect(SettingsSearch.find("snippet").contains { $0.pane == .features },
           "英語の「snippet」でも当たる")
    expect(SettingsSearch.find("SNIPPET").contains { $0.pane == .features },
           "大文字でも当たる")
    expect(SettingsSearch.find("ログイン").contains { $0.pane == .general },
           "「ログイン」で一般に当たる")
    expect(SettingsSearch.find("パスワード").contains { $0.pane == .clipboard },
           "「パスワード」でコピー履歴の除外に当たる")
    expect(SettingsSearch.find("ホットキー").contains { $0.pane == .shortcuts },
           "「ホットキー」でショートカットに当たる")
    expect(SettingsSearch.find("ぬるぽ").isEmpty, "当たらない言葉では何も出ない")

    // 空白で区切ったら絞り込み（AND）
    let both = SettingsSearch.find("コピー 除外")
    expect(both.allSatisfy { $0.pane == .clipboard }, "2語はどちらも満たすものだけ")
    expect(SettingsSearch.find("スニペット ログイン").isEmpty,
           "両方を満たすものが無ければ空（片方でも出す OR にしない）")

    // 並びは横メニューの順のまま（打つたびに行が入れ替わらない）
    let panes = SettingsSearch.panes(matching: "設定")
    let order = SettingsPane.allCases
    var last = -1
    var ordered = true
    for pane in panes {
        guard let at = order.firstIndex(of: pane) else { ordered = false; break }
        if at <= last { ordered = false; break }
        last = at
    }
    expect(ordered, "当たった画面は横メニューの並び順で返る")

    // ── 開いていない画面の設定を空で上書きしない（2026-08-14 の実害）
    let keep = ["com.apple.Safari", "com.1password.1password"]
    expect(SettingsLines.lines(keeping: keep, from: nil) == keep,
           "画面がまだ無いなら、今の設定をそのまま残す")
    expect(SettingsLines.lines(keeping: keep, from: "") == [],
           "画面があって空にされたなら、空にする（利用者が消したのだから従う）")
    expect(SettingsLines.lines(keeping: keep, from: "a\nb") == ["a", "b"],
           "画面があるなら打った通りに読む")
    expect(SettingsLines.lines(keeping: [], from: nil) == [],
           "元が空でも壊れない")
}


// MARK: - 設定画面の地と面

func checkSettingsSurface() {
    section("設定画面の地と面")

    // ── 仕切り線が「引いたつもりで見えていない」ことにならないか
    // ⚠️ 2026-08-23 実測: `.separatorColor × α0.7` はすりガラスの中（vibrant）だと
    // 最悪比 1.11 で、このアプリ自身が決めた下限 1.5 を割っていた
    expect(Contrast.Tones.separatorLine.worstRatio >= Contrast.Threshold.visibleEdge,
           "仕切り線は消えずに見分けが付く（\(String(format: "%.2f", Contrast.Tones.separatorLine.worstRatio)) ≧ \(Contrast.Threshold.visibleEdge)）")

    // ── まとまりを載せる面の上でも、説明文が読めるか
    // ⚠️ 面を重ねると地の明るさが変わる。文字の濃さだけ見ていても足りない
    let places: [(Double, Bool, String)] = [
        (Contrast.Backdrop.lightDarkest, false, "明るい見た目・いちばん暗い地"),
        (Contrast.Backdrop.lightBrightest, false, "明るい見た目・いちばん明るい地"),
        (Contrast.Backdrop.darkDarkest, true, "暗い見た目・いちばん暗い地"),
        (Contrast.Backdrop.darkBrightest, true, "暗い見た目・いちばん明るい地"),
    ]
    for (backdrop, isDark, name) in places {
        let card = Contrast.Card.gray(on: backdrop, isDark: isDark)
        let text = Contrast.Tones.caption.gray(on: card, isDark: isDark)
        let ratio = Contrast.ratio(text, card)
        expect(ratio >= Contrast.Threshold.readableText,
               "面の上でも説明文が読める（\(name)・\(String(format: "%.2f", ratio)) ≧ \(Contrast.Threshold.readableText)）")
    }

    // ⚠️ 暗い見た目で面に**白**を重ねると落ちることを、ここで示しておく。
    // 「明るくすれば浮く」と思って白に変えたくなるが、地が明るくなるぶん
    // 白い文字との差が縮む。浮かせるのは明るさの向きではなく**地との差**
    let wrong = Contrast.composite(overlay: 1, alpha: 0.07, on: Contrast.Backdrop.darkBrightest)
    let wrongText = Contrast.Tones.caption.gray(on: wrong, isDark: true)
    expect(Contrast.ratio(wrongText, wrong) < Contrast.Threshold.readableText,
           "暗い見た目で面に白を重ねると読めなくなる（だから黒を重ねている）")
}
