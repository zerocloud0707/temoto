import CoreGraphics
import Foundation

/// ウィンドウの配置先。
///
/// 座標の扱いについて（ここを間違えると全部ずれるので明示しておく）:
/// - NSScreen は「主ディスプレイの左下が原点・yは上向き」（Cocoa座標系）
/// - Accessibility API の kAXPosition は「主ディスプレイの左上が原点・yは下向き」（AX座標系）
/// このファイルの計算はすべて **AX座標系** で行う。そうすると top = yが小さい側 となり直感と一致する。
/// Cocoa座標系からの変換は `Geometry.axRect(fromCocoa:primaryHeight:)` を通すこと。
public enum WindowLayout: String, CaseIterable, Codable, Sendable {
    case leftHalf, rightHalf, topHalf, bottomHalf
    case topLeft, topRight, bottomLeft, bottomRight
    case leftThird, centerThird, rightThird
    case leftTwoThirds, rightTwoThirds
    case maximize, almostMaximize, center
    case restore

    public var title: String {
        switch self {
        case .leftHalf: return "左半分"
        case .rightHalf: return "右半分"
        case .topHalf: return "上半分"
        case .bottomHalf: return "下半分"
        case .topLeft: return "左上"
        case .topRight: return "右上"
        case .bottomLeft: return "左下"
        case .bottomRight: return "右下"
        case .leftThird: return "左1/3"
        case .centerThird: return "中央1/3"
        case .rightThird: return "右1/3"
        case .leftTwoThirds: return "左2/3"
        case .rightTwoThirds: return "右2/3"
        case .maximize: return "最大化"
        case .almostMaximize: return "ほぼ最大化"
        case .center: return "中央に寄せる"
        case .restore: return "元のサイズに戻す"
        }
    }

    /// 画面に対する占有範囲を割合で表したもの (x0, y0, x1, y1) ∈ [0,1]。
    /// 端の座標を先に丸めてから幅・高さを出すことで、左半分と右半分の境界が
    /// 必ず一致する（1px の隙間や重なりが出ない）。
    /// nil を返すものは割合では表現できない（現在のサイズに依存する）レイアウト。
    var fractions: (x0: Double, y0: Double, x1: Double, y1: Double)? {
        switch self {
        case .leftHalf:       return (0,     0,     0.5,   1)
        case .rightHalf:      return (0.5,   0,     1,     1)
        case .topHalf:        return (0,     0,     1,     0.5)
        case .bottomHalf:     return (0,     0.5,   1,     1)
        case .topLeft:        return (0,     0,     0.5,   0.5)
        case .topRight:       return (0.5,   0,     1,     0.5)
        case .bottomLeft:     return (0,     0.5,   0.5,   1)
        case .bottomRight:    return (0.5,   0.5,   1,     1)
        case .leftThird:      return (0,     0,     1.0/3, 1)
        case .centerThird:    return (1.0/3, 0,     2.0/3, 1)
        case .rightThird:     return (2.0/3, 0,     1,     1)
        case .leftTwoThirds:  return (0,     0,     2.0/3, 1)
        case .rightTwoThirds: return (1.0/3, 0,     1,     1)
        case .maximize:       return (0,     0,     1,     1)
        case .almostMaximize: return (0.05,  0.05,  0.95,  0.95)
        case .center, .restore: return nil
        }
    }
}

public enum Geometry {
    /// Cocoa座標系（左下原点・y上向き）の矩形を AX座標系（左上原点・y下向き）へ変換する。
    /// 逆変換も同じ式なので、この関数を2回通すと元に戻る。
    /// - Parameter primaryHeight: 主ディスプレイの高さ（NSScreen.screens[0].frame.height）
    public static func axRect(fromCocoa rect: CGRect, primaryHeight: CGFloat) -> CGRect {
        CGRect(
            x: rect.origin.x,
            y: primaryHeight - (rect.origin.y + rect.height),
            width: rect.width,
            height: rect.height
        )
    }

    /// AX座標系の矩形を Cocoa座標系へ戻す（式は上と同一）。
    public static func cocoaRect(fromAX rect: CGRect, primaryHeight: CGFloat) -> CGRect {
        axRect(fromCocoa: rect, primaryHeight: primaryHeight)
    }

    /// レイアウトの適用先フレームを求める（すべてAX座標系）。
    /// - Parameters:
    ///   - visible: メニューバーとDockを除いた作業領域（AX座標系）
    ///   - current: 現在のウィンドウ枠。center / restore で必要
    ///   - previous: restore で戻す先
    public static func targetFrame(
        for layout: WindowLayout,
        visible: CGRect,
        current: CGRect? = nil,
        previous: CGRect? = nil
    ) -> CGRect? {
        switch layout {
        case .restore:
            return previous

        case .center:
            guard let current else { return nil }
            // はみ出す場合は作業領域に収まるまで縮める
            let w = min(current.width, visible.width)
            let h = min(current.height, visible.height)
            return CGRect(
                x: (visible.minX + (visible.width - w) / 2).rounded(),
                y: (visible.minY + (visible.height - h) / 2).rounded(),
                width: w.rounded(),
                height: h.rounded()
            )

        default:
            guard let f = layout.fractions else { return nil }
            // 端の座標を先に丸める → 隣り合うレイアウトの境界が必ず一致する
            let left = (visible.minX + f.x0 * visible.width).rounded()
            let right = (visible.minX + f.x1 * visible.width).rounded()
            let top = (visible.minY + f.y0 * visible.height).rounded()
            let bottom = (visible.minY + f.y1 * visible.height).rounded()
            return CGRect(x: left, y: top, width: right - left, height: bottom - top)
        }
    }

    /// ウィンドウが最も多く重なっている画面の添字を返す。
    /// どの画面とも重ならない場合は中心が最も近い画面を返す（画面構成変更後の迷子対策）。
    public static func bestScreenIndex(for rect: CGRect, screens: [CGRect]) -> Int? {
        guard !screens.isEmpty else { return nil }

        var bestIndex = 0
        var bestArea: CGFloat = 0
        for (i, screen) in screens.enumerated() {
            let overlap = screen.intersection(rect)
            let area = overlap.isNull ? 0 : overlap.width * overlap.height
            if area > bestArea {
                bestArea = area
                bestIndex = i
            }
        }
        if bestArea > 0 { return bestIndex }

        var nearest = 0
        var nearestDistance = CGFloat.greatestFiniteMagnitude
        for (i, screen) in screens.enumerated() {
            let dx = screen.midX - rect.midX
            let dy = screen.midY - rect.midY
            let d = dx * dx + dy * dy
            if d < nearestDistance {
                nearestDistance = d
                nearest = i
            }
        }
        return nearest
    }

    /// 画面間の移動。元の画面での相対位置・相対サイズを保ったまま移動先へ写す。
    /// 解像度が違う画面へ移してもはみ出さないようにクランプする。
    ///
    /// 左上の角ではなく**中心**の相対位置を写す。角で写すと、
    /// 画面の真ん中に置いていたウィンドウが移動先では右下にずれてしまう。
    public static func movedProportionally(_ rect: CGRect, from source: CGRect, to destination: CGRect) -> CGRect {
        guard source.width > 0, source.height > 0 else { return rect }

        let relCenterX: CGFloat = (rect.midX - source.minX) / source.width
        let relCenterY: CGFloat = (rect.midY - source.minY) / source.height
        let relW: CGFloat = min(rect.width / source.width, CGFloat(1))
        let relH: CGFloat = min(rect.height / source.height, CGFloat(1))

        let w: CGFloat = min((destination.width * relW).rounded(), destination.width)
        let h: CGFloat = min((destination.height * relH).rounded(), destination.height)

        let rawX: CGFloat = (destination.minX + destination.width * relCenterX - w / 2).rounded()
        let rawY: CGFloat = (destination.minY + destination.height * relCenterY - h / 2).rounded()

        // 移動先からはみ出さないように寄せる
        let x: CGFloat = min(max(rawX, destination.minX), destination.maxX - w)
        let y: CGFloat = min(max(rawY, destination.minY), destination.maxY - h)

        return CGRect(x: x, y: y, width: w, height: h)
    }

    /// 次（+1）/前（-1）の画面の添字。画面が1枚しかなければ nil。
    public static func neighborScreenIndex(from index: Int, count: Int, step: Int) -> Int? {
        guard count > 1 else { return nil }
        let next = (index + step % count + count) % count
        return next == index ? nil : next
    }
}
