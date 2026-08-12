import CryptoKit
import Foundation

/// 保存層。
///
/// ファイルの置き場所: ~/Library/Application Support/Temoto/
///   settings.json    … 設定（秘密は入らないので平文。手で編集できることを優先）
///   quicklinks.json  … よく使うリンク（同上）
///   commands.json    … 自作コマンド（同上）
///   snippets.enc     … 定型文（振込先などが入りうるので暗号化）
///   clips.enc        … クリップボード履歴（暗号化）
///
/// 鍵が取り出せない場合は暗号化対象をディスクに書かない。平文に格下げはしない。
public final class Store {

    public let directory: URL
    public private(set) var vault: Vault?
    public private(set) var vaultProblem: String?

    public var settings: Settings = Settings()
    public var quicklinks: [Quicklink] = []
    public var commands: [CustomCommand] = []
    public var snippets: [Snippet] = []
    public var clips: [ClipItem] = []
    public var note: FloatingNote = FloatingNote()
    /// 複数枚のメモ（2026-07-30〜）。note は1枚時代の名残で、初回に notes へ引っ越す
    public var notes: [Note] = []

    /// 履歴を暗号化して保存できるか。false のときは起動中だけ覚えておく（終了で消える）。
    public var canPersistSecrets: Bool { vault != nil }

    private let vaultProvider: () throws -> Vault
    private let vaultRecreator: () throws -> Vault
    private let codeIdentity: () -> String?

    /// - Parameters:
    ///   - vaultProvider: 鍵の取り出し方。既定はキーチェーン。
    ///   - vaultRecreator: 鍵の作り直し方。既定はキーチェーン。
    ///   - codeIdentity: 今のビルドを表す文字列。既定はコード署名の cdhash。
    ///
    /// どれも差し替えられるようにしてあるのは、検証で本物のキーチェーンを触らないため。
    public init(
        directory: URL? = nil,
        vaultProvider: (() throws -> Vault)? = nil,
        vaultRecreator: (() throws -> Vault)? = nil,
        codeIdentity: (() -> String?)? = nil
    ) {
        self.directory = directory ?? Store.defaultDirectory()
        self.vaultProvider = vaultProvider ?? { Vault(key: try Vault.loadOrCreateKey()) }
        self.vaultRecreator = vaultRecreator ?? { Vault(key: try Vault.recreateKey()) }
        self.codeIdentity = codeIdentity ?? { Vault.currentCodeIdentity() }
    }

    public static func defaultDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("Temoto", isDirectory: true)
    }

    // MARK: - 読み込み

    /// 全部まとめて読む。検証・診断用。
    ///
    /// アプリ本体はこれを使わないこと。
    /// キーチェーンの許可ダイアログが出ると、答えるまでこの中で止まってしまう。
    /// アプリは loadPlaintext() → makeVault() → adoptVault() の順に分けて呼ぶ。
    @discardableResult
    public func load() -> Bool {
        let isFirstRun = loadPlaintext()
        adoptVault(makeVault())
        return isFirstRun
    }

    /// 鍵の要らないものだけ読む。ここは止まらないので、起動直後に呼んでよい。
    @discardableResult
    public func loadPlaintext() -> Bool {
        let isFirstRun = !FileManager.default.fileExists(atPath: directory.path)
        createDirectoryIfNeeded()

        settings = readJSON(Settings.self, from: "settings.json") ?? Settings()
        quicklinks = readJSON([Quicklink].self, from: "quicklinks.json") ?? []
        commands = readJSON([CustomCommand].self, from: "commands.json") ?? []

        // ファイルが無いときだけ初期値を入れる。
        // 「空だったら入れる」にすると、利用者が全部消したときに勝手に復活してしまう。
        if !fileExists("quicklinks.json") { seedQuicklinks() }
        if !fileExists("commands.json") { seedCommands() }
        // 設定は中身を変えていなくても書き出しておく。
        // ファイルがあれば利用者が直接開いて直せる（ショートカットの変更など）。
        if !fileExists("settings.json") { saveSettings() }
        return isFirstRun
    }

    /// 鍵を取り出す。キーチェーンの許可ダイアログでここが止まりうるので、
    /// メインスレッド以外から呼ぶこと（止まっても画面は動き続ける）。
    /// この関数は自分の中身を一切書き換えないので、別スレッドから呼んで安全。
    public func makeVault() -> Result<Vault, Error> {
        Result { try vaultProvider() }
    }

    // MARK: - 鍵の持ち主

    /// 鍵を作ったビルドを控えておくファイル。
    /// 中身はコード署名の cdhash だけで、秘密は入らないので平文でよい。
    private static let ownerFile = "key-owner.txt"

    public enum VaultPlan: Equatable {
        /// 自分が作った鍵なので、そのまま読んでよい（ダイアログは出ない）
        case readOurs
        /// 別のビルドが作った鍵か、持ち主が分からない。読みに行かず作り直す
        case recreate
    }

    /// 鍵を読みに行ってよいか決める。
    ///
    /// なぜ要るか:
    /// アプリを作り直すと署名が変わり、macOSは前のビルドが作った鍵を「他人のもの」と見なす。
    /// 読もうとすると許可ダイアログが出るが、これはキーチェーンのパスワードを求めてきて、
    /// 作者の環境では答えられなかった。しかも一度出ると答えるまで消えない。
    ///
    /// 「出てから対処する」ことはできないので、出る前に避ける。
    /// 鍵を作ったときに控えた cdhash と今の cdhash を比べれば、
    /// キーチェーンに一度も触らずに自分のものか判断できる。
    ///
    /// 控えが無いときは「読みに行かない」側に倒す。
    /// 読んで確かめようとすると、それ自体がダイアログを呼ぶため。
    public func planForVault() -> VaultPlan {
        guard let identity = codeIdentity(),
              let recorded = try? String(contentsOf: url(Store.ownerFile), encoding: .utf8)
        else { return .recreate }
        return recorded.trimmingCharacters(in: .whitespacesAndNewlines) == identity ? .readOurs : .recreate
    }

    private func recordVaultOwner() {
        guard let identity = codeIdentity() else { return }
        writeAtomically(Data(identity.utf8), to: url(Store.ownerFile))
    }

    /// 取り出した鍵を受け取り、暗号化してあるものを読む。必ずメインスレッドで呼ぶこと。
    public func adoptVault(_ result: Result<Vault, Error>) {
        switch result {
        case .success(let v):
            vault = v
            vaultProblem = nil
            // 次に起動したとき、この鍵が自分のものだと分かるように控える
            recordVaultOwner()
        case .failure(let error):
            vault = nil
            if case VaultError.keychainUnavailable(let status) = error {
                vaultProblem = "キーチェーンから鍵を取り出せませんでした（\(Store.explain(status))）。"
                    + "履歴・定型文・メモはディスクに保存せず、起動中だけ保持します。"
            } else {
                vaultProblem = "暗号鍵を用意できませんでした。履歴・定型文・メモはディスクに保存しません。"
            }
        }

        snippets = readEncrypted([Snippet].self, from: "snippets.enc") ?? []
        clips = readEncrypted([ClipItem].self, from: "clips.enc") ?? []
        note = readEncrypted(FloatingNote.self, from: "note.enc") ?? FloatingNote()
        notes = readEncrypted([Note].self, from: "notes.enc") ?? []

        // 1枚時代のメモ（note.enc）しか無ければ、それを最初の1枚にする。
        // 引っ越しの決まりは NoteMigration（検証済み）。note.enc は消さず残す。
        let migrated = NoteMigration.migrated(notes: notes, legacyText: note.text, legacyDate: note.updatedAt)
        if migrated.count != notes.count {
            notes = migrated
            if vault != nil { saveNotes() }
        }

        // 鍵が開けたときだけ初期値を入れる。開けないまま入れると保存できず、毎回消える。
        if vault != nil && !fileExists("snippets.enc") { seedSnippets() }
    }

    /// 鍵を取り直したときに呼ぶ。
    ///
    /// 鍵が取れなかった間も、コピーしたものはメモリには貯まっている（保存できないだけ）。
    /// ここで普通に読み直すと、その分がディスクの中身で上書きされて消えてしまう。
    /// なので、ディスクから読んだあとに、メモリ側にしか無いものを足し直して保存する。
    public func adoptVaultKeepingMemory(_ result: Result<Vault, Error>) {
        let pendingClips = clips
        let pendingNote = note
        let pendingNotes = notes

        adoptVault(result)
        guard vault != nil else {
            // 取り直しも失敗。メモリの中身は捨てずに戻す（次の機会にまだ救える）。
            clips = pendingClips
            note = pendingNote
            return
        }

        var known = Set(clips.map(\.id))
        let onlyInMemory = pendingClips.filter { known.insert($0.id).inserted }
        if !onlyInMemory.isEmpty {
            clips = (onlyInMemory + clips).sorted { $0.copiedAt > $1.copiedAt }
            clips = ClipRetention.prune(clips,
                                        maxCount: settings.clipboard.maxCount,
                                        maxAgeDays: settings.clipboard.maxAgeDays,
                                        maxImageCount: settings.clipboard.maxImageCount)
            saveClips()
        }

        // 鍵が無い間に拾った絵はメモリにしか無い。鍵が来たので今のうちにディスクへ移す
        // （移せなければメモリに残るだけなので、失っても起動中は使える）。
        let held = memoryClipImages
        let alive = Set(clips.filter { $0.kind == .image }.map(\.id))
        for (id, images) in held where alive.contains(id) {
            memoryClipImages[id] = nil
            saveClipImage(id: id, original: images.original, thumbnail: images.thumbnail)
        }

        // メモに書いた方が新しければ、そちらを残す
        if pendingNote.updatedAt > note.updatedAt && !pendingNote.text.isEmpty {
            note = pendingNote
            saveNote()
        }

        // 鍵が無い間に書いたメモ（メモリにしか無い分）を足し直す。同じ id は新しい方を残す
        var mergedNotes = notes
        for pending in pendingNotes {
            if let index = mergedNotes.firstIndex(where: { $0.id == pending.id }) {
                if pending.updatedAt > mergedNotes[index].updatedAt { mergedNotes[index] = pending }
            } else {
                mergedNotes.append(pending)
            }
        }
        if mergedNotes != notes {
            notes = mergedNotes
            saveNotes()
        }
    }

    /// キーチェーンのエラー番号に、人が読んで分かる説明を添える。
    private static func explain(_ status: Int32) -> String {
        switch status {
        case -128:
            return "OSStatus -128・許可されませんでした。"
                + "アプリを作り直すと署名が変わり、macOSが前のビルドの鍵を「他人のもの」と見なします。"
                + "メニューの「暗号鍵を作り直す」で直せます"
        case -25300: return "OSStatus -25300・鍵が見つかりません"
        case -25308: return "OSStatus -25308・キーチェーンがロックされています（画面ロックを解除してください）"
        case -25293: return "OSStatus -25293・認証に失敗しました"
        case -25244: return "OSStatus -25244・前のビルドが作った鍵なので触れません"
        default: return "OSStatus \(status)"
        }
    }

    // MARK: - 作り直しのときの引き継ぎ

    /// 鍵を作り直す前に取り出しておく中身。
    ///
    /// クリップボード履歴（clips）はわざと入れていない。
    /// 履歴にはパスワードやトークンがそのまま入りうるので、
    /// 一瞬でも平文でファイルに置きたくない。履歴は作り直しのたびに空から始める。
    /// 定型文とメモは作者が自分で書いたもので、消えると困る方なので引き継ぐ。
    public struct SecretsBackup: Codable, Sendable {
        public var snippets: [Snippet]
        public var note: FloatingNote
        /// 複数枚のメモ。古い引き継ぎファイルには無いので「無ければ空」で読む
        public var notes: [Note]

        public init(snippets: [Snippet], note: FloatingNote, notes: [Note] = []) {
            self.snippets = snippets
            self.note = note
            self.notes = notes
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            snippets = try c.decodeIfPresent([Snippet].self, forKey: .snippets) ?? []
            note = try c.decodeIfPresent(FloatingNote.self, forKey: .note) ?? FloatingNote()
            notes = try c.decodeIfPresent([Note].self, forKey: .notes) ?? []
        }
    }

    /// 定型文の「中身が同じか」を見るための文字列。
    /// 区切りに \0 を使うのは、題名と本文の境目を文字でごまかせないようにするため。
    private static func contentKey(_ s: Snippet) -> String {
        "\(s.title)\u{0}\(s.keyword)\u{0}\(s.body)"
    }

    /// 引き継ぐ中身を取り出す。鍵が開けていなければ nil（取り出しようがない）。
    public func exportSecrets() -> SecretsBackup? {
        guard vault != nil else { return nil }
        return SecretsBackup(snippets: snippets, note: note, notes: notes)
    }

    /// 引き継いだ中身を今の鍵で書き直す。
    ///
    /// 上書きではなく足し算にしてある。
    /// 作り直した直後は初期の定型文が入っているので、
    /// 単純に上書きすると引き継ぎ側に無いものが消える。
    public func importSecrets(_ backup: SecretsBackup) {
        guard vault != nil else { return }

        var merged = backup.snippets
        var knownIDs = Set(merged.map(\.id))
        // 中身が同じものも「既にある」と見なす。
        //
        // なぜ id だけで見てはいけないか:
        // 鍵を作り直した直後は初期の定型文が入るが、その id はその場で作られる。
        // 引き継ぎ側にも同じ初期の定型文が入っていて、そちらは前の id を持っている。
        // id だけで比べると別物に見えるので、同じ文面が2つ並んでしまう。
        var knownContent = Set(merged.map(Store.contentKey))
        for existing in snippets {
            let newID = knownIDs.insert(existing.id).inserted
            let newContent = knownContent.insert(Store.contentKey(existing)).inserted
            guard newID && newContent else { continue }
            merged.append(existing)
        }
        snippets = merged
        saveSnippets()

        // メモは新しい方を残す。
        //
        // ⚠️ 日付だけで比べてはいけない。
        // 空のメモは「作られた時刻」が入る（FloatingNote() の既定が Date()）。
        // 作り直した直後の空メモは必ず引き継ぎ側より新しくなるので、
        // 日付だけで比べると引き継いだメモが毎回負けて、黙って消える。
        // 空のメモには失うものが無いので、中身がある方を優先する。
        // 複数枚のメモも同じ理屈で足し算にする（id と中身の両方で「既にある」を見る）
        var mergedNotes = backup.notes
        var knownNoteIDs = Set(mergedNotes.map(\.id))
        var knownBodies = Set(mergedNotes.map(\.body))
        for existing in notes {
            let newID = knownNoteIDs.insert(existing.id).inserted
            let newBody = knownBodies.insert(existing.body).inserted
            guard newID && newBody else { continue }
            mergedNotes.append(existing)
        }
        // 引き継ぎ側が1枚時代（notes が空で note に中身）なら、ここで1枚にして運ぶ
        mergedNotes = NoteMigration.migrated(notes: mergedNotes,
                                             legacyText: backup.note.text,
                                             legacyDate: backup.note.updatedAt)
        if !mergedNotes.isEmpty {
            notes = mergedNotes
            saveNotes()
        }

        guard !backup.note.text.isEmpty else { return }
        if note.text.isEmpty || backup.note.updatedAt >= note.updatedAt {
            note = backup.note
            saveNote()
        }
    }

    /// 鍵を作り直して、今メモリにある中身をその鍵で保存し直す。
    ///
    /// 作り直したビルドは前のビルドの鍵を読めない（許可ダイアログがパスワードを求めてくる）。
    /// 読めない鍵は捨てて新しく作れば、ダイアログは一度も出ない。
    /// 前の .enc は消さずに .broken へ退避される。
    @discardableResult
    public func recreateVault() -> Bool {
        do {
            vault = try vaultRecreator()
            vaultProblem = nil
            recordVaultOwner()

            // ⚠️ここの順番が大事。
            // 新しい鍵では前のファイルを開けない。
            // 先に保存してしまうと、開けないファイルを空の中身で上書きして消してしまう。
            // 上書きする前に脇へよける（消さずに .broken として残す）。
            quarantineUnreadableEncrypted()

            // ⚠️ 絵は新しい鍵では開けない＝貼り付けようがない。
            // 行だけ残しても「押しても何も出てこない履歴」になるので、画像の行は落とす。
            // 絵のファイルそのものは消さずに脇へよける（他の .enc と同じ扱い）。
            if clips.contains(where: { $0.kind == .image }) {
                clips.removeAll { $0.kind == .image }
            }
            quarantineClipImages()

            // メモリにある分を新しい鍵で書き直す
            saveSnippets()
            saveClips()
            saveNote()
            saveNotes()
            if snippets.isEmpty { seedSnippets() }
            return true
        } catch {
            vault = nil
            if case VaultError.keychainUnavailable(let status) = error {
                vaultProblem = "暗号鍵を作り直せませんでした（\(Store.explain(status))）。"
            } else {
                vaultProblem = "暗号鍵を作り直せませんでした。"
            }
            return false
        }
    }

    /// 今の鍵で開けない .enc を脇へよける。上書きで消してしまう前に呼ぶ。
    private func quarantineUnreadableEncrypted() {
        guard let vault else { return }
        var moved: [String] = []
        for name in ["snippets.enc", "clips.enc", "note.enc", "notes.enc"] {
            guard let blob = try? Data(contentsOf: url(name)) else { continue }
            guard (try? vault.open(blob)) == nil else { continue }
            if quarantine(name) { moved.append(name) }
        }
        if !moved.isEmpty {
            vaultProblem = nil   // 問題ではなく想定どおりの引っ越しなので、警告としては出さない
            NSLog("[Temoto] 前の鍵で書いたファイルを退避しました: \(moved.joined(separator: ", "))")
        }
    }

    /// 前の鍵で書いた絵のフォルダを丸ごと脇へよける。
    /// 中身は開けないが、「既存データを消さない」に合わせて消さずに残す。
    private func quarantineClipImages() {
        let fm = FileManager.default
        guard fm.fileExists(atPath: clipImageDirectory.path) else { return }
        var destination = directory.appendingPathComponent("clip-images.broken")
        var suffix = 2
        while fm.fileExists(atPath: destination.path) {
            destination = directory.appendingPathComponent("clip-images.broken.\(suffix)")
            suffix += 1
            if suffix > 50 { return }
        }
        try? fm.moveItem(at: clipImageDirectory, to: destination)
    }

    // MARK: - 画像の実体

    /// 絵を置くフォルダ。1件1ファイルで、それぞれ暗号化してある。
    ///
    /// なぜ clips.enc に混ぜないか:
    /// clips.enc は「全件を1つの封筒に入れて毎回まるごと書き直す」作り。
    /// 絵を混ぜると、1回コピーするたびに過去の絵まで全部暗号化して書き直すことになり、
    /// 履歴が育つほど1回のコピーが重くなる。絵は変わった分だけ書く。
    public var clipImageDirectory: URL {
        directory.appendingPathComponent("clip-images", isDirectory: true)
    }

    /// 鍵が無いときの置き場（起動中だけ）。
    /// 鍵が無ければディスクには書かない方針なので、絵も同じ扱いにする。
    private var memoryClipImages: [UUID: (original: Data, thumbnail: Data)] = [:]

    private func clipImageURL(_ id: UUID, thumbnail: Bool) -> URL {
        clipImageDirectory.appendingPathComponent("\(id.uuidString)\(thumbnail ? ".thumb" : "").enc")
    }

    /// 絵を1件しまう。
    /// - Returns: ディスクに書けたら true。鍵が無いときは false（起動中だけメモリに持つ）。
    @discardableResult
    public func saveClipImage(id: UUID, original: Data, thumbnail: Data) -> Bool {
        guard let vault else {
            memoryClipImages[id] = (original, thumbnail)
            return false
        }
        guard let sealedOriginal = try? vault.seal(original),
              let sealedThumbnail = try? vault.seal(thumbnail) else { return false }
        try? FileManager.default.createDirectory(
            at: clipImageDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        writeAtomically(sealedOriginal, to: clipImageURL(id, thumbnail: false))
        writeAtomically(sealedThumbnail, to: clipImageURL(id, thumbnail: true))
        return true
    }

    public func loadClipImage(id: UUID) -> Data? { readClipImage(id: id, thumbnail: false) }
    public func loadClipThumbnail(id: UUID) -> Data? { readClipImage(id: id, thumbnail: true) }

    private func readClipImage(id: UUID, thumbnail: Bool) -> Data? {
        if let held = memoryClipImages[id] { return thumbnail ? held.thumbnail : held.original }
        guard let vault, let blob = try? Data(contentsOf: clipImageURL(id, thumbnail: thumbnail)) else { return nil }
        return try? vault.open(blob)
    }

    /// 履歴から消えた絵を片付ける。
    ///
    /// ⚠️ ここだけは「消さない」の例外。
    /// 履歴から消したのにディスクに絵が残り続ける方が、消したつもりが消えていない＝危ない。
    /// 消すのは自分が作ったサムネイル／複製だけで、元のファイルには触れない。
    public func pruneClipImages() {
        let alive = Set(clips.filter { $0.kind == .image }.map(\.id))
        memoryClipImages = memoryClipImages.filter { alive.contains($0.key) }

        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: clipImageDirectory.path) else { return }
        for name in names {
            let base = name
                .replacingOccurrences(of: ".thumb.enc", with: "")
                .replacingOccurrences(of: ".enc", with: "")
            guard let id = UUID(uuidString: base), !alive.contains(id) else { continue }
            try? fm.removeItem(at: clipImageDirectory.appendingPathComponent(name))
        }
    }

    /// 1件だけ消す（履歴から1行消したとき）
    public func deleteClipImage(id: UUID) {
        memoryClipImages[id] = nil
        try? FileManager.default.removeItem(at: clipImageURL(id, thumbnail: false))
        try? FileManager.default.removeItem(at: clipImageURL(id, thumbnail: true))
    }

    /// 絵を全部消す（「コピー履歴をすべて消す」から呼ぶ）
    public func deleteAllClipImages() {
        memoryClipImages.removeAll()
        try? FileManager.default.removeItem(at: clipImageDirectory)
    }

    private func fileExists(_ name: String) -> Bool {
        FileManager.default.fileExists(atPath: url(name).path)
    }

    /// 暗号化して保存したファイルが1つでもあるか。
    ///
    /// 鍵を作り直すとき、「前に書いた分が読めなくなります」と知らせるかどうかの判断に使う。
    /// 初回起動（まだ何も書いていない）で余計な警告を出さないため。
    public var hasEncryptedFiles: Bool {
        ["snippets.enc", "clips.enc", "note.enc", "notes.enc"].contains { fileExists($0) }
    }

    private func createDirectoryIfNeeded() {
        try? FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            // 本人以外読めないようにする
            attributes: [.posixPermissions: 0o700]
        )
    }

    // MARK: - 保存

    public func saveSettings() { writeJSON(settings, to: "settings.json") }
    @discardableResult
    public func saveQuicklinks() -> Bool { writeJSON(quicklinks, to: "quicklinks.json") }
    public func saveCommands() { writeJSON(commands, to: "commands.json") }
    @discardableResult
    public func saveSnippets() -> Bool { writeEncrypted(snippets, to: "snippets.enc") }
    public func saveClips() { writeEncrypted(clips, to: "clips.enc") }
    public func saveNote() { writeEncrypted(note, to: "note.enc") }
    public func saveNotes() { writeEncrypted(notes, to: "notes.enc") }

    public func saveAll() {
        saveSettings(); saveQuicklinks(); saveCommands(); saveSnippets(); saveClips(); saveNote(); saveNotes()
    }

    // MARK: - 入出力

    private func url(_ name: String) -> URL { directory.appendingPathComponent(name) }

    private func readJSON<T: Decodable>(_ type: T.Type, from name: String) -> T? {
        guard let data = try? Data(contentsOf: url(name)) else { return nil }
        return try? JSONDecoder.temoto.decode(type, from: data)
    }

    @discardableResult
    private func writeJSON<T: Encodable>(_ value: T, to name: String) -> Bool {
        guard let data = try? JSONEncoder.temoto.encode(value) else { return false }
        return writeAtomically(data, to: url(name))
    }

    private func readEncrypted<T: Decodable>(_ type: T.Type, from name: String) -> T? {
        guard let vault, let blob = try? Data(contentsOf: url(name)) else { return nil }

        // 鍵が変わった等で開けないことがある（キーチェーンを消した・別のMacから移した・バックアップから戻した）。
        // ここで消してしまうと、あとで正しい鍵が戻ってきても二度と読めない。
        // 消さずに脇へよけて、新しい方だけを使う。よけたファイルは自分で消すまで残る。
        guard let plain = try? vault.open(blob) else {
            let saved = quarantine(name)
            vaultProblem = saved
                ? "\(name) を今の鍵では開けませんでした。消さずに \(name).broken として残してあります（正しい鍵が戻れば読めます）。今回は空から始めます。"
                : "\(name) を今の鍵では開けませんでした。今回は空から始めます。"
            return nil
        }
        return try? JSONDecoder.temoto.decode(type, from: plain)
    }

    /// 読めなかったファイルを消さずに脇へよける。
    /// 同名が既にあれば連番を足す（前によけた分を上書きしないため）。
    private func quarantine(_ name: String) -> Bool {
        let source = url(name)
        let fm = FileManager.default
        var destination = url("\(name).broken")
        var suffix = 2
        while fm.fileExists(atPath: destination.path) {
            destination = url("\(name).broken.\(suffix)")
            suffix += 1
            if suffix > 50 { return false }   // 際限なく増やさない
        }
        do {
            try fm.moveItem(at: source, to: destination)
            try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
            return true
        } catch {
            NSLog("[Temoto] 退避に失敗: \(name) \(error.localizedDescription)")
            return false
        }
    }

    /// 書けたかどうかを返す。
    /// ⚠️ 黙って false を返して終わらせない。呼ぶ側は必ず結果を見て、
    /// 書けていないなら「保存しました」と言わないこと
    /// （2026-07-31「保存を押しても保存されない」＝失敗が誰にも見えないのが一番困る）。
    @discardableResult
    private func writeEncrypted<T: Encodable>(_ value: T, to name: String) -> Bool {
        guard let vault else { return false }          // 鍵が無ければ書かない
        guard let plain = try? JSONEncoder.temoto.encode(value),
              let sealed = try? vault.seal(plain) else { return false }
        return writeAtomically(sealed, to: url(name))
    }

    @discardableResult
    private func writeAtomically(_ data: Data, to fileURL: URL) -> Bool {
        do {
            try data.write(to: fileURL, options: [.atomic])
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
            return true
        } catch {
            NSLog("[Temoto] 保存に失敗: \(fileURL.lastPathComponent) \(error.localizedDescription)")
            return false
        }
    }

    // MARK: - 初回の中身

    // 初期データは3つに分けてある。
    // ファイルが1つも無いときだけそれぞれ入れるので、
    // 「リンクは自分で作り直したが定型文はまだ」といった中途半端な状態でも、
    // 消したものが勝手に戻ってくることはない。

    /// 初期リンク。誰のMacでも意味のあるものだけ（全部あとから編集・削除できる）。
    ///
    /// ⚠️ 2026-08-02 リリース準備で一般化した。それまでの初期データには
    /// 顧問先の実名・個人のGitHub・作業ログのスクリプトが入っていて、
    /// 配布すると全員に配られてしまう（守秘義務の問題）。
    /// 固有のものは初期値ではなく、それぞれの人が自分で足す。
    private func seedQuicklinks() {
        quicklinks = [
            Quicklink(title: "Google検索", url: "https://www.google.com/search?q={query}"),
            Quicklink(title: "Googleマップで探す", url: "https://www.google.com/maps/search/{query}"),
            Quicklink(title: "YouTube検索", url: "https://www.youtube.com/results?search_query={query}"),
        ]
        saveQuicklinks()
    }

    /// 初期コマンド。よく開くフォルダ（どのMacにもあるもの）だけ。
    private func seedCommands() {
        let home = NSHomeDirectory()
        let folders: [(String, String)] = [
            ("書類フォルダを開く", "\(home)/Documents"),
            ("ダウンロードフォルダを開く", "\(home)/Downloads"),
            ("デスクトップを開く", "\(home)/Desktop"),
        ]
        commands = folders.map {
            CustomCommand(title: $0.0, subtitle: $0.1, action: .openPath($0.1))
        }
        saveCommands()
    }

    /// 定型文。ここだけ暗号化して保存するので、鍵が開けたときにしか入れない。
    private func seedSnippets() {
        snippets = [
            Snippet(title: "今日の日付", keyword: "きょう", body: "{date}"),
            Snippet(title: "日付（和暦なしスラッシュ）", keyword: "ひづけ", body: "{date:yyyy/MM/dd}"),
            Snippet(title: "メール書き出し", keyword: "おせわ", body: "いつも大変お世話になっております。\n株式会社サンプル商事の山田です。\n"),
            Snippet(title: "メール結び", keyword: "むすび", body: "お手数をおかけしますが、何卒よろしくお願いいたします。"),
        ]
        saveSnippets()
    }
}

extension JSONEncoder {
    public static var temoto: JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        e.dateEncodingStrategy = .iso8601
        return e
    }
}

extension JSONDecoder {
    public static var temoto: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }
}
