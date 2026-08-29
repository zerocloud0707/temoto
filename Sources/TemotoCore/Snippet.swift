import Foundation

/// 定型文（合言葉で呼び出して貼る文章）と、その差し込み（{date} など）。

public struct Snippet: Codable, Identifiable, Equatable, Sendable {
    public let id: UUID
    public var title: String
    public var keyword: String
    public var body: String

    public init(id: UUID = UUID(), title: String, keyword: String = "", body: String) {
        self.id = id
        self.title = title
        self.keyword = keyword
        self.body = body
    }
}

/// 定型文の差し込み。
/// 対応: {date} {date:書式} {time} {clipboard} {query}
public struct SnippetContext: Sendable {
    public var now: Date
    public var clipboard: String
    public var query: String

    public init(now: Date = Date(), clipboard: String = "", query: String = "") {
        self.now = now
        self.clipboard = clipboard
        self.query = query
    }
}

public enum SnippetExpander {
    public static func expand(_ body: String, context: SnippetContext, locale: Locale = Locale(identifier: "ja_JP")) -> String {
        var out = ""
        var rest = Substring(body)

        while let open = rest.firstIndex(of: "{") {
            out += rest[rest.startIndex..<open]
            guard let close = rest[open...].firstIndex(of: "}") else {
                out += rest[open...]
                return out
            }
            let token = String(rest[rest.index(after: open)..<close])
            out += replacement(for: token, context: context, locale: locale)
                ?? "{\(token)}"          // 知らない記法はそのまま残す
            rest = rest[rest.index(after: close)...]
        }
        out += rest
        return out
    }

    private static func replacement(for token: String, context: SnippetContext, locale: Locale) -> String? {
        if token == "clipboard" { return context.clipboard }
        if token == "query" { return context.query }
        if token == "date" { return formatted(context.now, "yyyy-MM-dd", locale) }
        if token == "time" { return formatted(context.now, "HH:mm", locale) }
        if token.hasPrefix("date:") {
            return formatted(context.now, String(token.dropFirst("date:".count)), locale)
        }
        return nil
    }

    private static func formatted(_ date: Date, _ format: String, _ locale: Locale) -> String {
        let f = DateFormatter()
        f.locale = locale
        f.timeZone = TimeZone.current
        f.dateFormat = format
        return f.string(from: date)
    }
}
