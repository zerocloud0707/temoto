import Foundation

/// 複数枚のメモ。
///
/// ⚠️ ここが存在する理由（2026-07-30 作者の依頼）。
/// 「保存ボタンが欲しい」「メモしたことを検索できる様に」「メモがリストに出る様に」
/// 「保存先を選択できる様に（md形式で所定のフォルダーに保存や、このアプリ上に保存など）」。
/// メモは1枚の走り書きから、一覧・検索・保存先を持つメモ帳になった。
///
/// 保存先は2つ:
/// - **このアプリの中** … 暗号化して notes.enc に置く（振込先など秘密を書いてよい）
/// - **フォルダ（.md）** … 作者が選んだフォルダに平文の .md で置く
///   （Obsidian や他の道具からも読める代わりに、**秘密を書いてはいけない**）
public struct Note: Codable, Identifiable, Equatable, Sendable {
    public let id: UUID
    public var body: String
    public var createdAt: Date
    public var updatedAt: Date

    public init(id: UUID = UUID(), body: String = "", createdAt: Date = Date(), updatedAt: Date = Date()) {
        self.id = id
        self.body = body
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    /// 古い notes.enc も読めるようにする（項目を足しても履歴が丸ごと消えないように。
    /// ClipImageInfo で実際に踏んだ地雷と同じ対策）。
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        body = try c.decodeIfPresent(String.self, forKey: .body) ?? ""
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt) ?? createdAt
    }
}

/// メモの文字まわりの決まり（題名・検索・ファイル名）。
public enum NoteText {

    public static let untitled = "無題のメモ"

    /// 一覧に出す題名 = 最初の空でない行。
    /// Markdown の見出し記号（# ）は飾りなので題名からは外す。
    public static func title(for body: String) -> String {
        for line in body.split(separator: "\n", omittingEmptySubsequences: false) {
            var t = line.trimmingCharacters(in: .whitespaces)
            while t.hasPrefix("#") { t.removeFirst() }
            t = t.trimmingCharacters(in: .whitespaces)
            if !t.isEmpty { return String(t.prefix(60)) }
        }
        return untitled
    }

    /// 検索。空白で区切った語が**全部**（題名か本文の）どこかに入っていれば当たり。
    /// 大文字小文字は区別しない。
    public static func matches(title: String, body: String, query: String) -> Bool {
        let haystack = (title + "\n" + body).lowercased()
        let tokens = query
            .replacingOccurrences(of: "　", with: " ")
            .split(separator: " ")
            .map { $0.lowercased() }
            .filter { !$0.isEmpty }
        guard !tokens.isEmpty else { return true }
        return tokens.allSatisfy { haystack.contains($0) }
    }

    /// .md のファイル名を作る。
    ///
    /// - 題名（最初の行）から作る。ファイル名に使えない文字は空白に置き換える
    /// - 既にある名前とぶつかったら「 2」「 3」と番号を足す（**上書きしない**。
    ///   同じ題名の別のメモで、先にあった .md を黙って潰すのが一番怖い）
    /// - 題名が無ければ fallback（「メモ 2026-07-30 1030」のような時刻）を使う
    public static func fileName(for body: String, existing: [String], fallback: String) -> String {
        var base = title(for: body)
        if base == untitled { base = fallback }

        var cleaned = ""
        for scalar in base.unicodeScalars {
            if scalar.value < 0x20 || "/:\\?%*|\"<>".unicodeScalars.contains(scalar) {
                cleaned.append(" ")
            } else {
                cleaned.append(Character(scalar))
            }
        }
        // 連続空白を畳んで前後を落とす。ドット始まりは不可視ファイルになるので外す
        cleaned = cleaned.split(separator: " ").joined(separator: " ")
        while cleaned.hasPrefix(".") { cleaned.removeFirst() }
        cleaned = String(cleaned.prefix(40)).trimmingCharacters(in: .whitespaces)
        if cleaned.isEmpty { cleaned = fallback }

        let taken = Set(existing.map { $0.lowercased() })
        var candidate = cleaned + ".md"
        var number = 2
        while taken.contains(candidate.lowercased()) {
            candidate = "\(cleaned) \(number).md"
            number += 1
        }
        return candidate
    }
}

/// 1枚の .md ファイルのメモ（フォルダ保存の方）。
public struct FolderNote: Equatable, Sendable, Identifiable {
    /// 「会議メモ.md」のようなファイル名（これが一覧の題名にもなる）
    public var fileName: String
    public var body: String
    public var modifiedAt: Date

    public var id: String { fileName }
    public var title: String {
        fileName.lowercased().hasSuffix(".md") ? String(fileName.dropLast(3)) : fileName
    }

    public init(fileName: String, body: String, modifiedAt: Date) {
        self.fileName = fileName
        self.body = body
        self.modifiedAt = modifiedAt
    }
}

/// フォルダ保存の読み書き。
///
/// ⚠️ 読むのは**フォルダ直下の .md だけ**（中のフォルダには潜らない）。
/// 日記のフォルダ等を指されても、数百枚で止まるように上限を切ってある。
/// 消すときは**必ずゴミ箱へ**（このアプリの誤作動でファイルが消滅した、を作らない）。
public enum NoteFolder {

    public static let maxFiles = 300
    public static let maxBytes = 512 * 1024

    /// フォルダ直下の .md を新しい順に読む
    public static func scan(_ folderPath: String) -> [FolderNote] {
        guard !folderPath.isEmpty else { return [] }
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: folderPath) else { return [] }

        var notes: [FolderNote] = []
        for name in names where name.lowercased().hasSuffix(".md") && !name.hasPrefix(".") {
            let path = folderPath + "/" + name
            guard let attributes = try? fm.attributesOfItem(atPath: path),
                  (attributes[.size] as? Int ?? 0) <= maxBytes,
                  let data = fm.contents(atPath: path),
                  let body = String(data: data, encoding: .utf8) else { continue }
            let modified = attributes[.modificationDate] as? Date ?? Date.distantPast
            notes.append(FolderNote(fileName: name, body: body, modifiedAt: modified))
            if notes.count >= maxFiles { break }
        }
        return notes.sorted { $0.modifiedAt > $1.modifiedAt }
    }

    /// 書き込む（同じ名前なら上書き＝自分のファイルを更新する道）
    @discardableResult
    public static func write(_ body: String, fileName: String, folderPath: String) -> Bool {
        guard !folderPath.isEmpty else { return false }
        let url = URL(fileURLWithPath: folderPath).appendingPathComponent(fileName)
        do {
            try Data(body.utf8).write(to: url, options: [.atomic])
            return true
        } catch {
            return false
        }
    }

    /// ゴミ箱へ移す（完全削除はしない）
    @discardableResult
    public static func trash(_ fileName: String, folderPath: String) -> Bool {
        guard !folderPath.isEmpty else { return false }
        let url = URL(fileURLWithPath: folderPath).appendingPathComponent(fileName)
        return (try? FileManager.default.trashItem(at: url, resultingItemURL: nil)) != nil
    }

    public static func existingNames(_ folderPath: String) -> [String] {
        guard !folderPath.isEmpty,
              let names = try? FileManager.default.contentsOfDirectory(atPath: folderPath) else { return [] }
        return names.filter { $0.lowercased().hasSuffix(".md") }
    }
}

/// 1枚時代のメモ（FloatingNote）からの引っ越しの決まり。
public enum NoteMigration {
    /// 複数枚がまだ無く、1枚時代の中身があるなら、それを最初の1枚にする。
    /// 既に複数枚があるなら何もしない（二重に増やさない）。
    public static func migrated(notes: [Note], legacyText: String, legacyDate: Date) -> [Note] {
        guard notes.isEmpty else { return notes }
        let trimmed = legacyText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return notes }
        return [Note(body: legacyText, createdAt: legacyDate, updatedAt: legacyDate)]
    }
}
