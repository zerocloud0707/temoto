import AppKit
import TemotoCore

/// 貼り付けのときに「元の窓だけ」が前に戻るかを実測する
/// （`--check-paste-focus` ／ 古い道と比べるなら `--check-paste-focus --old`）。
///
/// ⚠️ なぜ要るか。
/// 2026-08-23 作者「コピー履歴を貼り付けると、なぜか他のブラウザの表示が最前面になったりします」。
/// 原因は戻し方に `NSWorkspace.openApplication`（＝Dockのアイコンを押すのと同じ道）を
/// 使っていたことで、これは**そのアプリの窓を全部前に出す**。
/// 直したが、これは検証（TemotoChecks）では確かめられない——実際に窓が何枚も開いた
/// アプリを相手に、前後の並びを測るしかない。
///
/// ⚠️ 画面を一瞬奪う（相手のアプリが前に出る）。確かめたいときだけ手で流すこと。
enum PasteFocusCheck {

    static func run(useOldWay: Bool) -> Int32 {
        NSApplication.shared.setActivationPolicy(.accessory)

        guard AXWindow.isTrusted(prompt: false) else {
            print("🔴 アクセシビリティの許可がありません（窓の並びを読めません）")
            return 1
        }

        // 窓を2枚以上開いているアプリを相手にする（ブラウザで起きた話なので、まずそれを探す）
        guard let target = pickTarget() else {
            print("🔴 窓を2枚以上開いているアプリが見つかりません（Chrome などを2枚開いて再実行）")
            return 1
        }
        let app = target.app
        let name = app.localizedName ?? "?"
        print("相手: \(name)（窓 \(target.count)枚）")

        // ① 実際に起きる場面を作る。
        //
        // ⚠️ これが無いと測れない。相手の窓が4枚とも連続して並んでいると、
        // 「他の窓が前に飛び出す」という変化そのものが起きない
        // （2026-08-23、これに気づかず「古い道でも問題なし」という嘘の合格を2回出した）。
        // 作りたい状態は、実際の使い方と同じ:
        //   打っていた窓（手前） → 他のアプリの窓 → 相手の残りの窓（奥）
        // 別のアプリを前に出してから、相手の窓を1枚だけ名指しで上げると、この形になる。
        let onScreen = Set(stackOrder().map(\.pid))
        let mine = ProcessInfo.processInfo.processIdentifier
        if let other = NSWorkspace.shared.runningApplications.first(where: { candidate in
            candidate.activationPolicy == .regular
                && candidate.processIdentifier != app.processIdentifier
                && candidate.processIdentifier != mine
                && onScreen.contains(candidate.processIdentifier)
        }) {
            other.activate()
            wait(0.8)
            if let front = AXWindow.focusedWindow(of: app) {
                AXWindow.raise(front, of: app)
                wait(0.5)
            }
            print("場面づくり: \(other.localizedName ?? "?") を間に挟みました")
        }

        // ② いまの並びと焦点を控える。
        // ⚠️ ここで相手を前に出さない。出すと相手の窓が全部前に来てしまい、
        // 「他のアプリの窓が間に挟まっている」という肝心の状態が消える。
        // 焦点のある窓は、前面でなくてもその相手に直接聞けば分かる
        guard let focused = AXWindow.focusedWindow(of: app) else {
            print("🔴 焦点のある窓を読めません")
            return 1
        }
        // ⚠️ 相手を前に出したままだと、他のアプリの窓が全部後ろに回って差が出ない。
        // 実際の場面（別のアプリを触ったあとに貼り付ける）に合わせて、
        // ここで一度テモトを挟み、相手の窓の間に他のアプリが入る状態を作る
        dumpOrder("場面づくりの直後")
        let before = stackOrder()
        let beforeOvertakes = othersAheadOfBackmost(before, pid: app.processIdentifier)
        let beforeCount = before.filter { $0.pid == app.processIdentifier }.count
        print("開く前: 画面に出ている \(name) の窓 \(beforeCount)枚／"
              + "いちばん奥の窓より手前にいる他アプリの窓 \(beforeOvertakes)枚")

        // ③ テモトを前に出す（検索窓を開いたのと同じ状態）
        NSApp.activate()
        wait(0.5)

        // ④ 戻す
        if useOldWay {
            print("戻し方: 古い道（NSWorkspace.openApplication ＝ Dockのアイコンを押すのと同じ）")
            if let url = app.bundleURL {
                let configuration = NSWorkspace.OpenConfiguration()
                configuration.activates = true
                NSWorkspace.shared.openApplication(at: url, configuration: configuration, completionHandler: nil)
            }
        } else {
            print("戻し方: 新しい道（NSApp.yieldActivation ＋ その窓だけを名指しで前へ）")
            NSApp.yieldActivation(to: app)
            app.activate()
            AXWindow.raise(focused, of: app)
        }
        wait(1.0)

        // ⑤ 他の窓が前に飛び出していないかを見る
        dumpOrder("戻した直後")
        let after = stackOrder()
        let afterOvertakes = othersAheadOfBackmost(after, pid: app.processIdentifier)
        print("戻した後: いちばん奥の窓より手前にいる他アプリの窓 \(afterOvertakes)枚")

        var failures: [String] = []
        // ⚠️ 向きに注意。不具合が起きると、間に挟まっていた他アプリの窓を
        // 相手の窓が**追い越して**しまい、数は**減る**（連続に戻る）。
        // 私は最初これを逆に書いて、不具合が起きているのに合格を出した
        if afterOvertakes < beforeOvertakes {
            failures.append("\(name) の他の窓まで前に飛び出した"
                            + "（他アプリの窓 \(beforeOvertakes - afterOvertakes) 枚を、まとめて追い越した）")
        }
        if let nowFocused = AXWindow.focusedWindow(of: app), nowFocused != focused {
            failures.append("焦点が別の窓に移った")
        }
        if !app.isActive {
            failures.append("相手が前に戻ってこなかった（貼り付けそのものが失敗する）")
        }

        if failures.isEmpty {
            print("✅ 打っていた窓だけが戻り、他の窓は前に出ていません")
            return 0
        }
        for f in failures { print("  🔴 \(f)") }
        return 1
    }

    /// 画面に出ている窓を、**本当の重なり順**（手前から奥へ）で読む。
    ///
    /// ⚠️ `kAXWindowsAttribute` を使わないこと。あれは重なりの順ではない
    /// （多くのアプリで作った順に返る）。2026-08-23、私は最初それで測って
    /// 「古い道でも並びは変わらない」という**嘘の合格**を出した。
    /// 重なりの順を知っているのは CoreGraphics だけ。
    /// ⚠️ 題名は読まない（画面収録の許可が要るうえ、ブラウザの題名は見ているページそのもの）。
    /// 番号と持ち主だけで足りる。
    private static func stackOrder() -> [(number: Int, pid: pid_t)] {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return []
        }
        return list.compactMap { entry in
            // 層が 0 でないもの（メニューバー・Dock・浮く窓）は数えない
            guard (entry[kCGWindowLayer as String] as? Int) == 0,
                  let number = entry[kCGWindowNumber as String] as? Int,
                  let pid = entry[kCGWindowOwnerPID as String] as? pid_t else { return nil }
            return (number: number, pid: pid)
        }
    }

    /// 相手の**いちばん奥の窓**より手前に、他のアプリの窓が何枚あるかを数える。
    ///
    /// ⚠️ この指標にした理由（測り方を2回間違えたので書いておく）。
    /// 正しい戻し方は「打っていた1枚だけを前に出す」。他の窓は動かないので、
    /// 奥の窓の手前にいる他アプリの窓の数は**変わらない**。
    /// 一方、アプリごと開き直すと窓が全部まとまって前に出るので、この数は**減る**。
    /// 実測（2026-08-23・Chrome 4枚）:
    ///   戻す前 Slack → Chrome×4 ／ 戻した後 Chrome×4 → Slack ＝ 1枚が0枚に
    ///
    /// ⚠️ 「相手の窓どうしの間に他アプリが挟まっているか」で測ろうとして2回失敗した。
    /// 窓が連続していると変化が出ず、不具合が起きているのに合格が出る
    private static func othersAheadOfBackmost(_ order: [(number: Int, pid: pid_t)], pid: pid_t) -> Int {
        guard let backmost = order.lastIndex(where: { $0.pid == pid }) else { return 0 }
        return order[..<backmost].filter { $0.pid != pid }.count
    }

    private static func pickTarget() -> (app: NSRunningApplication, count: Int)? {
        var best: (NSRunningApplication, Int)?
        for app in NSWorkspace.shared.runningApplications
        where app.activationPolicy == .regular
            && app.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            let element = AXUIElementCreateApplication(app.processIdentifier)
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, kAXWindowsAttribute as CFString, &value) == .success,
                  let list = value as? [AXUIElement], list.count >= 2 else { continue }
            // ブラウザで起きた話なので、見つかればそちらを優先する
            let isBrowser = (app.bundleIdentifier ?? "").contains("chrome")
                || (app.bundleIdentifier ?? "").contains("Safari")
                || (app.bundleIdentifier ?? "").contains("firefox")
            if isBrowser { return (app, list.count) }
            if best == nil || list.count > best!.1 { best = (app, list.count) }
        }
        return best.map { (app: $0.0, count: $0.1) }
    }

    /// 重なり順を、アプリ名の並びで出す（何が起きているかを目で見るため）
    private static func dumpOrder(_ label: String) {
        let names = stackOrder().prefix(12).map { window -> String in
            NSRunningApplication(processIdentifier: window.pid)?.localizedName ?? "?"
        }
        print("  [\(label)] \(names.joined(separator: " → "))")
    }

    private static func wait(_ seconds: TimeInterval) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }
}
