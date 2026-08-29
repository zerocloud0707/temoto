import Foundation

/// 自分で足したコマンドと、押したときにやること。

public struct CustomCommand: Codable, Identifiable, Equatable, Sendable {
    public let id: UUID
    public var title: String
    public var subtitle: String?
    public var action: CommandAction

    public init(id: UUID = UUID(), title: String, subtitle: String? = nil, action: CommandAction) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.action = action
    }
}

/// コマンドの実行内容。
///
/// セキュリティ上の約束: スクリプト実行は必ず「実行ファイルのパス + 引数の配列」で行い、
/// シェルに文字列を組み立てて渡すことは絶対にしない。
/// そのため {query} に何を入れられてもコマンド注入は成立しない（引数1個として渡るだけ）。
public enum CommandAction: Codable, Equatable, Sendable {
    case openPath(String)
    case openURL(String)
    case runScript(path: String, arguments: [String])

    public var kindLabel: String {
        switch self {
        case .openPath: return "フォルダ/ファイルを開く"
        case .openURL: return "リンクを開く"
        case .runScript: return "スクリプトを実行"
        }
    }

    /// {query}（ランチャーで入力した残りの語）と {today}（今日の日付）を差し替える。
    /// スクリプトはシェルを通さず引数の配列で渡すため、{query} に何を入れてもコマンド注入にならない。
    /// URLに差し込むときだけはURLエンコードする。
    public func resolved(query: String, now: Date = Date()) -> CommandAction {
        let today = CommandAction.todayString(now)
        switch self {
        case .runScript(let path, let args):
            return .runScript(path: CommandAction.expandTilde(path), arguments: args.map {
                $0.replacingOccurrences(of: "{query}", with: query)
                  .replacingOccurrences(of: "{today}", with: today)
            })
        case .openPath(let p):
            return .openPath(CommandAction.expandTilde(
                p.replacingOccurrences(of: "{query}", with: query)
                 .replacingOccurrences(of: "{today}", with: today)
            ))
        case .openURL(let u):
            return .openURL(
                u.replacingOccurrences(of: "{query}", with: URLQueryEscape.encode(query))
                 .replacingOccurrences(of: "{today}", with: today)
            )
        }
    }

    public var needsQuery: Bool {
        switch self {
        case .runScript(_, let args): return args.contains { $0.contains("{query}") }
        case .openPath(let p): return p.contains("{query}")
        case .openURL(let u): return u.contains("{query}")
        }
    }

    static func todayString(_ now: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ja_JP")
        f.timeZone = TimeZone.current
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: now)
    }

    static func expandTilde(_ path: String) -> String {
        path.hasPrefix("~") ? NSString(string: path).expandingTildeInPath : path
    }
}
