import AppKit
import TemotoCore
import Vision

/// 絵の中の文字を読む係。
///
/// ⚠️ なぜ入れたか（2026-07-30 作者の指摘「どんな画像かわかりにくい」）。
/// 履歴に絵が並ぶと、題名が「画像 912×592」「画像 574×1228」となって
/// どれがどれだか分からなかった。絵の中の文字が読めれば、それがそのまま題名になる。
///
/// おまけで、今まで塞げなかった穴が塞がる。
/// 絵の中の文字は誰にも読めなかったので、**画像には秘密の検知が効いていなかった**。
/// パスワードやカード番号を写したスクリーンショットが、そうと分からずに残っていた。
/// 文字が読めるようになれば、そこにも ClipboardGuard を通せる。
///
/// ⚠️ どこにも送らない。Apple の Vision をその場で呼ぶだけ（通信ゼロ）。
enum ImageTextReader {

    /// 一度に読みに行く上限（起動時の読み直し用）。
    /// 1枚あたり0.2〜0.4秒なので、10枚で数秒。裏で走らせるとはいえ電池は使う。
    static let catchUpLimit = 20

    /// 絵を読んで、文字を返す。文字が1つも無ければ空文字（＝「読んだが無かった」）。
    /// 読みに行けなかった（絵として開けない）ときだけ nil。
    static func read(png: Data) -> String? {
        guard let source = CGImageSourceCreateWithData(png as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }

        let request = VNRecognizeTextRequest()

        // ⚠️ `.fast` を使わない。**日本語を1行も返さない**。
        // 実測（2026-07-30・macOS 26.5.2）: 同じ日本語の画像で
        //   .fast     → 0行（132ms）
        //   .accurate → 7行（327ms）
        // `.fast` はラテン文字だけの速い経路で、日本語は黙って捨てられる。
        request.recognitionLevel = .accurate

        // ⚠️ 日本語を先に書く。順番は優先度で、後ろに置くと英語として読まれやすくなる。
        request.recognitionLanguages = ["ja-JP", "en-US"]
        request.usesLanguageCorrection = true

        do {
            try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        } catch {
            return nil
        }

        // ⚠️ 先に縮めない。実測では 5652×3042 をそのまま読んで274ms、
        // 長辺1600まで縮めても181msで、縮めて得するのは0.1秒ほどしかない。
        // 一方で細かい文字（表・注記）は縮めると読めなくなる。速さより正確さを取る。
        let lines = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
        return lines.joined(separator: "\n")
    }

    /// 裏で読んで、終わったら本筋（メインスレッド）に戻す。
    /// ⚠️ コピーした直後に呼ばれるので、ここで待つと貼り付けが0.3秒固まる。
    static func readInBackground(png: Data, completion: @escaping (String?) -> Void) {
        DispatchQueue.global(qos: .utility).async {
            let text = read(png: png)
            DispatchQueue.main.async { completion(text) }
        }
    }

    /// 読み取った文字を、履歴に書き戻せる形に判定する。
    ///
    /// ⚠️ 秘密が写っていたときは**文字を捨てて理由だけ残す**。
    /// 題名に出さないだけでなく、暗号化した履歴の中にも書かない。
    /// 絵そのものは消さない（誤検知で作者のスクリーンショットが黙って消える方がまずい）。
    /// 代わりに一覧へ ⚠️ を出して、消すかどうかは作者が決められるようにする。
    static func verdict(for raw: String, guardian: ClipboardGuard) -> Verdict {
        let text = ImageCaption.trimForStorage(raw)
        if text.isEmpty { return .noText }
        if let kind = guardian.detectSecretInImageText(text) { return .secret(kind.label) }
        return .text(text)
    }

    enum Verdict: Equatable {
        /// 文字が読めた
        case text(String)
        /// 絵に文字が無かった（写真・図）
        case noText
        /// 秘密が写っていた。文字は保存しない
        case secret(String)
    }
}
