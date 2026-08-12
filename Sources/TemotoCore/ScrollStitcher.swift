import Foundation

/// スクロールしながら撮った何枚もの絵を、1枚の長い絵につなぐための計算。
///
/// 2026-08-06 作者「画面スクロールでページ全体など。」
///
/// ⚠️ macOS にこの機能は無い（⇧⌘5 にも無い）。だから自分で作る。
/// 難しいのは「撮る」ことではなく**つなぐ**ことで、素朴にやると必ずこの3つで破綻する:
///   ① スクロール量が指示どおりとは限らない（慣性・行単位の丸め・ページの作りで変わる）
///      → 送った量を信じず、**絵そのものを見比べて**ずれ量を割り出す
///   ② 動かない帯がある（上に居座る見出し、下に貼り付く操作欄）
///      → そのまま繋ぐと同じ帯が何本も入る。**動かない帯を先に見つけて除く**
///   ③ 終わりが分からない（一番下に着いてもスクロールは「成功」する）
///      → ずれ量が0＝もう進んでいない、で止める
///
/// ⚠️ ここは AppKit を知らない。絵ではなく「1行ぶんの見た目」の列だけを受け取る。
/// そうしないと、この一番間違えやすい計算を機械で確かめられない。
public enum ScrollStitcher {

    /// 1行分の見た目を短くまとめたもの。
    /// 横幅を何等分かして、それぞれの明るさを 0〜255 で持つ。
    ///
    /// ⚠️ 1行を1つの数（合計や平均）にまとめない。
    /// 文章のページは「どの行も同じくらいの黒さ」なので、合計だけだと別の行が同じ値になり、
    /// ずれ量の探索が平気で嘘の答えを返す。横方向の分布まで持って初めて行を見分けられる。
    public typealias RowSignature = [UInt8]

    /// 2つの行がどれだけ違うか（0＝同じ）。1マスあたりの平均の差で返す
    public static func distance(_ a: RowSignature, _ b: RowSignature) -> Int {
        guard !a.isEmpty, a.count == b.count else { return Int.max }
        var total = 0
        for index in a.indices {
            total += abs(Int(a[index]) - Int(b[index]))
        }
        return total / a.count
    }

    /// 同じ行とみなす差の上限。
    /// ⚠️ 0（完全一致）にしない。画面の撮り直しでは、影・透過・アンチエイリアスで
    /// 数値がわずかに揺れる。厳しくしすぎると「毎回すべての行が別物」になって何も繋がらない。
    public static let sameRowTolerance = 6

    /// 2つの行の列が同じか
    private static func same(_ a: RowSignature, _ b: RowSignature, tolerance: Int) -> Bool {
        distance(a, b) <= tolerance
    }

    // MARK: - 動かない帯を見つける

    /// 上に居座っている帯の高さ（見出しなど）。
    ///
    /// ⚠️ 「上から順に、2枚で同じ行が続く数」で測る。
    /// スクロールしたのに同じままの行は、動かない帯しかない。
    ///
    /// ⚠️ 上限を切る。真っ白なページでは全部の行が「同じ」に見えるので、
    /// 上限が無いと画面まるごとを見出しと判定して、中身が1行も残らなくなる。
    public static func stickyTop(_ first: [RowSignature], _ second: [RowSignature],
                                 limit: Int, tolerance: Int = sameRowTolerance) -> Int {
        let bound = min(limit, min(first.count, second.count))
        var height = 0
        while height < bound, same(first[height], second[height], tolerance: tolerance) {
            height += 1
        }
        return height
    }

    /// 下に貼り付いている帯の高さ（操作欄など）。下から数える
    public static func stickyBottom(_ first: [RowSignature], _ second: [RowSignature],
                                    limit: Int, tolerance: Int = sameRowTolerance) -> Int {
        let bound = min(limit, min(first.count, second.count))
        var height = 0
        while height < bound,
              same(first[first.count - 1 - height], second[second.count - 1 - height],
                   tolerance: tolerance) {
            height += 1
        }
        return height
    }

    // MARK: - ずれ量を割り出す

    /// 前の絵と今の絵で、中身が何行ぶん進んだか。
    ///
    /// - Parameters:
    ///   - contentTop: 中身が始まる行（動かない見出しの下）
    ///   - contentBottom: 中身が終わる行（含まない・貼り付く操作欄の上）
    ///   - minOverlap: 重なりがこの行数より少ない答えは信じない
    /// - Returns: 進んだ行数。1行も進んでいなければ 0。信じられる答えが無ければ nil
    ///
    /// ⚠️ **送ったスクロール量を信じない**。ここで実際の絵から測り直す。
    /// 慣性やページ側の都合で、送った量と動いた量は普通に食い違う。
    ///
    /// ⚠️ 重なりが少ない答えを採らない理由。
    /// 端の数行だけがたまたま似ていると、ほぼ全部を「新しい中身」と判定してしまい、
    /// 実際には重なっている部分を二度貼って、継ぎ目に同じ文章が2回出る。
    public static func offset(previous: [RowSignature], current: [RowSignature],
                              contentTop: Int, contentBottom: Int,
                              minOverlap: Int, tolerance: Int = sameRowTolerance) -> Int? {
        let height = contentBottom - contentTop
        guard height > 0, minOverlap > 0, minOverlap <= height else { return nil }
        guard previous.count >= contentBottom, current.count >= contentBottom else { return nil }

        var best: (shift: Int, cost: Int)?
        // shift = 0 も試す（まったく動いていない＝一番下に着いた、を見分けるため）
        for shift in 0...(height - minOverlap) {
            let overlap = height - shift
            var total = 0
            var worst = 0
            for row in 0..<overlap {
                let d = distance(previous[contentTop + shift + row], current[contentTop + row])
                total += d
                worst = max(worst, d)
            }
            let cost = total / overlap
            // ⚠️ 平均だけで決めない。ほとんど同じで一部だけ大きく違う（＝別の場所）を
            // 平均は薄めてしまう。ひどい行が1つでもあれば、その候補は採らない。
            //
            // ⚠️ 最初は ×4 まで許していたが、検証で**偽の一致**を掴んだ
            // （正解95行ずれのところ、73行ずれを「合っている」と答えた。2026-08-06）。
            // 本当に重なっている絵なら、どの行もほぼ同じになるはず。緩めるほど嘘を掴む。
            guard cost <= tolerance, worst <= tolerance * 2 else { continue }
            if best == nil || cost < best!.cost {
                best = (shift, cost)
            }
        }
        return best?.shift
    }

    // MARK: - 全体の組み立て

    /// 1枚の長い絵の設計図
    public struct Plan: Equatable, Sendable {
        /// 上に居座る帯の高さ（最初の1枚にだけ入れる）
        public let stickyTop: Int
        /// 下に貼り付く帯の高さ（最後の1枚にだけ入れる）
        public let stickyBottom: Int
        /// どの絵の、どこからどこまでを、上から順に貼るか
        public let pieces: [Piece]
        /// できあがりの高さ（行数）
        public let totalHeight: Int
        /// 途中で進まなくなって打ち切ったか（＝最後まで撮れた）
        public let reachedBottom: Bool
    }

    public struct Piece: Equatable, Sendable {
        /// 何枚目の絵か
        public let frame: Int
        /// その絵の何行目から（含む）
        public let from: Int
        /// 何行目まで（含まない）
        public let to: Int

        public init(frame: Int, from: Int, to: Int) {
            self.frame = frame
            self.from = from
            self.to = to
        }

        public var height: Int { to - from }
    }

    /// 撮った絵の列から、1枚に繋ぐ設計図を作る。
    ///
    /// ⚠️ 最初の1枚は**まるごと**入れる（上の見出しも含めて）。
    /// 2枚目以降は「新しく出てきたぶん」だけを足す。
    /// 最後の1枚だけ、下に貼り付く帯も入れる（ページの終わりの操作欄は1回だけ見せたい）。
    public static func plan(frames: [[RowSignature]],
                            minOverlapRatio: Double = 0.25,
                            stickyLimitRatio: Double = 0.4,
                            tolerance: Int = sameRowTolerance) -> Plan {
        guard let first = frames.first, !first.isEmpty else {
            return Plan(stickyTop: 0, stickyBottom: 0, pieces: [], totalHeight: 0, reachedBottom: true)
        }
        let frameHeight = first.count
        guard frames.count >= 2 else {
            // 1枚しか撮れていない＝そのまま出す
            return Plan(stickyTop: 0, stickyBottom: 0,
                        pieces: [Piece(frame: 0, from: 0, to: frameHeight)],
                        totalHeight: frameHeight, reachedBottom: true)
        }

        let stickyLimit = max(1, Int(Double(frameHeight) * stickyLimitRatio))
        let top = stickyTop(frames[0], frames[1], limit: stickyLimit, tolerance: tolerance)
        let bottom = stickyBottom(frames[0], frames[1], limit: stickyLimit, tolerance: tolerance)
        let contentTop = top
        let contentBottom = frameHeight - bottom
        let minOverlap = max(1, Int(Double(contentBottom - contentTop) * minOverlapRatio))

        // 1枚目はまるごと（貼り付く帯は最後に回すので、ここでは中身の終わりまで）
        var pieces = [Piece(frame: 0, from: 0, to: contentBottom)]
        var totalHeight = contentBottom
        var reachedBottom = false
        var lastFrame = 0

        for index in 1..<frames.count {
            guard frames[index].count == frameHeight else { continue }
            guard let shift = offset(previous: frames[index - 1], current: frames[index],
                                     contentTop: contentTop, contentBottom: contentBottom,
                                     minOverlap: minOverlap, tolerance: tolerance) else {
                // 見比べても分からない＝ここで打ち切る（無理に繋ぐと嘘の絵になる）
                break
            }
            if shift == 0 {
                // もう進んでいない＝一番下に着いた
                reachedBottom = true
                break
            }
            // 新しく出てきたのは、中身の下から shift 行ぶん
            let from = contentBottom - shift
            pieces.append(Piece(frame: index, from: from, to: contentBottom))
            totalHeight += shift
            lastFrame = index
        }

        // 下に貼り付く帯は、最後の1枚から1回だけ足す
        if bottom > 0 {
            pieces.append(Piece(frame: lastFrame, from: frameHeight - bottom, to: frameHeight))
            totalHeight += bottom
        }

        return Plan(stickyTop: top, stickyBottom: bottom,
                    pieces: pieces, totalHeight: totalHeight, reachedBottom: reachedBottom)
    }
}
