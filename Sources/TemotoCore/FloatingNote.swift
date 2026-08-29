import Foundation

/// メモの1枚。中身は暗号化して保存する（`Store` が受け持つ）。

/// いつでも呼び出せる1枚のメモ。
/// 振込先や下書きが入りうるので、定型文と同じく暗号化して保存する。
public struct FloatingNote: Codable, Equatable, Sendable {
    public var text: String
    public var updatedAt: Date

    public init(text: String = "", updatedAt: Date = Date()) {
        self.text = text
        self.updatedAt = updatedAt
    }
}
