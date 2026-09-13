import Foundation

/// Local, offline text transforms applied to the Mac's current
/// selection. No cloud, no LLM — just deterministic formatting, so a
/// spoken "make this uppercase" works with the same privacy promise as
/// the rest of iBridge.
public enum IBTextCommand: String, Codable, Sendable, CaseIterable {
    case uppercase
    case lowercase
    case capitalize
    case trimWhitespace
    case stripNewlines
    case bulletList
}

public enum TextTransform {
    public static func apply(_ command: IBTextCommand, to text: String) -> String {
        switch command {
        case .uppercase:
            return text.uppercased()
        case .lowercase:
            return text.lowercased()
        case .capitalize:
            return text.capitalized
        case .trimWhitespace:
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        case .stripNewlines:
            return text
                .components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
                .joined(separator: " ")
        case .bulletList:
            return text
                .components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
                .map { "• \($0)" }
                .joined(separator: "\n")
        }
    }
}

/// iPhone → Mac: transform the Mac's current selection (kind 0x14).
public struct IBTextCommandMessage: Codable, Sendable, Equatable {
    public let command: IBTextCommand
    public init(command: IBTextCommand) { self.command = command }
}
